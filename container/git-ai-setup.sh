#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# git-ai-setup.sh — wire git-ai authorship attribution for a RiotBox session.
#
# Sourced by entrypoint.sh. Provides:
#   git_ai_setup — the entry point: configure, wire, confirm; or strip a
#                  previous session's wiring when the feature is switched off.
#
# Why this runs per session rather than at build time: ~/.claude and
# ~/.config/opencode are replaced by session bind mounts (see
# scripts/mount-projects.sh), so wiring written into the image is invisible at
# runtime — the same reason plugin-setup.sh copies from a staging directory.
# ~/.git-ai is itself a session mount, so the store and its config are session
# state too, and a session directory can arrive carrying wiring from any older
# image.
#
# Why upstream's `install-hooks` rather than hand-written stanzas: one call
# writes all three integration points — the Claude settings.json hooks, the
# opencode plugin, and the ~/.gitconfig trace2 target — and upstream's own
# documentation has already drifted from what its binary installs (the
# documented Write|Edit|MultiEdit matcher is actually "*"). Letting upstream own
# the shape keeps RiotBox out of that drift. What upstream cannot do is clean up
# a session directory that outlives the image, so that is what RiotBox owns; see
# the per-agent git-ai.sh strip verbs.
# ─────────────────────────────────────────────────────────────────────────────

# Path to the binary. NOT named GIT_AI_BIN: upstream's binary reads that env var
# itself, and shadowing it here would change the behaviour of the very tool this
# file configures.
RIOTBOX_GIT_AI_BIN="${RIOTBOX_GIT_AI_BIN:-${HOME}/.local/bin/git-ai}"

# git-ai is the first RiotBox feature that is ON by default, so the gate reads
# :-1 where every other flag reads :-0. The strict "1" comparison is kept to
# match the rest of the codebase rather than introducing truthy parsing for one
# feature; the consequence, documented in the README, is that any value other
# than 1 — including "true" — switches it off.
git_ai_enabled() {
	[[ "${RIOTBOX_GIT_AI:-1}" = "1" ]]
}

# Turn off everything that reaches the network before the daemon ever starts.
#
# Upstream ships telemetry_oss enabled, disable_version_checks false,
# disable_auto_updates false, and feature_flags.daemon_log_upload true. The
# version check and the auto-update both violate this image's offline-after-build
# rule outright; the log upload is a surface nobody asked for.
#
# Prompt storage is pinned here too, which is not a network setting but belongs
# to the same "decide the default, do not inherit it" rule. git-ai can embed the
# user's prompt text — the transcript's user_message values — directly in the
# authorship note. The note is the one git-ai artifact that travels with the
# repository, so a prompt embedded there is conversation content that a later
# `git push` can publish without anyone deciding to. `local` is the enumerated
# mode that keeps prompts out of the note; upstream offers no "off", so this is
# the most restrictive setting available rather than a way to stop capture.
#
# Both keys are set. prompt_storage is the mode; default_prompt_storage is the
# fallback upstream applies to repositories absent from
# include_prompts_in_repositories, so pinning only the first would leave that
# path on whatever upstream ships. exclude_prompts_in_repositories is NOT used:
# upstream's own help calls other keys "globs" and this one only "Repos", so
# there is no evidence a "*" entry matches anything, and a setting that looks
# protective while matching nothing is worse than none.
#
# `git-ai config set` is used rather than writing JSON directly so upstream owns
# the file's schema. The result is sparse — only overridden keys are stored.
git_ai_write_config() {
	local k
	for k in "telemetry_oss off" \
		"disable_version_checks true" \
		"disable_auto_updates true" \
		"feature_flags.daemon_log_upload false" \
		"prompt_storage local" \
		"default_prompt_storage local"; do
		# Word-splitting is intended: each entry is a key/value pair.
		# shellcheck disable=SC2086
		if ! "${RIOTBOX_GIT_AI_BIN}" config set ${k} >/dev/null 2>&1; then
			echo "  [git-ai] WARN: could not set '${k}' — continuing." >&2
		fi
	done
}

# Record which git-ai release wrote this store.
#
# The store is session-local, so `git ai usage` and `git ai analyze` see one
# session at a time. A later phase adds a host-side reader that merges every
# session's store, and it has to open SQLite DBs written by whatever image
# produced them. Stamping the writer's version here means that reader can pick a
# matching binary instead of guessing, and can say so plainly when it cannot.
#
# Written after the config so a store that exists at all is a configured one.
git_ai_stamp_version() {
	local marker="${HOME}/.git-ai/.riotbox-version"
	local version
	if ! version="$("${RIOTBOX_GIT_AI_BIN}" --version 2>/dev/null)"; then
		echo "  [git-ai] WARN: could not read the git-ai version — store left unstamped." >&2
		return 0
	fi
	if ! mkdir -p "${HOME}/.git-ai" || ! printf '%s\n' "${version}" >"${marker}"; then
		echo "  [git-ai] WARN: could not write ${marker} — store left unstamped." >&2
		return 0
	fi
}

# Install upstream's wiring for every agent it detects.
#
# `--env` is deliberately omitted: it edits shell rc files to put ~/.git-ai/bin
# on PATH, which is wrong here twice over — the binary is at ~/.local/bin, and
# ~/.git-ai is a session mount whose bin/ does not exist.
#
# install-hooks writes to every agent it finds, not just the one this session
# launched. That is left alone: the extra wiring is inert for an agent that
# never runs, and suppressing it would mean hand-maintaining the per-agent
# shapes this file exists to avoid owning.
git_ai_install_hooks() {
	if ! "${RIOTBOX_GIT_AI_BIN}" install-hooks >/dev/null 2>&1; then
		echo "  [git-ai] WARN: install-hooks failed — attribution is off for this session." >&2
		return 1
	fi
}

# Confirm the daemon is reachable, warning rather than failing.
#
# A dead daemon means attribution silently records nothing, which is worth
# telling the user about. It is not worth aborting a session over: the agent's
# actual work is unaffected, and a hard failure here would make a broken
# analytics sidecar into a broken container.
git_ai_check_daemon() {
	if ! "${RIOTBOX_GIT_AI_BIN}" bg status >/dev/null 2>&1; then
		echo "  [git-ai] WARN: background service is not responding — commits will not be attributed." >&2
	fi
}

# Take this session's wiring back out for every agent that can do it.
#
# This is not optional housekeeping. Session directories outlive images, so a
# directory wired by an on-run and reopened without a working feature would keep
# firing PreToolUse and PostToolUse hooks at a binary whose config is gone —
# every tool call paying for a checkpoint that records nothing. This is the same
# class of failure container/codegraph-setup.sh exists to undo.
#
# The verb is optional, so absence is probed with `declare -F` rather than left
# for agent_call to report — matching context_mode_strip_all, which does the
# same for the same reason. The alternative spelling, discarding agent_call's
# stderr, takes the strip verbs' own output with it: those verbs say what they
# removed and, more importantly, what they could NOT remove, and a silenced
# warning leaves the user believing the wiring is gone while stale hooks fire on
# every tool call.
git_ai_strip_all() {
	local agent
	for agent in "${AGENT_REGISTRY[@]:-}"; do
		[[ -n "${agent}" ]] || continue
		declare -F "agent_${agent}_git_ai_strip" >/dev/null || continue
		agent_call "${agent}" git_ai_strip
	done
}

# Entry point, called from entrypoint.sh.
git_ai_setup() {
	if ! git_ai_enabled; then
		git_ai_strip_all
		return 0
	fi

	# A missing binary reaches the same end state as the feature being switched
	# off — nothing will maintain the wiring this session — so it gets the same
	# remedy. Warning and returning here would leave a session directory holding
	# hooks that name a path which no longer resolves.
	if [[ ! -x "${RIOTBOX_GIT_AI_BIN}" ]]; then
		echo "  [git-ai] WARN: ${RIOTBOX_GIT_AI_BIN} is missing — attribution is off." >&2
		git_ai_strip_all
		return 0
	fi

	git_ai_write_config
	git_ai_stamp_version
	git_ai_install_hooks || return 0
	git_ai_check_daemon
}
