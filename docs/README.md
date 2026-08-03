# RiotBox documentation

**Using RiotBox?** Start at the [root README](../README.md) — install, quick
start, commands, and every user-facing feature.

Everything under `docs/` is **maintainer-facing**: how the internals work, and why
they are the way they are.

## What are you trying to do?

| Goal | Read |
|---|---|
| Add a new CLI agent (aider, goose, codex, …) | [dev/adding-an-agent.md](dev/adding-an-agent.md) |
| Look up what a manifest verb must do | [dev/agent-contract.md](dev/agent-contract.md) |
| Understand how Context Mode is wired | [dev/context-mode.md](dev/context-mode.md) |
| Change `scripts/mount-projects.sh` without breaking it | [dev/mount-projects.md](dev/mount-projects.md) |
| Find out *why* something was built this way | [dev/decisions/](dev/decisions/) |

## Layout

```
docs/
  dev/
    adding-an-agent.md   how-to      — the three steps, with a worked example
    agent-contract.md    reference   — every manifest verb, in detail
    context-mode.md      explanation — how the Context Mode integration works today
    mount-projects.md    reference   — invariants you must not break
    decisions/           records     — why we adopted, rejected, or abandoned things
```

Each page states its mode at the top. Reference pages are for looking things up;
how-to pages are for following start to finish; decision records are **frozen** —
they say what we believed at the time, not what the code does now.

## What is not here

`docs/superpowers/` holds specs and implementation plans generated while working.
It is gitignored on purpose: those are working artifacts, not deliverables, and
they go stale the moment the work lands. Nothing outside that directory should
link into it.
