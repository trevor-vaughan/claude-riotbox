#!/usr/bin/env bash
# headroom-summary.sh — compact per-model performance summary on session exit.
#
# Sourced by entrypoint.sh. Provides:
#   headroom_summary_init   — record session start time (no-op unless RIOTBOX_HEADROOM=1)
#   headroom_render_perf_json — pure renderer: stdin → formatted summary or silent
#   headroom_summary_print  — invoke headroom perf and render (no-op unless gate open)
#
# Dollar amounts shown per model are list-price approximations; cache pricing differs.

# _humanize_num N
# Print N as X.XXM (>=1e6), X.XK (>=1e3), or raw integer. No trailing newline.
_humanize_num() {
	awk -v n="$1" 'BEGIN{
		if(n>=1000000) printf "%.2fM", n/1000000
		else if(n>=1000) printf "%.1fK", n/1000
		else printf "%d", n
	}'
}

# headroom_render_perf_json
# Reads headroom perf output on stdin (may have non-JSON banner lines before the
# first line starting with "{").  Strips banner, parses JSON with jq, and prints
# the approved compact summary.  Returns 1 (printing nothing) when:
#   - input is empty or does not contain valid JSON
#   - total_requests is 0, null, or missing
headroom_render_perf_json() {
	local raw json
	raw="$(cat)"
	# Strip everything before the first line that starts with "{"
	json="$(printf '%s\n' "${raw}" | sed -n '/^[[:space:]]*{/,$p')"
	[[ -z "${json}" ]] && return 1

	# Validate JSON and extract top-level scalars
	local total_req total_before total_after saved savings_pct cache_hit
	if ! total_req="$(printf '%s\n' "${json}" | jq -r '.total_requests // empty' 2>/dev/null)"; then
		return 1
	fi
	[[ -z "${total_req}" || "${total_req}" = "null" || "${total_req}" = "0" ]] && return 1
	# Numeric zero check (jq outputs "0" as string)
	[[ "${total_req}" -eq 0 ]] 2>/dev/null && return 1

	total_before="$(printf '%s\n' "${json}" | jq -r '.total_tokens_before // 0')"
	total_after="$(printf '%s\n' "${json}" | jq -r '.total_tokens_after // 0')"
	saved="$(printf '%s\n' "${json}" | jq -r '.tokens_saved // 0')"
	savings_pct="$(printf '%s\n' "${json}" | jq -r '.savings_pct // 0')"
	cache_hit="$(printf '%s\n' "${json}" | jq -r '.cache_hit_pct // empty')"

	# Humanize numbers
	local h_before h_after h_saved
	h_before="$(_humanize_num "${total_before}")"
	h_after="$(_humanize_num "${total_after}")"
	h_saved="$(_humanize_num "${saved}")"

	# Build filtered, sorted model rows: tokens_before > 0, sorted by requests desc, max 5
	local models_json
	models_json="$(printf '%s\n' "${json}" | jq -c '
		[.by_model[]?
		 | select(.tokens_before > 0)
		 | {model, requests, savings_pct,
		    list_price_per_mtok,
		    tokens_after,
		    tokens_saved}]
		| sort_by(-.requests)
		| .[0:5]
	' 2>/dev/null)" || return 1

	# Compute max model name width (capped at 24) for column alignment
	local max_width=0
	while IFS= read -r row; do
		local name
		name="$(printf '%s\n' "${row}" | jq -r '.model')"
		local len="${#name}"
		[[ ${len} -gt 24 ]] && len=24
		[[ ${len} -gt ${max_width} ]] && max_width="${len}"
	done < <(printf '%s\n' "${models_json}" | jq -c '.[]')
	[[ ${max_width} -lt 1 ]] && max_width=20

	# Print summary
	printf '── headroom ─────────────────────────────────────────\n'
	printf ' requests %s · tokens %s → %s · saved %s (%s%%)\n' \
		"${total_req}" "${h_before}" "${h_after}" "${h_saved}" "${savings_pct}"
	if [[ -n "${cache_hit}" && "${cache_hit}" != "null" ]]; then
		printf ' cache-hit %s%%\n' "${cache_hit}"
	fi

	while IFS= read -r row; do
		local mname mreq msavings mprice mtok_after mtok_saved
		mname="$(printf '%s\n' "${row}" | jq -r '.model')"
		mreq="$(printf '%s\n' "${row}" | jq -r '.requests')"
		msavings="$(printf '%s\n' "${row}" | jq -r '.savings_pct')"
		mprice="$(printf '%s\n' "${row}" | jq -r '.list_price_per_mtok // empty')"
		mtok_after="$(printf '%s\n' "${row}" | jq -r '.tokens_after // 0')"
		mtok_saved="$(printf '%s\n' "${row}" | jq -r '.tokens_saved // 0')"
		# Truncate model name to 24 chars
		[[ ${#mname} -gt 24 ]] && mname="${mname:0:24}"
		if [[ -n "${mprice}" && "${mprice}" != "null" && "${mprice}" != "0" ]]; then
			local spent_str saved_str
			spent_str="$(awk -v ta="${mtok_after}" -v p="${mprice}" 'BEGIN{
				v = ta / 1000000 * p
				if (v > 0 && v < 0.01) { print "<$0.01" }
				else { printf "$%.2f", v }
			}')"
			saved_str="$(awk -v ts="${mtok_saved}" -v p="${mprice}" 'BEGIN{
				v = ts / 1000000 * p
				if (v > 0 && v < 0.01) { print "<$0.01" }
				else { printf "$%.2f", v }
			}')"
			printf "   %-${max_width}s  %3s req  %s spent  %s saved (%s%%)\n" \
				"${mname}" "${mreq}" "${spent_str}" "${saved_str}" "${msavings}"
		else
			printf "   %-${max_width}s  %3s req  %s%% saved\n" \
				"${mname}" "${mreq}" "${msavings}"
		fi
	done < <(printf '%s\n' "${models_json}" | jq -c '.[]')

	printf ' full report: headroom perf\n'
}

# headroom_summary_init
# Record the session start time.  No-op unless RIOTBOX_HEADROOM=1.
headroom_summary_init() {
	[[ "${RIOTBOX_HEADROOM:-0}" = "1" ]] || return 0
	_HEADROOM_SUMMARY_START="$(date +%s)"
}

# headroom_summary_print
# Compute elapsed hours, invoke headroom perf, and render the summary.
# No-op unless: RIOTBOX_HEADROOM=1, headroom and jq are on PATH, and
# headroom_summary_init was called.  Never propagates failure or affects exit code.
headroom_summary_print() {
	[[ "${RIOTBOX_HEADROOM:-0}" = "1" ]] || return 0
	command -v headroom >/dev/null 2>&1 || return 0
	command -v jq >/dev/null 2>&1 || return 0
	[[ -n "${_HEADROOM_SUMMARY_START:-}" ]] || return 0

	# Compute elapsed hours; pass current epoch via -v to avoid gawk-only systime().
	# Minimum 0.1 h so the perf window is never zero.
	local _hours
	_hours="$(awk -v s="${_HEADROOM_SUMMARY_START}" -v now="$(date +%s)" \
		'BEGIN{h=(now-s)/3600; if(h<0.1)h=0.1; printf "%.2f",h}')"

	timeout 10 headroom perf --hours "${_hours}" --format json 2>/dev/null \
		| headroom_render_perf_json || true
}
