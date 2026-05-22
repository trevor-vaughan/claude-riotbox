#!/usr/bin/env bash
# opencode-setup.sh — Runtime setup for opencode inside the riotbox.
#
# Sourced by entrypoint.sh. Provides:
#   opencode_setup — place AGENTS.md (from template, or from RIOTBOX_PROMPT
#                    override), then merge any host-synced opencode.json and
#                    opencode.jsonc into a single ~/.config/opencode/opencode.jsonc
#                    with riotbox-mandatory overrides applied (permission=allow,
#                    share=disabled, autoupdate=false, instructions includes
#                    AGENTS.md).
#
# Idempotent: safe to run on every container start. Regenerates the merged
# opencode.jsonc each call so content matches current host config + overrides.

# JSONC comment stripper used by opencode_setup. Reads from $1, writes JSON
# to stdout. Handles "//" and "/* ... */" comments outside double-quoted
# strings. Exits non-zero with a diagnostic if Python is unavailable.
_opencode_strip_jsonc() {
    local infile="$1"
    python3 - "${infile}" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
out = []
i = 0
n = len(src)
in_str = False
esc = False
while i < n:
    c = src[i]
    if esc:
        out.append(c)
        esc = False
        i += 1
        continue
    if c == "\\" and in_str:
        out.append(c)
        esc = True
        i += 1
        continue
    if c == '"':
        in_str = not in_str
        out.append(c)
        i += 1
        continue
    if not in_str and c == "/" and i + 1 < n and src[i + 1] == "/":
        # Line comment: skip to newline (keep the newline itself)
        while i < n and src[i] != "\n":
            i += 1
        continue
    if not in_str and c == "/" and i + 1 < n and src[i + 1] == "*":
        # Block comment: skip until "*/"
        i += 2
        while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
            i += 1
        i += 2
        continue
    out.append(c)
    i += 1
sys.stdout.write("".join(out))
PY
}

opencode_setup() {
    local opencode_dir="${HOME}/.config/opencode"
    local agents_md="${opencode_dir}/AGENTS.md"
    local opencode_json="${opencode_dir}/opencode.json"
    local opencode_jsonc="${opencode_dir}/opencode.jsonc"
    local template="${HOME}/.riotbox/AGENTS.md.template"

    mkdir -p "${opencode_dir}"

    # ── AGENTS.md: render from RIOTBOX_PROMPT override, or copy from template
    if [ -n "${RIOTBOX_PROMPT:-}" ] && [ -f "${RIOTBOX_PROMPT}" ]; then
        local os_pretty="Linux"
        if [ -f /etc/os-release ]; then
            # shellcheck disable=SC1091
            os_pretty="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-Linux}")"
        fi
        awk -v os="${os_pretty}" '{gsub(/\{\{OS_PRETTY_NAME\}\}/, os); print}' \
            "${RIOTBOX_PROMPT}" > "${agents_md}"
    elif [ ! -f "${agents_md}" ] && [ -f "${template}" ]; then
        cp "${template}" "${agents_md}"
    fi

    # ── opencode.jsonc: merge host JSON + JSONC, then force riotbox overrides
    local json_obj='{}'
    local jsonc_obj='{}'

    if [ -f "${opencode_json}" ]; then
        if ! json_obj="$(jq -c 'if type == "object" then . else error("root must be an object") end' "${opencode_json}" 2>/dev/null)" \
           || [ -z "${json_obj}" ]; then
            echo "  [opencode] WARN: ${opencode_json} is not a valid JSON object — ignoring." >&2
            json_obj='{}'
        fi
    fi

    if [ -f "${opencode_jsonc}" ]; then
        local stripped
        if stripped="$(_opencode_strip_jsonc "${opencode_jsonc}" 2>/dev/null)" \
           && jsonc_obj="$(printf '%s' "${stripped}" | jq -c 'if type == "object" then . else error("root must be an object") end' 2>/dev/null)" \
           && [ -n "${jsonc_obj}" ]; then
            :
        else
            echo "  [opencode] WARN: ${opencode_jsonc} is not a valid JSONC object — ignoring." >&2
            jsonc_obj='{}'
        fi
    fi

    # Merge (recursive, jsonc wins), then force riotbox-mandatory keys.
    # instructions handling: if not an array, replace with the single-element
    # default; if already an array, append AGENTS.md only when missing.
    local merged
    # The tilde in agents_path is a literal — opencode expands ~ itself when
    # reading the instructions array. shellcheck SC2088 wants us to use $HOME,
    # but that would defeat the purpose.
    # shellcheck disable=SC2088
    merged="$(jq -n \
        --argjson j "${json_obj}" \
        --argjson jc "${jsonc_obj}" \
        --arg agents_path '~/.config/opencode/AGENTS.md' \
        --arg schema 'https://opencode.ai/config.json' \
        '
        ($j * $jc)
        | .permission = "allow"
        | .share = "disabled"
        | .autoupdate = false
        | (if (.instructions | type) == "array"
           then (if (.instructions | index($agents_path)) == null
                 then .instructions += [$agents_path]
                 else .
                 end)
           else .instructions = [$agents_path]
           end)
        | (if has("$schema") then . else .["$schema"] = $schema end)
        ')"

    # Write banner + merged JSON to opencode.jsonc. The banner explains the
    # forced keys; the JSON body is generated by jq and is plain JSON (a
    # valid subset of JSONC), so no comments inside the body.
    {
        cat <<'BANNER'
// This file is generated by claude-riotbox at session start.
// It merges your host ~/.config/opencode/{opencode.json,opencode.jsonc}
// and then forces these keys for the disposable-container threat model:
//   permission   = "allow"     (the container is the riotbox; no host escape)
//   share        = "disabled"  (no session telemetry from the container)
//   autoupdate   = false       (the image pins opencode at build time)
//   instructions = [AGENTS.md] (riotbox autonomy prompt always loaded)
// Edit your host opencode.json/opencode.jsonc to change anything else.
BANNER
        printf '%s\n' "${merged}"
    } > "${opencode_jsonc}"

    # The legacy opencode.json is no longer the source of truth — remove it
    # so opencode loads only the merged jsonc.
    if [ -f "${opencode_json}" ]; then
        rm -f "${opencode_json}"
    fi
}
