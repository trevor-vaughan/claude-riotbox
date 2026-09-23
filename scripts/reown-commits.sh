#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# reown-commits.sh — Rewrite container-authored commits to use your identity.
#
# After a riotbox run, the container's commits will have its generic LLM
# identity (currently "LLM (riotbox)" <llm@riotbox>; see Containerfile). This
# script rewrites the author/committer on those commits so the history looks
# like yours, while preserving the Co-Authored-By trailer.
#
# Container identities recognised:
#   llm@riotbox     — current primary (matches the Containerfile)
#   claude@riotbox  — legacy: pre-rename, when the identity was Claude-specific
#   llm@localhost   — legacy: pre-domain-rename
#   riotbox@local   — legacy: oldest squash-merge identity (pre-ff-only fix)
#
# Uses git-filter-repo (the officially recommended replacement for
# filter-branch) with a two-pass approach:
#   Pass 1: Rewrite author/committer fields via filter-repo
#   Pass 2: Re-sign commits with GPG (if commit.gpgsign is enabled)
#
# A backup tag is created before rewriting so you can verify the result
# and easily restore if needed.
#
# Usage:
#   ./reown-commits.sh                     # rewrite all container-authored commits
#   ./reown-commits.sh <since-ref>         # rewrite since a specific ref
#   ./reown-commits.sh --force             # skip confirmation prompt
#
# Your name/email are read from your git config.
# Requires: git-filter-repo (pip install git-filter-repo)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# Container identities that get rewritten. The first entry is the current
# primary (matches the Containerfile); the rest are legacy identities still
# present in older history. To recognise a new identity, append it here.
CONTAINER_EMAILS=(
	"llm@riotbox"    # current primary — matches Containerfile
	"claude@riotbox" # legacy: pre-rename, Claude-specific identity
	"llm@localhost"  # legacy: pre-domain-rename
	"riotbox@local"  # legacy: oldest squash-merge identity (pre-ff-only fix)
)

# Pre-built --author flag list — used by every git query that filters by
# container identity. Built once because it is referenced from several places.
AUTHOR_FLAGS=()
for email in "${CONTAINER_EMAILS[@]}"; do
	AUTHOR_FLAGS+=(--author="${email}")
done

# Regex alternation for ERE grep — matches an email at the start of a line
# followed by a space (the `git log %ae <space>` shape used below).
EMAIL_REGEX="^($(
	IFS='|'
	echo "${CONTAINER_EMAILS[*]}"
)) "

# ── Dependency check ─────────────────────────────────────────────────────────

if ! command -v git-filter-repo &>/dev/null; then
	echo "ERROR: git-filter-repo is not installed." >&2
	echo "Install it with:  pip install git-filter-repo" >&2
	exit 1
fi

# ── Parse arguments ──────────────────────────────────────────────────────────

FORCE=false
REF_ARG=""
for arg in "$@"; do
	case "${arg}" in
	--force | -f) FORCE=true ;;
	-*)
		echo "ERROR: Unknown option '${arg}'." >&2
		echo "Usage: riotbox reown [<since-ref>] [--force]" >&2
		exit 1
		;;
	*) REF_ARG="${arg}" ;;
	esac
done

YOUR_NAME="$(git config user.name)"
YOUR_EMAIL="$(git config user.email)"

if [[ -z "${YOUR_NAME}" ]] || [[ -z "${YOUR_EMAIL}" ]]; then
	echo "ERROR: git user.name and user.email must be configured." >&2
	exit 1
fi

# ── GPG pre-flight check ─────────────────────────────────────────────────────
# Fail fast before touching history if GPG signing is enabled but the key is
# not available. filter-repo runs first (Pass 1), so a signing failure in
# Pass 2 would leave the repo in a rewritten-but-unsigned state.

# shellcheck disable=SC2312  # git config returns non-zero when key absent — handled by default-false comparison
if [[ "$(git config --bool commit.gpgsign 2>/dev/null)" == "true" ]]; then
	SIGNING_KEY="$(git config user.signingkey 2>/dev/null || true)"
	if [[ -z "${SIGNING_KEY}" ]]; then
		echo "ERROR: commit.gpgsign is true but no user.signingkey is configured." >&2
		echo "Set it with:  git config --global user.signingkey <key-id>" >&2
		exit 1
	fi
	if ! echo "riotbox-gpg-preflight" |
		gpg --local-user "${SIGNING_KEY}" --sign --batch --no-tty --pinentry-mode loopback --output /dev/null 2>/dev/null; then
		echo "ERROR: GPG key '${SIGNING_KEY}' is not unlocked or not accessible." >&2
		echo "Unlock your key before running reown. For example:" >&2
		echo "  echo test | gpg --local-user ${SIGNING_KEY} --sign --output /dev/null" >&2
		exit 1
	fi
	echo "GPG key ${SIGNING_KEY} is unlocked and ready."
	echo ""
fi

# ── Determine the range of commits to rewrite ───────────────────────────────

GIT_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${GIT_TOPLEVEL}" ]]; then
	echo "ERROR: not inside a git repository." >&2
	# shellcheck disable=SC2312  # pwd never fails in a sane invocation
	echo "  CWD: $(pwd)" >&2
	exit 1
fi

CURRENT_BRANCH="$(git branch --show-current)"
if [[ -z "${CURRENT_BRANCH}" ]]; then
	echo "ERROR: detached HEAD state — checkout a branch first." >&2
	exit 1
fi

echo "Repository: ${GIT_TOPLEVEL}"
echo "Branch:     ${CURRENT_BRANCH}"
echo ""

if [[ -n "${REF_ARG}" ]]; then
	# Validate that the ref exists (also prevents flag injection via --)
	if ! git rev-parse --verify "${REF_ARG}" &>/dev/null; then
		echo "ERROR: '${REF_ARG}' is not a valid git ref." >&2
		echo "Usage: riotbox reown [<since-ref>] [--force]" >&2
		exit 1
	fi
	RANGE_DESC="commits since ${REF_ARG}"
	LOG_RANGE=("${REF_ARG}..HEAD")
	# Scope filter-repo to only this range (commits before the ref keep their hashes)
	FILTER_REFS="${REF_ARG}..refs/heads/${CURRENT_BRANCH}"
else
	# Find the oldest container-authored commit on this branch and use its
	# parent as the range start. This minimises the hash blast radius —
	# commits before the oldest container commit keep their original hashes.
	OLDEST_CONTAINER_COMMIT="$(git log "${AUTHOR_FLAGS[@]}" \
		--format='%H' "${CURRENT_BRANCH}" | tail -1)"
	if [[ -z "${OLDEST_CONTAINER_COMMIT}" ]]; then
		echo "No container-authored commits found on ${CURRENT_BRANCH}. Nothing to do."
		exit 0
	fi
	PARENT="$(git rev-parse --verify "${OLDEST_CONTAINER_COMMIT}^" 2>/dev/null || true)"
	if [[ -n "${PARENT}" ]]; then
		RANGE_DESC="commits since $(git log -1 --format='%h %s' "${PARENT}")"
		LOG_RANGE=("${PARENT}..HEAD")
		FILTER_REFS="${PARENT}..refs/heads/${CURRENT_BRANCH}"
	else
		# Oldest container commit is the root commit
		RANGE_DESC="all commits on ${CURRENT_BRANCH} (container commit is root)"
		LOG_RANGE=("${CURRENT_BRANCH}")
		FILTER_REFS="refs/heads/${CURRENT_BRANCH}"
	fi
fi

# ── Count affected commits ──────────────────────────────────────────────────

TOTAL_IN_RANGE="$(git rev-list --count "${LOG_RANGE[@]}")"
CONTAINER_COUNT="$(git rev-list --count "${LOG_RANGE[@]}" "${AUTHOR_FLAGS[@]}")"

if [[ "${CONTAINER_COUNT}" -eq 0 ]]; then
	echo "No container-authored commits found in range (${RANGE_DESC}). Nothing to do."
	exit 0
fi

echo "Found ${CONTAINER_COUNT} container-authored commit(s) in range (${RANGE_DESC})."
echo "  ${TOTAL_IN_RANGE} total commit(s) in hash chain will be rewritten."
echo "  New author: ${YOUR_NAME} <${YOUR_EMAIL}>"
echo ""

# List the container-authored commits that will be rewritten
echo "Commits to reown:"
git --no-pager log "${LOG_RANGE[@]}" "${AUTHOR_FLAGS[@]}" \
	--format="  %C(yellow)%h%Creset %s" --reverse
echo ""

# Show any non-container commits in the range (they get rewritten too due to hash chain)
NON_CONTAINER_COUNT=$((TOTAL_IN_RANGE - CONTAINER_COUNT))
if [[ "${NON_CONTAINER_COUNT}" -gt 0 ]]; then
	echo "Also in range (${NON_CONTAINER_COUNT} commit(s) by other authors — hashes will change):"
	# --invert-grep only works with --grep, not --author; use grep -Ev to exclude
	# any of the container identities at the start of the line.
	git log "${LOG_RANGE[@]}" --format="%ae %C(dim)%h%Creset %s %C(dim)(%an)%Creset" --reverse |
		grep -Ev "${EMAIL_REGEX}" |
		sed 's/^[^ ]* /  /'
	echo ""
fi

if [[ "${FORCE}" != true ]]; then
	read -rp "Proceed with rewrite? [y/N] " confirm
	if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
		echo "Aborted."
		exit 0
	fi
	echo ""
fi

# ── Create backup tags ──────────────────────────────────────────────────────

# shellcheck disable=SC2312  # tag-name composition; date/urandom pipe failures are unrecoverable bugs we'd want to crash on, but masking is acceptable here
BACKUP_TAG="backup/pre-reown-$(date +%Y%m%d-%H%M%S)-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"

git tag "${BACKUP_TAG}/${CURRENT_BRANCH}" "${CURRENT_BRANCH}"
echo "Backup tag created: ${BACKUP_TAG}/${CURRENT_BRANCH}"
echo "  Restore with:  git reset --hard ${BACKUP_TAG}/${CURRENT_BRANCH}"
echo ""

# ── Save remote URLs and upstream tracking (filter-repo removes both) ───────

declare -A REMOTES
# shellcheck disable=SC2312  # git remote exits 0 on any repo; git remote get-url succeeds for every name it yields
while IFS= read -r remote_name; do
	REMOTES["${remote_name}"]="$(git remote get-url "${remote_name}")"
done < <(git remote)

# Capture upstream tracking ref so we can restore it after filter-repo wipes
# refs/remotes/*. Without this, `git push` sees no remote tracking ref, fetches
# from origin, and incorrectly tells the user to rebase instead of force-push.
# shellcheck disable=SC1083  # braces are part of git @{upstream} syntax
UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name @{upstream} 2>/dev/null || true)"

# ── git-ai attribution notes ────────────────────────────────────────────────
#
# git-ai records AI authorship in refs/notes/ai, keyed by the SHA of the commit
# each note annotates. Both passes below rewrite SHAs, and filter-repo scopes
# itself to --refs, so the notes ref is never in the rewritten set: without this
# every note is left pointing at a commit that no longer exists and the
# attribution silently disappears. Attribution is on by default and reown is the
# documented way to take ownership of a session's work, so the loss would land
# on the user at the moment they finish something.
AI_NOTES_REF="refs/notes/ai"

# remap_ai_notes <map-file>
#
# <map-file> is filter-repo's commit-map shape: a "old new" header line followed
# by one "old new" pair per rewritten commit. Each note is MOVED — copied to the
# new SHA, removed from the old — so a note is never left behind to be counted
# twice. A commit absent from the map keeps its note exactly where it is, which
# is what leaves history outside the rewritten range untouched.
#
# Iterates the notes rather than the map: the map holds every commit in the
# rewritten range, which in an old repo is thousands, while the notes on them
# are a handful.
remap_ai_notes() {
	local map_file="$1"
	local old new annotated blob notes_list
	local moved=0
	local -A commit_map=()

	# Nothing to do in a repo that has never been attributed — the common
	# case for anyone who does not use git-ai.
	git rev-parse --verify --quiet "${AI_NOTES_REF}" >/dev/null 2>&1 || return 0
	[[ -f "${map_file}" ]] || {
		echo "WARNING: ${map_file} is missing — git-ai attribution notes were not remapped." >&2
		return 0
	}

	while read -r old new; do
		# The header line, and any short/blank line a future
		# filter-repo might add.
		[[ "${old}" == "old" ]] && continue
		[[ -n "${old}" && -n "${new}" ]] || continue
		commit_map["${old}"]="${new}"
	done <"${map_file}"

	# Listed into a variable first so a failure of `git notes list` is
	# visible here rather than masked by the redirection.
	notes_list="$(git notes --ref="${AI_NOTES_REF}" list)" || {
		echo "WARNING: could not list ${AI_NOTES_REF} — attribution notes were not remapped." >&2
		return 0
	}

	while read -r blob annotated; do
		: "${blob}" # `git notes list` emits "<note-blob> <annotated-object>"
		new="${commit_map[${annotated}]:-}"
		[[ -n "${new}" ]] || continue
		[[ "${new}" != "${annotated}" ]] || continue

		# filter-repo writes an all-zero target for a commit it dropped.
		# The note is the only surviving record that the work was
		# AI-authored, so say so rather than deleting it quietly.
		if [[ "${new}" =~ ^0+$ ]]; then
			echo "NOTE: ${annotated} was dropped by the rewrite — its attribution note is left in place." >&2
			continue
		fi

		if git notes --ref="${AI_NOTES_REF}" copy -f "${annotated}" "${new}" >/dev/null 2>&1 &&
			git notes --ref="${AI_NOTES_REF}" remove "${annotated}" >/dev/null 2>&1; then
			moved=$((moved + 1))
		else
			echo "WARNING: could not move the attribution note for ${annotated} to ${new}." >&2
		fi
	done <<<"${notes_list}"

	if [[ "${moved}" -gt 0 ]]; then
		echo "Remapped ${moved} git-ai attribution note(s)."
	fi
}

# ── Pass 1: Rewrite author/committer via filter-repo ────────────────────────

MAILMAP="$(mktemp)"
trap 'rm -f "${MAILMAP}"' EXIT

# mailmap format: New Name <new@email> <old@email>
# One line per recognised container identity.
: >"${MAILMAP}"
for email in "${CONTAINER_EMAILS[@]}"; do
	printf '%s <%s> <%s>\n' "${YOUR_NAME}" "${YOUR_EMAIL}" "${email}" >>"${MAILMAP}"
done

echo "Pass 1: Rewriting author/committer fields..."

FILTER_REPO_ARGS=(
	--mailmap "${MAILMAP}"
	--force
	--refs "${FILTER_REFS}"
)

git filter-repo "${FILTER_REPO_ARGS[@]}"

echo "Pass 1 complete."

GIT_DIR_PATH="$(git rev-parse --git-dir)"
remap_ai_notes "${GIT_DIR_PATH}/filter-repo/commit-map"

# ── Restore remotes ─────────────────────────────────────────────────────────

for remote_name in "${!REMOTES[@]}"; do
	if git remote add "${remote_name}" "${REMOTES[${remote_name}]}" 2>/dev/null; then
		echo "Restored remote: ${remote_name} -> ${REMOTES[${remote_name}]}"
	elif git remote set-url "${remote_name}" "${REMOTES[${remote_name}]}" 2>/dev/null; then
		echo "Updated remote: ${remote_name} -> ${REMOTES[${remote_name}]}"
	else
		echo "WARNING: Failed to restore remote '${remote_name}'." >&2
	fi
done

# Restore the upstream tracking ref so push commands know where to push.
# filter-repo deletes refs/remotes/* for rewritten refs, so without this step
# `git push` would not know the remote-side state and would suggest rebasing.
if [[ -n "${UPSTREAM}" ]]; then
	if git branch --set-upstream-to="${UPSTREAM}" "${CURRENT_BRANCH}" 2>/dev/null; then
		echo "Restored upstream tracking: ${CURRENT_BRANCH} -> ${UPSTREAM}"
	else
		echo "NOTE: Could not restore upstream tracking to '${UPSTREAM}' — set it manually if needed." >&2
	fi
fi

# ── Pass 2: Re-sign commits with GPG (if enabled) ───────────────────────────

# shellcheck disable=SC2312  # git config returns non-zero when key absent — handled by default-false comparison
if [[ "$(git config --bool commit.gpgsign 2>/dev/null)" == "true" ]]; then
	SIGNING_KEY="$(git config user.signingkey 2>/dev/null || true)"
	if [[ "${TOTAL_IN_RANGE}" -gt 0 ]]; then
		echo ""
		echo "Pass 2: Re-signing ${TOTAL_IN_RANGE} rewritten commit(s) with GPG key ${SIGNING_KEY}..."

		REBASE_ARGS=(--committer-date-is-author-date --exec 'git commit --amend --no-edit -S -n')

		# Amending to add a signature changes the commit object, so this
		# pass rewrites every SHA a SECOND time and orphans the notes
		# Pass 1's remap just fixed. filter-repo's commit-map describes
		# only its own rewrite and cannot describe this one, so the map
		# is derived by listing the history either side of the rebase.
		# Whole history rather than the range: the --root branch below
		# re-signs commits outside TOTAL_IN_RANGE too.
		PRE_SIGN_SHAS="$(mktemp)"
		POST_SIGN_SHAS="$(mktemp)"
		SIGN_MAP="$(mktemp)"
		git rev-list HEAD >"${PRE_SIGN_SHAS}"

		# Re-verify the upstream ref post-filter-repo: filter-repo only rewrites
		# commits unique to this branch, so HEAD~N may not exist if the range
		# abuts or includes the root of the rewritten portion.
		if git rev-parse --verify "HEAD~${TOTAL_IN_RANGE}" &>/dev/null; then
			git rebase "${REBASE_ARGS[@]}" "HEAD~${TOTAL_IN_RANGE}"
		else
			git rebase "${REBASE_ARGS[@]}" --root
		fi

		git rev-list HEAD >"${POST_SIGN_SHAS}"

		# rebase replays a linear history in order and drops nothing
		# here, so the two listings correspond index for index. A length
		# mismatch means that assumption no longer holds; pairing them
		# anyway would attach every note to the wrong commit, which is
		# worse than the orphaning this function exists to prevent.
		if [[ "$(wc -l <"${PRE_SIGN_SHAS}")" -eq "$(wc -l <"${POST_SIGN_SHAS}")" ]]; then
			{
				echo "old new"
				paste -d' ' "${PRE_SIGN_SHAS}" "${POST_SIGN_SHAS}"
			} >"${SIGN_MAP}"
			remap_ai_notes "${SIGN_MAP}"
		else
			echo "WARNING: the re-signing pass changed the commit count — git-ai attribution notes were left at their pre-signing commits." >&2
		fi
		rm -f "${PRE_SIGN_SHAS}" "${POST_SIGN_SHAS}" "${SIGN_MAP}"

		echo "Pass 2 complete. Commits signed with key ${SIGNING_KEY}."
	fi
else
	echo ""
	echo "GPG signing not enabled — skipping Pass 2."
fi

# ── Warn when the next rebase will orphan attribution ───────────────────────
#
# The remap above carries notes through THIS rewrite. It cannot carry them
# through a rebase that already happened: those notes sit on SHAs filter-repo
# never saw, so remap_ai_notes skips them and they stay lost. git will carry
# them itself across rebase and amend, but only for refs named in
# notes.rewriteRef, which defaults to refs/notes/commits.
#
# Checked here rather than up front because the fix applies to the user's NEXT
# session, not this one, and this is the point in the workflow where they are
# still reading output. Silent for repos with no attribution to lose.
if git rev-parse --verify --quiet "${AI_NOTES_REF}" >/dev/null 2>&1; then
	NOTES_REFS_RAW="$(git config --get-all notes.rewriteRef 2>/dev/null || true)"
	NOTES_COVERED=false
	if [[ -n "${NOTES_REFS_RAW}" ]]; then
		while IFS= read -r ref; do
			if [[ "${ref}" = "${AI_NOTES_REF}" || "${ref}" = "refs/notes/*" ]]; then
				NOTES_COVERED=true
				break
			fi
		done <<<"${NOTES_REFS_RAW}"
	fi
	if [[ "${NOTES_COVERED}" = false ]]; then
		echo "" >&2
		echo "WARNING: git will not carry ${AI_NOTES_REF} across a rebase." >&2
		echo "  This run remapped the attribution notes, but a rebase done BEFORE" >&2
		echo "  reown orphans them first, and nothing downstream can recover them." >&2
		echo "  Fix it once:" >&2
		echo "    git config --global notes.rewriteRef 'refs/notes/*'" >&2
		echo "  Use the glob, not ${AI_NOTES_REF}: setting this key replaces git's" >&2
		echo "  default of refs/notes/commits instead of adding to it." >&2
		echo "  Or run: riotbox install-hooks" >&2
	fi
fi

echo ""
echo "Done. ${CONTAINER_COUNT} commit(s) rewritten."
echo ""
echo "Review with:  git log --oneline -${TOTAL_IN_RANGE}"
echo "Compare with: git diff ${BACKUP_TAG}/${CURRENT_BRANCH}..${CURRENT_BRANCH}"
echo ""
echo "IMPORTANT: History was rewritten — commit hashes have changed."
echo "A normal 'git push' will be rejected because the remote has different hashes."
echo "You must force-push:"
echo "  git push --force-with-lease"
echo ""
echo "Once satisfied, delete the backup tag:"
echo "  git tag -d ${BACKUP_TAG}/${CURRENT_BRANCH}"
