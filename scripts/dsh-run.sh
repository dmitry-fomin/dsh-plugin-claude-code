#!/usr/bin/env bash
# dsh-run.sh — единая точка запуска DeepSeek Harness (dsh) из Claude Code.
#
#   dsh-run.sh check [--json]
#   dsh-run.sh run [опции] < prompt.txt
#   dsh-run.sh status [job-id]
#   dsh-run.sh result <job-id>
#   dsh-run.sh transcript [job-id]
#
# Инвариант, на котором держится вся обвязка: в stdout подкоманды `run`
# попадает РОВНО финальный ответ dsh и ничего больше. Всё служебное —
# прогресс, диагностика, ошибки запуска — идёт в stderr или в лог джобы.
# Вызывающий может отдавать stdout пользователю дословно.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${DSH_CLAUDE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsh-claude}"
JOBS_DIR="$STATE_DIR/jobs"
DSH_HOME_DIR="${DSH_HOME:-$HOME/.dsh}"
DEFAULT_TIMEOUT=600

# Пути, которые надо убрать при любом выходе. die() уходит через exit, поэтому
# уборка в конце функции недостижима — только trap.
CLEANUP_PATHS=()
cleanup() {
  local rc=$?
  [[ ${#CLEANUP_PATHS[@]} -eq 0 ]] || rm -rf "${CLEANUP_PATHS[@]}"
  exit "$rc"
}
trap cleanup EXIT

# Значение поля meta: ключи разбираем по ПЕРВОМУ "=", иначе путь со знаком
# равенства в имени обрезается на нём.
meta_get() {
  local key="$1" file="$2"
  awk -v k="$key" 'index($0, k "=")==1 { print substr($0, length(k)+2); exit }' "$file"
}

# Экранирование значения для строки JSON.
json_escape() {
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  printf '%s' "$v"
}

die() {
  local code="$1"; shift
  echo "error: $*" >&2
  exit "$code"
}

usage() {
  cat >&2 <<'USAGE'
usage:
  dsh-run.sh check [--json]
  dsh-run.sh run [--write] [--model pro|flash|vision|<имя>] [--effort <level>]
                 [--cwd <dir>] [--timeout <сек>] [--background] < prompt.txt
  dsh-run.sh status [job-id]
  dsh-run.sh result <job-id>
  dsh-run.sh transcript [job-id]
USAGE
  exit 2
}

# --- поиск бинаря -----------------------------------------------------------
# Порядок: явный DSH_BIN → PATH. Абсолютный путь важен для фоновых запусков:
# отвязанный процесс не наследует изменения PATH, сделанные после старта.
resolve_dsh() {
  local bin="${DSH_BIN:-}"
  if [[ -n "$bin" ]]; then
    command -v "$bin" >/dev/null 2>&1 || die 2 "DSH_BIN указывает на '$bin', но такого исполняемого файла нет"
    command -v "$bin"
    return 0
  fi
  command -v dsh >/dev/null 2>&1 \
    || die 2 "dsh не найден в PATH — установи DeepSeek Harness или укажи путь через переменную DSH_BIN"
  command -v dsh
}

pick_timeout_bin() {
  # coreutils timeout не гарантирован на macOS. Без него запускаем без лимита:
  # у foreground-вызова лимит всё равно ставит вызывающий Bash-инструмент.
  if command -v timeout >/dev/null 2>&1; then echo timeout
  elif command -v gtimeout >/dev/null 2>&1; then echo gtimeout
  else echo ""; fi
}

# --- check ------------------------------------------------------------------
cmd_check() {
  local as_json=0
  [[ "${1:-}" == "--json" ]] && as_json=1

  local bin="" bin_status="missing" version="" model="" provider="" effort="" auth="unknown"
  if [[ -n "${DSH_BIN:-}" ]] && command -v "${DSH_BIN}" >/dev/null 2>&1; then
    bin="$(command -v "${DSH_BIN}")"
  elif command -v dsh >/dev/null 2>&1; then
    bin="$(command -v dsh)"
  fi

  if [[ -n "$bin" ]]; then
    if version="$("$bin" --version 2>/dev/null)"; then
      bin_status="ok"
    else
      bin_status="broken"
      version=""
    fi
  fi

  # Модель читаем из user-слоя настроек: именно он перекрывает всё остальное,
  # включая --patch overlay (проверено вживую — см. SKILL.md).
  local settings="$DSH_HOME_DIR/settings.yaml"
  if [[ -f "$settings" ]]; then
    model="$(awk '/^agent-default-model:/{f=1;next} f&&/^[^ ]/{f=0} f&&/^[[:space:]]*model:/{gsub(/^[[:space:]]*model:[[:space:]]*/,"");print;exit}' "$settings")"
    provider="$(awk '/^agent-default-model:/{f=1;next} f&&/^[^ ]/{f=0} f&&/^[[:space:]]*provider:/{gsub(/^[[:space:]]*provider:[[:space:]]*/,"");print;exit}' "$settings")"
    effort="$(awk '/^agent-default-model:/{f=1;next} f&&/^[^ ]/{f=0} f&&/^[[:space:]]*reasoningEffort:/{gsub(/^[[:space:]]*reasoningEffort:[[:space:]]*/,"");print;exit}' "$settings")"
  fi

  # Признак выполненного входа: локальное хранилище учётных данных харнесса.
  # Содержимое не читаем и наружу не отдаём — только факт существования.
  if [[ -s "$DSH_HOME_DIR/credentials.json" ]] || [[ -d "$DSH_HOME_DIR/storages" && -n "$(ls -A "$DSH_HOME_DIR/storages" 2>/dev/null)" ]]; then
    auth="present"
  else
    auth="absent"
  fi

  local profiles=""
  if [[ -d "$DSH_HOME_DIR/profiles" ]]; then
    profiles="$(ls "$DSH_HOME_DIR/profiles" 2>/dev/null | grep -v '^node_modules$' | paste -sd, - || true)"
  fi

  local ready="no"
  [[ "$bin_status" == "ok" && "$profiles" == *headless* ]] && ready="yes"

  if [[ $as_json -eq 1 ]]; then
    printf '{"ready":"%s","binary":"%s","binary_status":"%s","version":"%s","profiles":"%s","provider":"%s","model":"%s","effort":"%s","credentials":"%s","dsh_home":"%s"}\n' \
      "$(json_escape "$ready")" "$(json_escape "$bin")" "$(json_escape "$bin_status")" \
      "$(json_escape "$version")" "$(json_escape "$profiles")" "$(json_escape "$provider")" \
      "$(json_escape "$model")" "$(json_escape "$effort")" "$(json_escape "$auth")" \
      "$(json_escape "$DSH_HOME_DIR")"
  else
    echo "готовность:   $ready"
    echo "бинарь:       ${bin:-не найден} ($bin_status)"
    echo "версия:       ${version:-—}"
    echo "профили:      ${profiles:-—}"
    echo "модель:       ${provider:-—} / ${model:-—} (effort: ${effort:-—})"
    echo "учётные данные: $auth"
    echo "DSH_HOME:     $DSH_HOME_DIR"
  fi
  [[ "$ready" == "yes" ]] || exit 1
}

# --- сборка overlay для выбора модели --------------------------------------
# `--patch` НЕ переопределяет модель: user-слой settings.yaml накладывается
# поверх любого overlay. Рабочий обход — подменить сам путь, из которого
# settings-плагин читает документ (проверено: так поднимается deepseek-v4-pro).
write_model_overlay() {
  local model="$1" effort="$2" dir="$3"
  local settings_file="$dir/settings.yaml" patch_file="$dir/patch.yml"
  {
    echo "agent-default-model:"
    echo "  provider: deepseek-official"
    echo "  model: $model"
    [[ -n "$effort" ]] && echo "  reasoningEffort: $effort"
  } > "$settings_file"
  {
    echo "- id: settings"
    echo "  config:"
    echo "    path: $settings_file"
  } > "$patch_file"
  echo "$patch_file"
}

expand_model_alias() {
  case "$1" in
    pro)    echo "deepseek-v4-pro" ;;
    flash)  echo "deepseek-v4-flash" ;;
    vision) echo "deepseek-v4-flash-vision-exp" ;;
    *)      echo "$1" ;;
  esac
}

# --- run --------------------------------------------------------------------
cmd_run() {
  local write=0 model="" effort="" workdir="" timeout_s="$DEFAULT_TIMEOUT" background=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --write)      write=1; shift ;;
      --model)      model="${2:-}"; [[ -z "$model" ]] && die 2 "--model требует значение"; shift 2 ;;
      --effort)     effort="${2:-}"; [[ -z "$effort" ]] && die 2 "--effort требует значение"
                    case "$effort" in low|medium|high|xhigh|max) ;; *) die 2 "--effort принимает low, medium, high, xhigh или max" ;; esac
                    shift 2 ;;
      --cwd)        workdir="${2:-}"; [[ -z "$workdir" ]] && die 2 "--cwd требует значение"; shift 2 ;;
      --timeout)    timeout_s="${2:-}"; [[ -z "$timeout_s" ]] && die 2 "--timeout требует значение"; shift 2 ;;
      --background) background=1; shift ;;
      -h|--help)    usage ;;
      *)            die 2 "неизвестная опция '$1' (промпт передаётся на stdin, не аргументом)" ;;
    esac
  done

  [[ "$timeout_s" =~ ^[0-9]+$ ]] || die 2 "--timeout принимает целое число секунд"

  local prompt
  prompt="$(cat)"
  [[ -z "${prompt//[[:space:]]/}" ]] && die 2 "пустой промпт на stdin"

  # Задача уходит одним элементом argv (dsh читает только позиционный
  # аргумент, stdin он не смотрит). Лимит ARG_MAX — 1 МиБ на macOS;
  # держим порог ниже с запасом на окружение процесса.
  local prompt_bytes
  prompt_bytes=$(printf '%s' "$prompt" | wc -c | tr -d ' ')
  if [[ "$prompt_bytes" -gt 262144 ]]; then
    die 2 "промпт $prompt_bytes байт — слишком длинный для argv. Положи материал в файл внутри рабочего каталога и сошлись на него из задачи."
  fi

  workdir="${workdir:-$PWD}"
  [[ -d "$workdir" ]] || die 2 "каталог '$workdir' не существует"
  workdir="$(cd "$workdir" && pwd)"

  local bin; bin="$(resolve_dsh)"

  local mode="read-only"
  [[ $write -eq 1 ]] && mode="workspace-write"

  local tmpdir=""
  local args=(--profile headless)
  if [[ -n "$model" ]]; then
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/dsh-overlay.XXXXXX")"
    chmod 700 "$tmpdir"
    CLEANUP_PATHS+=("$tmpdir")
    local patch_file
    patch_file="$(write_model_overlay "$(expand_model_alias "$model")" "$effort" "$tmpdir")"
    args+=(--patch "$patch_file")
  elif [[ -n "$effort" ]]; then
    die 2 "--effort задаётся только вместе с --model (уровень усилий живёт в той же секции настроек)"
  fi

  if [[ $background -eq 1 ]]; then
    [[ -n "$tmpdir" ]] && CLEANUP_PATHS=()
    run_background "$bin" "$mode" "$workdir" "$timeout_s" "$prompt" "$tmpdir" "${args[@]}"
    return 0
  fi

  run_foreground "$bin" "$mode" "$workdir" "$timeout_s" "$prompt" "${args[@]}"
}

run_foreground() {
  local bin="$1" mode="$2" workdir="$3" timeout_s="$4" prompt="$5"; shift 5
  local args=("$@")
  local tb; tb="$(pick_timeout_bin)"
  local out err_file rc=0
  err_file="$(mktemp "${TMPDIR:-/tmp}/dsh-stderr.XXXXXX")"
  CLEANUP_PATHS+=("$err_file")

  # Потоки разводим строго: stdout — только ответ модели, диагностика dsh
  # остаётся в stderr. Слить их здесь значило бы отдать прогресс харнесса
  # пользователю как содержательный ответ.
  if [[ -n "$tb" ]]; then
    out="$(cd "$workdir" && DSH_PERMISSION_MODE="$mode" "$tb" "$timeout_s" "$bin" "${args[@]}" "$prompt" 2>"$err_file")" || rc=$?
  else
    out="$(cd "$workdir" && DSH_PERMISSION_MODE="$mode" "$bin" "${args[@]}" "$prompt" 2>"$err_file")" || rc=$?
  fi

  local err_text=""
  [[ -s "$err_file" ]] && err_text="$(cat "$err_file")"

  if [[ $rc -eq 124 ]]; then
    [[ -n "$out" ]] && printf '%s\n' "$out"
    die 6 "dsh: таймаут ${timeout_s}с. Задача слишком большая для одного прогона — разбей её или запусти с --background."
  fi
  if [[ $rc -ne 0 ]]; then
    # Содержательный кусок ответа, если он успел появиться, всё равно отдаём:
    # он полезнее кода возврата. Причина отказа идёт в stderr, к die.
    [[ -n "$out" ]] && printf '%s\n' "$out"
    die 6 "dsh: прогон завершился с кодом $rc${err_text:+ — $err_text}"
  fi
  [[ -z "$out" ]] && die 6 "dsh: пустой ответ — проверь готовность командой check${err_text:+. stderr: $err_text}"
  printf '%s\n' "$out"
}

new_job_id() {
  # Ни date, ни $RANDOM по отдельности не дают достаточной уникальности
  # при двух запусках в одну секунду; вместе — достаточно.
  printf '%s-%s' "$(date +%Y%m%d-%H%M%S)" "$$"
}

run_background() {
  local bin="$1" mode="$2" workdir="$3" timeout_s="$4" prompt="$5" tmpdir="$6"; shift 6
  local args=("$@")
  local job_id job_dir
  job_id="$(new_job_id)"
  job_dir="$JOBS_DIR/$job_id"
  mkdir -p "$job_dir"
  chmod 700 "$STATE_DIR" "$JOBS_DIR" 2>/dev/null || true
  chmod 700 "$job_dir"

  printf '%s' "$prompt" > "$job_dir/prompt.txt"
  {
    echo "id=$job_id"
    echo "status=running"
    echo "cwd=$workdir"
    echo "mode=$mode"
    echo "timeout=$timeout_s"
    echo "started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$job_dir/meta"

  # Отвязанный воркер: он же убирает overlay-каталог и проставляет итог.
  # nohup + disown, потому что родительский шелл Claude Code завершится сразу.
  (
    local tb rc=0
    tb="$(pick_timeout_bin)"
    cd "$workdir" || exit 1
    if [[ -n "$tb" ]]; then
      DSH_PERMISSION_MODE="$mode" "$tb" "$timeout_s" "$bin" "${args[@]}" "$prompt" > "$job_dir/output.txt" 2> "$job_dir/stderr.txt" || rc=$?
    else
      DSH_PERMISSION_MODE="$mode" "$bin" "${args[@]}" "$prompt" > "$job_dir/output.txt" 2> "$job_dir/stderr.txt" || rc=$?
    fi
    local final="completed"
    [[ $rc -eq 124 ]] && final="timeout"
    [[ $rc -ne 0 && $rc -ne 124 ]] && final="failed"
    sed -i.bak "s/^status=.*/status=$final/" "$job_dir/meta" && rm -f "$job_dir/meta.bak"
    echo "exit=$rc" >> "$job_dir/meta"
    echo "finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$job_dir/meta"
    [[ -n "$tmpdir" ]] && rm -rf "$tmpdir"
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true

  echo "$job_id"
}

# --- status / result --------------------------------------------------------
cmd_status() {
  local job_id="${1:-}"
  [[ -d "$JOBS_DIR" ]] || { echo "фоновых задач нет" >&2; exit 1; }

  if [[ -n "$job_id" ]]; then
    local dir="$JOBS_DIR/$job_id"
    [[ -d "$dir" ]] || die 2 "нет задачи с id '$job_id'"
    cat "$dir/meta"
    return 0
  fi

  local found=0
  local dir
  for dir in $(ls -1t "$JOBS_DIR" 2>/dev/null | head -20); do
    found=1
    local meta="$JOBS_DIR/$dir/meta"
    [[ -f "$meta" ]] || continue
    local st cw
    st="$(meta_get status "$meta")"
    cw="$(meta_get cwd "$meta")"
    # Потребитель вывода может закрыть пайп раньше (`| head`); для нас это
    # не ошибка, а сигнал, что читать больше некому.
    printf '%-24s %-10s %s\n' "$dir" "$st" "$cw" || exit 0
  done
  [[ $found -eq 1 ]] || { echo "фоновых задач нет" >&2; exit 1; }
}

cmd_result() {
  local job_id="${1:-}"
  [[ -n "$job_id" ]] || die 2 "нужен job-id (список — dsh-run.sh status)"
  local dir="$JOBS_DIR/$job_id"
  [[ -d "$dir" ]] || die 2 "нет задачи с id '$job_id'"

  local st
  st="$(meta_get status "$dir/meta")"

  if [[ "$st" == "running" ]]; then
    die 5 "задача ещё выполняется (запущена $(meta_get started "$dir/meta"))"
  fi

  # Частичный вывод оборванной или упавшей задачи печатаем в stdout ДО die:
  # он и есть самое ценное, что от такой задачи осталось.
  [[ -s "$dir/output.txt" ]] && cat "$dir/output.txt"

  case "$st" in
    timeout)
      die 6 "задача оборвалась по таймауту ($(meta_get timeout "$dir/meta")с); выше — то, что успело прийти"
      ;;
    failed)
      die 6 "задача завершилась с ошибкой (код $(meta_get exit "$dir/meta"))$( [[ -s "$dir/stderr.txt" ]] && printf ' — %s' "$(head -c 500 "$dir/stderr.txt")" )"
      ;;
  esac

  if [[ ! -s "$dir/output.txt" ]]; then
    [[ -s "$dir/stderr.txt" ]] && cat "$dir/stderr.txt" >&2
    die 6 "пустой ответ"
  fi
}

# --- transcript -------------------------------------------------------------
# Полный ход рассуждений и вызовов инструментов dsh пишет в свою сессию;
# наружу он отдаёт только финальное сообщение. Разбор нужен, когда ответ
# выглядит неправдоподобно и надо посмотреть, что харнесс делал на самом деле.
cmd_transcript() {
  local job_id="${1:-}" workdir="$PWD"
  if [[ -n "$job_id" ]]; then
    local meta="$JOBS_DIR/$job_id/meta"
    [[ -f "$meta" ]] || die 2 "нет задачи с id '$job_id'"
    workdir="$(meta_get cwd "$meta")"
  fi

  local sessions_root="$DSH_HOME_DIR/sessions"
  [[ -d "$sessions_root" ]] || die 2 "нет каталога сессий: $sessions_root"

  # Каталог сессий именуется по рабочему каталогу: разделители пути заменены
  # на дефисы, имя обрамлено двойными дефисами.
  local slug
  slug="--$(printf '%s' "$workdir" | sed 's|^/||; s|/|-|g')--"
  local dir="$sessions_root/$slug"
  [[ -d "$dir" ]] || die 2 "для каталога '$workdir' сессий не найдено (искал $dir)"

  local latest
  latest="$(ls -1td "$dir"/session-* 2>/dev/null | head -1 || true)"
  [[ -n "$latest" ]] || die 2 "в '$dir' нет сессий"

  local file="$latest/session.jsonl.zstd"
  if [[ -f "$file" ]]; then
    command -v zstd >/dev/null 2>&1 || die 2 "нужен zstd, чтобы распаковать $file"
    zstd -dc "$file"
  elif [[ -f "$latest/session.jsonl" ]]; then
    cat "$latest/session.jsonl"
  else
    die 2 "в '$latest' нет ни session.jsonl.zstd, ни session.jsonl"
  fi
}

# --- диспетчер --------------------------------------------------------------
[[ $# -eq 0 ]] && usage
sub="$1"; shift
# -h принимает любая подкоманда: субагент спрашивает синтаксис именно так.
for a in "$@"; do [[ "$a" == "-h" || "$a" == "--help" ]] && usage; done
case "$sub" in
  check)      cmd_check "$@" ;;
  run)        cmd_run "$@" ;;
  status)     cmd_status "$@" ;;
  result)     cmd_result "$@" ;;
  transcript) cmd_transcript "$@" ;;
  -h|--help)  usage ;;
  *)          die 2 "неизвестная подкоманда '$sub'" ;;
esac
