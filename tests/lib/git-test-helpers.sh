#!/usr/bin/env bash
# Shared helpers for git-based Venom tests.
# Source this file at the top of each test script.
set -euo pipefail

HUMAN_NAME="Test Human"
HUMAN_EMAIL="human@example.com"

# Current container identity — matches the Containerfile's git config.
LLM_NAME="LLM"
LLM_EMAIL="llm@riotbox"

# Legacy container identities recognised by reown-commits.sh and the pre-push
# hook. Tests use these to assert that old history is still rewritten.
# shellcheck disable=SC2034  # consumed by callers that source this helper
LLM_EMAIL_LEGACY_CLAUDE="claude@riotbox"
# shellcheck disable=SC2034  # consumed by callers that source this helper
LLM_EMAIL_LEGACY_LOCALHOST="llm@localhost"
# shellcheck disable=SC2034  # consumed by callers that source this helper
LLM_EMAIL_LEGACY_RIOTBOX="riotbox@local"

# Activate an isolated, signing-disabled git profile rooted at the given dir.
#
# Why: the host may carry commit.gpgsign=true plus a real signing key in
# ~/.gitconfig or /etc/gitconfig. Any repo a test creates (or that
# checkpoint.sh creates via `git init`) would inherit that and either abort
# committing (no key in the sandbox) or sign with the developer's key. We
# point GIT_CONFIG_GLOBAL at a throwaway file, ignore system config, and
# pin signing off so every repo born during the test uses the same safe
# profile. Call this BEFORE any `git init` so even repo creation is isolated.
# Sets/exports: GIT_CONFIG_GLOBAL, GIT_CONFIG_NOSYSTEM.
setup_git_test_profile() {
	local base="${1}"
	export GIT_CONFIG_GLOBAL="${base}/isolated.gitconfig"
	export GIT_CONFIG_NOSYSTEM=1
	# checkpoint.sh derives its backup root from XDG_DATA_HOME (via
	# resolve_projects); sandbox it so checkpoint backups land under the
	# test dir instead of the developer's real ~/.local/share/riotbox.
	export XDG_DATA_HOME="${base}/xdg"
	git config --global user.name "${HUMAN_NAME}"
	git config --global user.email "${HUMAN_EMAIL}"
	git config --global init.defaultBranch main
	git config --global commit.gpgsign false
	git config --global tag.gpgsign false
}

# Create a test directory with a git repo and optional bare remote.
# Sets: TEST_DIR, REPO_DIR, BARE_DIR, GIT_CONFIG_GLOBAL
init_test_repo() {
	TEST_DIR="$(mktemp -d)"
	REPO_DIR="${TEST_DIR}/project"
	BARE_DIR="${TEST_DIR}/remote.git"

	# Isolate from host git config before creating any repo.
	setup_git_test_profile "${TEST_DIR}"

	git init --bare --initial-branch=main "${BARE_DIR}" >/dev/null 2>&1
	git init --initial-branch=main "${REPO_DIR}" >/dev/null 2>&1
	cd "${REPO_DIR}"
	git config user.name "${HUMAN_NAME}"
	git config user.email "${HUMAN_EMAIL}"
	git config init.defaultBranch main
	git remote add origin "${BARE_DIR}"
}

# Create a plain working directory that is NOT a git repo, under the isolated
# signing-disabled profile. Used to exercise checkpoint.sh's non-git path.
# Sets: TEST_DIR, WORK_DIR (and exports the test git profile).
init_test_workdir() {
	TEST_DIR="$(mktemp -d)"
	WORK_DIR="${TEST_DIR}/project"
	mkdir -p "${WORK_DIR}"
	setup_git_test_profile "${TEST_DIR}"
}

# Run a command under a pseudo-terminal so the child sees an interactive stdin
# (isatty() is true), which is the only way to exercise checkpoint.sh's
# "prompt to create a repo" branch — Venom's plain exec has no controlling tty.
# Feeds one line of input (INPUT, may be empty for a bare Enter / default), then
# prints the child's combined output and returns its exit code.
# Relevant env (ROOT_DIR, RIOTBOX_*, the git profile) must be exported by the
# caller; the child inherits it.
# Usage: run_under_pty "<input>" COMMAND [ARGS...]
run_under_pty() {
	local input="$1"
	shift
	PTY_INPUT="${input}" python3 - "$@" <<'PY'
import os, pty, sys, time

argv = sys.argv[1:]
line = (os.environ.get("PTY_INPUT", "") + "\n").encode()

pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)
    os._exit(127)

# Give the child a moment to reach a prompt, then answer it. If the child
# never prompts it will have exited already and the write simply fails.
time.sleep(0.5)
try:
    os.write(fd, line)
except OSError:
    pass

out = bytearray()
while True:
    try:
        chunk = os.read(fd, 1024)
    except OSError:
        break
    if not chunk:
        break
    out += chunk

_, status = os.waitpid(pid, 0)
sys.stdout.buffer.write(bytes(out))
sys.stdout.flush()
sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status))
PY
}

# Build a throwaway install tree (a stand-in for RIOTBOX_DIR/ROOT_DIR) that
# reuses the real helper scripts but replaces launch.sh with a stub, so run.sh
# can be exercised end-to-end without building or starting a container. The
# stub prints "STUB-LAUNCH reached: <args>" and exits 0. Echoes the root path.
# Usage: fake_root="$(make_fake_root "<real_riotbox_dir>" "<base_dir>")"
make_fake_root() {
	local real="$1" base="$2"
	local root="${base}/fakeroot"
	mkdir -p "${root}/libexec"
	ln -s "${real}/scripts" "${root}/scripts"
	ln -s "${real}/agents" "${root}/agents"
	ln -s "${real}/libexec/run.sh" "${root}/libexec/run.sh"
	ln -s "${real}/libexec/checkpoint.sh" "${root}/libexec/checkpoint.sh"
	cat >"${root}/libexec/launch.sh" <<'STUB'
#!/usr/bin/env bash
echo "STUB-LAUNCH reached: $*"
exit 0
STUB
	chmod +x "${root}/libexec/launch.sh"
	printf '%s\n' "${root}"
}

human_commit() {
	local msg="${1}"
	echo "${msg}" >>history.txt
	git add -A
	GIT_AUTHOR_NAME="${HUMAN_NAME}" \
		GIT_AUTHOR_EMAIL="${HUMAN_EMAIL}" \
		GIT_COMMITTER_NAME="${HUMAN_NAME}" \
		GIT_COMMITTER_EMAIL="${HUMAN_EMAIL}" \
		git commit -m "${msg}" --allow-empty-message >/dev/null
}

# Commit using the current container identity (LLM_NAME / LLM_EMAIL).
llm_commit() {
	local msg="${1}"
	echo "${msg}" >>history.txt
	git add -A
	GIT_AUTHOR_NAME="${LLM_NAME}" \
		GIT_AUTHOR_EMAIL="${LLM_EMAIL}" \
		GIT_COMMITTER_NAME="${LLM_NAME}" \
		GIT_COMMITTER_EMAIL="${LLM_EMAIL}" \
		git commit -m "${msg}" --allow-empty-message >/dev/null
}

# Commit using an arbitrary identity — used in tests that need to exercise
# the legacy email recognition paths in reown-commits.sh / pre-push.
identity_commit() {
	local name="${1}"
	local email="${2}"
	local msg="${3}"
	echo "${msg}" >>history.txt
	git add -A
	GIT_AUTHOR_NAME="${name}" \
		GIT_AUTHOR_EMAIL="${email}" \
		GIT_COMMITTER_NAME="${name}" \
		GIT_COMMITTER_EMAIL="${email}" \
		git commit -m "${msg}" --allow-empty-message >/dev/null
}

count_by_author() {
	local email="${1}"
	shift
	git log "$@" --author="${email}" --format='%H' | wc -l | tr -d ' '
}

# Repo left mid-merge with a conflict. Layers on init_test_repo, so the
# isolated signing-disabled profile is active.
# Sets: TEST_DIR, REPO_DIR, BARE_DIR (from init_test_repo)
init_test_repo_mid_merge() {
	init_test_repo
	printf 'line1\n' >"${REPO_DIR}/f.txt"
	git -C "${REPO_DIR}" add f.txt
	git -C "${REPO_DIR}" commit -qm initial
	git -C "${REPO_DIR}" checkout -qb feature
	printf 'feature\n' >"${REPO_DIR}/f.txt"
	git -C "${REPO_DIR}" commit -qam feature
	git -C "${REPO_DIR}" checkout -q main
	printf 'mainline\n' >"${REPO_DIR}/f.txt"
	git -C "${REPO_DIR}" commit -qam mainline
	git -C "${REPO_DIR}" merge feature >/dev/null 2>&1 || true

	# The merge is expected to conflict; if it did not (e.g. a future git
	# version or config change resolves it cleanly), fail loudly rather than
	# silently handing back a quiescent repo under a "mid-merge" name.
	git -C "${REPO_DIR}" rev-parse -q --verify MERGE_HEAD >/dev/null || {
		echo "init_test_repo_mid_merge: expected merge conflict did not occur" >&2
		return 1
	}
}

# Repo left mid-rebase with a conflict (detached HEAD, .git/rebase-merge present).
# Sets: TEST_DIR, REPO_DIR, BARE_DIR (from init_test_repo)
init_test_repo_mid_rebase() {
	init_test_repo
	printf 'a\n' >"${REPO_DIR}/f.txt"
	git -C "${REPO_DIR}" add f.txt
	git -C "${REPO_DIR}" commit -qm initial
	git -C "${REPO_DIR}" checkout -qb topic
	printf 'topic\n' >"${REPO_DIR}/f.txt"
	git -C "${REPO_DIR}" commit -qam topic
	git -C "${REPO_DIR}" checkout -q main
	printf 'main\n' >"${REPO_DIR}/f.txt"
	git -C "${REPO_DIR}" commit -qam main
	git -C "${REPO_DIR}" checkout -q topic
	git -C "${REPO_DIR}" rebase main >/dev/null 2>&1 || true

	# The rebase is expected to conflict; if it did not, fail loudly rather
	# than silently handing back a quiescent repo under a "mid-rebase" name.
	# rev-parse --git-path may return a path relative to REPO_DIR or an
	# absolute path; canonicalise the same way ensure_managed_excludes does
	# in checkpoint.sh.
	local raw_path rebase_state_dir
	raw_path="$(git -C "${REPO_DIR}" rev-parse --git-path rebase-merge)"
	if [[ "${raw_path}" = /* ]]; then
		rebase_state_dir="${raw_path}"
	else
		rebase_state_dir="${REPO_DIR}/${raw_path}"
	fi
	test -d "${rebase_state_dir}" || {
		echo "init_test_repo_mid_rebase: expected rebase conflict did not occur" >&2
		return 1
	}
}

# init_test_repo_with_hook <hook-name> <exit-code>
# Repo with one commit and a hook that exits as directed.
# Sets: TEST_DIR, REPO_DIR, BARE_DIR (from init_test_repo)
init_test_repo_with_hook() {
	local hook="${1}" code="${2}"
	init_test_repo
	printf 'base\n' >"${REPO_DIR}/f.txt"
	git -C "${REPO_DIR}" add f.txt
	git -C "${REPO_DIR}" commit -qm initial

	# rev-parse --git-path may return a path relative to REPO_DIR or an
	# absolute path (e.g. worktrees); canonicalise the same way
	# ensure_managed_excludes does in checkpoint.sh.
	local raw_path hook_path
	raw_path="$(git -C "${REPO_DIR}" rev-parse --git-path "hooks/${hook}")"
	if [[ "${raw_path}" = /* ]]; then
		hook_path="${raw_path}"
	else
		hook_path="${REPO_DIR}/${raw_path}"
	fi
	mkdir -p "$(dirname "${hook_path}")"
	cat >"${hook_path}" <<HOOK
#!/usr/bin/env bash
echo "${hook} hook refusing" >&2
exit ${code}
HOOK
	chmod +x "${hook_path}"
}

# backup_path <project-dir>
# Echo the bare backup store checkpoint.sh will use for a project:
#   ${XDG_DATA_HOME}/riotbox/backups/<canonical-path-with-slashes-mangled>.git
# Mirrors _backup_project's derivation in libexec/checkpoint.sh character for
# character. The key is the CANONICAL PROJECT PATH, not the basename, so
# ~/work/a/web and ~/work/b/web cannot share (and clobber) one store — a test
# that re-derives this by hand and drifts goes vacuous rather than red.
# Requires XDG_DATA_HOME, which setup_git_test_profile exports.
# Usage: backup="$(backup_path "${REPO_DIR}")"
backup_path() {
	local project="${1}"
	local canonical key
	canonical="$(cd "${project}" && pwd -P)"
	# shellcheck disable=SC2312  # printf into sed cannot fail for a non-empty path
	key="$(printf '%s\n' "${canonical}" | sed 's|/|-|g; s|^-||')"
	printf '%s/riotbox/backups/%s.git\n' "${XDG_DATA_HOME}" "${key}"
}

# occupy_legacy_backup_path <project-dir>
# Occupy the LEGACY, basename-keyed backup path with a plain (non-repo)
# directory containing a `placeholder` file:
#   ${XDG_DATA_HOME}/riotbox/backups/<basename>.git
# checkpoint.sh no longer backs up there — it keys the store on the canonical
# project path (see backup_path) and only probes the legacy path to decide
# whether a pre-existing store should be migrated. So this does NOT break the
# backup: it fixtures the "legacy path exists but is not a repo" case, where the
# migration probe must refuse and the real backup must still succeed.
# Echoes the path it occupied.
occupy_legacy_backup_path() {
	local project="${1}"
	local base
	base="$(basename "${project}")"
	local path="${XDG_DATA_HOME}/riotbox/backups/${base}.git"
	mkdir -p "${path}"
	printf 'not a git repo\n' >"${path}/placeholder"
	printf '%s\n' "${path}"
}

# Repo with one staged file, one unstaged edit, and one untracked file.
# Sets: TEST_DIR, REPO_DIR, BARE_DIR (from init_test_repo)
init_test_repo_staged_and_unstaged() {
	init_test_repo
	printf 'orig\n' >"${REPO_DIR}/tracked.txt"
	git -C "${REPO_DIR}" add tracked.txt
	git -C "${REPO_DIR}" commit -qm initial
	printf 'staged\n' >>"${REPO_DIR}/tracked.txt"
	git -C "${REPO_DIR}" add tracked.txt
	printf 'unstaged\n' >>"${REPO_DIR}/tracked.txt"
	printf 'new\n' >"${REPO_DIR}/untracked.txt"
}
