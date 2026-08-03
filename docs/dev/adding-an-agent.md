# Adding a new CLI agent to RiotBox

Follow this start to finish to add a third (or fourth, or fifth) CLI agent
alongside `claude` and `opencode` — for example [aider](https://aider.chat/),
[goose](https://block.github.io/goose/), [cursor-agent](https://docs.cursor.com/cli),
or [codex](https://github.com/openai/codex).

Looking up a single verb rather than adding an agent? Go straight to
[The agent contract](agent-contract.md).

Adding an agent is a **single-directory operation**. You drop a new manifest
under `agents/`, register the name, install the binary in the Containerfile,
and you're done — no edits to dispatch sites, wrappers, or test fixtures.

## TL;DR — the three steps

1. **Install the binary** in the Containerfile (one `RUN` line).
2. **Create `agents/<name>/`** with at minimum a `manifest.sh` defining the
   eight required functions, each a handful of lines — see
   [The agent contract](agent-contract.md). Add `setup.sh` for container-side
   runtime setup and `sync-settings.sh` for host config sync if your agent needs
   them. Use `agents/claude/` or `agents/opencode/` as a template.
3. **Run `task lint && task test`** — the contract suite at
   `tests/agents.venom.yml` automatically validates the new manifest.

That's it. The registry **auto-discovers** any directory under `agents/`
that contains a `manifest.sh`, so you don't need to edit any list. The
wrapper, all dispatch sites, install.sh's `--agent` validation, the
entrypoint's setup loop, and `mount-projects.sh`'s sync loop pick up the
new agent automatically.

**Discovery rules:**
- Subdirectories without `manifest.sh` are silently skipped (drafts,
  scaffolding, tooling).
- Directories whose names start with `_` or `.` are skipped (templates,
  hidden state).
- Iteration order is the shell glob's lexical order — stable across runs.

## Layout per agent

```
agents/<name>/
  manifest.sh        ← required: contract functions
  setup.sh           ← optional: container-side runtime setup
  sync-settings.sh   ← optional: host-side config sync
  context-mode.sh    ← optional: Context Mode verbs (sourced by manifest.sh)
```

The registry sources `agents/<name>/manifest.sh`. The manifest decides
whether to source `setup.sh` (from `container_setup`) and whether to
exec `sync-settings.sh` (from `host_sync`). Files outside `manifest.sh`
are agent-private — the rest of the system never references them.

## The contract

Every `agents/<name>/manifest.sh` must define eight functions, and may define
optional ones for headroom and Context Mode support.

**→ [The agent contract](agent-contract.md)** documents each verb: its signature,
what it must print, and the rules it has to honour.

The two shipped manifests are the working references —
[`agents/claude/manifest.sh`](../../agents/claude/manifest.sh) and
[`agents/opencode/manifest.sh`](../../agents/opencode/manifest.sh).

## Worked example: adding `aider`

Suppose [aider](https://aider.chat/) is your third agent. Here's the
complete diff:

### 1. Install in Containerfile

```dockerfile
# Aider — Python-based pair-programming agent
RUN pip install --no-cache-dir --break-system-packages aider-install && \
    aider-install && aider --version
```

### 2. Manifest at `agents/aider/manifest.sh`

```bash
#!/usr/bin/env bash
_AGENT_AIDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

agent_aider_real_binary() { printf 'aider\n'; }

agent_aider_run_argv() {
    local prompt="${1:?run_argv requires a prompt argument}"
    # aider takes a prompt via --message and exits non-interactively
    # with --no-stream, --yes-always for autonomy.
    printf '%s\0' aider --message "${prompt}" --no-stream --yes-always
}

agent_aider_resume_argv() {
    # aider has no native "resume" — opening it without a prompt picks
    # up the local repo state.
    printf '%s\0' aider --no-stream --yes-always
}

agent_aider_audit_argv() {
    local prompt="${1:?audit_argv requires a prompt argument}"
    printf '%s\0' aider --message "${prompt}" --no-stream --yes-always
}

agent_aider_wrapper_inject() {
    # aider's --yes-always disables interactive prompts; the run_argv
    # already passes it. The wrapper itself only needs to scan for
    # --message to decide CI=true.
    local set_ci=0 arg
    for arg in "$@"; do
        if [ "${arg}" = "--message" ]; then set_ci=1; break; fi
    done
    for arg in "$@"; do printf '%s\0' "${arg}"; done
    if [ "${set_ci}" = "1" ] && [ -n "${RIOTBOX_INJECT_ENV_FILE:-}" ]; then
        printf 'CI=true\n' >> "${RIOTBOX_INJECT_ENV_FILE}"
    fi
    return 0
}

agent_aider_container_setup() { :; }   # no runtime setup needed

agent_aider_host_sync() {
    local session_dir="${1:?host_sync requires a session_dir argument}"
    # aider reads ~/.aider.conf.yml; copy it into the session dir if
    # present, otherwise no-op.
    if [ -f "${HOME}/.aider.conf.yml" ]; then
        cp "${HOME}/.aider.conf.yml" "${session_dir}/.aider.conf.yml"
        echo "-v ${session_dir}/.aider.conf.yml:/home/llm/.aider.conf.yml:z"
    fi
}

agent_aider_env_vars() {
    # Provider keys aider reads upstream. Listing each candidate up front
    # lets users switch backends without re-editing this manifest.
    cat <<'EOF'
ANTHROPIC_API_KEY
OPENAI_API_KEY
DEEPSEEK_API_KEY
GEMINI_API_KEY
EOF
}
```

### 3. Run the tests

The registry auto-discovers `agents/aider/manifest.sh` — no edit to
`registry.sh` is needed.

```sh
task lint && task test ARGS=agents
```

The registry contract suite at `tests/agents.venom.yml` automatically
validates `aider` against every contract check — `real_binary`,
`run_argv`, `resume_argv`, `audit_argv`, `container_setup`,
`wrapper_inject`, `host_sync`, `env_vars`, plus the dispatcher's
reject-unknown behaviour.

That's the whole change. No edits to:

- `install.sh` — the wrapper sources `agents/registry.sh` at runtime.
- `libexec/run.sh`, `resume.sh`, `audit.sh` — they call
  `agent_call "$RIOTBOX_AGENT" <verb>`.
- `container/agent-wrapper.sh` — it dispatches by `basename($0)`.
- `container/entrypoint.sh` — it loops over `AGENT_REGISTRY`.
- `scripts/mount-projects.sh` — it loops over `AGENT_REGISTRY`.
- `Containerfile` (apart from the install step) — the symlink loop reads
  `AGENT_REGISTRY` directly.

## Things to avoid

- **Don't break the contract.** If a new manifest skips a function, the
  registry tests fail loudly. Don't `# shellcheck disable=...` your way
  past missing functions.
- **Don't add agent-specific dispatch outside the registry.** If you're
  about to write a `case "$RIOTBOX_AGENT" in <name>) ... ;; esac`, stop
  and put the logic in the manifest. The whole point of the refactor is
  that there is one place to look up agent behaviour.
- **Don't overload the manifest with unrelated logic.** Keep it focused
  on the contract. Long setup bodies belong in `agents/<name>/setup.sh`
  (sourced by `container_setup`); long sync logic in
  `agents/<name>/sync-settings.sh` (called by `host_sync`).

## Where to look when something breaks

| Symptom                                              | Where to look                                                                                                        |
|------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------|
| `--agent=<new>` rejected with "must be one of"       | Does `agents/<new>/manifest.sh` exist? The host wrapper sources the registry at runtime, so no re-install is needed. |
| `riotbox run` exits with "unknown verb"              | Manifest is missing `agent_<name>_run_argv`                                                                          |
| Wrapper invokes wrong binary                         | Check `agent_<name>_real_binary` and PATH order                                                                      |
| `--dangerously-skip-permissions` in wrong place      | Bug in `agent_<name>_wrapper_inject`; see opencode for subcommand-local injection                                    |
| Container fails to start with "no agents discovered" | The `COPY agents/` in the Containerfile didn't run, or every subdirectory is missing `manifest.sh`                      |
| Host config not synced                               | `agent_<name>_host_sync` is a no-op or its sync script is missing                                                    |

Run `task test ARGS=agents` to re-exercise the contract suite at any
time — it's the fastest signal that a manifest is well-formed.
