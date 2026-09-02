#!/usr/bin/env bash
# plugin-setup.sh — Plugin lifecycle management inside the container.
#
# Sourced by entrypoint.sh. Provides:
#   plugin_setup — configure settings.json, copy staged and host plugins,
#                  install marketplace plugins, wire statusline, sync enabled
#
# Plugin precedence (lowest → highest):
#   1. Pre-staged defaults (baked into the image at build time)
#   2. Marketplace plugins from plugins.conf or RIOTBOX_PLUGINS env var
#   3. Host plugins copied from ~/.host-plugins (bind-mounted read-only)

# Print the Context Mode tree the image staged for this session, or nothing.
#
# Which tree, and nothing else about it. Whether it is usable is the separate
# question context_mode_staged_version answers, for the one caller that decides
# anything on it; whether this session actually registered it is a third
# question, and the two registry files are where that one is read. Keeping this
# one a pure lookup is what lets both callers below name the same tree while
# deciding different things about it — the registration on usability, the
# host-plugin copy in step 5 on what the registration then recorded.
#
# Nothing means one of two things, and no caller needs to tell them apart.
# RIOTBOX_CONTEXT_MODE off is the feature's opt-in gate — only the literal "1"
# enables it, the same test container/context-mode-setup.sh makes. A tree the
# image does not carry is what an image built before the staging layer existed,
# or one deliberately built without it, looks like. In both states this session
# has no staged Context Mode, which is the whole of what a caller acts on.
#
# The toggle is tested here rather than at the two call sites because that is
# what keeps them from disagreeing about whether a staged tree is in play at all:
# the registration below and the host-plugin copy in step 5 both branch on this
# one answer, and a session where one of them thought a tree was in play and the
# other did not would register a plugin whose directory nothing filled. That is
# the whole of what step 5 takes from here — a staged tree existing is necessary
# for it to stand down and is not sufficient, the rest of its question being
# answered by what the registration wrote against that tree. There is
# deliberately no way for an in-process caller to ask for the raw staging path
# around the toggle — a future one wanting it has to add it and say why.
#
# One caller does resolve that path outside this function, and it is not a lapse
# in the rule above: preflight_check_context_mode in scripts/preflight.sh
# reimplements this lookup in the probe script it sends into the image. It has
# to. That probe runs inside a container where nothing in this file is sourced,
# and it asks a different question — is this image's staged tree usable at all —
# from the per-session one answered here, whose toggle test would reduce a
# doctor run to "nothing staged" for reasons doctor has already handled.
#
# CHANGE BOTH TOGETHER. A different default, a different -maxdepth, or dropping
# the version sort here without the same edit there puts doctor on a tree the
# session does not read, and the whole worth of that check is that it fails on
# an image the session would find nothing in. context_mode_staged_version below
# is duplicated there for the same reason and under the same rule.
#
# One stamped directory per image. The newest is taken by version sort so a
# hand-built image carrying two does not depend on glob order: v1.0.9 sorts after
# v1.0.169 lexically, and picking the older tree would pin the session to a
# plugin the image no longer intends to ship.
context_mode_staged_path() {
	[[ "${RIOTBOX_CONTEXT_MODE:-0}" == "1" ]] || return 0
	local plugin_dir="${RIOTBOX_CM_PLUGIN_DIR:-${HOME}/.riotbox/context-mode-plugin}"
	# shellcheck disable=SC2312  # a failing find prints nothing, which every caller reads as "nothing staged" — the quiet no-op this owes an image built without the staging layer
	find "${plugin_dir}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null |
		sort -V | tail -n 1
}

# Print the version the staged tree at $1 declares, or fail if it declares none.
#
# This is the whole of what makes a staged tree usable here. The registry
# records the version Claude Code shows the user and compares against the
# marketplace, so a tree that cannot state its own is not registered at all
# rather than registered as something it is not — and a tree that is not
# registered is not one this session can use.
#
# One in-process caller, the registration below. The host-plugin copy in step 5
# used to ask this too and now reads what the registration wrote instead; the
# argument for that is at the gate, and is not repeated here.
#
# A second copy of this test lives in the doctor probe in scripts/preflight.sh,
# for the reason given on context_mode_staged_path above, and is bound by the
# same rule from a distance: doctor must never accept a tree this function would
# refuse, or it reports green on one the session is about to unregister. Loosen
# the gate here and the probe there has to be loosened with it.
context_mode_staged_version() {
	local package_json="${1}/package.json"
	[[ -f "${package_json}" ]] || return 1
	local version
	# Type-gated, because -r renders whatever it is handed: a number, an object
	# or an array in this field would otherwise reach the registry as the string
	# "123", "{}" or "[]" — registering the tree as something it is not, which is
	# the one thing reading the version prevents. select drops every other type,
	# so a jq failure, a document with no version, and a version that is not a
	# string are one answer to the caller: nothing to register this tree as.
	version="$(jq -r '.version | select(type == "string")' "${package_json}" 2>/dev/null)" || return 1
	[[ -n "${version}" ]] || return 1
	printf '%s\n' "${version}"
}

# Register the image-staged Context Mode plugin against this session's plugin
# registry, without copying it.
#
# The staged tree is ~60 MB and ~/.claude is a bind mount of the host session
# directory, so a copy would cost that much host disk per project-set key. The
# registry entry names the image path instead, and the tree is read in place.
#
# The path a session records can outlive the image that provided it: the staged
# tree is version-stamped, so a rebuild at a new ref leaves an older session
# directory pointing at a directory that is gone. Rather than trust the recorded
# value, this rebuilds the entry from whatever is staged now — which makes it
# both the installer and the reconciler, and makes a second call in the same
# session a no-op.
#
# Every path that declines to register hands over to
# context_mode_plugin_unregister instead of returning: nothing staged for this
# session (the toggle off, or an image that carries no tree), and a staged tree
# this code cannot read. The session directory outlives the run, so what an
# earlier image recorded is still there — and it names a version-stamped path
# this image does not have. Leaving it is the "surface the plugin, then fail to
# load every hook in it" outcome below, arrived at from the other direction, and
# it is why refusing to write is not the same as arriving at nothing registered.
# The paths that fail reading, building, formatting or writing these two files
# return instead. Not because a removal could not be attempted — when the
# marketplace file is the corrupt one, the registry beside it is still perfectly
# readable and writable — but because the rule below refuses both halves of one
# fact together, and a call that cannot record that fact does not get to act on
# half of it either. Removing half is acting on it.
#
# One rule this function does not follow is the under-remove rule its removal
# counterpart does: the entry is replaced outright, host entry and all. That is
# deliberate and it is not an oversight of that rule — see the replacement
# below for why a host entry may not sit beside this one.
#
# The two files record one fact between them — where this session's Context Mode
# is — so both replacement documents are parsed, built and formatted before
# either is written, the rule agents/claude/forge-mcp.sh states for the config it
# owns and the one docs/dev/agent-contract.md puts on a wire verb. Every failure
# that can be seen before the filesystem is touched at all is therefore seen
# while both files are still exactly as the user left them, rather than after
# the registry has been committed to a path the marketplace file never learns
# about. That covers both files being unreadable, both entries being unbuildable
# and both documents being unformattable — every way this can fail except the
# writes themselves.
#
# What that does not buy is a transaction, and nothing here should be read as
# claiming one. json_write_atomic makes each file's replacement atomic on its
# own; the pair is not atomic, so an I/O failure on the second write, or the
# process being killed between the two, still leaves one file updated and the
# other not. No rollback is attempted: the compensating write would go to the
# same directory with the same tools that just failed, and it would trade a
# registered plugin whose marketplace record is stale for no plugin at all. This
# function is a reconciler that rebuilds both files from what is staged now and
# runs at every session start, and that is what repairs the pair.
#
# The rule has a cost and it falls here rather than on the removal. A registry
# entry an earlier image wrote, naming a version-stamped path this image no
# longer carries, now survives a session whose only real problem is a corrupt
# known_marketplaces.json: the readable half could have been reconciled and
# deliberately is not. That is the dangling registration this function otherwise
# exists to prevent, kept standing by an unrelated file, and nothing clears it
# before the next session that can read both.
#
# context_mode_plugin_unregister answers the same question the other way: it
# judges each file on its own evidence. The asymmetry is deliberate and its
# argument, with the request to move both rules together, is in that header.
#
# Every failure warns and returns 0. A session without this plugin is degraded,
# not broken, and the caller runs before the rest of plugin_setup. Nothing here
# reports the outcome to that session's Context Mode wiring either:
# context_mode_setup asks ~/.claude/plugins/installed_plugins.json instead, so
# that a plugin arriving from the host — which this function declines to
# register and its removal deliberately spares — counts for as much as a
# registration made here.
context_mode_plugin_register() {
	local registry="${HOME}/.claude/plugins/installed_plugins.json"
	local marketplaces="${HOME}/.claude/plugins/known_marketplaces.json"

	# ── 1. Read: the staged tree, then both registry documents ────────────
	local staged
	staged="$(context_mode_staged_path)"
	if [[ -z "${staged}" ]]; then
		context_mode_plugin_unregister
		return 0
	fi

	# An image that stages a tree stating no version is a build defect, so this
	# says so rather than declining quietly — the session has just lost the
	# registration the image was built to make. It also names what happens next,
	# because the outcome is not "no Context Mode": step 5 stands down only for a
	# tree this session's two registry documents already name, which the removal
	# below is about to stop being true, so where the session has a host copy that
	# copy is taken instead and is what it ends up running.
	local version
	if ! version="$(context_mode_staged_version "${staged}")"; then
		echo "  [plugins] WARNING: ${staged}/package.json is missing, unreadable, or declares no version — Context Mode plugin not registered; a host copy, if this session has one, stands in for it." >&2
		context_mode_plugin_unregister
		return 0
	fi

	# Both registry files are hand-editable and live in the host session
	# directory, so a document jq cannot read is left exactly as it is — the same
	# refusal agent_claude_context_mode_strip makes for settings.json. Reading
	# them compacted also gives the comparison that skips the write when this
	# call would change nothing.
	local current='{"version":2,"plugins":{}}'
	if [[ -f "${registry}" ]]; then
		if ! current="$(jq -c '.' "${registry}" 2>/dev/null)" || [[ -z "${current}" ]]; then
			echo "  [plugins] WARNING: ${registry} is not valid JSON — Context Mode plugin not registered." >&2
			return 0
		fi
	fi

	# Read here beside the registry rather than beside the write that consumes
	# it: the all-or-nothing rule in the header is what puts it this far up.
	local markets_current='{}'
	if [[ -f "${marketplaces}" ]]; then
		if ! markets_current="$(jq -c '.' "${marketplaces}" 2>/dev/null)" ||
			[[ -z "${markets_current}" ]]; then
			echo "  [plugins] WARNING: ${marketplaces} is not valid JSON — Context Mode marketplace not registered." >&2
			return 0
		fi
	fi

	# ── 2. Build: both entries, neither written ───────────────────────────
	# The entry is replaced, not appended to: a stale stamped path recorded by an
	# earlier image has to leave, and a v2 value is an array Claude Code reads
	# whole. `.version` is preserved when the file already declares one so a
	# future format bump is not silently rolled back to 2.
	#
	# Replacing takes a host-installed entry with it, and that is the intent
	# rather than a lapse in the under-remove rule context_mode_plugin_unregister
	# follows. That rule binds removal — do not destroy what cannot be proven
	# ours — and reaching this line means the feature is on and the image staged
	# a tree, the one state in which this key names one thing. Step 5 refuses to
	# copy the host tree once both writes below have landed, so an entry left
	# beside this one would name a cache path nothing filled, and Claude Code
	# reading the array whole could take it: exactly the dangling registration
	# this function and that skip both exist to prevent. Where only one write
	# lands, or none, this replacement is not written either and step 5 does copy
	# the host tree in — the two move together, which is the point. The host copy
	# is spared where it is the session's Context Mode — toggle off, or nothing
	# staged — and there the early return above means this line is never reached.
	local updated
	if ! updated="$(jq -c --arg path "${staged}" --arg version "${version}" '
		.version = (.version // 2)
		| .plugins = ((.plugins // {})
			| .["context-mode@context-mode"] =
				[{scope: "user", installPath: $path, version: $version}])
	' <<<"${current}" 2>/dev/null)" || [[ -z "${updated}" ]]; then
		echo "  [plugins] WARNING: could not build the Context Mode entry for ${registry} — plugin not registered." >&2
		return 0
	fi

	# The staged tree is its own marketplace: upstream's .claude-plugin/
	# marketplace.json declares the plugin with source "./", so the marketplace
	# install location and the plugin install path are the same directory.
	# autoUpdate stays false — the image pins the ref, and an update would go to
	# the network from a session that may have none.
	local markets_updated
	if ! markets_updated="$(jq -c --arg path "${staged}" '
		.["context-mode"] = {source: {source: "github", repo: "mksglu/context-mode"},
		                     installLocation: $path,
		                     autoUpdate: false}
	' <<<"${markets_current}" 2>/dev/null)" || [[ -z "${markets_updated}" ]]; then
		echo "  [plugins] WARNING: could not build the Context Mode entry for ${marketplaces} — marketplace not registered." >&2
		return 0
	fi

	# ── 3. Format: both documents, still nothing written ──────────────────
	# Pretty-printed for the write: Claude Code writes these files indented and
	# users read them, so reflowing a whole document onto one line would be a far
	# larger change than the one entry being made.
	#
	# A document that already says what this call would say is not formatted at
	# all, and the empty string that leaves stands for "nothing to write" in the
	# phase below. jq printing nothing is a failure caught here, so an empty
	# value can only mean the comparison matched — which is what lets the second
	# call in a session write nothing, and say nothing, when the host merge left
	# the entry alone. It does not promise that: a session whose host mount
	# carries a context-mode of its own has that entry overwritten by the step-5
	# merge every start, so the re-assert has real work every time and announces
	# it every time. The guarantee is "no write without a change", not "silent
	# after the first run".
	local pretty='' markets_pretty=''
	if [[ "${updated}" != "${current}" ]]; then
		if ! pretty="$(jq . <<<"${updated}")" || [[ -z "${pretty}" ]]; then
			echo "  [plugins] WARNING: could not format the Context Mode entry for ${registry} — plugin not registered." >&2
			return 0
		fi
	fi
	if [[ "${markets_updated}" != "${markets_current}" ]]; then
		if ! markets_pretty="$(jq . <<<"${markets_updated}")" || [[ -z "${markets_pretty}" ]]; then
			echo "  [plugins] WARNING: could not format the Context Mode entry for ${marketplaces} — marketplace not registered." >&2
			return 0
		fi
	fi

	# ── 4. Write: both files ──────────────────────────────────────────────
	# Nothing above this line has written anything, and nothing below it can
	# fail for a reason this code could have seen earlier. What is left is the
	# filesystem, and the header says plainly what these two writes do and do
	# not guarantee together.
	local wrote=0
	if [[ -n "${pretty}" ]]; then
		wrote=1
		if ! json_write_atomic "${registry}" "${pretty}"; then
			echo "  [plugins] WARNING: could not write ${registry} — Context Mode plugin not registered." >&2
			return 0
		fi
	fi
	if [[ -n "${markets_pretty}" ]]; then
		wrote=1
		if ! json_write_atomic "${marketplaces}" "${markets_pretty}"; then
			echo "  [plugins] WARNING: could not write ${marketplaces} — Context Mode marketplace not registered." >&2
			return 0
		fi
	fi

	# Said once, by whichever call actually changed something: this runs twice per
	# session start, and a second line reporting a registration nobody made would
	# read as a repeat install.
	if ((wrote)); then
		echo "  [plugins] Context Mode ${version} registered at ${staged}."
	fi
}

# Remove the registration this project made against its own staged tree.
#
# Both no-register paths land here, and neither can settle for declining to
# write. ~/.claude is a bind mount of the host session directory, which outlives
# the image and can be reopened under a different toggle, so an entry an earlier
# run wrote stays until something takes it out: without this, RIOTBOX_CONTEXT_MODE
# off would stop enabling Context Mode and never disable it, and a rollback or a
# rebuild that drops the staging layer would leave an entry naming a directory
# that is gone — the plugin surfaced, every hook in it failing to load, which is
# the outcome the registration above refuses to create in the first place.
#
# Under-remove rather than over-remove, the rule agent_claude_context_mode_strip
# follows: an entry is ours only if its installPath is inside
# RIOTBOX_CM_PLUGIN_DIR, the directory the image stages into. A context-mode the
# user installed on the host and mounted in resolves under the plugin cache
# instead, and is left exactly as found in both files — it is not what this
# toggle governs, and it is the only Context Mode some sessions have.
#
# The rule binds this function and not its counterpart. Registration replaces
# the whole entry, host record included, because it runs only where the staged
# tree is the session's one Context Mode; the reasoning is at that replacement.
#
# The two files are judged independently, and that is the one thing this
# function does not share with the registration. Registration records a single
# fact in two places and so refuses both halves together; removal asks two
# questions — is this registry entry ours, is this marketplace entry ours — and
# a host merge can leave the marketplace naming a host path while the registry
# still names a staged one, so neither answer may constrain the other. Coupling
# them would let a marketplace file no answer can be read out of keep a registry
# entry this code can prove it wrote, and that entry is the one that surfaces a
# plugin whose every hook then fails to load. Whoever revisits either rule should
# move both together or neither.
#
# What is shared is the write phase: both answers are computed and formatted
# before either file is written, so the two writes sit next to each other with
# no work left between them that could still fail. That is as close to
# all-or-nothing as two files allow here, and no closer — json_write_atomic
# makes each replacement atomic on its own, the pair is not atomic, and the
# process being killed between the two writes leaves one file cleaned and the
# other not. Unlike the registration this is not called at every session start —
# only its three decline paths reach here — but the states that reach it (the
# toggle off, an image staging nothing, a staged tree that cannot be read) are
# properties of the image and the environment, so they still hold at the next
# start and a half-cleaned pair is re-reached and finished then.
#
# Every failure warns and returns 0, like the registration. A session carrying a
# stale entry is degraded, not broken.
context_mode_plugin_unregister() {
	local plugin_dir="${RIOTBOX_CM_PLUGIN_DIR:-${HOME}/.riotbox/context-mode-plugin}"
	local registry="${HOME}/.claude/plugins/installed_plugins.json"
	local marketplaces="${HOME}/.claude/plugins/known_marketplaces.json"
	local removed=""

	# The prefix the filters below match on is "${plugin_dir}/", so a trailing
	# slash on the override would end it "//" and match nothing find emits —
	# a removal that silently does nothing. Stripped rather than tolerated,
	# leaving "/" alone: emptying the variable would make the prefix match every
	# absolute path there is, which is the one direction this must never fail in.
	while [[ "${plugin_dir}" == */ && "${plugin_dir}" != "/" ]]; do
		plugin_dir="${plugin_dir%/}"
	done

	# One definition of ownership, prefixed to both jq programs below. The two
	# files spell the path differently — .installPath against
	# .["context-mode"].installLocation — so a rule written at each site would be
	# two things to tighten the day this test moves, with only one of them under
	# test.
	#
	# Wrapped in `// null` because the argument is a filter evaluated in the
	# caller's context: `.installPath` against a JSON string yields no value at
	# all, and a predicate that answers nothing rather than false would take the
	# element out of the `map(select(...))` below — over-removing on exactly the
	# shape it cannot read. The startswith test is textual on top of that, and a
	# path can start with the prefix and still resolve outside it, so a ".."
	# segment below the directory disqualifies the entry: what this proves it
	# owns is what the image staged, and a traversal is not that.
	# shellcheck disable=SC2016  # $p is jq's own binding and $dir is its --arg; the shell must not expand either
	local owned_def='def owned(path): (path // null) as $p
		| ($p | type) == "string"
			and ($p | startswith($dir))
			and ($p | ltrimstr($dir) | split("/") | index("..") | not);
	'

	# Both decisions first, formatted and held, then both writes. An empty value
	# means this file needs no write — either nothing in it was ours, or the
	# answer could not be read out of it and the warning has already said so.
	local pretty='' markets_pretty=''

	if [[ -f "${registry}" ]]; then
		local current stripped
		if ! current="$(jq -c '.' "${registry}" 2>/dev/null)" || [[ -z "${current}" ]]; then
			echo "  [plugins] WARNING: ${registry} is not valid JSON — Context Mode registration left in place." >&2
		elif ! stripped="$(jq -c --arg dir "${plugin_dir}/" "${owned_def}"'
			# Type-gated the whole way down, because this file is hand-editable
			# and jq raises rather than answering false when a path indexes
			# something that is not an object. A shape this filter cannot read
			# is not one it can prove is ours.
			#
			# The v2 value is an array, so ours are filtered out of it and the
			# key itself goes only once nothing is left — an entry sharing the
			# key from somewhere else keeps it.
			if type == "object"
				and (.plugins | type) == "object"
				and (.plugins["context-mode@context-mode"] | type) == "array" then
				.plugins["context-mode@context-mode"] |= map(select(owned(.installPath?) | not))
				| if (.plugins["context-mode@context-mode"] | length) == 0
					then del(.plugins["context-mode@context-mode"]) else . end
			else . end
			' <<<"${current}" 2>/dev/null)"; then
			echo "  [plugins] WARNING: could not clean ${registry} — Context Mode registration left in place." >&2
		elif [[ "${stripped}" != "${current}" ]]; then
			# Empty-checked as well as status-checked: an unchecked command
			# substitution yields "" when jq prints nothing, and the writer would
			# put a lone newline where the user's registry was. Reset on failure
			# so the write phase reads it as the "nothing to write" it is.
			if ! pretty="$(jq . <<<"${stripped}")" || [[ -z "${pretty}" ]]; then
				pretty=''
				echo "  [plugins] WARNING: could not format the cleaned ${registry} — Context Mode registration left in place." >&2
			fi
		fi
	fi

	if [[ -f "${marketplaces}" ]]; then
		local markets_current markets_stripped
		if ! markets_current="$(jq -c '.' "${marketplaces}" 2>/dev/null)" ||
			[[ -z "${markets_current}" ]]; then
			echo "  [plugins] WARNING: ${marketplaces} is not valid JSON — Context Mode marketplace left in place." >&2
		elif ! markets_stripped="$(jq -c --arg dir "${plugin_dir}/" "${owned_def}"'
			# The object test has to come first even though owned() type-checks
			# the value: indexing a non-object raises rather than answering, and
			# `and` is what short-circuits before it can.
			if type == "object"
				and (.["context-mode"] | type) == "object"
				and owned(.["context-mode"].installLocation)
			then del(.["context-mode"]) else . end
			' <<<"${markets_current}" 2>/dev/null)"; then
			echo "  [plugins] WARNING: could not clean ${marketplaces} — Context Mode marketplace left in place." >&2
		elif [[ "${markets_stripped}" != "${markets_current}" ]]; then
			if ! markets_pretty="$(jq . <<<"${markets_stripped}")" || [[ -z "${markets_pretty}" ]]; then
				markets_pretty=''
				echo "  [plugins] WARNING: could not format the cleaned ${marketplaces} — Context Mode marketplace left in place." >&2
			fi
		fi
	fi

	if [[ -n "${pretty}" ]]; then
		if json_write_atomic "${registry}" "${pretty}"; then
			removed="registration"
		else
			echo "  [plugins] WARNING: could not write ${registry} — Context Mode registration left in place." >&2
		fi
	fi
	if [[ -n "${markets_pretty}" ]]; then
		if json_write_atomic "${marketplaces}" "${markets_pretty}"; then
			removed="${removed:+${removed} and }marketplace entry"
		else
			echo "  [plugins] WARNING: could not write ${marketplaces} — Context Mode marketplace left in place." >&2
		fi
	fi

	# Said only by the call that changed something. This runs twice per session
	# start, and the common case — a session that never had Context Mode — must
	# not be told about a cleanup that did not happen.
	[[ -n "${removed}" ]] || return 0
	echo "  [plugins] Removed the staged Context Mode ${removed} left in ${HOME}/.claude/plugins."
}

# Copy one host plugin cache entry into this session's plugin cache.
#
# Safety: dereference symlinks, so a symlink on the host cannot point this
# session's plugin tree at a sensitive container path. `cp -rL` would abort on
# the first dangling symlink (e.g. left by a host-side install/uninstall race or
# a partial git fetch). Instead, pre-filter with `find -L … ! -type l` — under
# `-L`, valid symlinks report their target's type, so only broken symlinks
# retain `-type l` — then stream paths through `tar -h` to dereference and copy.
# The setuid/setgid strip belongs to the caller: it runs once over the finished
# tree rather than once per entry.
#
# The pipeline's shape is preserved verbatim from the loop this was extracted
# from, including the fact that its exit status is the extracting tar's. What
# changed is that the caller now reports that status instead of discarding it.
#
# Both values are arguments rather than reads of plugin_setup's locals: bash's
# dynamic scoping would make the latter work, and would make this function
# silently dependent on being called from exactly one place.
_copy_host_plugin_entry() {
	local cache_dir="${1:?_copy_host_plugin_entry: cache dir required}"
	local entry_name="${2:?_copy_host_plugin_entry: entry name required}"
	# shellcheck disable=SC2312  # subshell pipeline; cd guard via && and tar consumes find's stream
	(
		cd "${cache_dir}" &&
			find -L "${entry_name}" ! -type l -print0 |
			tar -ch --null --no-recursion --files-from=- -f -
	) | tar -xf - -C ~/.claude/plugins/cache/ --no-same-owner
}

plugin_setup() {
	local STAGING_DIR="${HOME}/.riotbox/plugins-staging/.claude"
	local HOST_PLUGINS_DIR="${HOME}/.host-plugins"
	local PLUGINS_CONF="${HOME}/.config/riotbox/plugins.conf"

	# ── 1. Seed settings.json ──────────────────────────────────────────────
	# Create on first run, or strip legacy enabledPlugins from prior versions.
	# Host settings.json is intentionally NOT synced — it contains hooks,
	# permission rules, and paths that reference the host filesystem and
	# would break or cause unexpected behavior inside the container.
	if [[ ! -f ~/.claude/settings.json ]]; then
		jq -n '{
            promptSuggestionEnabled: false,
            skipDangerousModePermissionPrompt: true,
            autoCompact: true
        }' >~/.claude/settings.json
	elif jq -e '.enabledPlugins' ~/.claude/settings.json &>/dev/null; then
		jq 'del(.enabledPlugins)' ~/.claude/settings.json >~/.claude/settings.json.tmp &&
			mv ~/.claude/settings.json.tmp ~/.claude/settings.json
	fi

	# ── 2. Copy pre-staged plugins (first run only) ────────────────────────
	# Pre-installed at build time into ~/.riotbox/plugins-staging/ to avoid
	# network access and Node.js spawns at startup. Guard with a stamp file
	# so this runs exactly once per session, not on every startup.
	if [[ ! -f ~/.claude/plugins/.staged ]] && [[ -d "${STAGING_DIR}/plugins" ]]; then
		# `cp -a` is `-dR --preserve=all`, which includes context+xattr.
		# When the destination lands on fuse-overlayfs (overlay mode), the
		# fsetxattr syscall used to copy the SELinux label is denied by the
		# kernel ("AVC: denied { relabelto } … tcontext=…fusefs_t"). Drop
		# those two attributes; mode/timestamps/links are still preserved.
		with_progress "  [plugins] Copying pre-staged plugins" \
			cp -a --no-preserve=context,xattr "${STAGING_DIR}/plugins/"* ~/.claude/plugins/
		# Fix paths — staging used a different HOME.
		# This substitution is safe for sed because STAGING_DIR is a known
		# build-time constant (no user content), unlike host plugin paths.
		sed -i "s|${STAGING_DIR}|${HOME}/.claude|g" \
			~/.claude/plugins/installed_plugins.json \
			~/.claude/plugins/known_marketplaces.json 2>/dev/null || true
		# Merge marketplace registration into settings.json
		if [[ -f "${STAGING_DIR}/settings.json" ]]; then
			local marketplaces
			marketplaces="$(jq '.extraKnownMarketplaces // {}' "${STAGING_DIR}/settings.json")"
			jq --argjson m "${marketplaces}" \
				'.extraKnownMarketplaces = ($m + (.extraKnownMarketplaces // {}))' \
				~/.claude/settings.json >~/.claude/settings.json.tmp &&
				mv ~/.claude/settings.json.tmp ~/.claude/settings.json
		fi
		touch ~/.claude/plugins/.staged
	fi

	# ── 3. Register the image-staged Context Mode plugin ───────────────────
	# Runs on every session start rather than once behind the .staged stamp: the
	# staged path is version-stamped and a rebuild moves it, so the registration
	# is reconciled rather than seeded. Placed before the marketplace-install
	# loop so a plugins.conf entry naming context-mode sees the staged tree as
	# already installed and never spawns `claude plugin install` against the
	# network. With RIOTBOX_CONTEXT_MODE off there is no entry left for it to
	# see — this call removes one instead — so step 4 refuses that install
	# outright rather than relying on the ordering.
	context_mode_plugin_register

	# ── 4. Install marketplace plugins from config or env ─────────────────
	# RIOTBOX_PLUGINS (comma-separated) replaces plugins.conf entirely.
	# Plugins already present in installed_plugins.json are skipped to avoid
	# spawning Node.js processes on every startup.
	local plugin_list=""

	if [[ -n "${RIOTBOX_PLUGINS:-}" ]]; then
		plugin_list="${RIOTBOX_PLUGINS}"
		echo "  [plugins] Using RIOTBOX_PLUGINS env var."
	elif [[ -f "${PLUGINS_CONF}" ]]; then
		while IFS= read -r line || [[ -n "${line}" ]]; do
			line="${line%%#*}"
			line="$(echo "${line}" | xargs)"
			[[ -z "${line}" ]] && continue
			if [[ -z "${plugin_list}" ]]; then
				plugin_list="${line}"
			else
				plugin_list="${plugin_list},${line}"
			fi
		done <"${PLUGINS_CONF}"
	fi

	if [[ -n "${plugin_list}" ]]; then
		# shellcheck disable=SC2312  # pure-transform pipeline; echo/tr cannot fail meaningfully
		echo "${plugin_list}" | tr ',' '\n' | while IFS= read -r plugin; do
			plugin="$(echo "${plugin}" | xargs)"
			[[ -z "${plugin}" ]] && continue
			# Validate plugin name to prevent argument injection
			if [[ ! "${plugin}" =~ ^[a-zA-Z0-9/_-]+$ ]]; then
				echo "  [plugins] WARNING: Ignoring invalid plugin name: ${plugin}" >&2
				continue
			fi
			# Context Mode has a toggle of its own, and with it on step 3 has
			# already registered the staged tree, so this line never reaches the
			# network anyway. Installing it only while the feature is off would
			# invert that switch, and would land an entry under the plugin cache
			# that context_mode_plugin_unregister cannot tell from a host
			# install and step 7 would enable.
			#
			# Bare name only, the spelling the registry check below also
			# assumes; the validator above has already rejected the "@" that
			# would write a qualified one.
			if [[ "${plugin}" == "context-mode" && "${RIOTBOX_CONTEXT_MODE:-0}" != "1" ]]; then
				echo "  [plugins] WARNING: Not installing context-mode from a marketplace — RiotBox owns Context Mode and RIOTBOX_CONTEXT_MODE is off; set it to 1 to register the tree the image staged, where it staged a usable one. Any context-mode copied in from the host is left alone." >&2
				continue
			fi
			# v2 format uses qualified keys ("plugin@marketplace"), so match
			# both exact name and any key starting with "name@".
			if jq -e --arg p "${plugin}" \
				'.plugins | has($p) or ([keys[] | select(startswith($p + "@"))] | length > 0)' \
				~/.claude/plugins/installed_plugins.json &>/dev/null; then
				echo "  [plugins] ${plugin}: already installed."
			else
				with_progress "  [plugins] Installing ${plugin}" \
					claude plugin install "${plugin}" ||
					echo "  [plugins] WARNING: Failed to install ${plugin}." >&2
			fi
		done
	fi

	# ── 5. Copy host plugins (highest precedence, overwrites others) ───────
	# ~/.host-plugins is bind-mounted read-only from the host's ~/.claude/plugins.
	if [[ -d "${HOST_PLUGINS_DIR}" ]]; then
		echo "  [plugins] Copying host plugins..."
		# Copy cache directories (plugin source trees), skipping temp_git_*
		# leftovers from interrupted `claude plugin install` on the host. The
		# per-entry copy and its symlink handling live in
		# _copy_host_plugin_entry above; the setuid/setgid strip runs once over
		# the finished tree, below.
		#
		# The image's staged Context Mode tree is authoritative where this session
		# has registered it: it carries the pinned-interpreter rewrite and the
		# offline dependency install that a host tree has never been through. A
		# host copy still invokes a bare `node`, which here resolves to the image
		# default Node 20 — below the node:sqlite floor Context Mode needs —
		# sending every hook into ensure-deps.mjs, where an image built with
		# RIOTBOX_NETWORK=none spends 120 seconds per invocation and never
		# succeeds. Skipping it also keeps the 60 MB out of a session directory
		# that would only ignore it.
		#
		# Empty unless both registry documents already name the tree
		# context_mode_staged_path resolves now — the literal test, and not quite
		# "step 3 registered it this run": a pair an earlier start left standing
		# counts, and a removal that could not finish does not. It is the question
		# this loop has anyway, since what it would withhold the host copy in
		# favour of is whatever the registry calls this session's Context Mode.
		#
		# Reading that back out of the files step 3 writes, rather than re-deriving
		# it from the image, covers every way step 3 can decline without this code
		# knowing what they are. Standing down for a registration that did not
		# happen protects nothing and costs the session the only Context Mode it
		# could have had — worse than nothing, because the merge below still
		# records the host entry onto a cache path this loop declined to fill,
		# surfacing a plugin whose every hook then fails to load.
		#
		# Both documents, because the registration refuses both halves of its one
		# fact together and a pair with one half standing is not a registration.
		# Where the missing half cannot be rebuilt that costs the session the
		# staged tree — the host copy comes in and runs on the slower hooks this
		# carve-out exists to avoid — and the trade is deliberate: a plugin that
		# loads slowly is recoverable, an entry naming a directory nothing filled
		# is not. A document naming something else and one jq cannot read are the
		# same answer here.
		local cm_staged
		cm_staged="$(context_mode_staged_path)"
		if [[ -n "${cm_staged}" ]]; then
			if ! jq -e --arg p "${cm_staged}" \
				'.plugins["context-mode@context-mode"] | any(.installPath == $p)' \
				~/.claude/plugins/installed_plugins.json &>/dev/null ||
				! jq -e --arg p "${cm_staged}" '.["context-mode"].installLocation == $p' \
					~/.claude/plugins/known_marketplaces.json &>/dev/null; then
				cm_staged=""
			fi
		fi
		if [[ -d "${HOST_PLUGINS_DIR}/cache" ]]; then
			for entry in "${HOST_PLUGINS_DIR}/cache/"*; do
				[[ -e "${entry}" ]] || continue
				local entry_name
				entry_name="$(basename "${entry}")"
				[[ "${entry_name}" == temp_git_* ]] && continue
				# Skipped by marketplace directory name, the granularity this loop
				# copies at: upstream publishes context-mode from its own
				# same-named marketplace, which is what `claude plugin install`
				# records as context-mode@context-mode.
				[[ -n "${cm_staged}" && "${entry_name}" == "context-mode" ]] && continue
				# Per entry rather than once for the whole loop: a host cache
				# with several large plugins otherwise reports one opaque
				# duration, and the entry name is the part that tells a user
				# which copy is the slow one.
				#
				# This status used to be discarded — the pipeline had no `||`
				# and nothing read `$?`. It stays non-fatal and the loop still
				# continues, but a partial copy is now visible instead of
				# silent, because a half-copied plugin tree is exactly the
				# fault that produces an unexplainable session later.
				with_progress "  [plugins] Copying host plugin ${entry_name}" \
					_copy_host_plugin_entry "${HOST_PLUGINS_DIR}/cache" "${entry_name}" ||
					true
			done
			find ~/.claude/plugins/cache/ -perm /6000 -exec chmod ug-s {} + 2>/dev/null || true
		fi
		# Merge installed_plugins.json: host entries overwrite existing entries.
		# The host's JSON contains paths from the host filesystem (e.g.
		# /home/alice/.claude/plugins/cache/...). We rewrite any path ending
		# in /.claude/plugins to the container's path using a regex.
		if [[ -f "${HOST_PLUGINS_DIR}/installed_plugins.json" ]]; then
			if [[ -f ~/.claude/plugins/installed_plugins.json ]]; then
				# Preserve version field (v2+) and merge plugin entries.
				jq -s '
                    (([.[].version // null] | map(select(. != null)) | max) as $v |
                     if $v then {version: $v} else {} end)
                    + {plugins: ((.[0].plugins // {}) * (.[1].plugins // {}))}
                ' \
					~/.claude/plugins/installed_plugins.json \
					"${HOST_PLUGINS_DIR}/installed_plugins.json" \
					>~/.claude/plugins/installed_plugins.json.tmp &&
					mv ~/.claude/plugins/installed_plugins.json.tmp \
						~/.claude/plugins/installed_plugins.json
			else
				cp "${HOST_PLUGINS_DIR}/installed_plugins.json" \
					~/.claude/plugins/installed_plugins.json
			fi
			# Rewrite host plugin paths to the container's plugin directory.
			# Uses jq (JSON-aware) instead of sed to avoid corrupting values
			# that happen to contain /.claude/plugins as a substring.
			jq --arg prefix "${HOME}/.claude/plugins" '
                walk(if type == "string" and test("/.claude/plugins/")
                     then sub(".*/.claude/plugins/"; $prefix + "/")
                     else . end)
            ' ~/.claude/plugins/installed_plugins.json \
				>~/.claude/plugins/installed_plugins.json.tmp &&
				mv ~/.claude/plugins/installed_plugins.json.tmp \
					~/.claude/plugins/installed_plugins.json
		fi
		# Merge known_marketplaces.json if present
		if [[ -f "${HOST_PLUGINS_DIR}/known_marketplaces.json" ]]; then
			if [[ -f ~/.claude/plugins/known_marketplaces.json ]]; then
				jq -s '(.[0] // {}) * (.[1] // {})' \
					~/.claude/plugins/known_marketplaces.json \
					"${HOST_PLUGINS_DIR}/known_marketplaces.json" \
					>~/.claude/plugins/known_marketplaces.json.tmp &&
					mv ~/.claude/plugins/known_marketplaces.json.tmp \
						~/.claude/plugins/known_marketplaces.json
			else
				cp "${HOST_PLUGINS_DIR}/known_marketplaces.json" \
					~/.claude/plugins/known_marketplaces.json
			fi
			jq --arg prefix "${HOME}/.claude/plugins" '
                walk(if type == "string" and test("/.claude/plugins/")
                     then sub(".*/.claude/plugins/"; $prefix + "/")
                     else . end)
            ' ~/.claude/plugins/known_marketplaces.json \
				>~/.claude/plugins/known_marketplaces.json.tmp &&
				mv ~/.claude/plugins/known_marketplaces.json.tmp \
					~/.claude/plugins/known_marketplaces.json
		fi
		# Both merges above let host entries win, which for Context Mode hands the
		# session a host-side absolute path that does not exist here, naming a
		# tree the loop above just refused to copy. Re-asserting undoes that
		# rather than carving an exception into the two merges and the path
		# rewrite that follows each: the registration rebuilds both files from
		# what is staged now, so it stays the one place that knows the shape of
		# those entries, and its second call in a session writes only what the
		# host merge changed. With nothing staged it is a second attempt at a
		# removal the first call may have been unable to write — the merges above
		# rewrite only paths under /.claude/plugins/ and so do not normally put a
		# staged path back — and the host's own Context Mode is left exactly as it
		# was merged.
		context_mode_plugin_register
	else
		echo "  [plugins] Notice: No host plugins found (~/.claude/plugins not mounted)."
	fi

	# ── 6. Wire statusline ─────────────────────────────────────────────────
	# Claude Code reads settings.json key "statusLine" as an object:
	#   { "type": "command", "command": "<path>" }
	if [[ -f ~/.claude/statusline-command.sh ]]; then
		jq '.statusLine = {"type": "command", "command": "/home/llm/.claude/statusline-command.sh"}' \
			~/.claude/settings.json >~/.claude/settings.json.tmp &&
			mv ~/.claude/settings.json.tmp ~/.claude/settings.json
	else
		jq 'del(.statusLine)' \
			~/.claude/settings.json >~/.claude/settings.json.tmp &&
			mv ~/.claude/settings.json.tmp ~/.claude/settings.json
	fi

	# ── 7. Sync enabledPlugins from installed_plugins.json ─────────────────
	# Done via jq (pure JSON) instead of `claude plugin enable` to avoid
	# spawning a Node.js process per plugin on every startup.
	#
	# Two hand-editable documents in the bind-mounted session directory, so each
	# read is checked and a document jq cannot read leaves both files exactly as
	# they are — the refusal the registration above makes for the same reason.
	# Neither read may abort the function either: a standalone assignment from a
	# failing command substitution trips a caller's `set -e`, which would
	# abandon plugin_setup here rather than at the end of it.
	#
	# The derived entries lose to the ones already in the file — `$p + existing`
	# — which is what re-enables a plugin the user switched off by hand at the
	# next start. Deliberate, pinned by tests/context-mode.venom.yml, unchanged.
	local registry="${HOME}/.claude/plugins/installed_plugins.json"
	local settings="${HOME}/.claude/settings.json"
	if [[ -f "${registry}" ]]; then
		local new_enabled synced
		# Type-gated the whole way down, because jq raises rather than answering
		# when a path indexes something that is not an object, and because the
		# one wrong shape that raises nothing — a `.plugins` array, whose `keys`
		# are its indices — would otherwise be read as a plugin list keyed by
		# numbers, or as an empty one. select emitting nothing makes a jq
		# failure and a shape this cannot read one answer to the branch below.
		if ! new_enabled="$(jq '
			select(type == "object" and (.plugins | type) == "object")
			| .plugins | keys | map({(.): true}) | add // {}
		' "${registry}" 2>/dev/null)" || [[ -z "${new_enabled}" ]]; then
			echo "  [plugins] WARNING: ${registry} is not valid JSON or does not list its plugins as an object — enabledPlugins left as it was." >&2
		elif ! synced="$(jq --argjson p "${new_enabled}" \
			'.enabledPlugins = ($p + (.enabledPlugins // {}))' \
			"${settings}" 2>/dev/null)" || [[ -z "${synced}" ]]; then
			echo "  [plugins] WARNING: ${settings} is not valid JSON — enabledPlugins not synced." >&2
		# Through the shared writer, like the registration's writes above,
		# rather than a `jq > tmp && mv` of its own: the rename adopts the
		# staging file's inode, so a hand-rolled one hands settings.json back at
		# the process umask instead of the mode the user set on it, and leaves
		# the staging file behind on every path short of the rename. Steps 1, 2
		# and 6 still write settings.json the hand-rolled way and carry both
		# costs; moving them is a change of its own and is not made here.
		elif ! json_write_atomic "${settings}" "${synced}"; then
			echo "  [plugins] WARNING: could not write ${settings} — enabledPlugins not synced." >&2
		fi
	fi
}
