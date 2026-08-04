#!/usr/bin/env bash
set -euo pipefail
# ─────────────────────────────────────────────────────────────────────────────
# checkpoint.sh — Create pre-session backup of all project git repos.
#
# Snapshots each project into refs/riotbox/checkpoints/<timestamp> and pushes it
# to a local bare backup repo under $XDG_DATA_HOME/riotbox/backups/. The backup
# is outside the container mount tree so Claude cannot access or modify it.
#
# The snapshot is built in a throwaway index and sealed with `git commit-tree`,
# so the worktree, the index, HEAD and every branch are left exactly as the user
# left them: nothing is committed and nothing is tagged. That also means a
# conflicted merge, an in-progress rebase, a pre-commit hook and a host that
# forces commit.gpgsign cannot affect (or be affected by) a checkpoint —
# commit-tree runs no hooks and does not sign.
#
# A directory that is not yet a git repo can be initialized on the spot (see
# RIOTBOX_GIT_INIT below); an empty repo with no commits, and a bare repo with
# no worktree to snapshot, are both skipped gracefully. Every per-project
# failure warns and moves to the next project — a checkpoint problem must never
# take the launch down with it, so this script exits 0 even after warning.
#
# Required env: ROOT_DIR
# Optional env: RIOTBOX_PROJECTS (space-separated project paths; defaults to CWD)
#               RIOTBOX_GIT_INIT (1=init non-git dirs, 0=never, unset=prompt on
#                                 an interactive terminal, default Yes)
#               RIOTBOX_CHECKPOINT_QUIET (1=suppress the large-untracked-set
#                                 warning; for CI and scripted runs. It does
#                                 NOT suppress the skipped-large-file report —
#                                 that one names data left unprotected.)
#               RIOTBOX_SNAPSHOT_MAX_MB (per-file size cap for UNTRACKED files;
#                                 default 10. Tracked files are never capped.)
# ─────────────────────────────────────────────────────────────────────────────

source "${ROOT_DIR}/scripts/mount-projects.sh"
resolve_projects "${RIOTBOX_PROJECTS:-}"

# Managed exclude block — exact content; markers are the stable identity.
#
# These patterns only affect UNTRACKED files: `git add -A` still captures a
# tracked vendor/lib/dep.go, with its modifications, even though `vendor/` is
# listed here. That is what makes an aggressive list safe — nothing the user
# has already committed can be dropped from a snapshot by adding a pattern.
#
# `dist/` and `build/` are deliberately absent: both are real source
# directories often enough, with no strong enough convention to guess.
_MANAGED_BLOCK='# >>> riotbox managed excludes (do not edit between markers) >>>
.headroom/
.codegraph/
.claude/settings.local.json
CLAUDE.local.md
venom.log
venom.*.log

# bulk — dependency and build trees
node_modules/
.venv/
venv/
__pycache__/
target/
.next/
.nuxt/
vendor/
.gradle/
.m2/
Pods/
.terraform/
*.egg-info/
.pytest_cache/
.mypy_cache/
.ruff_cache/

# secrets — excluded even when the project forgot to gitignore them
.env
.env.*
*.pem
*.key
id_rsa*
id_ed25519*
.npmrc
.netrc
*.p12
*.pfx
# <<< riotbox managed excludes <<<'

# Ensure the project repo's .git/info/exclude contains the current managed
# block. Called for every git project before the snapshot is built.
#
# Behaviour:
#   - Resolves the exclude path via `git -C <dir> rev-parse --git-path
#     info/exclude` to handle worktrees and submodule gitdirs correctly.
#   - Creates the parent directory if it doesn't exist yet.
#   - If the markers are already present, replaces everything between them
#     (including the markers themselves) so that list updates propagate.
#   - If no markers exist, appends the block (with a separating newline).
#   - Never modifies content outside the markers.
#   - Non-git directory → silent no-op.
#   - Any other failure → one-line warning to stderr; does NOT abort.
ensure_managed_excludes() {
	local dir="$1"

	# Resolve exclude path. rev-parse may return a relative path; canonicalise.
	local raw_path
	raw_path="$(git -C "${dir}" rev-parse --git-path info/exclude 2>/dev/null)" || return 0

	local exclude_path
	if [[ "${raw_path}" = /* ]]; then
		exclude_path="${raw_path}"
	else
		exclude_path="${dir}/${raw_path}"
	fi

	# Create parent directory if needed (bare repos / worktrees may not have it).
	local exclude_dir
	exclude_dir="$(dirname "${exclude_path}")"
	mkdir -p "${exclude_dir}" 2>/dev/null || {
		echo "  WARNING: cannot create ${exclude_dir} — skipping managed excludes" >&2
		return 0
	}

	# Touch the file if it doesn't exist so all paths below can treat it uniformly.
	[[ -f "${exclude_path}" ]] || touch "${exclude_path}" 2>/dev/null || {
		echo "  WARNING: cannot write ${exclude_path} — skipping managed excludes" >&2
		return 0
	}

	# Derive markers from _MANAGED_BLOCK so there is only one source of truth.
	local open_marker close_marker
	open_marker="$(printf '%s\n' "${_MANAGED_BLOCK}" | head -1)"
	close_marker="$(printf '%s\n' "${_MANAGED_BLOCK}" | tail -1)"

	# Classify the marker structure in one pass. The replace path is only safe
	# when there is exactly one open marker with a close marker somewhere after
	# it — any other shape (duplicate opens, an open that never closes, a close
	# preceding an unclosed open) would make the rewrite below eat user content
	# to EOF. Stray close markers OUTSIDE a block are user content and are
	# preserved. Exact-line matching ($0 ==) is consistent with the rewrite awk.
	local marker_state
	marker_state="$(awk \
		-v open_marker="${open_marker}" \
		-v close_marker="${close_marker}" \
		'
		BEGIN { opens=0; inside=0; closed=0 }
		$0 == open_marker  { opens++; inside=1; next }
		inside && $0 == close_marker { inside=0; closed=1 }
		END {
			if (opens == 0)                print "absent"
			else if (opens == 1 && closed) print "valid"
			else                           print "corrupt"
		}
		' "${exclude_path}" 2>/dev/null)" || marker_state="corrupt"

	if [[ "${marker_state}" == "valid" ]]; then
		# Both markers present — replace the entire block (open marker through close
		# marker) so that list updates propagate. Awk uses exact-line matching
		# ($0 == marker) which is consistent with the grep -xF probes above.
		local new_content
		new_content="$(awk \
			-v block="${_MANAGED_BLOCK}" \
			-v open_marker="${open_marker}" \
			-v close_marker="${close_marker}" \
			'
			BEGIN { inside=0; printed_block=0 }
			$0 == open_marker {
				if (!printed_block) { print block; printed_block=1 }
				inside=1
				next
			}
			inside && $0 == close_marker { inside=0; next }
			inside { next }
			{ print }
			' "${exclude_path}")" || {
			echo "  WARNING: awk failed updating ${exclude_path} — skipping managed excludes" >&2
			return 0
		}
		printf '%s\n' "${new_content}" > "${exclude_path}" 2>/dev/null || {
			echo "  WARNING: cannot write ${exclude_path} — skipping managed excludes" >&2
		}
	elif [[ "${marker_state}" == "corrupt" ]]; then
		# Duplicate or unclosed markers — corrupt/hand-edited state. Refuse to
		# rewrite (would eat user content to EOF) and warn loudly.
		echo "  WARNING: ${exclude_path} has a malformed managed block (duplicate or unclosed markers) — skipping managed excludes" >&2
	else
		# No markers yet — append with a separating newline if the file is
		# non-empty (so we don't create a blank leading line). Read the size
		# before opening the file for writing to satisfy shellcheck SC2094.
		local needs_separator=false
		[[ -s "${exclude_path}" ]] && needs_separator=true
		{
			"${needs_separator}" && printf '\n'
			printf '%s\n' "${_MANAGED_BLOCK}"
		} >> "${exclude_path}" 2>/dev/null || {
			echo "  WARNING: cannot append to ${exclude_path} — skipping managed excludes" >&2
		}
	fi
}

# Decide whether to create a git repo in a directory that has none, so the
# project still gets checkpoint protection. Behaviour is driven by
# RIOTBOX_GIT_INIT to keep automation predictable:
#   1     → always create
#   0     → never create
#   unset → ask on an interactive terminal (default Yes). Non-interactive
#           callers (riotbox run, CI, tests) fall through to "no" so a repo is
#           never created in the user's directory without consent and the
#           launcher never blocks on a prompt that nobody can answer.
# Returns 0 if a repo was created, 1 otherwise.
maybe_init_git_repo() {
	local dir="$1"
	local create=false
	case "${RIOTBOX_GIT_INIT:-}" in
	1) create=true ;;
	0) create=false ;;
	*)
		if [[ -t 0 ]]; then
			local answer
			printf "  %s is not a git repository.\n" "${dir}" >&2
			printf "  Create one so your work can be checkpointed? [Y/n] " >&2
			read -r answer || answer=""
			[[ "${answer}" =~ ^[Nn] ]] || create=true
		fi
		;;
	esac

	if [[ "${create}" = true ]] && git -C "${dir}" init >/dev/null 2>&1; then
		echo "  [git-init] Created git repository in ${dir}"
		return 0
	fi
	return 1
}

# Report a failed backup as loudly as the exposure deserves, then print the
# degraded success line. The local snapshot ref still exists — but it lives in
# the project directory that is about to be bind-mounted read-write, so a
# failed backup means there is no copy the agent cannot reach. The underlying
# error is reproduced verbatim and unindented: a full disk, an unwritable path
# and a rejected non-fast-forward need different actions from the user, and
# only the tool's own wording distinguishes them.
_backup_failed() {
	local project_name="$1" ref="$2" backup_dir="$3" err="$4"
	{
		echo "  WARNING: ${project_name}: backup to ${backup_dir} FAILED:"
		printf '%s\n' "${err}"
		echo "           This session has NO protection outside the container mount tree."
		echo "           The snapshot ref lives in the project you are mounting read-write;"
		echo "           the agent can delete it."
	} >&2
	echo "  checkpoint: ${project_name} → ${ref} (local only — backup failed)"
}

# Return 0 if the path is itself a bare git repository. `git -C <dir> rev-parse`
# walks UP the directory tree, so a bare probe answers "yes" for a plain
# directory that merely sits inside a repo — a real case when XDG_DATA_HOME
# lives under a dotfiles repo. In a bare repo (and only when the probed dir IS
# the git dir) `rev-parse --git-dir` answers "."; a discovered parent answers
# with a path. That makes the check local without any path canonicalisation.
_is_backup_repo() {
	local candidate="$1"
	[[ -d "${candidate}" ]] || return 1
	local git_dir
	git_dir="$(git -C "${candidate}" rev-parse --git-dir 2>/dev/null)" || return 1
	[[ "${git_dir}" == "." ]]
}

# Push the project to its bare backup. Snapshot refs are pushed WITHOUT --force:
# timestamps are unique per launch, so force would only ever let a tampered local
# ref overwrite a pristine backup copy. Returns 0 always — the local snapshot ref
# already exists, so a backup problem must not take the session down.
_backup_project() {
	local dir="$1" project_name="$2" ref="$3"
	local backup_root backup_key backup_dir legacy_dir err

	backup_root="${RIOTBOX_DATA_DIR}/backups"
	# Key on the canonical project path, not the basename: ~/work/a/web and
	# ~/work/b/web would otherwise share one backup, where the second project
	# force-overwrites the first's branches and collides with its snapshot ref
	# on every launch — so one of the two is never actually backed up. Same
	# path mangling as the session key in scripts/mount-projects.sh.
	# shellcheck disable=SC2312  # printf into sed cannot fail for a non-empty path
	backup_key="$(printf '%s\n' "${dir}" | sed 's|/|-|g; s|^-||')"
	backup_dir="${backup_root}/${backup_key}.git"

	# 0700 on the backup root: a backup holds the full history plus every
	# untracked file the snapshot swept in. _MANAGED_BLOCK keeps the obvious
	# secrets out, but only the ones it can name — a project's own credential
	# file under any other name is still in there. Sibling stores in
	# scripts/mount-projects.sh are 0700 for the same reason. Applied on every
	# run so stores created at the old 0755 are fixed.
	if ! err="$(mkdir -p "${backup_root}" 2>&1)"; then
		_backup_failed "${project_name}" "${ref}" "${backup_root}" "${err}"
		return 0
	fi
	# A filesystem that refuses chmod outright (CIFS, exFAT, NFS with squash)
	# must not lose its backups over a permission bit, so this warns rather
	# than aborting — same handling as the chmod on the store itself below.
	if ! err="$(chmod 700 "${backup_root}" 2>&1)"; then
		echo "  WARNING: ${project_name}: could not restrict ${backup_root} to 0700:" >&2
		printf '%s\n' "${err}" >&2
	fi

	# Backups predating the path-keyed layout live under the bare basename.
	# Adopt one only when it provably belongs to THIS project — on a basename
	# collision the legacy backup is some other project's history, and moving
	# it would hand this project a stranger's data and orphan the real owner.
	legacy_dir="${backup_root}/${project_name}.git"
	# shellcheck disable=SC2310  # checking function return — set -e suppression is intentional
	if [[ "${legacy_dir}" != "${backup_dir}" ]] && ! _is_backup_repo "${backup_dir}" &&
		_is_backup_repo "${legacy_dir}" &&
		[[ "$(git -C "${legacy_dir}" config --get remote.origin.url 2>/dev/null || true)" == "${dir}" ]]; then
		if err="$(mv "${legacy_dir}" "${backup_dir}" 2>&1)"; then
			echo "  checkpoint: ${project_name}: migrated backup ${legacy_dir} → ${backup_dir}"
			# A rename preserves what the old store IS. Only versions that
			# predate the path-keyed layout ever wrote to the legacy path, and
			# those cloned it with a plain `git clone --bare`: on one
			# filesystem that hardlinks the loose objects, so the "isolated"
			# store shares inodes with a .git the agent is handed read-write
			# and a write inside <project>/.git/objects corrupts the backup in
			# place. That is the failure --no-hardlinks exists to prevent, and
			# nothing below re-clones a store that already exists. Said here
			# because this line is the one moment the user is looking at that
			# store; README and THREAT_MODEL carry the standing note.
			echo "  WARNING: ${project_name}: that store predates --no-hardlinks, so its objects may" >&2
			echo "           still be hardlinked to ${dir}/.git and it is NOT isolated from it." >&2
			echo "           Force a fresh clone — see \"Upgrading from checkpoint tags\" in the" >&2
			echo "           README for the four steps that keep the old snapshots." >&2
		else
			echo "  WARNING: ${project_name}: could not migrate legacy backup ${legacy_dir}:" >&2
			printf '%s\n' "${err}" >&2
		fi
	fi

	# shellcheck disable=SC2310  # checking function return — set -e suppression is intentional
	if ! _is_backup_repo "${backup_dir}"; then
		if [[ -e "${backup_dir}" ]]; then
			# Why the probe said no decides what to tell the user, and getting
			# it wrong is destructive: an unreadable store is still a store,
			# holding every historical snapshot. LC_ALL=C keeps the match
			# stable on a host with translated git catalogs.
			local probe_err
			probe_err="$(LC_ALL=C git -C "${backup_dir}" rev-parse --git-dir 2>&1 >/dev/null || true)"
			if [[ -n "${probe_err}" ]] && [[ "${probe_err}" != *"not a git repository"* ]]; then
				# git found something it could not read — wrong owner, wrong
				# mode, safe.directory, failing disk. Deleting it to "fix" a
				# permission problem would throw away the only off-mount copy.
				_backup_failed "${project_name}" "${ref}" "${backup_dir}" \
					"${probe_err}
${backup_dir} exists but could not be read as a git repository.
Check its ownership and permissions. Do NOT delete it — if it is a real
backup store it holds every snapshot from every earlier session."
				return 0
			fi
			# git looked and found no repository: a leftover non-repo path.
			# git clone would refuse forever, and its "does not appear to be a
			# git repository" says nothing about the fix.
			_backup_failed "${project_name}" "${ref}" "${backup_dir}" \
				"${backup_dir} exists but is not a git repository, so it cannot receive the backup.
Remove or rename that path, then relaunch to rebuild the backup from scratch."
			return 0
		fi
		echo "  checkpoint: ${project_name}: creating backup at ${backup_dir} (first run; large repos take a while)"
		# --no-hardlinks is what makes the backup a backup. A local `git clone`
		# hardlinks loose objects by default, so the "isolated" copy would share
		# inodes with the project the agent is handed read-write: overwriting an
		# object in .git/objects corrupts the backup in place, without the agent
		# ever touching the backup directory.
		#
		# --dissociate is the other half. A local clone stays local, so it also
		# copies objects/info/alternates verbatim: a project made with `git
		# clone --shared`/`--reference` would hand the backup a POINTER into a
		# store riotbox does not own — and in a multi-project launch that
		# borrowed store can itself be inside the mount, where the agent can
		# delete it. --dissociate copies the borrowed objects in instead. It is
		# a no-op on an ordinary repo.
		if ! err="$(git clone --bare --no-hardlinks --dissociate "${dir}" "${backup_dir}" 2>&1)"; then
			# A concurrent launch may have won the race and created it already;
			# that backup is just as good, so fall through to the push rather
			# than leaving this launch's snapshot unbacked.
			# shellcheck disable=SC2310  # checking function return — set -e suppression is intentional
			if ! _is_backup_repo "${backup_dir}"; then
				_backup_failed "${project_name}" "${ref}" "${backup_dir}" "${err}"
				return 0
			fi
		fi
	fi

	# The store is readable — now make sure it is OURS before writing to it.
	# The key mangling matches mount-projects.sh character for character, but it
	# is not injective: any '-' in a path component aliases with '/', so
	# ~/a-b/c and ~/a/b-c key alike, and hyphenated directories are common.
	# Pushing into the wrong store would force-overwrite another project's
	# branches silently. The origin URL is the store's own record of who it
	# belongs to, so it also catches any future drift in the key scheme.
	local store_origin
	store_origin="$(git -C "${backup_dir}" config --get remote.origin.url 2>/dev/null || true)"
	if [[ "${store_origin}" != "${dir}" ]]; then
		_backup_failed "${project_name}" "${ref}" "${backup_dir}" \
			"${backup_dir} already holds the backup for a different project.
  the store belongs to: ${store_origin:-<unknown: no origin recorded>}
  this project is:      ${dir}
Both project paths map to the same backup key, so backing up here would
overwrite the other project's history. Rename one of the two directories
so their paths no longer differ only by a '-' where the other has a '/',
then relaunch. Do NOT delete the store — it is the other project's backup."
		return 0
	fi

	if ! err="$(chmod 700 "${backup_dir}" 2>&1)"; then
		echo "  WARNING: ${project_name}: could not restrict ${backup_dir} to 0700:" >&2
		printf '%s\n' "${err}" >&2
	fi

	# A global core.hooksPath is inherited by the backup's own receive-pack, so
	# an org-wide pre-receive hook would reject every backup push. Point the
	# backup at a directory that holds no hooks (git treats a missing hooks
	# directory as "no hooks"). Setting it on the push side does not work — the
	# receiving repo reads its own config. Re-applied every run so backups
	# created before this existed are covered too.
	if ! err="$(git -C "${backup_dir}" config core.hooksPath "${backup_dir}/no-hooks" 2>&1)"; then
		echo "  WARNING: ${project_name}: could not neutralise hooks on ${backup_dir}:" >&2
		printf '%s\n' "${err}" >&2
	fi

	# The refspecs are explicit because they have to be: refs/riotbox/* does not
	# propagate through `git clone --bare`, nor through a default push. Relying
	# on --all/--tags would back up the branches and quietly leave every snapshot
	# behind, so the safety net would report success while storing nothing.
	#
	# --no-verify: the pre-push hook blocks container-identity commits; the
	# backup is a local bare repo, not a shared remote, so that intent does
	# not apply. push.gpgSign=false: a signed push is unsupported over the local
	# transport, so a host that forces it would break every backup with
	# "the receiving end does not support --signed push" — the same class of
	# hole as commit.gpgsign, which commit-tree already sidesteps.
	# --force on heads and tags, where rewriting is expected; never on snapshot
	# refs, where the only thing it could achieve is letting a tampered local
	# ref overwrite the pristine backup copy.
	# LC_ALL=C: the "forced update" marker below is a translated string, and a
	# host with git message catalogs and a non-English locale would silently
	# lose the branch-rewrite notice.
	if err="$(LC_ALL=C git -c push.gpgSign=false -C "${dir}" push --no-verify "${backup_dir}" \
		'+refs/heads/*:refs/heads/*' \
		'+refs/tags/*:refs/tags/*' \
		'refs/riotbox/checkpoints/*:refs/riotbox/checkpoints/*' 2>&1)"; then
		# Surface forced branch rewrites — the only notice the user gets that a
		# backed-up branch was replaced rather than extended.
		local line
		while IFS= read -r line; do
			echo "  checkpoint: ${project_name}: backup branch rewritten — ${line}"
		done < <(printf '%s\n' "${err}" | grep -F 'forced update' | sed 's/^[[:space:]]*//')
		# Name the tool. No git command lists this ref by name, so a user who
		# reads this line and later wants the snapshot back has nowhere else
		# to learn where to look. Outside the parenthesis, which stays the
		# status token the other outcomes vary.
		echo "  checkpoint: ${project_name} → ${ref} (backed up) — list with: riotbox checkpoints"
		return 0
	fi

	# `git push` is not atomic: one rejected ref does not mean nothing landed.
	# A single tampered historical snapshot would otherwise report "no
	# protection" on every future launch while this launch's snapshot is in
	# fact safely stored — which trains the user to ignore the warning that
	# matters. Ask the backup directly what happened to THIS launch's ref.
	local backup_sha local_sha
	backup_sha="$(git -C "${backup_dir}" rev-parse --verify --quiet "${ref}" 2>/dev/null || true)"
	local_sha="$(git -C "${dir}" rev-parse --verify "${ref}")"
	if [[ -n "${backup_sha}" ]] && [[ "${backup_sha}" == "${local_sha}" ]]; then
		{
			echo "  WARNING: ${project_name}: this launch's snapshot IS backed up, but some refs were rejected:"
			printf '%s\n' "${err}"
			echo "           A local ref named above diverged from the pristine backup copy."
			echo "           Heads and tags are force-pushed, so a rejection here means an"
			echo "           EARLIER launch's snapshot ref was rewritten in the project."
			echo "           This repeats every launch until you resolve it. For each ref above,"
			echo "           either restore it from the pristine copy:"
			echo "             git -C ${dir} update-ref <ref> \"\$(git -C ${backup_dir} rev-parse <ref>)\""
			echo "           or drop the local one, which the backup still holds:"
			echo "             git -C ${dir} update-ref -d <ref>"
		} >&2
		echo "  checkpoint: ${project_name} → ${ref} (backed up; other refs rejected)"
		return 0
	fi

	_backup_failed "${project_name}" "${ref}" "${backup_dir}" "${err}"
	return 0
}

# Build the snapshot for one project and push it to the bare backup.
# Warns and returns non-zero on any failure so the caller can move to the next
# project; never aborts the launch.
_snapshot_project() {
	local dir="$1" project_name="$2"
	local ref="refs/riotbox/checkpoints/${timestamp}"

	# Throwaway index. Seeded by copying the real one so git's stat cache
	# survives — a read-tree-seeded index re-hashes every file on every launch
	# (96ms vs 11ms on 3000 files). A freshly init'd repo has no index yet.
	local tmp_index pathspec_file
	if ! tmp_index="$(mktemp)" || ! pathspec_file="$(mktemp)"; then
		echo "  WARNING: ${project_name}: snapshot failed at mktemp (is ${TMPDIR:-/tmp} writable?) — no checkpoint protection!" >&2
		rm -f "${tmp_index:-}"
		return 1
	fi
	# Single quotes: the trap body is re-parsed as a command when it fires, so
	# an interpolated path would execute anything TMPDIR smuggled into it.
	trap 'rm -f "${tmp_index}" "${pathspec_file}"' RETURN

	# rev-parse --git-path may return a relative OR an absolute path; canonicalise
	# the same way ensure_managed_excludes does.
	local raw_index real_index
	raw_index="$(git -C "${dir}" rev-parse --git-path index)"
	if [[ "${raw_index}" = /* ]]; then
		real_index="${raw_index}"
	else
		real_index="${dir}/${raw_index}"
	fi
	if [[ -f "${real_index}" ]]; then
		cp "${real_index}" "${tmp_index}"
	elif ! GIT_INDEX_FILE="${tmp_index}" git -C "${dir}" read-tree --empty; then
		echo "  WARNING: ${project_name}: snapshot failed at read-tree — no checkpoint protection!" >&2
		return 1
	fi

	# Per-file size cap for UNTRACKED files. One forgotten core dump or VM image
	# costs its full size in the snapshot AND in the off-host backup, on every
	# launch. TRACKED files are never capped: they are already in git, cost
	# nothing extra to re-snapshot, and dropping one would lose real work.
	#
	# The cap is applied as `:(exclude)` pathspecs on the same `git add -A` the
	# snapshot has always used, NOT by adding everything and unstaging the big
	# entries afterwards — by then git has already hashed and written the blob,
	# which is the entire cost being avoided. Measured on a 200 MB untracked
	# file: 3086 ms to add it, 4 ms to exclude it.
	#
	# The pathspecs are `:(top)`-relative and the enumeration below runs from
	# the worktree top level, because `git add -A` covers the whole worktree no
	# matter which directory it is invoked from. A project path that points at a
	# SUBDIRECTORY of a repo would otherwise pair top-level-relative exclusions
	# with subdirectory-relative names and exclude the wrong path.
	local top
	if ! top="$(git -C "${dir}" rev-parse --show-toplevel)"; then
		echo "  WARNING: ${project_name}: snapshot failed at rev-parse --show-toplevel — no checkpoint protection!" >&2
		return 1
	fi

	local max_mb="${RIOTBOX_SNAPSHOT_MAX_MB:-10}"
	if [[ ! "${max_mb}" =~ ^[0-9]+$ ]] || [[ "${max_mb}" -lt 1 ]]; then
		echo "  WARNING: ${project_name}: RIOTBOX_SNAPSHOT_MAX_MB='${max_mb}' is not a positive whole number of MB — using 10." >&2
		max_mb=10
	fi
	local max_bytes=$((max_mb * 1048576))

	# `stat` without -L on purpose: a symlink to a 4 GB image is 20 bytes, and
	# git stores the link target rather than the target's contents, so following
	# it would skip a file that costs nothing. A file that vanishes between the
	# listing and the stat simply produces no record — it is then not excluded,
	# and `git add` skips a missing path exactly as `git add -A` always has.
	# A listing that fails outright yields no records, so the cap silently does
	# not apply: that errs toward capturing MORE, and the loop above has already
	# refused to reach here on the one failure that is real (a corrupt index).
	local -a skipped_paths=() skipped_sizes=()
	local record size path
	while IFS= read -r -d '' record; do
		size="${record%%$'\t'*}"
		path="${record#*$'\t'}"
		[[ "${size}" =~ ^[0-9]+$ ]] || continue
		[[ "${size}" -gt "${max_bytes}" ]] || continue
		skipped_paths+=("${path}")
		skipped_sizes+=("${size}")
	done < <(
		cd "${top}" || exit 1
		git ls-files -z --others --exclude-standard |
			xargs -0 -r stat --printf="%s\t%n\0" 2>/dev/null
	)

	# The leading `:(top)` states "the whole worktree" explicitly. git 2.52 also
	# reaches the whole worktree from an empty pathspec list and from an
	# exclude-only one, so this line changes no behaviour today — it is here so
	# the nothing-skipped case passes a real pathspec instead of depending on
	# either of those two undocumented shapes.
	local skipped
	{
		printf ':(top)\0'
		for skipped in "${skipped_paths[@]}"; do
			printf ':(top,literal,exclude)%s\0' "${skipped}"
		done
	} > "${pathspec_file}"

	if ! GIT_INDEX_FILE="${tmp_index}" git -C "${dir}" add -A \
		--pathspec-from-file="${pathspec_file}" --pathspec-file-nul; then
		echo "  WARNING: ${project_name}: snapshot failed at add — no checkpoint protection!" >&2
		return 1
	fi

	# Deliberately NOT gated on RIOTBOX_CHECKPOINT_QUIET. That switch silences
	# an advisory ("your snapshot is bigger than you may realise"); this one
	# names user data the safety net decided not to protect, and a safety net
	# that omits data silently is the failure mode this whole script exists to
	# prevent.
	local i human
	if [[ "${#skipped_paths[@]}" -gt 0 ]]; then
		{
			echo "  WARNING: ${project_name}: snapshot skipped ${#skipped_paths[@]} untracked file(s) over ${max_mb} MB:"
			for ((i = 0; i < ${#skipped_paths[@]}; i++)); do
				# MB below a gigabyte, one decimal above it: a 1.4 GB core dump
				# reading as "1434 MB" makes the number harder to act on.
				human="$(awk -v b="${skipped_sizes[i]}" 'BEGIN {
					if (b >= 1073741824) printf "%.1f GB", b / 1073741824
					else printf "%.0f MB", b / 1048576
				}')"
				printf '             %-24s (%s)\n' "${skipped_paths[i]}" "${human}"
			done
			echo "           These are NOT in the snapshot and NOT in the backup."
			echo "           Add them to .gitignore, or \`git add\` them to include them."
			echo "           Raise the limit with RIOTBOX_SNAPSHOT_MAX_MB."
		} >&2
	fi

	local tree
	if ! tree="$(GIT_INDEX_FILE="${tmp_index}" git -C "${dir}" write-tree)"; then
		echo "  WARNING: ${project_name}: snapshot failed at write-tree — no checkpoint protection!" >&2
		return 1
	fi

	# An unborn HEAD with nothing to capture has no snapshot to make.
	local empty_tree head_sha
	empty_tree="$(git -C "${dir}" hash-object -t tree /dev/null)"
	head_sha="$(git -C "${dir}" rev-parse --verify HEAD 2>/dev/null || true)"
	if [[ -z "${head_sha}" ]] && [[ "${tree}" == "${empty_tree}" ]]; then
		echo "  ${project_name}: empty git repo (no commits yet) — nothing to checkpoint."
		return 0
	fi

	# A clean tree needs no new object: point the ref at HEAD itself.
	local snapshot
	if [[ -n "${head_sha}" ]] && [[ "${tree}" == "$(git -C "${dir}" rev-parse "HEAD^{tree}")" ]]; then
		snapshot="${head_sha}"
	else
		local -a parent=()
		[[ -n "${head_sha}" ]] && parent=(-p "${head_sha}")
		if ! snapshot="$(git -C "${dir}" commit-tree "${tree}" "${parent[@]}" \
			-m "checkpoint: pre-riotbox-${timestamp}")"; then
			echo "  WARNING: ${project_name}: snapshot failed at commit-tree — no checkpoint protection!" >&2
			return 1
		fi
	fi

	# The trailing "" is the expected old value: it requires the ref to NOT
	# already exist, so two launches in the same second cannot silently clobber
	# each other's snapshot (timestamp has one-second resolution, and refs/riotbox
	# has no reflog history to recover a clobbered snapshot from). --create-reflog
	# gives the ref a reflog so any future update is recoverable.
	if ! git -C "${dir}" update-ref --create-reflog "${ref}" "${snapshot}" ""; then
		# git's own error reaches stderr above; distinguish the two causes so the
		# message names the real one — a collision and an unwritable refs store
		# need different actions from the user.
		if git -C "${dir}" rev-parse --verify --quiet "${ref}" >/dev/null; then
			echo "  WARNING: ${project_name}: a checkpoint for ${timestamp} already exists — no checkpoint protection!" >&2
			echo "           Another riotbox launch started in the same second." >&2
			echo "           This launch is continuing WITHOUT a checkpoint for this project — Ctrl-C now and relaunch if you want one." >&2
		else
			echo "  WARNING: ${project_name}: snapshot failed at update-ref — no checkpoint protection!" >&2
		fi
		return 1
	fi

	# Post-condition: a safety net that reports success having written nothing
	# is worse than one that fails loudly. On the clean-tree branch above this
	# holds by construction, so there it can only catch an update-ref that
	# returned 0 while leaving the ref unresolvable.
	if [[ "$(git -C "${dir}" rev-parse --verify "${ref}^{tree}")" != "${tree}" ]]; then
		echo "  WARNING: ${project_name}: snapshot ref does not match the tree just written — no checkpoint protection!" >&2
		return 1
	fi

	_backup_project "${dir}" "${project_name}" "${ref}"
}

timestamp="$(date +%Y%m%d-%H%M%S)"
for dir in "${PROJECT_DIRS[@]}"; do
	project_name="$(basename "${dir}")"

	if ! git -C "${dir}" rev-parse --git-dir &>/dev/null; then
		# shellcheck disable=SC2310  # checking function return — set -e suppression is intentional
		if ! maybe_init_git_repo "${dir}"; then
			echo "  WARNING: ${dir} is not a git repo — no checkpoint protection!" >&2
			continue
		fi
	fi

	# A bare repo has no worktree, so there is no working state to snapshot.
	# Skip it explicitly: `git ls-files --others` below dies with "this
	# operation must be run in a work tree", and under `set -e` that aborted
	# the whole loop, leaving every project after this one unprotected.
	# shellcheck disable=SC2312  # rev-parse cannot fail here — the dir is a verified git repo
	if [[ "$(git -C "${dir}" rev-parse --is-bare-repository)" == "true" ]]; then
		echo "  WARNING: ${dir} is a bare git repo (no worktree) — no checkpoint protection!" >&2
		continue
	fi

	# Ensure .git/info/exclude has the managed block so runtime artifacts
	# (headroom DBs, venom logs, Claude Code local files) are never swept
	# into the snapshot. This runs before `git add -A` so the gitignore
	# semantics take effect for this and all future checkpoints.
	ensure_managed_excludes "${dir}"

	# Warn if the snapshot is about to sweep in a large untracked set
	# (e.g. a .test-output/ tree that should have been gitignored).
	# Without this, multi-hundred-MB snapshots get pushed to the bare
	# backup on every run and the backup volume balloons silently.
	# Threshold tuned to "noticeable but not nagging": anything over 100
	# files OR 50 MB triggers the warning.
	# RIOTBOX_CHECKPOINT_QUIET=1 silences (CI, scripted runs).
	#
	# Guarded like every other per-project step: `git ls-files` exits 128 on a
	# corrupt .git/index, and unguarded at loop top level that took the whole
	# launch down under `set -e` — every project after this one silently got no
	# checkpoint at all. A repo this broken cannot be snapshotted either, so
	# warn and move on.
	if ! _untracked="$(git -C "${dir}" ls-files --others --exclude-standard)"; then
		echo "  WARNING: ${project_name}: cannot list untracked files (corrupt index?) — no checkpoint protection!" >&2
		continue
	fi
	if [[ -n "${_untracked}" ]] && [[ -z "${RIOTBOX_CHECKPOINT_QUIET:-}" ]]; then
		_untracked_count="$(printf '%s\n' "${_untracked}" | wc -l)"
		# Sum bytes of the untracked set. Use ls-files -z + du
		# --files0-from to handle paths with spaces/newlines safely.
		# shellcheck disable=SC2312 # awk on pipe stdout; failure → 0
		_untracked_bytes="$(
			cd "${dir}" 2>/dev/null &&
				git ls-files -z --others --exclude-standard |
				du -bc --files0-from=- 2>/dev/null |
				awk 'END {print $1+0}'
		)"
		_untracked_mb=$(((_untracked_bytes + 1048575) / 1048576))
		if [[ "${_untracked_count}" -gt 100 ]] || [[ "${_untracked_mb}" -gt 50 ]]; then
			echo "  WARNING: checkpoint will bundle ${_untracked_count} untracked file(s), ~${_untracked_mb} MB, into ${project_name}." >&2
			echo "           Add patterns to .gitignore if these shouldn't be in the snapshot." >&2
			echo "           Suppress with RIOTBOX_CHECKPOINT_QUIET=1." >&2
		fi
		unset _untracked_count _untracked_bytes _untracked_mb
	fi

	# Snapshot the project into refs/riotbox/checkpoints/<ts> without touching
	# the worktree, the index, HEAD, or any branch. commit-tree runs no hooks
	# and ignores commit.gpgsign, so a host that forces signing, a repo with a
	# pre-commit hook, and a conflicted merge in progress are all safe.
	_snapshot_project "${dir}" "${project_name}" || continue
done
