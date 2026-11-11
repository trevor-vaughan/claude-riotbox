#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# anywhere.sh — the main command of a `riotbox anywhere` session.
#
# Run by entrypoint.sh (through run_main_command) after every agent's
# container_setup, so Claude Code and opencode are configured exactly as they
# are for `riotbox run`. Starts Yep Anywhere, a mobile-first web UI, which in
# turn starts the agents when the phone opens a session.
#
# Why CLAUDE_CODE_EXECUTABLE: Yep Anywhere drives Claude through Anthropic's
# Agent SDK, which by default runs the native Claude binary bundled in its own
# npm package — a different Claude Code than the image's, and one that skips
# the RiotBox wrapper (container/agent-wrapper.sh) and the flags it injects.
# Yep Anywhere reads CLAUDE_CODE_EXECUTABLE before falling back to that bundle,
# and with it set never falls back (packages/server/src/sdk/providers/claude.ts
# upstream), so the wrapper is what runs. The image build also deletes the
# bundled binaries, so a regression there fails a session rather than quietly
# running unwrapped.
#
# Known gap — opencode: Yep Anywhere looks for opencode at ~/.local/bin before
# PATH, and that is where the image keeps the REAL binary, so opencode sessions
# skip the wrapper. Its config (permission = "allow", plugins, the RiotBox
# prompt) still applies, because opencode reads that itself; what is lost is
# what only the wrapper adds — headroom wrapping. Fixing it needs an upstream
# setting for the opencode path; see docs/dev/decisions/yep-anywhere.md.
#
# The password: on first use, or with RIOTBOX_ANYWHERE_RESET_PASSWORD=1, a
# random one is generated, handed to `yepanywhere --setup-auth` (which stores
# only a bcrypt hash, in ~/.yep-anywhere/auth.json) and printed here once.
# ~/.yep-anywhere is a state-dir mount (scripts/mount-projects.sh), so the
# password and the self-signed certificate survive to the next session of the
# same projects — the phone accepts the certificate once, not every launch.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# Where the image build stages the pinned release and its shim. Overridable
# for the test suite only.
YEP_BIN="${RIOTBOX_YEP_BIN:-${HOME}/.riotbox/yepanywhere/bin/yepanywhere}"
YEP_DATA="${YEP_DATA_DIR:-${HOME}/.yep-anywhere}"
YEP_PORT=3400

if [[ ! -x "${YEP_BIN}" ]]; then
	echo "ERROR: Yep Anywhere is not installed in this image (${YEP_BIN})." >&2
	echo "       Rebuild it with: riotbox build" >&2
	exit 1
fi

claude_wrapper="${HOME}/.riotbox/bin/claude"
if [[ ! -x "${claude_wrapper}" ]]; then
	echo "ERROR: the RiotBox claude wrapper is missing (${claude_wrapper})." >&2
	exit 1
fi
export CLAUDE_CODE_EXECUTABLE="${claude_wrapper}"
unset CLAUDE_CODE_PATH
export YEP_DATA_DIR="${YEP_DATA}"
unset YEP_PROFILE
# The bind address the host publishes on (libexec/anywhere-lib.sh). Without
# it Yep Anywhere's Host-header check refuses API calls addressed to anything
# but localhost, a private IPv4 address or *.ts.net.
if [[ -n "${RIOTBOX_ANYWHERE_HOST:-}" ]]; then
	export ALLOWED_HOSTS="${RIOTBOX_ANYWHERE_HOST}"
else
	unset ALLOWED_HOSTS
fi

mkdir -p "${YEP_DATA}"
chmod 700 "${YEP_DATA}"

# At "info" Yep Anywhere logs every request to the terminal and scrolls the
# banner below, with its once-shown password, out of sight. The terminal gets
# warnings and errors; the full log goes to a file that 0.11.0 only appends to
# and never rotates, so each launch empties it. Sessions of one project set
# share this directory, so a second concurrent launch empties the first's
# log and both then append to it.
export LOG_LEVEL=warn LOG_FILE_LEVEL=info LOG_TO_FILE=true
mkdir -p "${YEP_DATA}/logs"
: >"${YEP_DATA}/logs/server.log"

password=""
if [[ ! -s "${YEP_DATA}/auth.json" ]] || [[ "${RIOTBOX_ANYWHERE_RESET_PASSWORD:-0}" = "1" ]]; then
	# 24 alphanumerics, ~143 bits; easy to type on a phone. No "-": the
	# --setup-auth parser reads a value starting with "-" as the next flag.
	# A finite read, not `tr < /dev/urandom | head`: under pipefail the
	# SIGPIPE that tr gets when head exits would end the script.
	while ((${#password} < 24)); do
		password+="$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
	done
	password="${password:0:24}"
	if ! "${YEP_BIN}" --setup-auth "${password}" >/dev/null 2>&1; then
		echo "ERROR: yepanywhere --setup-auth failed; no password was set." >&2
		exit 1
	fi
fi

url="${RIOTBOX_ANYWHERE_URL:-https://localhost:${YEP_PORT}}"
echo ""
echo "Yep Anywhere: ${url}"
if [[ -n "${password}" ]]; then
	echo "Password:     ${password}"
	echo "              (shown once; reset with RIOTBOX_ANYWHERE_RESET_PASSWORD=1 riotbox anywhere)"
else
	echo "Password:     unchanged from the last session of these projects"
	echo "              (forgotten? RIOTBOX_ANYWHERE_RESET_PASSWORD=1 riotbox anywhere)"
fi
echo "Certificate:  self-signed; your browser asks you to accept it once."
echo "Log:          ~/.yep-anywhere/logs/server.log in the container (only warnings and errors show here)"
echo "Stop:         Ctrl-C here."
echo ""
unset password

# 0.0.0.0 inside the container only: the host publishes the port on the single
# address RIOTBOX_ANYWHERE_BIND names (libexec/anywhere-lib.sh).
exec "${YEP_BIN}" --host 0.0.0.0 --port "${YEP_PORT}" --https-self-signed
