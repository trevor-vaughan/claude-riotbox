#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# agents/pi/setup.sh — container-side Pi setup, sourced by
# agent_pi_container_setup on every container start.
#
# Defines pi_setup, which:
#   1. Places ~/.pi/agent/AGENTS.md — RIOTBOX_PROMPT when set, otherwise the
#      host copy host_sync brought in, otherwise the RiotBox template. Same
#      precedence as opencode_setup.
#   2. Rewrites ~/.pi/agent/settings.json: host keys are kept, and the keys
#      below are forced to RiotBox values.
#
# The "ignoring host packages" NOTE is printed only when RIOTBOX_AGENT is pi:
# this runs at every agent's container start, and Claude/opencode sessions
# have no use for it. The packages are replaced regardless.
#
# Forced settings:
#   packages               the extensions installed in the image, as absolute
#                          paths. Host entries cannot work here: local paths
#                          name host directories, and npm/git specs would make
#                          Pi install unpinned code at startup.
#   defaultProjectTrust    "always" — the container is the boundary, as for
#                          Claude and opencode, and print mode would otherwise
#                          skip a project's .pi/ resources without saying so.
#   enableInstallTelemetry false
#   enableAnalytics        false
#
# The extension list is read from the installed extensions manifest rather
# than repeated here, so adding an extension is one edit to
# container/pi/package.json.
#
# Depends on json_write_atomic (scripts/lib/json-write.sh), which
# container/entrypoint.sh sources before any agent's container_setup runs.
# ─────────────────────────────────────────────────────────────────────────────

pi_setup() {
	local agent_dir="${HOME}/.pi/agent"
	local agents_md="${agent_dir}/AGENTS.md"
	local settings="${agent_dir}/settings.json"
	local template="${HOME}/.riotbox/AGENTS.md.template"
	local ext_root="${RIOTBOX_PI_DIR:-${HOME}/.riotbox/pi}/extensions"

	mkdir -p "${agent_dir}"

	if [[ -n "${RIOTBOX_PROMPT:-}" ]] && [[ -f "${RIOTBOX_PROMPT}" ]]; then
		local os_pretty="Linux"
		if [[ -f /etc/os-release ]]; then
			# shellcheck disable=SC1091
			os_pretty="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-Linux}")"
		fi
		# Other sessions of the project share this file: render beside it and
		# rename, keeping its mode, so a concurrent start never reads it
		# half-written.
		local tmp=""
		if ! tmp="$(mktemp "${agents_md}.XXXXXX")" ||
			! awk -v os="${os_pretty}" '{gsub(/\{\{OS_PRETTY_NAME\}\}/, os); print}' \
				"${RIOTBOX_PROMPT}" >"${tmp}" ||
			{ [[ -f "${agents_md}" ]] && ! chmod --reference="${agents_md}" -- "${tmp}"; } ||
			! mv -fT -- "${tmp}" "${agents_md}"; then
			[[ -z "${tmp}" ]] || rm -f -- "${tmp}"
			echo "  [pi] WARN: could not write ${agents_md} from RIOTBOX_PROMPT." >&2
		fi
	elif [[ ! -f "${agents_md}" ]] && [[ -f "${template}" ]]; then
		cp "${template}" "${agents_md}"
	fi

	local host='{}'
	if [[ -f "${settings}" ]]; then
		if ! host="$(jq -c 'if type == "object" then . else error("root must be an object") end' "${settings}" 2>/dev/null)" ||
			[[ -z "${host}" ]]; then
			echo "  [pi] WARN: ${settings} is not a valid JSON object — ignoring it." >&2
			host='{}'
		fi
	fi

	local packages='[]'
	if [[ ! -f "${ext_root}/package.json" ]]; then
		echo "  [pi] WARN: ${ext_root}/package.json is missing — Pi will start without RiotBox's extensions." >&2
	elif ! packages="$(jq -c --arg root "${ext_root}/node_modules" \
		'[(.dependencies // {}) | keys[] | "\($root)/\(.)"]' "${ext_root}/package.json" 2>/dev/null)" ||
		[[ -z "${packages}" ]]; then
		echo "  [pi] WARN: ${ext_root}/package.json is not valid JSON — Pi will start without RiotBox's extensions." >&2
		packages='[]'
	elif ! jq -e '(.dependencies // {}) | type == "object"' "${ext_root}/package.json" >/dev/null; then
		echo "  [pi] WARN: ${ext_root}/package.json has no dependencies object — Pi will start without RiotBox's extensions." >&2
		packages='[]'
	fi

	local dropped
	dropped="$(jq -r --argjson keep "${packages}" '
		(.packages // [])
		| (if type == "array" then . elif type == "object" then [.[]] else [.] end)
		| map(if type == "object" then (.source // tojson) else tostring end)
		| map(select(IN($keep[]) | not))
		| .[]' <<<"${host}")"
	if [[ -n "${dropped}" && "${RIOTBOX_AGENT:-}" == "pi" ]]; then
		echo "  [pi] NOTE: RiotBox manages Pi packages; ignoring these from the host settings.json:" >&2
		local entry
		while IFS= read -r entry; do
			echo "  [pi]   ${entry}" >&2
		done <<<"${dropped}"
	fi

	local merged
	if ! merged="$(jq --argjson packages "${packages}" '. + {
		packages: $packages,
		defaultProjectTrust: "always",
		enableInstallTelemetry: false,
		enableAnalytics: false
	}' <<<"${host}")" || [[ -z "${merged}" ]]; then
		echo "  [pi] WARN: could not compose ${settings} — Pi will start without RiotBox's settings." >&2
		return 0
	fi
	if ! json_write_atomic "${settings}" "${merged}"; then
		echo "  [pi] WARN: could not write ${settings} — Pi will start without RiotBox's settings." >&2
	fi
}
