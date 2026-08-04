#!/usr/bin/env bash
set -euo pipefail
# ─────────────────────────────────────────────────────────────────────────────
# checkpoints.sh — find, keep and delete RiotBox checkpoint snapshots.
#
# checkpoint.sh stores each pre-session snapshot at
# refs/riotbox/checkpoints/<timestamp>. That namespace sits outside refs/heads
# and refs/tags on purpose: `git tag`, `git describe` and `git push` (including
# --all and --tags) never see it, so the safety net cannot pollute the user's
# repository.
#
# `git log` is the exception, and it is worth being precise about: `--all` means
# every ref under refs/, refs/riotbox included, so `git log --all`, `gitk --all`
# and any GUI that defaults to all refs DO show the snapshot commits. They show
# up undecorated, with no ref name attached, because no branch or tag points at
# them. So git can put a snapshot in front of the user but never names it —
# this script is the entire discovery and management surface for them.
#
# Subcommands, dispatched by bin/riotbox as the verbs in parentheses:
#   list [project...]              (riotbox checkpoints) Read-only listing.
#   tag <timestamp> [project]      (riotbox checkpoint-tag) Promote one
#                                  snapshot to a real, visible tag.
#   prune [project...] <selector>  (riotbox checkpoint-prune) Delete snapshot
#                                  refs; one selector required.
#
# Exit codes: 0 success, 1 operational failure, 2 usage error — matching
# bin/riotbox's own unknown-command exit 2.
#
# `prune --older-than` needs GNU date (`date -d`), which is the one
# non-portable dependency here; list, tag and the other selectors are
# POSIX-portable. RiotBox already assumes GNU coreutils elsewhere
# (checkpoint.sh uses `du -bc --files0-from`), and the failure is closed: on a
# host without it the age cannot be computed and nothing is deleted.
#
# Required env: ROOT_DIR
# ─────────────────────────────────────────────────────────────────────────────

source "${ROOT_DIR}/scripts/mount-projects.sh"

# The three ref namespaces this script knows about. Only the first is created
# by RiotBox today; the second is created on request by `tag`; the third is
# what RiotBox used to create before snapshots moved out of refs/tags, and is
# only ever read or deleted here.
SNAPSHOT_NS="refs/riotbox/checkpoints"
TAG_NS="riotbox-snapshot"
LEGACY_NS="riotbox-checkpoint"

# A session timestamp as `date +%Y%m%d-%H%M%S` writes it. Nothing outside this
# shape is ever deleted: a ref in the snapshot namespace that does not match
# was put there by a human or another tool, and is not ours to remove.
TS_RE='^[0-9]{8}-[0-9]{6}$'

# Quote a path for a command the user is meant to copy and paste. Project paths
# belong to the user: a directory named `glob*star` produces a hint that globs
# against the wrong thing when pasted, and one named `quote'sq` produces a hint
# with an unbalanced quote. printf %q leaves an ordinary path untouched.
_shq() {
	printf '%q' "$1"
}

# Named for the verbs the user types, not for this file's own subcommands: a
# usage message that says `checkpoints.sh prune` sends them looking for a
# libexec path they have no reason to know about. Same three verbs, same order
# and same wording as bin/riotbox's own help.
_usage() {
	cat <<'EOF'
Usage: riotbox checkpoints [project...]
       riotbox checkpoint-tag <timestamp> [project]
       riotbox checkpoint-prune [project...] <selector> [--force]

  checkpoints [project...]           List checkpoint snapshots (read-only).
  checkpoint-tag <ts> [project]      Tag a snapshot as riotbox-snapshot/<ts>.
  checkpoint-prune [project...]      Delete snapshot refs. Exactly one selector:
                                       --keep <N>          keep the N newest per project
                                       --older-than <N>d   keep those newer than N days
                                       --legacy            delete legacy riotbox-checkpoint/* tags
                                     Add --force (-f) to skip the confirmation.

Projects default to the current directory.
EOF
}

# Describe how much a snapshot holds, in one short column:
#   clean    the ref points at an ordinary commit — nothing was dirty
#   initial  the snapshot has no parent — it was taken on an unborn HEAD
#   N files  paths that differ between the snapshot and its parent
#   ?        the ref could not be read as a commit (see below)
#
# The discriminator is the commit SUBJECT, not a comparison against HEAD.
# _snapshot_project in checkpoint.sh writes `checkpoint: pre-riotbox-<ts>` only
# on the dirty path; on a clean tree it points the ref straight at the commit
# HEAD was on, which keeps that commit's own subject. So the subject is a
# permanent property of the snapshot, and a HEAD comparison is not: it answered
# "clean" only until the user's next commit, after which the same ref at the
# same sha relabelled itself as N files of captured work — or, if the snapshot
# was on a root commit, as `initial`, which means something else entirely.
# (The legacy riotbox-checkpoint/* tags read the same way: those versions
# committed with the same subject on the dirty path and tagged an ordinary user
# commit on the clean one.)
#
# This function NEVER fails: a listing is the only way to find a snapshot at
# all, so one unreadable row must not cost the user the other rows. Every git
# call is guarded and falls back to `?`.
_snapshot_size() {
	local dir="$1" ref="$2"

	local sha
	if ! sha="$(git -C "${dir}" rev-parse --verify --quiet "${ref}^{commit}" 2>/dev/null)"; then
		printf '?\n'
		return 0
	fi

	local subject
	if ! subject="$(git -C "${dir}" log -1 --format=%s "${sha}" 2>/dev/null)"; then
		printf '?\n'
		return 0
	fi
	if [[ "${subject}" != "checkpoint: pre-riotbox-"* ]]; then
		printf 'clean\n'
		return 0
	fi

	local parent
	if ! parent="$(git -C "${dir}" rev-parse --verify --quiet "${sha}^" 2>/dev/null)"; then
		printf 'initial\n'
		return 0
	fi

	local count
	if ! count="$(git -C "${dir}" diff --name-only "${parent}" "${sha}" 2>/dev/null | wc -l)"; then
		printf '?\n'
		return 0
	fi
	if [[ "${count}" -eq 1 ]]; then
		printf '1 file\n'
	else
		printf '%s files\n' "${count}"
	fi
}

_list_project() {
	local dir="$1"

	echo "Project: ${dir}"
	if ! git -C "${dir}" rev-parse --git-dir >/dev/null 2>&1; then
		echo "  Not a git repository — RiotBox has no snapshots for it."
		return 0
	fi

	# The hints below are pasted verbatim, and `restore ... -- .` is relative to
	# whatever directory `git -C` puts it in — so a hint naming a SUBDIRECTORY
	# restores only that subtree, silently, while looking like it worked. Name
	# the worktree top level instead, the same resolution _snapshot_project in
	# checkpoint.sh does before it builds its pathspec list. A directory git
	# cannot answer for is left as given; the listing above already said it is
	# not a repository.
	local top
	top="$(git -C "${dir}" rev-parse --show-toplevel 2>/dev/null)" || top="${dir}"

	# Sorted by name descending, which for session timestamps is newest first.
	local -a refs=()
	mapfile -t refs < <(git -C "${dir}" for-each-ref --sort=-refname --format='%(refname)' "${SNAPSHOT_NS}" 2>/dev/null)

	if [[ ${#refs[@]} -eq 0 ]]; then
		echo "  No checkpoint snapshots. RiotBox takes one at the start of each session."
	else
		echo "  Snapshots (in ${SNAPSHOT_NS} — no branch, no tag, so git tag, git describe"
		echo "  and git push never show them; git log --all shows the commits, unnamed):"
		local ref
		for ref in "${refs[@]}"; do
			printf '    %-15s  %-9s  %s\n' "${ref##*/}" "$(_snapshot_size "${dir}" "${ref}")" "${ref}"
		done
		echo "  Restore one into the working tree (HEAD and your branches do not move):"
		echo "    git -C $(_shq "${top}") restore --source=<ref> -- ."
		echo "  See what it would change first (git diff never looks at untracked files,"
		echo "  so a file the snapshot captured that is untracked today shows as a deletion):"
		echo "    git -C $(_shq "${top}") diff <ref>"
	fi

	_list_legacy "${dir}"
}

# Legacy tags get their own block, because they need a different action from
# the user: they are real tags, and they are the reason snapshots moved out of
# refs/tags in the first place.
_list_legacy() {
	local dir="$1"

	local -a tags=()
	mapfile -t tags < <(git -C "${dir}" for-each-ref --sort=-refname --format='%(refname)' "refs/tags/${LEGACY_NS}" 2>/dev/null)
	[[ ${#tags[@]} -gt 0 ]] || return 0

	echo "  Legacy checkpoint tags (older RiotBox versions made these; nothing does now):"
	local ref
	for ref in "${tags[@]}"; do
		printf '    %-15s  %-9s  %s\n' "${ref##*/}" "$(_snapshot_size "${dir}" "${ref}")" "${ref}"
	done
	echo "    These are real tags: they appear in git tag, they change what"
	echo "    git describe --tags reports, and git push --tags publishes them."
	echo "    Remove one:  git -C $(_shq "${dir}") tag -d ${LEGACY_NS}/<timestamp>"
	echo "    Remove all:  riotbox checkpoint-prune --legacy"
}

cmd_list() {
	# resolve_projects takes one space-separated string and defaults to the
	# current directory when it is empty.
	# shellcheck disable=SC2310  # checking function return — set -e suppression is intentional
	resolve_projects "$*" || return 1

	local dir first=true
	for dir in "${PROJECT_DIRS[@]}"; do
		if [[ "${first}" == true ]]; then
			first=false
		else
			echo ""
		fi
		_list_project "${dir}"
	done
}

cmd_tag() {
	local ts="${1:-}"
	if [[ ! "${ts}" =~ ${TS_RE} ]]; then
		echo "ERROR: '${ts}' is not a checkpoint timestamp (expected YYYYMMDD-HHMMSS)." >&2
		echo "Run 'riotbox checkpoints' to see the snapshots you can tag." >&2
		return 2
	fi
	shift
	if [[ $# -gt 1 ]]; then
		echo "ERROR: tag takes one timestamp and at most one project (got: $*)." >&2
		_usage >&2
		return 2
	fi

	# shellcheck disable=SC2310  # checking function return — set -e suppression is intentional
	resolve_projects "${1:-}" || return 1
	local dir="${PROJECT_DIRS[0]}"

	if ! git -C "${dir}" rev-parse --git-dir >/dev/null 2>&1; then
		echo "ERROR: ${dir} is not a git repository." >&2
		return 1
	fi

	local ref="${SNAPSHOT_NS}/${ts}"
	local sha
	if ! sha="$(git -C "${dir}" rev-parse --verify --quiet "${ref}" 2>/dev/null)"; then
		echo "ERROR: no snapshot ${ts} in ${dir}." >&2
		echo "Run 'riotbox checkpoints' to see the snapshots that exist." >&2
		return 1
	fi

	local tag="${TAG_NS}/${ts}"
	if git -C "${dir}" rev-parse --verify --quiet "refs/tags/${tag}" >/dev/null 2>&1; then
		echo "ERROR: tag ${tag} already exists in ${dir}." >&2
		echo "Inspect it with: git -C $(_shq "${dir}") show ${tag}" >&2
		echo "Replace it by removing it first: git -C $(_shq "${dir}") tag -d ${tag}" >&2
		return 1
	fi

	# Lightweight on purpose: an annotated tag would need an identity and would
	# be signed on a host that forces tag.gpgsign, which is exactly the class of
	# host configuration checkpoint.sh goes out of its way not to depend on.
	if ! git -C "${dir}" tag "${tag}" "${ref}"; then
		echo "ERROR: could not create tag ${tag} in ${dir}." >&2
		return 1
	fi

	# Top level, not the given directory: see the same resolution in
	# _list_project — `restore ... -- .` is relative to the -C directory, so a
	# hint naming a subdirectory restores only that subtree.
	local top
	top="$(git -C "${dir}" rev-parse --show-toplevel 2>/dev/null)" || top="${dir}"

	echo "Tagged refs/tags/${tag} → ${sha}"
	echo "  Restore it:  git -C $(_shq "${top}") restore --source=${tag} -- ."
	echo "  Remove it:   git -C $(_shq "${top}") tag -d ${tag}"
	echo "  Note: this is a real tag. Until you remove it, it appears in git tag,"
	echo "        it changes what git describe --tags reports, and git push --tags"
	echo "        publishes it."
}

_prune_usage_err() {
	echo "ERROR: $1" >&2
	_usage >&2
}

# Echo every bare backup store that could hold a copy of this project's
# snapshots, one per line. Never fails, and may echo a path that does not
# exist — the caller only ever reads refs out of these.
#
# Snapshot refs are per-REPOSITORY: refs/riotbox/* is a shared, non-per-worktree
# namespace, so every linked worktree of a repo sees the same set. A backup
# store, though, is named after the project path checkpoint.sh was launched
# with. Deriving the store from prune's own invocation path conflates the two,
# and both directions were seen reporting "NO BACKUP COPY … Deleting those is
# irreversible" over refs the store was holding all along: pruning from a
# subdirectory of the project, and pruning from the main checkout of a repo
# whose snapshots were taken while riotbox ran against a linked worktree.
#
# So resolve it two ways and check both:
#   1. The path key derived from the worktree top level. Same mangling as
#      _backup_project in checkpoint.sh, and the answer for the ordinary case.
#      It keeps working when the project has since been moved or deleted, where
#      (2) cannot resolve the store's recorded origin at all.
#   2. Any store whose recorded origin URL is a path inside THIS repository —
#      which is how a store created from a subdirectory or from a linked
#      worktree is found. _backup_project writes that URL when it clones the
#      store and re-checks it before every push, so it is the store's own
#      record of what it belongs to.
_backup_stores_for() {
	local dir="$1"
	local -a stores=()
	local top common store origin origin_common known duplicate

	top="$(git -C "${dir}" rev-parse --show-toplevel 2>/dev/null)" || top="${dir}"
	# shellcheck disable=SC2312  # printf into sed cannot fail for a non-empty path
	stores+=("${RIOTBOX_DATA_DIR}/backups/$(printf '%s\n' "${top}" | sed 's|/|-|g; s|^-||').git")

	# The common git dir is the repository's identity: a subdirectory, the main
	# checkout and every linked worktree all resolve to the same one. Same
	# resolution cmd_prune uses to collapse duplicate project arguments.
	common="$(cd "${dir}" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)" || common=""
	if [[ -n "${common}" ]]; then
		for store in "${RIOTBOX_DATA_DIR}"/backups/*.git; do
			[[ -d "${store}" ]] || continue
			origin="$(git -C "${store}" config --get remote.origin.url 2>/dev/null || true)"
			[[ -n "${origin}" ]] || continue
			# A store whose origin is a URL, or a path that no longer exists,
			# simply does not answer here — (1) is the fallback for that.
			origin_common="$(cd "${origin}" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)" || continue
			[[ "${origin_common}" == "${common}" ]] || continue
			duplicate=false
			for known in "${stores[@]}"; do
				[[ "${known}" == "${store}" ]] && duplicate=true
			done
			[[ "${duplicate}" == true ]] || stores+=("${store}")
		done
	fi

	printf '%s\n' "${stores[@]}"
}

# Select and delete snapshot refs. Nothing is deleted without an explicit
# selector, and nothing is deleted without confirmation unless --force is given.
cmd_prune() {
	local selector="" keep="" older="" force=false
	local -a projects=()

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--keep)
			if [[ -n "${selector}" ]]; then
				_prune_usage_err "exactly one of --keep, --older-than or --legacy may be given"
				return 2
			fi
			if [[ $# -lt 2 ]]; then
				_prune_usage_err "--keep needs a count, e.g. --keep 5"
				return 2
			fi
			selector="keep"
			keep="$2"
			shift 2
			;;
		--older-than)
			if [[ -n "${selector}" ]]; then
				_prune_usage_err "exactly one of --keep, --older-than or --legacy may be given"
				return 2
			fi
			if [[ $# -lt 2 ]]; then
				_prune_usage_err "--older-than needs an age in days, e.g. --older-than 30d"
				return 2
			fi
			selector="older"
			older="$2"
			shift 2
			;;
		--legacy)
			if [[ -n "${selector}" ]]; then
				_prune_usage_err "exactly one of --keep, --older-than or --legacy may be given"
				return 2
			fi
			selector="legacy"
			shift
			;;
		--force | -f)
			force=true
			shift
			;;
		-h | --help)
			_usage
			return 0
			;;
		-*)
			_prune_usage_err "unknown option '$1'"
			return 2
			;;
		*)
			projects+=("$1")
			shift
			;;
		esac
	done

	if [[ -z "${selector}" ]]; then
		_prune_usage_err "prune needs a selector: --keep <N>, --older-than <N>d or --legacy"
		return 2
	fi

	# Validate the selector's argument BEFORE anything is selected, so a typo
	# can never delete the wrong set.
	local cutoff=""
	case "${selector}" in
	keep)
		if [[ ! "${keep}" =~ ^[0-9]+$ ]]; then
			_prune_usage_err "--keep needs a non-negative integer (got: '${keep}')"
			return 2
		fi
		;;
	older)
		if [[ ! "${older}" =~ ^[0-9]+d$ ]]; then
			_prune_usage_err "--older-than needs a whole number of days like 30d (got: '${older}')"
			return 2
		fi
		if ! cutoff="$(date -d "${older%d} days ago" +%s 2>/dev/null)"; then
			echo "ERROR: could not compute the cutoff date for --older-than ${older}." >&2
			return 1
		fi
		;;
	esac

	local joined=""
	if [[ ${#projects[@]} -gt 0 ]]; then
		joined="${projects[*]}"
	fi
	# shellcheck disable=SC2310  # checking function return — set -e suppression is intentional
	resolve_projects "${joined}" || return 1

	# Collapse project paths that share ONE ref store, keeping the first named.
	# refs/riotbox/* is a shared (non-per-worktree) namespace, so a repo and its
	# linked worktrees are the same set of snapshots reached by different
	# canonical paths — resolve_projects cannot see that, since it only
	# canonicalises paths. Without this, a repo listed alongside its own
	# worktree gets selected and deleted twice, and `update-ref -d` on an
	# already-deleted ref exits 0, so the second pass is counted as success and
	# the reported total is double the truth. Keying on the common git dir
	# covers the plain `prune ~/proj ~/proj` slip as well. A non-repo has no
	# common dir; it keys on its own path and is reported as skipped below.
	local -a unique_dirs=()
	local dir store seen=""
	for dir in "${PROJECT_DIRS[@]}"; do
		store="$(cd "${dir}" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)" || store="${dir}"
		if [[ ":${seen}:" == *":${store}:"* ]]; then
			echo "Note: ${dir} shares its snapshot refs with an earlier project — counting it once." >&2
			continue
		fi
		seen="${seen}:${store}"
		unique_dirs+=("${dir}")
	done
	PROJECT_DIRS=("${unique_dirs[@]}")

	# ── Selection ─────────────────────────────────────────────────────
	# Printed before anything is deleted, and before the confirmation, so the
	# user confirms a list they have actually read.
	local namespace="${SNAPSHOT_NS}"
	[[ "${selector}" == "legacy" ]] && namespace="refs/tags/${LEGACY_NS}"

	local -a to_delete=()
	local unbacked=0
	echo "Refs to delete from the project repository. Prune never writes to the"
	echo "backup stores under ${RIOTBOX_DATA_DIR}/backups; every ref below was looked"
	echo "up in the store(s) belonging to its own repository, and any ref no store"
	echo "holds a copy of is marked."
	echo ""

	local ref
	for dir in "${PROJECT_DIRS[@]}"; do
		echo "  ${dir}"
		if ! git -C "${dir}" rev-parse --git-dir >/dev/null 2>&1; then
			echo "    not a git repository — skipped"
			continue
		fi

		# Where _backup_project in checkpoint.sh would have pushed this
		# project's backup — keyed on the project path, not the basename, so
		# same-named projects do not share a store.
		local backup_dir
		local -a backup_dirs=()
		mapfile -t backup_dirs < <(_backup_stores_for "${dir}")

		local -a found=() candidates=() unrecognised=() chosen=()
		mapfile -t found < <(git -C "${dir}" for-each-ref --sort=-refname --format='%(refname)' "${namespace}" 2>/dev/null)
		for ref in "${found[@]}"; do
			if [[ "${ref##*/}" =~ ${TS_RE} ]]; then
				candidates+=("${ref}")
			else
				unrecognised+=("${ref}")
			fi
		done

		case "${selector}" in
		keep)
			local index=0
			for ref in "${candidates[@]}"; do
				index=$((index + 1))
				if [[ ${index} -gt ${keep} ]]; then
					chosen+=("${ref}")
				fi
			done
			;;
		older)
			# The age comes from the ref NAME, never the commit date: a
			# clean-tree snapshot points at HEAD, whose date belongs to the
			# user's own commit and may be years old (or, after a rebase,
			# newer than the session that snapshotted it).
			#
			# checkpoint.sh writes the name with a bare `date +%Y%m%d-%H%M%S`,
			# so it carries no zone and is read back in whatever zone the
			# pruning shell is in. A snapshot named in one zone and pruned in
			# another shifts by up to ~26h, which against a day-granularity
			# cutoff can move a borderline snapshot to the other side of it.
			# Erring by a day on a retention window is acceptable; erring by
			# the years a commit date can be off is not.
			local ts epoch
			for ref in "${candidates[@]}"; do
				ts="${ref##*/}"
				if ! epoch="$(date -d "${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:9:2}:${ts:11:2}:${ts:13:2}" +%s 2>/dev/null)"; then
					# Right shape, impossible date (20261301-000000). Its age
					# is unknowable, so it is not ours to delete either.
					unrecognised+=("${ref}")
					continue
				fi
				if [[ "${epoch}" -lt "${cutoff}" ]]; then
					chosen+=("${ref}")
				fi
			done
			;;
		legacy)
			chosen=("${candidates[@]}")
			;;
		esac

		if [[ ${#chosen[@]} -eq 0 ]]; then
			echo "    nothing to delete"
		else
			local sha backed_up marker
			for ref in "${chosen[@]}"; do
				# The ref's own value, not the peeled commit: it is both what
				# the backup is compared against and the expected old value
				# handed to `update-ref -d` below.
				if ! sha="$(git -C "${dir}" rev-parse --verify --quiet "${ref}" 2>/dev/null)"; then
					echo "    ${ref}  ← vanished since it was listed — skipping"
					continue
				fi
				# _backup_project in checkpoint.sh returns 0 on every failure
				# path, and a first run may never have created the store at
				# all, so "this snapshot has no copy anywhere else" is an
				# ordinary state — and this is the last moment the user can act
				# on it. Compare the object, not just the ref name: a store
				# holding a different commit under that name is not a copy of
				# what is about to be deleted. One matching store is enough,
				# and the answer is only ever assigned on a match, so which
				# store the glob happens to reach first cannot change it.
				backed_up=false
				for backup_dir in "${backup_dirs[@]}"; do
					if [[ "$(git -C "${backup_dir}" rev-parse --verify --quiet "${ref}" 2>/dev/null || true)" == "${sha}" ]]; then
						backed_up=true
						break
					fi
				done
				marker=""
				if [[ "${backed_up}" != true ]]; then
					marker="  ← NO BACKUP COPY — this is the only one"
					unbacked=$((unbacked + 1))
				fi
				printf '    %-46s  %-9s  %s%s\n' \
					"${ref}" "$(_snapshot_size "${dir}" "${ref}")" "${sha:0:7}" "${marker}"
				to_delete+=("${dir}"$'\t'"${ref}"$'\t'"${sha}")
			done
		fi

		local kept=$((${#found[@]} - ${#chosen[@]}))
		if [[ ${kept} -gt 0 ]]; then
			echo "    keeping ${kept} other ref(s) here"
		fi
		if [[ ${#unrecognised[@]} -gt 0 ]]; then
			echo "    unrecognised, never deleted (not a YYYYMMDD-HHMMSS timestamp):"
			for ref in "${unrecognised[@]}"; do
				echo "      ${ref}"
			done
		fi
	done

	echo ""
	if [[ ${#to_delete[@]} -eq 0 ]]; then
		echo "Nothing to delete."
		return 0
	fi
	if [[ ${unbacked} -gt 0 ]]; then
		echo "${unbacked} of the ${#to_delete[@]} ref(s) above have no copy in the backup store."
		echo "Deleting those is irreversible."
		echo ""
	fi

	# ── Confirmation ──────────────────────────────────────────────────
	if [[ "${force}" != true ]]; then
		if [[ ! -t 0 ]]; then
			echo "ERROR: refusing to delete ${#to_delete[@]} ref(s) without confirmation." >&2
			echo "Re-run this from a terminal, or pass --force." >&2
			return 1
		fi
		local answer
		read -rp "Delete ${#to_delete[@]} ref(s)? [y/N] " answer || answer=""
		if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
			echo "Aborted."
			return 0
		fi
	fi

	# ── Deletion ──────────────────────────────────────────────────────
	local entry repo target expected deleted=0 failures=0
	local -a gc_dirs=()
	local gc_seen=""
	for entry in "${to_delete[@]}"; do
		IFS=$'\t' read -r repo target expected <<<"${entry}"

		# Empty the reflog BEFORE deleting the ref, and in that order only.
		#
		# checkpoint.sh creates snapshot refs with --create-reflog, and a
		# reflog keeps its objects reachable for gc.reflogExpireUnreachable
		# (30 days by default) — a prune that leaves one behind frees no disk
		# space at all, which is the whole point of pruning. git 2.52 drops the
		# reflog along with the ref on both ref backends, but a reflog that
		# outlives its ref cannot be cleaned up afterwards: `git reflog expire`
		# on a deleted ref fails with "reflog could not be found" and the
		# objects stay pinned. Expiring first works on every backend, and costs
		# nothing if the ref then survives: a snapshot ref is written exactly
		# once, so its reflog only ever records its own creation.
		#
		# The `reflog exists` guard is not decoration — refs outside
		# refs/heads, refs/remotes and refs/notes get no reflog unless one is
		# asked for, so a hand-made snapshot ref legitimately has none, and
		# expiring a missing reflog is an error rather than a no-op.
		if git -C "${repo}" reflog exists "${target}" 2>/dev/null; then
			if ! git -C "${repo}" reflog expire --expire=now --expire-unreachable=now --rewrite "${target}"; then
				echo "  WARNING: could not expire the reflog of ${target} in ${repo};" >&2
				echo "           deleting it anyway, but its objects stay reachable until" >&2
				echo "           gc.reflogExpireUnreachable elapses (30 days by default)." >&2
			fi
		fi

		# The expected old value is the sha shown in the selection above, so a
		# ref that moved between the listing and the confirmation is refused
		# rather than deleted blind — and a ref already deleted by an earlier
		# pass fails loudly instead of being silently counted twice.
		if ! git -C "${repo}" update-ref -d "${target}" "${expected}"; then
			echo "  WARNING: could not delete ${target} in ${repo}" >&2
			echo "           It no longer points at ${expected:0:7}, so it is not the ref that was listed." >&2
			failures=$((failures + 1))
			continue
		fi
		deleted=$((deleted + 1))
		if [[ ":${gc_seen}:" != *":${repo}:"* ]]; then
			gc_seen="${gc_seen}:${repo}"
			gc_dirs+=("${repo}")
		fi
	done

	# Only claim what happened, and only point gc at repositories something was
	# actually deleted from — a directory that was skipped, or one where every
	# deletion failed, has nothing to reclaim.
	if [[ ${deleted} -gt 0 ]]; then
		echo "Deleted ${deleted} ref(s) — in the project repository only."
		echo "The objects they held are freed by the next git gc. To reclaim the space now:"
		for repo in "${gc_dirs[@]}"; do
			echo "  git -C $(_shq "${repo}") gc --prune=now"
		done
	fi

	if [[ ${failures} -gt 0 ]]; then
		echo "ERROR: ${failures} ref(s) could not be deleted (see the warnings above)." >&2
		return 1
	fi
}

main() {
	local cmd="${1:-}"
	if [[ -z "${cmd}" ]]; then
		_usage >&2
		return 2
	fi
	shift
	case "${cmd}" in
	list) cmd_list "$@" ;;
	tag) cmd_tag "$@" ;;
	prune) cmd_prune "$@" ;;
	-h | --help | help) _usage ;;
	*)
		echo "checkpoints: unknown subcommand '${cmd}'" >&2
		_usage >&2
		return 2
		;;
	esac
}

if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
	main "$@"
fi
