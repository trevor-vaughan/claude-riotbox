#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/lib/egress-prompt.sh — the egress section of an agent's system
# prompt (RIOTBOX_EGRESS=1; docs/dev/egress.md "Telling the agent about
# denials").
#
# A refused CONNECT reaches the agent as a bare 403 ("CONNECT tunnel failed,
# response 403"): clients drop the proxy's explanation. This section tells
# the agent what that means and to stop and ask the user, instead of
# spending tokens looking for a way around the allowlist.
#
# container/entrypoint.sh sources this file before the agents'
# container_setup; each manifest's container_setup calls one of the two
# functions below on the prompt file its agent reads. In the image it is
# ~/.riotbox/lib/egress-prompt.sh (the Containerfile copies scripts/lib/).
#
# Public:
#   egress_prompt_apply <file>
#       For a prompt file that is fresh in each container (Claude's managed
#       policy). Remove any egress section in <file>, then, when
#       RIOTBOX_EGRESS_SESSION is set, append the section naming that
#       session. A file with no begin marker outside egress mode is not
#       touched. Returns 1, with a warning, when RIOTBOX_EGRESS_SESSION is
#       not a session name: the old section is still removed, and none is
#       appended.
#   egress_prompt_apply_shared <file>
#       For a prompt file every session of a project shares (Pi's and
#       opencode's AGENTS.md; the user runs sessions concurrently).
#       opencode re-reads the file on every model call (1.19.3), and Pi
#       at startup and on /reload, /new, resume or switch, and fork
#       (pi-coding-agent 1.3.0; docs/dev/egress.md). At every start,
#       egress or not, replace any egress section in <file> with static
#       text that applies only while RIOTBOX_EGRESS_SESSION is set and
#       tells the agent to use its value. It is never stripped: a normal
#       start beside a running egress session must not take the section
#       away from it.
#       A missing <file> is created to hold it, as pi_setup and
#       opencode_setup create the file from the template.
#
#   Both: a section is a begin-marker line through the next end-marker
#   line (a trailing CR is ignored when matching markers); a begin marker
#   with no end marker after it is the user's text, kept with a warning.
#   egress_prompt_apply creates a missing <file> only to hold a section.
#   The new content replaces <file> by a rename, so a link at <file> is
#   replaced, not written through. A link, a FIFO or another non-regular
#   file at <file> is never read either: it is replaced by the section
#   alone, with a warning. No riotbox code puts one there (host sync copies
#   links' targets, and Claude's file is fresh in each container), so one
#   is a planted file, and reading it could leak its target into the
#   prompt or block the start. Outside egress mode egress_prompt_apply
#   leaves one alone. Both return 1, with a warning, when
#   <file> cannot be rewritten: the session still starts, and the proxy's
#   403 still explains itself.
# ─────────────────────────────────────────────────────────────────────────────

EGRESS_PROMPT_BEGIN='<!-- riotbox:egress begin -->'
EGRESS_PROMPT_END='<!-- riotbox:egress end -->'
# riotbox-core's session-name rule. The name is printed into the prompt, so
# anything else (a newline, a backtick) could forge prompt text.
_EGRESS_PROMPT_SESSION_RE='^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$'

egress_prompt_apply() {
	local file="$1" session="${RIOTBOX_EGRESS_SESSION:-}" rc=0 section=""
	if [[ -n "${session}" && ! "${session}" =~ ${_EGRESS_PROMPT_SESSION_RE} ]]; then
		echo "  [egress] WARN: RIOTBOX_EGRESS_SESSION is not a valid session name; the agent is not told about the egress allowlist." >&2
		session=""
		rc=1
	fi
	if [[ -n "${session}" ]]; then
		section="$(_egress_prompt_section \
			'Network access in this session goes through an allowlist proxy.' \
			"${session}" '')"
	elif [[ ! -f "${file}" || -L "${file}" ]] ||
		! grep -qxF -e "${EGRESS_PROMPT_BEGIN}" -e "${EGRESS_PROMPT_BEGIN}"$'\r' -- "${file}" 2>/dev/null; then
		return "${rc}"
	fi
	_egress_prompt_rewrite "${file}" "${section}" || return 1
	return "${rc}"
}

egress_prompt_apply_shared() {
	local file="$1" section
	# The backticks and $ are prompt text, not shell.
	# shellcheck disable=SC2016
	section="$(_egress_prompt_section \
		'If the environment variable `RIOTBOX_EGRESS_SESSION` is set, network access in this session goes through an allowlist proxy.' \
		'<value of $RIOTBOX_EGRESS_SESSION>' \
		'If `RIOTBOX_EGRESS_SESSION` is not set, this section does not apply.')"
	_egress_prompt_rewrite "${file}" "${section}"
}

# _egress_prompt_section <opening> <session> <closing> — print the section:
# <opening> sentence, the spec §6.2 instructions with <session> as the
# --session argument, then <closing> as its own paragraph when not empty.
_egress_prompt_section() {
	local opening="$1" session="$2" closing="$3"
	cat <<EOF
${EGRESS_PROMPT_BEGIN}

## Network allowlist

${opening}
A \`403\` from the proxy, or "CONNECT tunnel failed", means the host is not
allowed. It is not a transient error. Do not retry it, and do not try other
hosts, IP addresses, DNS, or proxies to get around it — nothing will work.
Stop and tell the user: "\`<host:port>\` is blocked; to allow it run
\`riotbox egress allow --session ${session} <host>\`" (or an \`@group\`
from \`riotbox egress groups\`), then carry on with work that doesn't need
it.
EOF
	[[ -z "${closing}" ]] || printf '\n%s\n' "${closing}"
	printf '\n%s\n' "${EGRESS_PROMPT_END}"
}

# _egress_prompt_rewrite <file> <section> — replace <file> with its text
# minus any egress section, plus <section> when not empty.
_egress_prompt_rewrite() {
	local file="$1" section="$2" tmp
	if [[ -d "${file}" && ! -L "${file}" ]]; then
		echo "  [egress] WARN: ${file} is a directory; the agent is not told about the egress allowlist." >&2
		return 1
	fi
	# A new <file> keeps mktemp's 0600: only llm, the file's owner, reads it.
	if ! tmp="$(mktemp "${file}.riotbox-egress.XXXXXX" 2>/dev/null)"; then
		echo "  [egress] WARN: cannot write beside ${file}; the agent is not told about the egress allowlist." >&2
		return 1
	fi
	if [[ -f "${file}" && ! -L "${file}" ]] && ! chmod --reference="${file}" -- "${tmp}"; then
		rm -f -- "${tmp}"
		echo "  [egress] WARN: cannot copy the mode of ${file}; the agent is not told about the egress allowlist." >&2
		return 1
	fi
	if ! _egress_prompt_render "${file}" "${section}" >"${tmp}" || ! mv -fT -- "${tmp}" "${file}"; then
		rm -f -- "${tmp}"
		echo "  [egress] WARN: could not rewrite ${file}; the agent is not told about the egress allowlist." >&2
		return 1
	fi
}

# _egress_prompt_render <file> <section> — print <file> without any egress
# section, then <section> when not empty. Lines after a begin marker are
# held back until the end marker drops them; a second begin marker or the
# end of the file prints them after all, so an unmatched begin marker never
# swallows the rest of the user's file. Only a regular file is read,
# checked right before the read: see the header for a link or a FIFO.
_egress_prompt_render() {
	local file="$1" section="$2"
	if [[ -L "${file}" ]]; then
		echo "  [egress] WARN: ${file} is a symbolic link; it is replaced by the egress section alone, and its target is not read." >&2
	elif [[ -e "${file}" && ! -f "${file}" ]]; then
		echo "  [egress] WARN: ${file} is not a regular file; it is replaced by the egress section alone, and it is not read." >&2
	elif [[ -f "${file}" && ! -L "${file}" ]]; then
		# The file is read from stdin, and its path for the warning comes
		# through ENVIRON: as an operand a path with "=" is an assignment,
		# and -v would treat its backslashes as escapes.
		EGRESS_PROMPT_FILE="$1" awk -v begin="${EGRESS_PROMPT_BEGIN}" -v end="${EGRESS_PROMPT_END}" '
			function flush(  i) { for (i = 1; i <= n; i++) print held[i]; n = 0 }
			{ line = $0; sub(/\r$/, "", line) }
			line == begin {
				if (n) { orphan = 1; flush() }
				held[++n] = $0
				next
			}
			n && line == end { n = 0; next }
			n { held[++n] = $0; next }
			{ print }
			END {
				if (n) { orphan = 1; flush() }
				if (orphan) printf "  [egress] WARN: %s has an egress begin marker with no end marker; the text after it was kept.\n", ENVIRON["EGRESS_PROMPT_FILE"] > "/dev/stderr"
			}' <"${file}" || return 1
	fi
	[[ -z "${section}" ]] || printf '%s\n' "${section}"
}
