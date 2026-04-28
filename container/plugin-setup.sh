#!/usr/bin/env bash
# plugin-setup.sh — Plugin lifecycle management inside the container.
#
# Sourced by entrypoint.sh. Provides:
#   plugin_setup — configure settings.json, copy staged and host plugins,
#                  install marketplace plugins, wire statusline, sync enabled
#
# Plugin precedence (lowest → highest):
#   1. Pre-staged defaults (baked into the image at build time)
#   2. Marketplace plugins from plugins.conf or RIOTBOX_PLUGINS env var
#   3. Host plugins copied from ~/.host-plugins (bind-mounted read-only)

plugin_setup() {
    local STAGING_DIR="${HOME}/.riotbox/plugins-staging/.claude"
    local HOST_PLUGINS_DIR="${HOME}/.host-plugins"
    local PLUGINS_CONF="${HOME}/.config/claude-riotbox/plugins.conf"

    # ── 1. Seed settings.json ──────────────────────────────────────────────
    # Create on first run, or strip legacy enabledPlugins from prior versions.
    # Host settings.json is intentionally NOT synced — it contains hooks,
    # permission rules, and paths that reference the host filesystem and
    # would break or cause unexpected behavior inside the container.
    if [ ! -f ~/.claude/settings.json ]; then
        jq -n '{
            promptSuggestionEnabled: false,
            skipDangerousModePermissionPrompt: true,
            autoCompact: true
        }' > ~/.claude/settings.json
    elif jq -e '.enabledPlugins' ~/.claude/settings.json &>/dev/null; then
        jq 'del(.enabledPlugins)' ~/.claude/settings.json > ~/.claude/settings.json.tmp \
            && mv ~/.claude/settings.json.tmp ~/.claude/settings.json
    fi

    # ── 2. Copy pre-staged plugins (first run only) ────────────────────────
    # Pre-installed at build time into ~/.riotbox/plugins-staging/ to avoid
    # network access and Node.js spawns at startup. Guard with a stamp file
    # so this runs exactly once per session, not on every startup.
    if [ ! -f ~/.claude/plugins/.staged ] && [ -d "${STAGING_DIR}/plugins" ]; then
        echo "  [plugins] Copying pre-staged plugins..."
        # `cp -a` is `-dR --preserve=all`, which includes context+xattr.
        # When the destination lands on fuse-overlayfs (overlay mode), the
        # fsetxattr syscall used to copy the SELinux label is denied by the
        # kernel ("AVC: denied { relabelto } … tcontext=…fusefs_t"). Drop
        # those two attributes; mode/timestamps/links are still preserved.
        cp -a --no-preserve=context,xattr "${STAGING_DIR}/plugins/"* ~/.claude/plugins/
        # Fix paths — staging used a different HOME.
        # This substitution is safe for sed because STAGING_DIR is a known
        # build-time constant (no user content), unlike host plugin paths.
        sed -i "s|${STAGING_DIR}|${HOME}/.claude|g" \
            ~/.claude/plugins/installed_plugins.json \
            ~/.claude/plugins/known_marketplaces.json 2>/dev/null || true
        # Merge marketplace registration into settings.json
        if [ -f "${STAGING_DIR}/settings.json" ]; then
            local marketplaces
            marketplaces="$(jq '.extraKnownMarketplaces // {}' "${STAGING_DIR}/settings.json")"
            jq --argjson m "${marketplaces}" \
                '.extraKnownMarketplaces = ($m + (.extraKnownMarketplaces // {}))' \
                ~/.claude/settings.json > ~/.claude/settings.json.tmp \
                && mv ~/.claude/settings.json.tmp ~/.claude/settings.json
        fi
        touch ~/.claude/plugins/.staged
    fi

    # ── 3. Install marketplace plugins from config or env ─────────────────
    # RIOTBOX_PLUGINS (comma-separated) replaces plugins.conf entirely.
    # Plugins already present in installed_plugins.json are skipped to avoid
    # spawning Node.js processes on every startup.
    local plugin_list=""

    if [ -n "${RIOTBOX_PLUGINS:-}" ]; then
        plugin_list="${RIOTBOX_PLUGINS}"
        echo "  [plugins] Using RIOTBOX_PLUGINS env var."
    elif [ -f "${PLUGINS_CONF}" ]; then
        while IFS= read -r line || [ -n "${line}" ]; do
            line="${line%%#*}"
            line="$(echo "${line}" | xargs)"
            [ -z "${line}" ] && continue
            if [ -z "${plugin_list}" ]; then
                plugin_list="${line}"
            else
                plugin_list="${plugin_list},${line}"
            fi
        done < "${PLUGINS_CONF}"
    fi

    if [ -n "${plugin_list}" ]; then
        echo "${plugin_list}" | tr ',' '\n' | while IFS= read -r plugin; do
            plugin="$(echo "${plugin}" | xargs)"
            [ -z "${plugin}" ] && continue
            # Validate plugin name to prevent argument injection
            if [[ ! "${plugin}" =~ ^[a-zA-Z0-9/_-]+$ ]]; then
                echo "  [plugins] WARNING: Ignoring invalid plugin name: ${plugin}" >&2
                continue
            fi
            # v2 format uses qualified keys ("plugin@marketplace"), so match
            # both exact name and any key starting with "name@".
            if jq -e --arg p "${plugin}" \
                '.plugins | has($p) or ([keys[] | select(startswith($p + "@"))] | length > 0)' \
                ~/.claude/plugins/installed_plugins.json &>/dev/null; then
                echo "  [plugins] ${plugin}: already installed."
            else
                echo "  [plugins] Installing ${plugin}..."
                claude plugin install "${plugin}" || \
                    echo "  [plugins] WARNING: Failed to install ${plugin}." >&2
            fi
        done
    fi

    # ── 4. Copy host plugins (highest precedence, overwrites others) ───────
    # ~/.host-plugins is bind-mounted read-only from the host's ~/.claude/plugins.
    if [ -d "${HOST_PLUGINS_DIR}" ]; then
        echo "  [plugins] Copying host plugins..."
        # Copy cache directories (plugin source trees), skipping temp_git_*
        # leftovers from interrupted `claude plugin install` on the host.
        # Safety: dereference symlinks to prevent symlinks targeting sensitive
        # container paths; strip setuid/setgid bits afterwards.
        #
        # `cp -rL` would abort on the first dangling symlink (e.g. left by a
        # host-side install/uninstall race or a partial git fetch). Instead,
        # pre-filter with `find -L … ! -type l` — under `-L`, valid symlinks
        # report their target's type, so only broken symlinks retain `-type l`
        # — then stream paths through `tar -h` to dereference and copy.
        if [ -d "${HOST_PLUGINS_DIR}/cache" ]; then
            for entry in "${HOST_PLUGINS_DIR}/cache/"*; do
                [ -e "${entry}" ] || continue
                local entry_name
                entry_name="$(basename "${entry}")"
                [[ "${entry_name}" == temp_git_* ]] && continue
                ( cd "${HOST_PLUGINS_DIR}/cache" \
                    && find -L "${entry_name}" ! -type l -print0 \
                    | tar -ch --null --no-recursion --files-from=- -f - \
                ) | tar -xf - -C ~/.claude/plugins/cache/ --no-same-owner
            done
            find ~/.claude/plugins/cache/ -perm /6000 -exec chmod ug-s {} + 2>/dev/null || true
        fi
        # Merge installed_plugins.json: host entries overwrite existing entries.
        # The host's JSON contains paths from the host filesystem (e.g.
        # /home/alice/.claude/plugins/cache/...). We rewrite any path ending
        # in /.claude/plugins to the container's path using a regex.
        if [ -f "${HOST_PLUGINS_DIR}/installed_plugins.json" ]; then
            if [ -f ~/.claude/plugins/installed_plugins.json ]; then
                # Preserve version field (v2+) and merge plugin entries.
                jq -s '
                    (([.[].version // null] | map(select(. != null)) | max) as $v |
                     if $v then {version: $v} else {} end)
                    + {plugins: ((.[0].plugins // {}) * (.[1].plugins // {}))}
                ' \
                    ~/.claude/plugins/installed_plugins.json \
                    "${HOST_PLUGINS_DIR}/installed_plugins.json" \
                    > ~/.claude/plugins/installed_plugins.json.tmp \
                    && mv ~/.claude/plugins/installed_plugins.json.tmp \
                          ~/.claude/plugins/installed_plugins.json
            else
                cp "${HOST_PLUGINS_DIR}/installed_plugins.json" \
                   ~/.claude/plugins/installed_plugins.json
            fi
            # Rewrite host plugin paths to the container's plugin directory.
            # Uses jq (JSON-aware) instead of sed to avoid corrupting values
            # that happen to contain /.claude/plugins as a substring.
            jq --arg prefix "${HOME}/.claude/plugins" '
                walk(if type == "string" and test("/.claude/plugins/")
                     then sub(".*/.claude/plugins/"; $prefix + "/")
                     else . end)
            ' ~/.claude/plugins/installed_plugins.json \
                > ~/.claude/plugins/installed_plugins.json.tmp \
                && mv ~/.claude/plugins/installed_plugins.json.tmp \
                      ~/.claude/plugins/installed_plugins.json
        fi
        # Merge known_marketplaces.json if present
        if [ -f "${HOST_PLUGINS_DIR}/known_marketplaces.json" ]; then
            if [ -f ~/.claude/plugins/known_marketplaces.json ]; then
                jq -s '(.[0] // {}) * (.[1] // {})' \
                    ~/.claude/plugins/known_marketplaces.json \
                    "${HOST_PLUGINS_DIR}/known_marketplaces.json" \
                    > ~/.claude/plugins/known_marketplaces.json.tmp \
                    && mv ~/.claude/plugins/known_marketplaces.json.tmp \
                          ~/.claude/plugins/known_marketplaces.json
            else
                cp "${HOST_PLUGINS_DIR}/known_marketplaces.json" \
                   ~/.claude/plugins/known_marketplaces.json
            fi
            jq --arg prefix "${HOME}/.claude/plugins" '
                walk(if type == "string" and test("/.claude/plugins/")
                     then sub(".*/.claude/plugins/"; $prefix + "/")
                     else . end)
            ' ~/.claude/plugins/known_marketplaces.json \
                > ~/.claude/plugins/known_marketplaces.json.tmp \
                && mv ~/.claude/plugins/known_marketplaces.json.tmp \
                      ~/.claude/plugins/known_marketplaces.json
        fi
    else
        echo "  [plugins] Notice: No host plugins found (~/.claude/plugins not mounted)."
    fi

    # ── 5. Wire statusline ─────────────────────────────────────────────────
    # Claude Code reads settings.json key "statusLine" as an object:
    #   { "type": "command", "command": "<path>" }
    if [ -f ~/.claude/statusline-command.sh ]; then
        jq '.statusLine = {"type": "command", "command": "/home/claude/.claude/statusline-command.sh"}' \
            ~/.claude/settings.json > ~/.claude/settings.json.tmp \
            && mv ~/.claude/settings.json.tmp ~/.claude/settings.json
    else
        jq 'del(.statusLine)' \
            ~/.claude/settings.json > ~/.claude/settings.json.tmp \
            && mv ~/.claude/settings.json.tmp ~/.claude/settings.json
    fi

    # ── 6. Sync enabledPlugins from installed_plugins.json ─────────────────
    # Done via jq (pure JSON) instead of `claude plugin enable` to avoid
    # spawning a Node.js process per plugin on every startup.
    if [ -f ~/.claude/plugins/installed_plugins.json ]; then
        local new_enabled
        new_enabled="$(jq '.plugins | keys | map({(.): true}) | add // {}' \
            ~/.claude/plugins/installed_plugins.json)"
        jq --argjson p "${new_enabled}" \
            '.enabledPlugins = ($p + (.enabledPlugins // {}))' \
            ~/.claude/settings.json > ~/.claude/settings.json.tmp \
            && mv ~/.claude/settings.json.tmp ~/.claude/settings.json
    fi
}
