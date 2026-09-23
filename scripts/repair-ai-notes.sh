#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# repair-ai-notes.sh — Reattach orphaned git-ai attribution notes.
#
# refs/notes/ai is keyed by the SHA of the commit it annotates, so any history
# rewrite orphans it. git carries notes across `rebase` and `commit --amend`
# when notes.rewriteRef names the ref, and reown-commits.sh remaps the rewrite
# it performs itself — but nothing covers a cherry-pick, a squash, a reset, a
# rebase whose --exec amends each commit, or any rewrite done where no git-ai
# daemon was running to re-derive the notes.
#
# This reattaches what is left, using content as the only evidence:
#   Pass 1: identical tree     — reword, reorder, re-sign, author rewrite
#   Pass 2: identical patch-id — replay onto a new base, cherry-pick
#   Pass 3: per-file salvage   — squash, where only some files survive intact
#
# Nothing is guessed: a match that is not unique is refused and reported, and
# no line range is ever recomputed or invented.
#
# Usage:
#   ./repair-ai-notes.sh              # repair the current branch
#   ./repair-ai-notes.sh --all        # widen to every local branch and tag
#   ./repair-ai-notes.sh --force      # skip the confirmation prompt
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

AI_NOTES_REF="refs/notes/ai"

# ── Parse arguments ──────────────────────────────────────────────────────────

# FORCE and ALL are unused until the confirmation prompt and the --all branch
# widening land in later tasks; parsed now so `--help` documents the full flag
# set from day one and unknown-option detection is correct in the meantime.
FORCE=false
ALL=false
for arg in "$@"; do
	case "${arg}" in
	--force | -f)
		FORCE=true
		;;
	--all | -a)
		ALL=true
		;;
	--help | -h)
		echo "Usage: riotbox repair-notes [--all] [--force]"
		echo ""
		echo "Reattach orphaned git-ai attribution notes to the commits that"
		echo "replaced them, matching on content alone."
		echo "  --all     consider every local branch and tag, not just HEAD"
		echo "  --force   skip the confirmation prompt"
		exit 0
		;;
	*)
		echo "ERROR: Unknown option '${arg}'." >&2
		echo "Usage: riotbox repair-notes [--all] [--force]" >&2
		exit 1
		;;
	esac
done

if ! git rev-parse --git-dir >/dev/null 2>&1; then
	echo "ERROR: not inside a git repository." >&2
	exit 1
fi

# ── Discover orphaned notes ──────────────────────────────────────────────────
#
# An orphan is a note whose annotated commit is unreachable from EVERY ref, not
# merely from the branch being repaired. A note on a commit that lives on
# another branch is attached, and moving it would strip attribution off that
# branch — which is exactly what would happen to `main` the first time a commit
# was cherry-picked out of it. Note refs are excluded from the walk because
# `git rev-list --all` includes them and their own commits are not history.

if ! git rev-parse --quiet --verify "${AI_NOTES_REF}" >/dev/null; then
	echo "Nothing to repair: ${AI_NOTES_REF} does not exist."
	exit 0
fi

# Captured rather than piped so a failure is the script's to handle: masking it
# would leave REACHABLE empty, which reclassifies every ATTACHED note as an
# orphan and hands the matching passes licence to move notes off healthy
# commits. Refusing is the only safe answer to not knowing what is reachable.
if ! reachable_list="$(git rev-list --exclude=refs/notes/'*' --all)"; then
	echo "ERROR: could not walk the repository's refs; refusing to guess which notes are orphaned." >&2
	exit 1
fi

declare -A REACHABLE=()
while read -r sha; do
	[[ -n "${sha}" ]] || continue
	REACHABLE["${sha}"]=1
done <<<"${reachable_list}"

if ! notes_list="$(git notes --ref="${AI_NOTES_REF}" list)"; then
	echo "ERROR: could not list ${AI_NOTES_REF}; refusing to guess which notes are orphaned." >&2
	exit 1
fi

ORPHANS=()
UNRECOVERABLE=()
while read -r _blob annotated; do
	[[ -n "${annotated}" ]] || continue
	[[ -n "${REACHABLE[${annotated}]:-}" ]] && continue
	# A note outlives its commit only while the object survives. Past a gc the
	# annotated object is gone and there is nothing left to compare it by, so
	# it is named and set aside rather than left to crash the passes that would
	# try to read its tree.
	if ! git cat-file -e "${annotated}^{commit}" 2>/dev/null; then
		UNRECOVERABLE+=("${annotated}")
		continue
	fi
	ORPHANS+=("${annotated}")
done <<<"${notes_list}"

if [[ ${#ORPHANS[@]} -eq 0 && ${#UNRECOVERABLE[@]} -eq 0 ]]; then
	echo "Nothing to repair: every attribution note is still attached."
	exit 0
fi

if [[ ${#ORPHANS[@]} -eq 0 ]]; then
	for sha in "${UNRECOVERABLE[@]}"; do
		printf '  %s -- unrecoverable: the annotated commit object is gone\n' "${sha:0:9}"
	done
	echo "No orphan has a surviving commit to compare against; nothing written."
	exit 1
fi

echo "Found ${#ORPHANS[@]} orphaned attribution note(s)."

# ── Collect the repair scope ─────────────────────────────────────────────────
#
# IN_SCOPE is every commit in the repair scope, filtered by nothing: ambiguity
# has to be counted over the true population or a tie can be undercounted into
# a false unique match. HAS_NOTE marks which of those already carry a note —
# checked only once a unique match is chosen, not before. A target with a note
# is left alone: in-session, git-ai re-derives notes from its own checkpoint
# store and does it better than any reconstruction here, so overwriting one
# would be a downgrade.

declare -A HAS_NOTE=()
while read -r _blob annotated; do
	[[ -n "${annotated}" ]] || continue
	HAS_NOTE["${annotated}"]=1
done <<<"${notes_list}"

if [[ "${ALL}" = true ]]; then
	SCOPE_ARGS=(--branches --tags)
else
	SCOPE_ARGS=(HEAD)
fi

if ! scope_list="$(git rev-list "${SCOPE_ARGS[@]}")"; then
	echo "ERROR: could not list the commits in scope." >&2
	exit 1
fi

IN_SCOPE=()
while read -r sha; do
	[[ -n "${sha}" ]] || continue
	IN_SCOPE+=("${sha}")
done <<<"${scope_list}"

# ── Matching ─────────────────────────────────────────────────────────────────
#
# PLAN_DEST maps an orphan to the commit its note will move to; PLAN_PASS names
# the evidence. CLAIMED_BY maps a destination back to its orphan, so a target
# two orphans both match is caught and refused rather than won by whichever was
# seen last. PLAN_REASON records why an orphan was left alone.

declare -A PLAN_DEST=() PLAN_PASS=() PLAN_REASON=() CLAIMED_BY=() AMBIGUOUS=()

# match_pass <name> <key-function>
# Group orphans and in-scope commits by the key the function prints for a
# commit, then pair them where exactly one unmatched orphan and one unclaimed
# commit share a key. Ambiguity in EITHER direction is refused: two commits
# with one key, or two orphans with one key — counted over EVERY in-scope
# commit, not just the ones eligible to receive a note, or a genuine tie could
# be undercounted into a false unique match. Eligibility (HAS_NOTE) is checked
# only once a match is unique, and disqualifies it rather than un-counting it.
# AMBIGUOUS is reset on entry: a tie under one pass's evidence says nothing
# about the next pass's evidence, so it must not carry over.
match_pass() {
	local pass="${1}" keycmd="${2}"
	local -A orphan_key=() cand_by_key=() cand_count=() orphan_count=()
	local sha key dest

	AMBIGUOUS=()

	for sha in "${ORPHANS[@]}"; do
		[[ -n "${PLAN_DEST[${sha}]:-}" ]] && continue
		[[ -n "${AMBIGUOUS[${sha}]:-}" ]] && continue
		key="$("${keycmd}" "${sha}")"
		[[ -n "${key}" ]] || continue
		orphan_key["${sha}"]="${key}"
		orphan_count["${key}"]=$((${orphan_count["${key}"]:-0} + 1))
	done

	for sha in "${IN_SCOPE[@]}"; do
		[[ -n "${CLAIMED_BY[${sha}]:-}" ]] && continue
		key="$("${keycmd}" "${sha}")"
		[[ -n "${key}" ]] || continue
		cand_by_key["${key}"]="${sha}"
		cand_count["${key}"]=$((${cand_count["${key}"]:-0} + 1))
	done

	for sha in "${!orphan_key[@]}"; do
		key="${orphan_key[${sha}]}"
		[[ -n "${cand_by_key[${key}]:-}" ]] || continue
		if [[ ${cand_count["${key}"]} -gt 1 || ${orphan_count["${key}"]} -gt 1 ]]; then
			AMBIGUOUS["${sha}"]=1
			PLAN_REASON["${sha}"]="ambiguous: ${cand_count[${key}]} candidate(s) and ${orphan_count[${key}]} orphan(s) share the same ${pass}"
			continue
		fi
		dest="${cand_by_key[${key}]}"
		if [[ -n "${HAS_NOTE[${dest}]:-}" ]]; then
			PLAN_REASON["${sha}"]="destination already has a note"
			continue
		fi
		PLAN_DEST["${sha}"]="${dest}"
		PLAN_PASS["${sha}"]="${pass}"
		CLAIMED_BY["${dest}"]="${sha}"
	done
}

# shellcheck disable=SC2317  # invoked indirectly via match_pass's keycmd parameter
key_tree() { git rev-parse "${1}^{tree}"; }

match_pass "tree" key_tree

# `--root` is required, or a root commit produces no patch-id at all and would
# silently never match. patch-id prints "<id> <commit>"; only the id is the key.
# shellcheck disable=SC2317  # invoked indirectly via match_pass's keycmd parameter
key_patch() {
	git diff-tree -p --root "${1}" | git patch-id --stable | cut -d' ' -f1
}

match_pass "patch" key_patch

# ── Pass 3: per-file salvage ─────────────────────────────────────────────────
#
# For the squash case, where several orphans collapse into one commit and no
# whole-commit identity survives. A file entry transposes only when the blob at
# that path is byte-identical in the orphan and the target. That identity is the
# entire justification: if the content is the same, the note's recorded line
# ranges are valid for the target BY CONSTRUCTION, so nothing here recomputes or
# invents a range. A path with no byte-identical counterpart contributes nothing
# and its lines read `unknown`, which is the honest answer.
#
# Not routed through match_pass: that helper assumes one key per commit, and a
# salvage match is per-file. Several orphans may legitimately contribute to one
# target, which is also why a salvage target is not marked CLAIMED_BY.
#
# A squash's result has the same tree as its last source, so Pass 1 has already
# claimed it for that one orphan. That claim must not lock the other sources
# out: an identical tree makes every path in the claiming note byte-identical,
# so the claimer joins as one more salvage source. A patch match vouches for no
# file's bytes, so a target it claimed stays exclusive.

# note_text <commit> — the note's text section, without the JSON half.
# shellcheck disable=SC2317  # invoked below, in the salvage pass
note_text() {
	git notes --ref="${AI_NOTES_REF}" show "${1}" | sed -n '/^---$/q; p'
}

# note_json <commit> — the note's JSON half.
# shellcheck disable=SC2317  # invoked in the apply-loop's salvage compose step
note_json() {
	git notes --ref="${AI_NOTES_REF}" show "${1}" | sed -n '/^---$/,$p' | tail -n +2
}

# note_paths_of <commit> — the paths the note names.
# shellcheck disable=SC2317  # invoked below, in the salvage pass
note_paths_of() {
	note_text "${1}" | sed -n '/^[^ \t]/p'
}

# entries_for_path <commit> <path> — the indented turn lines under <path>.
# shellcheck disable=SC2317  # invoked in the apply-loop's salvage compose step
entries_for_path() {
	note_text "${1}" | awk -v want="${2}" '
		/^[^ \t]/ { inpath = ($0 == want); next }
		inpath { print }
	'
}

# qualifying_paths <orphan> <target>
# The paths whose blob is byte-identical in both commits.
# shellcheck disable=SC2317  # invoked below, in the salvage pass
qualifying_paths() {
	local orphan="${1}" target="${2}" path orphan_blob target_blob paths
	paths="$(note_paths_of "${orphan}")"
	while IFS= read -r path; do
		[[ -n "${path}" ]] || continue
		orphan_blob="$(git rev-parse --quiet --verify "${orphan}:${path}" || true)"
		target_blob="$(git rev-parse --quiet --verify "${target}:${path}" || true)"
		[[ -n "${orphan_blob}" && "${orphan_blob}" = "${target_blob}" ]] || continue
		printf '%s\n' "${path}"
	done <<<"${paths}"
}

# SALVAGE maps a target to newline-separated "<orphan> <path>" pairs.
declare -A SALVAGE=()

for orphan in "${ORPHANS[@]}"; do
	[[ -n "${PLAN_DEST[${orphan}]:-}" ]] && continue

	best_target=""
	best_count=0
	tied=false
	for target in "${IN_SCOPE[@]}"; do
		claimer="${CLAIMED_BY[${target}]:-}"
		[[ -n "${claimer}" && "${PLAN_PASS[${claimer}]}" = "patch" ]] && continue
		count="$(qualifying_paths "${orphan}" "${target}" | wc -l | tr -d ' ')"
		if [[ ${count} -gt ${best_count} ]]; then
			best_target="${target}"
			best_count=${count}
			tied=false
		elif [[ ${count} -gt 0 && ${count} -eq ${best_count} ]]; then
			tied=true
		fi
	done

	if [[ ${best_count} -eq 0 ]]; then
		continue
	fi
	if [[ "${tied}" = true ]]; then
		PLAN_REASON["${orphan}"]="ambiguous: two commits salvage the same number of files"
		continue
	fi
	# Eligibility last, exactly as the earlier passes do it.
	if [[ -n "${HAS_NOTE[${best_target}]:-}" ]]; then
		PLAN_REASON["${orphan}"]="destination already has a note"
		continue
	fi

	sources=("${orphan}")
	claimer="${CLAIMED_BY[${best_target}]:-}"
	if [[ -n "${claimer}" && "${PLAN_PASS[${claimer}]}" = "tree" ]]; then
		sources+=("${claimer}")
		PLAN_PASS["${claimer}"]="salvage"
	fi
	for source in "${sources[@]}"; do
		salvage_paths="$(qualifying_paths "${source}" "${best_target}")"
		while IFS= read -r path; do
			[[ -n "${path}" ]] || continue
			SALVAGE["${best_target}"]="${SALVAGE[${best_target}]:-}${source} ${path}"$'\n'
		done <<<"${salvage_paths}"
	done

	PLAN_DEST["${orphan}"]="${best_target}"
	PLAN_PASS["${orphan}"]="salvage"
done

# ── Report and apply ─────────────────────────────────────────────────────────

echo ""
for sha in "${ORPHANS[@]}"; do
	if [[ -n "${PLAN_DEST[${sha}]:-}" ]]; then
		printf '  %s -> %s  (%s)\n' "${sha:0:9}" "${PLAN_DEST[${sha}]:0:9}" "${PLAN_PASS[${sha}]}"
	else
		printf '  %s -- %s\n' "${sha:0:9}" "${PLAN_REASON[${sha}]:-no candidate}"
	fi
done
for sha in "${UNRECOVERABLE[@]}"; do
	printf '  %s -- unrecoverable: the annotated commit object is gone\n' "${sha:0:9}"
done
echo ""

if [[ ${#PLAN_DEST[@]} -eq 0 ]]; then
	echo "No orphan could be matched; nothing written."
	exit 1
fi

if [[ "${FORCE}" != true ]]; then
	# EOF is not a decline — it means there is nobody to ask. Saying so beats
	# dying at the read with no output.
	if ! read -rp "Proceed with repair? [y/N] " confirm; then
		echo "ERROR: no terminal to confirm on; re-run with --force." >&2
		exit 1
	fi
	if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
		echo "Aborted; nothing written."
		exit 0
	fi
fi

UNREPAIRED=0
for sha in "${ORPHANS[@]}"; do
	if [[ -z "${PLAN_DEST[${sha}]:-}" ]]; then
		UNREPAIRED=$((UNREPAIRED + 1))
		continue
	fi
	# Salvage targets are composed once, below, from every contributing orphan.
	if [[ "${PLAN_PASS[${sha}]}" = "salvage" ]]; then
		continue
	fi
	# Re-checked here rather than trusted from the plan: the plan was computed
	# before the prompt above blocked for an unbounded time, and a live git-ai
	# daemon writing a note on the destination in that window is the normal
	# case this tool has to coexist with, not a race worth ignoring.
	if git notes --ref="${AI_NOTES_REF}" list "${PLAN_DEST[${sha}]}" >/dev/null 2>&1; then
		echo "SKIPPED: ${PLAN_DEST[${sha}]:0:9} gained a note since the plan was made; ${sha:0:9} left in place." >&2
		UNREPAIRED=$((UNREPAIRED + 1))
		continue
	fi
	git notes --ref="${AI_NOTES_REF}" copy -f "${sha}" "${PLAN_DEST[${sha}]}"
	if ! git notes --ref="${AI_NOTES_REF}" remove "${sha}" 2>/dev/null; then
		echo "ERROR: copied the note to ${PLAN_DEST[${sha}]:0:9} but could not remove the orphan ${sha:0:9}; both now carry it." >&2
		exit 1
	fi
done

# Compose one note per salvage target: the qualifying file entries verbatim,
# then a JSON document whose sessions and prompts are the union of the
# contributing notes and whose base_commit_sha names the target.
for target in "${!SALVAGE[@]}"; do
	if git notes --ref="${AI_NOTES_REF}" list "${target}" >/dev/null 2>&1; then
		echo "SKIPPED: ${target:0:9} gained a note since the plan was made; its salvage sources are left in place." >&2
		for sha in "${ORPHANS[@]}"; do
			if [[ "${PLAN_DEST[${sha}]:-}" = "${target}" ]]; then
				UNREPAIRED=$((UNREPAIRED + 1))
			fi
		done
		continue
	fi

	json_inputs=()
	{
		while IFS=' ' read -r orphan path; do
			[[ -n "${orphan}" ]] || continue
			printf '%s\n' "${path}"
			entries_for_path "${orphan}" "${path}"
			json_inputs+=("${orphan}")
		done <<<"${SALVAGE[${target}]}"
		printf -- '---\n'
		for orphan in "${json_inputs[@]}"; do
			note_json "${orphan}"
		done | jq -s --arg sha "${target}" '
			reduce .[] as $n ({};
				. * $n
				| .sessions = ((.sessions // {}) + ($n.sessions // {}))
				| .prompts = ((.prompts // {}) + ($n.prompts // {}))
			)
			| .base_commit_sha = $sha
		'
	} | git notes --ref="${AI_NOTES_REF}" add -f -F - "${target}"
done

echo "Repaired $((${#ORPHANS[@]} - UNREPAIRED)) of ${#ORPHANS[@]} note(s)."
# An unrecoverable orphan is an unrepaired one: the caller asked for every note
# to be reattached and some were not.
[[ ${UNREPAIRED} -eq 0 && ${#UNRECOVERABLE[@]} -eq 0 ]] || exit 1
exit 0
