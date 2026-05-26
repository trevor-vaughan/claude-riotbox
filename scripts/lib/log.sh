#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/lib/log.sh — structured JSON logger.
#
# Sourced by engine-side scripts that want machine-parseable output. Existing
# scripts that print free-form text are NOT migrated by this file; this is
# opt-in for new code.
#
# Public:
#   log_emit <level> <step> <msg> [<json-extras>]
#     Writes one JSON line to stdout. Fields:
#       ts     ISO 8601 UTC timestamp (second resolution)
#       level  info|warn|error|debug (free-form; conventionally one of these)
#       step   short tag identifying the engine step (e.g. "launch.run")
#       msg    short message
#       …      additional fields merged from the optional <json-extras> arg
#              (a JSON object, e.g. '{"key":"abc","count":3}')
#
#   log_fmt <line>
#     Render one JSON line (as produced by log_emit) as a single human-
#     readable line. Output format:
#       <ts> [<LEVEL>] <step>: <msg>
#     Extra fields are not rendered by log_fmt; consumers that want them
#     should use jq directly.
#
# Both helpers depend on `jq` (already a base-image package — see Dockerfile).
# ─────────────────────────────────────────────────────────────────────────────

# Internal: emit current UTC timestamp in ISO 8601 (second resolution).
# Extracted because callers may want to override it for deterministic tests.
_log_iso_now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log_emit() {
	local level="${1:?log_emit: level required}"
	local step="${2:?log_emit: step required}"
	local msg="${3:?log_emit: msg required}"
	local extras="${4:-{\}}"
	local ts
	ts="$(_log_iso_now)"
	# --argjson rejects malformed JSON — that's the desired failure mode.
	# Fields from $extras win on key collision; this is intentional so
	# callers can override step/msg per-call when needed.
	jq -cn \
		--arg ts "${ts}" \
		--arg level "${level}" \
		--arg step "${step}" \
		--arg msg "${msg}" \
		--argjson extras "${extras}" \
		'{ts:$ts, level:$level, step:$step, msg:$msg} + $extras'
}

log_fmt() {
	local line="${1:?log_fmt: line required}"
	jq -r '"\(.ts) [\(.level | ascii_upcase)] \(.step): \(.msg)"' <<<"${line}"
}
