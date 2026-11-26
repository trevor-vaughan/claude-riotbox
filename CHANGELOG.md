# Changelog

All notable changes to this project are documented in this file. The format is
generated from [Conventional Commits](https://www.conventionalcommits.org) by
[git-cliff](https://git-cliff.org); do not edit it by hand — run
`task release:bump` instead.

## [0.8.1] - 2026-11-26

### 💼 Other

- *(changelog)* List chore(deps) commits in the changelog

### ⚙️ Miscellaneous Tasks

- *(deps)* Bump the pinned toolchain and agent dependencies

## [0.8.0] - 2026-11-20

### 🚀 Features

- *(egress)* Put the agent behind a per-session Envoy egress proxy
- *(egress)* Inject provider API keys at the proxy
- *(egress)* Add OS mirror plugins and more allowlist groups
- *(launch)* Warn before starting inside a linked git worktree
- *(session)* Add filters to session-reset all and skip unsafe sessions
- *(git-ai)* Show per-store progress on a terminal
- *(context-mode)* [**breaking**] Migrate to context-mode 2.x on Node 24
- *(opencode)* [**breaking**] Move the image to OpenCode 2
- *(checkpoints)* Add backups listing and backup-prune commands
- *(egress)* Let egress.conf [inject] rows add or replace provider keys
- *(egress)* Allow plain HTTP with http:// entries and allow_plain
- *(egress)* Allow port ranges and every port
- *(egress)* Reach host-loopback services such as ssh -L forwards
- *(egress)* RIOTBOX_EGRESS_CONF gives a session its own egress.conf
- *(anywhere)* Drive sessions from a phone with Yep Anywhere
- *(anywhere)* Riotbox hub lists every running session on one page
- *(hub)* Add `riotbox hub`, one entry point for every anywhere session
- *(hub)* Draw the hub link as a QR code on a terminal
- *(config)* Vet host config files before sourcing them
- *(config)* Vet the host config in every sourcer
- *(config)* Pin the config dir under agent mounts that reach it
- *(launch)* Protect the riotbox config dir from the agent's mounts
- *(checkpoint)* Add RIOTBOX_CHECKPOINT=0 to skip checkpoints

### 🐛 Bug Fixes

- *(egress)* Run the proxy and agent without a pod
- *(egress)* Run e2e venom scripts under bash, not the host's /bin/sh
- *(release)* Declare the MIT license in rpm and deb metadata
- *(git-ai)* Drop stale daemon sockets from the private store copy
- *(overlay)* List overlays whose folder name starts with a dot
- *(overlay)* List dot-keyed sessions and keep caller shell options
- Find sessions and projects whose names start with a dot
- *(checkpoint)* Ask before checkpointing through an enclosing repo
- *(security)* Scrub URL-embedded credentials from staged tool configs
- *(egress)* Mask the egress root under a --mount spelled dest=
- *(anywhere)* Allow the bind address past Yep Anywhere's Host check
- *(anywhere)* Never generate a password --setup-auth rejects
- *(anywhere)* Warn on every spelling of a wildcard bind
- *(hub)* List a session only where it really publishes Yep Anywhere
- *(hub)* Say how to open the link printed for a wildcard bind
- *(anywhere)* Refuse malformed IPv6 before canonicalising it
- *(anywhere)* Install the openssl CLI Yep Anywhere needs for TLS
- *(anywhere)* Keep the launch banner in view
- *(hub)* Name an address this host lacks, before printing a link
- *(lint)* Satisfy shellcheck 0.11 (SC2329, SC2154)
- *(config)* Protect the config the host resolves, not the path as written
- *(config)* Vet the directory holding every link on the config's path
- *(config)* Vet the host config in detect-mounts.sh
- *(config)* Close privileged/cap-add spellings and hard-linked configs
- *(config)* Unbreak CI shellcheck and config e2e on the runner
- *(config)* Mount a per-launch copy of the riotbox config dir

### 💼 Other

- *(containerfile)* Install sourcemeta jsonschema, drop python3-jsonschema
- *(containerfile)* Install shfmt and go-global-update tools

### 🚜 Refactor

- *(egress)* Move bind-mount parsing to scripts/lib/bind-mounts.sh
- *(mounts)* Share the unreadable --mount check

### 📚 Documentation

- *(anywhere)* Passwords and certificates are per project set
- *(anywhere)* Record the trial run and what it settled
- *(config)* Document config vetting, mount protection and fail-closed secrets
- *(config)* Correct the config dir mount note, fail-closed example, new residuals

### 🧪 Testing

- *(egress)* Parse the echo from stdout, not curl's combined output
- *(egress)* Track floating tags instead of digest pins for e2e images

### ⚙️ Miscellaneous Tasks

- *(deps)* Bump the pinned toolchain and agent dependencies
- Run the test job on Ubuntu 26.04
- Run the config protection end-to-end suite
- *(deps)* Bump the pinned toolchain and agent dependencies

## [0.7.1] - 2026-10-23

### 🚀 Features

- *(core)* Compute session keys in riotbox-core; build and ship it
- *(core)* Move session-state migration, locks and key moves to Go

### 💼 Other

- *(task)* Llm venom summary, fmt, full clean and git isolation

### 📚 Documentation

- *(decisions)* Record moving the session core to Go

### 🧪 Testing

- *(setup)* Stub podman info so final verification always runs

## [0.7.0] - 2026-10-22

### 🚀 Features

- *(image)* Keep space-prefixed commands out of shell history
- *(image)* Turn off update checks in pinned gh, glab and scanners
- *(image)* [**breaking**] Remove the GitHub and GitLab MCP servers

### 🐛 Bug Fixes

- *(build)* Check Podman ID mappings before builds
- *(tests)* Split TEST_REAL_CAT assignment from export
- *(headroom)* Route Claude background sessions through the proxy
- *(headroom)* Pass a merged user --settings as a private file
- *(headroom)* Leave routing keys set in a settings.json env to that file

### 🚜 Refactor

- *(session)* Share session-key validation and replace-then-rename

## [0.6.1] - 2026-10-15

### 🐛 Bug Fixes

- *(container)* Let go fetch newer toolchains (GOTOOLCHAIN=auto)
- *(opencode)* Refresh opencode-config in place on relaunch
- *(security)* Reject tokscale scan roots reached through any link
- *(session)* Find sessions by their launch record, not .projects alone

### 🧪 Testing

- *(overlay)* Cover the overlays gates for a hidden session

## [0.6.0] - 2026-10-15

### 🚀 Features

- *(pi)* Add Pi as a RiotBox agent
- *(session)* [**breaking**] Move mount sources to a per-session state dir

### 🐛 Bug Fixes

- *(container)* Make git honor the copied ~/.gitignore_global
- *(ci)* Stage gitignore stub in build fixtures; allow quoted tilde
- *(session,headroom)* Give sessions unique keys; keep headroom out of projects
- *(test)* Install file in the test image
- *(headroom)* Treat a zombie proxy's record as stale

## [0.5.3] - 2026-10-02

### 💼 Other

- *(containerfile)* Add python3-jsonschema to image dependencies
- *(containerfile)* Enable relative paths for git worktrees

### ⚡ Performance

- *(repair-notes)* Batch Pass 3 blob lookups into one git call per commit

## [0.5.2] - 2026-10-01

### 🚀 Features

- *(context-mode)* [**breaking**] Adopt the upstream plugin as Claude's wiring
- *(startup)* Report elapsed time for slow startup steps
- *(git-ai)* Wire git-ai attribution into the image and session
- *(git-ai)* Add `riotbox git-ai` to merge usage across sessions
- *(git-ai)* Keep prompt text out of the authorship note
- *(repair-notes)* Reattach orphaned git-ai attribution notes
- *(install)* Drop newer config stubs in as .new files

### 🐛 Bug Fixes

- *(headroom)* Disable the kompress canary in one-shot preloads
- *(checkpoints)* Match backup stores only for real repositories
- *(ctx-stats)* Report a jq failure instead of an empty ledger
- *(codegraph)* Stop registering the MCP server at session start
- *(context-mode)* Scope the Claude strip to the hooks it owns
- *(container)* Install the locale the image tells shells to use
- *(tests)* Declare diffutils the test image stopped inheriting
- *(checkpoint)* Exclude lola's module cache from snapshots
- *(git-ai)* Keep attribution notes attached across history rewrites
- *(checkpoint)* Back up attribution notes with the project

### 💼 Other

- *(containerfile)* Bump pinned tool versions

### 🚜 Refactor

- *(opencode)* Delegate headroom routing to wrap opencode

### 📚 Documentation

- *(codegraph)* Narrow the cleanup's claims to what the strips prove

### 🧪 Testing

- *(git-ai)* Cover the setup's warn-and-continue paths

### ⚙️ Miscellaneous Tasks

- *(deps)* Bump pinned Containerfile toolchain to latest
- *(lint)* Raise shellcheck to -S info -o all

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
