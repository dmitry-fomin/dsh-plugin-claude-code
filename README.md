# dsh — DeepSeek Harness bridge for Claude Code

Delegate a task to DeepSeek Harness (`dsh`) from inside
Claude Code. Unlike sending a prompt to another model, `dsh` is a second **agent**: it reads
files, greps, and runs commands in the working directory on its own, and it obeys the same
`CLAUDE.md` / `AGENTS.md` your session does.

The point is not a second opinion in the abstract — it is a second agent that walks the
codebase in its own context window instead of yours.

**Read-only by default.** Write access is a deliberate flag, never inferred from how a task
is phrased.

## Where your code goes

`dsh` sends the files it reads to DeepSeek's servers (provider `deepseek-official`). This
plugin is a bridge, not a sandbox: installing it means your working directory can leave your
machine. Read-only mode prevents writes, not reads. Decide whether that is acceptable for a
given repository *before* you delegate, and scope every task to the files it actually needs.

## Requirements

- [Claude Code](https://code.claude.com) v2.1.216 or later — earlier versions drop the
  plugin prefix from command names, so `/dsh:delegate` would not resolve
- DeepSeek Harness on your `PATH`, signed in, with the `headless` profile available:
  ```
  npm install -g @deepseek-ai/dsh
  dsh --profile web        # sign in through the web UI once
  ```
  Note the name collision: Homebrew's `dsh` is an unrelated tool (Dancer's shell). The one
  this plugin drives is the npm package `@deepseek-ai/dsh`, which is pre-release software —
  its flags may still move.
- `bash`, plus `zstd` if you want to read session transcripts

Verify everything at once with `/dsh:check` after installing.

## Install

```
/plugin marketplace add dmitry-fomin/dsh-plugin-claude-code
/plugin install dsh@dsh-plugin-claude-code
```

The shortcut clones over SSH and falls back to HTTPS when no key is configured. To force
HTTPS, pass the full URL: `/plugin marketplace add https://github.com/dmitry-fomin/dsh-plugin-claude-code.git`

Then restart Claude Code — the subagent list is read at session start, so `dsh:dsh-runner`
only appears in a fresh session.

## What you get

| Command | What it does |
| --- | --- |
| `/dsh:delegate` | hand a task to `dsh` — explore a subsystem, map a codebase, find every occurrence |
| `/dsh:check` | is the harness ready: binary, profiles, active model, credentials |
| `/dsh:second-opinion` | check your own hypothesis against `dsh`, which reads the relevant code itself |

Two internal pieces you never call directly: the `dsh-runtime` skill (the calling contract,
preloaded into the subagent) and the `dsh:dsh-runner` subagent (a thin forwarder whose only
job is to run the script and return its stdout verbatim, so the harness output never floods
your main context).

## How it works

```
/dsh:delegate  ──Agent──▶  dsh:dsh-runner  ──Bash──▶  scripts/dsh-run.sh  ──▶  dsh --profile headless
   decides                  forwards only              all the mechanics          the actual agent
```

The invariant everything rests on: **stdout of `dsh-run.sh run` is exactly the model's final
answer, nothing else.** Diagnostics go to stderr. That is what makes "show the output
verbatim" a safe rule rather than a leak of progress spinners into your answer.

## The script

`scripts/dsh-run.sh` is usable on its own:

```bash
scripts/dsh-run.sh run [options] <<'EOF'
your task
EOF
```

| Subcommand | Purpose |
| --- | --- |
| `run` | one shot; prompt on stdin, answer on stdout |
| `check [--json]` | readiness report; exit 1 when not ready |
| `status [job-id]` | background jobs |
| `result <job-id>` | collect a finished background job |
| `transcript [job-id]` | full JSONL session — what the harness actually did |

| Option | Default | Meaning |
| --- | --- | --- |
| `--write` | off | allow writes to the working directory (`workspace-write`) |
| `--model pro\|flash\|vision\|<name>` | user's setting | `pro` for hard reasoning, `flash` for mechanical work |
| `--effort low\|medium\|high\|xhigh\|max` | user's setting | only together with `--model` |
| `--cwd <dir>` | current directory | working directory and sandbox boundary |
| `--timeout <sec>` | 600 | matches the Bash tool's own ceiling |
| `--background` | off | detach, print a job id |

Always use a **quoted** heredoc (`<<'EOF'`). Tasks nearly always contain code, and an
unquoted marker lets the shell expand `$` and backticks before the text ever reaches `dsh`.

Exit codes: `0` success · `1` `check` not ready / no jobs · `2` bad invocation · `5` job
still running · `6` timeout, non-zero exit, or empty answer.

## What it looks like

```
> /dsh:check
готовность:   yes
бинарь:       /opt/homebrew/bin/dsh (ok)
версия:       0.1.1-rc.2
профили:      headless,web
модель:       deepseek-official / deepseek-v4-pro (effort: max)
```

A delegated task comes back as one final message — the harness's own words, passed through
verbatim. Asked to review this very script, it answered with a numbered list of defects,
each with a line number and the scenario that triggers it; nine of them were real and got
fixed before this release.

## Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `DSH_BIN` | `dsh` from `PATH` | full path to the harness binary when it isn't on `PATH` |
| `DSH_HOME` | `~/.dsh` | harness home: settings, credentials, session transcripts |
| `DSH_CLAUDE_STATE_DIR` | `${XDG_STATE_HOME:-~/.local/state}/dsh-claude` | where background jobs are kept |

## Two things worth knowing

**Choosing the model is not what you'd expect.** `dsh --patch` does *not* override the
model: the user layer in `~/.dsh/settings.yaml` is applied on top of any overlay. The script
works around this by repointing the settings plugin at a generated document. Use `--model`
and let it handle that.

**The secret guard cannot live in the prompt.** `dsh` opens files by itself, so scanning the
task text proves nothing. Scope every task to the files it actually needs and say plainly
that `.env`, `*.key`, `*.pem`, and `credentials.json` are off limits. Read-only mode stops
writes, not reads — whoever writes the task owns this.

## Limits

- One task per run. The `headless` profile has no follow-up turn, so repeat the context in a
  new task instead of continuing a conversation.
- The task travels as a single argv element; prompts above 256 KiB are rejected. Put bulk
  material in a file inside the working directory and point at it.
- No `cancel` for background jobs, and `status` is not scoped per Claude Code session — it
  lists all your jobs.
- Background jobs are kept forever: each one leaves its prompt, answer, and stderr as plain
  files under `DSH_CLAUDE_STATE_DIR` (mode 700, but never pruned). Clean the directory
  yourself if the prompts are sensitive.
- In headless mode there is no approval channel, so a request to escalate permissions is
  declined rather than queued. Re-run with `--write` if the task genuinely needs it.

## A note on language

The skill bodies, the script's comments **and all of its runtime output** are written in
Russian — `/dsh:check` and every error message will greet you in Russian, as the sample
above shows. This README, the manifests, and every command, flag, and identifier are in
English. The skills work the same regardless of the language you talk to Claude in.

## Credits

The architecture — a routing command, a thin forwarding subagent, a runtime-contract skill,
and one script holding all deterministic logic — follows the shape of the community
`grok` plugin for Claude Code.

MIT licensed.
