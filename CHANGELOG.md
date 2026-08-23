# Changelog

All notable changes to this project are documented in this file. The format is
generated from [Conventional Commits](https://www.conventionalcommits.org) by
[git-cliff](https://git-cliff.org); do not edit it by hand — run
`task release:bump` instead.

## [0.5.1] - 2026-08-23

### 🚀 Features

- Add self-locating bin/riotbox dispatcher
- Rewrite install.sh for XDG app-tree layout
- Package riotbox as rpm/deb via nfpm
- Rename docker task namespace to container; add LLM tool update
- *(launch)* Add confirmation-gated RIOTBOX_EXTRA_ARGS engine args
- Opt-in headroom context compression for agent sessions
- *(opencode)* Add headroom context-compression support
- Add `riotbox tokscale` subcommand for unified offline usage reporting
- *(codegraph)* Integrate CodeGraph code intelligence into sessions
- *(context-mode)* Add opt-in Context Mode for autonomous runs
- *(context-mode)* Wire opencode through per-agent registry verbs
- *(checkpoint)* Snapshot to refs/riotbox instead of the user's branch
- *(checkpoints)* Add list, tag and prune for snapshot refs
- *(riotbox)* Route checkpoints, checkpoint-tag and checkpoint-prune
- *(forge-mcp)* Add riotbox-gh-glab flavor with on-demand GitHub/GitLab MCP
- *(mounts)* Allow per-entry rw mounts in mounts.conf
- *(release)* Prompt for the version and generate the changelog

### 🐛 Bug Fixes

- Remove stray 'Claude' from build.sh header comment
- *(docker)* Ship container/startup-scripts.sh into the image
- Update libexec script cross-references after move
- *(test)* Add vars block to dispatch.venom.yml for venom linter
- Don't ship generated configs/; build from a writable context
- Drop task from riotbox doctor's host checks
- Scrub dead task hints from shipped scripts; harden --agent parsing
- Wire the /etc system config layer (config + mounts.conf)
- Handle empty and non-git project dirs on checkpoint
- *(lint)* Resolve megalinter findings across shell, docker, ci, and tests
- Address cranky-review findings across install, doctor, build, and docs
- *(lint)* Clear shellcheck --enable=all findings in shell scripts
- *(ci)* Answer hadolint's new DL3066/DL3025 rules
- *(session-branch)* Diagnose dirty-tree teardown, do not pre-gate it
- *(opencode)* Inject --auto, the 1.18 replacement for the dead flag

### 🚜 Refactor

- Relocate runtime scripts to libexec/
- Remove task from the runtime path (dispatcher owns it)
- Rename Dockerfile to Containerfile for vendor-agnostic naming

### 📚 Documentation

- Capitalize Network row notes cell for table consistency
- Correct agent-install order to document both opencode and Claude Code
- Normalize product name to RiotBox in prose (casing pass)
- *(threat-model)* Rewrite remediated finding 018 for current architecture
- Update threat model and docs for libexec/ relocation
- Document package install and riotbox CLI usage
- Restructure maintainer docs for human readers
- Describe snapshot refs and the recovery flow that works
- *(decisions)* Record why checkpoints use refs, and why not a worktree

### 🧪 Testing

- Rename inject-claude-md suite to inject-system-prompt
- Update suites for libexec/ script locations
- Port CLI routing coverage from generated wrapper to bin/riotbox dispatcher
- Container-driven rpm/deb install contract
- *(checkpoint)* Add fixtures for non-quiescent repo states
- *(checkpoint)* Re-target the existing suites at the snapshot ref

### ⚙️ Miscellaneous Tasks

- Point dev taskfiles and linter at libexec/
- Publish rpm/deb artifacts on version tags
- Ignore /.worktrees/ for isolated feature work

## [0.5.0] - 2026-05-27

### 🚀 Features

- Add socket mode runtime and fix multi-project name truncation
- *(passthrough)* Support KEY=VALUE entries in RIOTBOX_PASSTHROUGH_VARS
- *(mount)* Auto-switch unowned project dirs to podman :O overlay
- *(passthrough)* Add RIOTBOX_PASSTHROUGH_EXTRA_VARS append channel
- Merge host opencode config and add user startup-scripts hook
- *(opencode)* Persist plugin install cache across sessions

### 🐛 Bug Fixes

- Harden mount-path handling and pin negative-path test exit codes
- *(socket)* Use only rootless podman socket and add SELinux :z relabel
- *(checkpoint)* Disable git signing on checkpoint commit and tag

### 🚜 Refactor

- Rebrand claude-riotbox -> riotbox (CLI, image, config, paths)
- Rebrand claude-riotbox -> riotbox in design docs
- Rename container OS user claude -> llm
- Neutral autonomy-prompt source CLAUDE.md -> AGENTS.md
- Neutralize checkpoint tag namespace -> riotbox-checkpoint/
- Neutralize checkpoint commit-message prefix pre-claude- -> pre-riotbox-

### 📚 Documentation

- Update stale 'claude user' references to 'llm' after user rename
- Fix remaining /etc/passwd-entry references to renamed llm user
- Neutralize prose, fix stale wrapper refs, bump VERSION 0.5.0
