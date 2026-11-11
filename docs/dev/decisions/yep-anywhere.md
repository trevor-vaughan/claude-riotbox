# Driving RiotBox sessions from a phone

**Decision:** Add `riotbox anywhere`, which runs [Yep Anywhere](https://github.com/kzahel/yepanywhere)
inside the session container as its main command and publishes its port on one
host address the user names. Claude runs through the RiotBox wrapper. Pin Yep
Anywhere with a committed lockfile, refuse egress mode until a sidecar exists,
and fork or contribute upstream for the gaps below.

**Date:** 2026-11-08 · **Branch:** `riotbox-anywhere` (from `claude/riotbox-phone-local-network-4ccfjs`)

> **Frozen record.** For the current implementation, read
> [THREAT_MODEL § Yep Anywhere web UI](../../../THREAT_MODEL.md#yep-anywhere-web-ui-riotbox-anywhere-opt-in),
> `libexec/anywhere-lib.sh`, `container/anywhere.sh` and the Yep Anywhere
> block in the `Containerfile`.

**Verified against:** yepanywhere 0.11.0 from npm, run on the host (Node 22)
with a stub `claude`; then, on 2026-11-08, installed the way the image layer
does and run by `container/anywhere.sh` inside a RiotBox container (Node 25,
the real wrapper and Claude Code 2.1.319), driven from headless Chromium at
phone size (see *Trial run* below). **Not yet verified in a freshly built image
or on a real phone.**

## Requirements

1. Use it from a phone browser over the local network.
2. Both Claude Code and opencode.
3. It must drive the real `claude` CLI, so the RiotBox wrapper, its flags, the
   pinned Claude Code version, the managed system prompt and the hooks all
   apply. An SDK that runs its own bundled Claude does not meet this.
4. Better use of a small screen than a terminal: formatting and real estate
   were the main complaint about SSH + tmux and web terminals.

## Options considered

| Option | Why not, or why |
|---|---|
| SSH + tmux, mosh, ttyd and other web terminals | Meet 1–3, fail 4: a TUI on a phone is the problem being solved. |
| Claude Code Remote Control | Best UI, but not local (it relays through Anthropic), Claude only, and it needs the non-essential-traffic and telemetry variables RiotBox sets left unset. |
| opencode web UI | opencode only. |
| CloudCLI / claudecodeui | No opencode in the self-hosted version; AGPL. |
| Coder AgentAPI | Deprecated upstream. |
| Vibe Kanban | Shutting down upstream. |
| AionUi | Both agents, but a desktop (Electron) app first; running it headless in a container was not confirmed. |
| ACP clients (acp-ui + a stdio bridge) | Claude only through an SDK-based adapter (fails 3); the bridge's security is undocumented. |
| Happier | Both agents, but phone traffic goes through a relay, and how it launches Claude was not settled from its source. |
| **Yep Anywhere** | Phone-first chat UI (meets 4), both agents (opencode is experimental upstream), MIT, direct LAN mode with a password, optional relay. Claude runs through the Agent SDK, **but** it reads `CLAUDE_CODE_EXECUTABLE` first and then never falls back, so it can run the RiotBox wrapper (meets 3). |

## What was checked

- `dist/sdk/providers/claude.js` resolves the executable from
  `CLAUDE_CODE_EXECUTABLE ?? CLAUDE_CODE_PATH`, falling back to the SDK's
  bundled native binary and then PATH only when neither is set.
- With `CLAUDE_CODE_EXECUTABLE` pointing at a stub, a session created through
  the API started the stub with `--output-format stream-json --verbose
  --input-format stream-json --permission-prompt-tool=stdio
  --setting-sources=user,project,local --permission-mode=default
  --include-partial-messages`. The real wrapper adds
  `--dangerously-skip-permissions` to that line.
- `--setup-auth <password>` stores a bcrypt hash and exits; afterwards the API
  answers `Authentication required` until login. `--https-self-signed` serves
  HTTPS and nothing on plain HTTP.
- Its `/api` routes refuse a Host header other than localhost, private IPv4
  or `*.ts.net` (403), so a Tailscale `100.x`, IPv6 or public bind failed every
  call. The launch passes the bind address as `ALLOWED_HOSTS`; with it a
  `100.64.1.2` Host logged in and created a session.
- At its default level it logs every request to the console, which scrolled
  the launch banner (and the once-shown password) away in seconds.
  `dist/server-main.js` reads `LOG_LEVEL` (console), `LOG_FILE_LEVEL` and
  `LOG_TO_FILE`; the file, `logs/server.log` under the data dir, is only ever
  appended to. The launch sets the console to `warn`, the file to `info`, and
  empties the file at each launch. Concurrent sessions of one project set
  share the data dir, so the later launch empties the earlier one's log and
  both append to it from then on; accepted over per-launch files, which would
  pile up unrotated.
- The install is ~440 MB, ~260 MB of it the SDK's native Claude binaries,
  which the layer deletes (~180 MB left). The one install script in the graph
  (bcrypt's `node-gyp-build`) is unnecessary: bcrypt ships linux-x64 and
  linux-arm64 prebuilds.
- Outbound hosts in the code: `updates.yepanywhere.com`, `push.yepanywhere.com`,
  `api.github.com`, the optional relay, and model/speech providers that only
  apply when configured. Nothing was contacted at start.

## Open items

These are where we expect to fork or send fixes upstream.

1. **opencode skips the RiotBox wrapper.** `findOpenCodePath()` checks
   `~/.opencode/bin`, `~/.local/bin`, `/usr/local/bin` and `~/bin` before
   PATH, and the image keeps the real binary at `~/.local/bin/opencode`; the
   provider is constructed with no `opencodePath`. **Upstream fix:** honour an
   `OPENCODE_EXECUTABLE` (or similar) environment variable, as Claude already
   does. Until then, opencode sessions lose headroom wrapping. opencode's own
   config (permission policy, plugins, RiotBox prompt) still applies.
2. **Permission mode.** *Settled by the trial run: the wrapper's
   `--dangerously-skip-permissions` wins and no approval prompt appears.*
   Yep Anywhere passes `--permission-mode=default` and
   `--permission-prompt-tool=stdio`, and the wrapper adds
   `--dangerously-skip-permissions`. Which one Claude Code honours, and whether
   Yep Anywhere's approval UI then appears, needs a real image. Either outcome
   is safe; only the first matches RiotBox's autonomy model. If prompts
   appear, set bypass in Yep Anywhere's session settings, or ask upstream for a
   server-wide default mode.
3. **Egress mode.** Refused for now. The agent's network is `--internal`, so a
   port published from it does not reach the host. Plan: a sidecar on
   `<name>-int` plus a publishing bridge network that forwards one port to the
   agent and nothing else, in the shape of the egress proxy.
4. **Certificate trust.** The certificate's names come from `--host` (here
   `0.0.0.0`, which it skips) and the container's own interfaces, so it never
   names the host LAN address the phone uses: the phone sees a name mismatch
   on top of the unknown issuer. A RiotBox CA would have to issue for
   `RIOTBOX_ANYWHERE_HOST`. The self-signed certificate is trust-on-first-use,
   and phone browsers may restrict PWA install and push notifications for it.
   A RiotBox CA the phone installs once would fix both.
5. **Image and phone tests.** Build the image, confirm the layer's smoke
   passes, then use it from a phone with both agents.

## Follow-up: switching between sessions

**Decision:** `riotbox hub`, one page on one host address that lists the
running `riotbox anywhere` sessions, plus one hub port per session that
reverse-proxies it, so the sessions stay on loopback and the phone needs one
firewall range (3399-3419 by default). For a session published on port N the
hub listens on `<hub address>:N`. Several sessions share
`RIOTBOX_ANYWHERE_BIND` by taking the next free port.

- **One Yep Anywhere per session, not one for all.** Each project set has its
  own `~/.claude` and its own container; a single server would need every
  session's files and would undo the isolation the user runs them in for.
- **Discovery from the engine.** The launch labels the container
  `riotbox.anywhere.url`; the hub lists containers with that label and reads
  their projects from the host-only state dir named by `riotbox.session`.
  Nothing new is written, and a session that dies drops off the page.
- **In `riotbox-core`, standard library only.** It has to run on the host, and
  the Go binary is already pinned, built and released with checksums and a
  signature; a Node or Python server would be a new runtime dependency.
- **Attaching to a session that is already running was rejected.** A
  container's published ports are fixed at start and rootless podman gives the
  host no other route in, so it would need every launch to reserve a port in
  advance. Even then Yep Anywhere could only watch a terminal Claude's
  conversation (it marks such sessions "external"), not take it over.

- **Why a port per session.** The agent has passwordless sudo in the container
  that serves Yep Anywhere, so a prompt-injected agent controls the JavaScript
  its session sends. A port is an origin: per-port origins keep scripts,
  storage and service workers of different sessions apart, as the sessions'
  own ports did.
- **Rejected: one origin with a session cookie** (the first design: one hub
  port, `/_riotbox/open/<container>` selects a session). On a shared origin a
  session's script could switch the browser to another session and drive it
  with that session's login, or register a service worker over all of them.
  Dropped after review.
- **Rejected: Envoy in front.** Same routing problem, plus a sidecar whose
  config must be regenerated as sessions come and go; the hub already
  discovers sessions and terminates TLS.
- **Rejected: path-prefix routing.** Yep Anywhere's client loads `/assets/...`
  and `/api/...` from the root, and it would share one origin.
- **Rejected: host-name routing.** Needs a DNS name per session on the phone's
  network, a certificate per name, and relaxing the hub's IP-literal Host
  check, its DNS-rebinding defence.
- **Session ports are not muxed.** Each is its own `http.Server` with a
  handler that proxies every path; `ServeMux` path cleaning (redirecting
  `/a/../b`) does not apply, so paths reach the session as sent. Checks on
  them: Host and token in `guard` (`internal/hub/server.go`), `Origin` and
  `Sec-Fetch-Site` in `internal/hub/proxy.go`.
- **Pinned upstream certificate.** The session's certificate sits in a
  container-writable state dir, so the proxy opens it with `os.OpenRoot` and
  `root.OpenFile` (`O_NONBLOCK`),
  non-blocking, regular file only, 64 KiB, and dials only a byte-equal leaf.
  See THREAT_MODEL.md.

## Follow-up: the hub signs you in

**Decision:** opening a session from the hub page logs the browser in; the
per-session password stays, and the hub types it. The host launcher
(`anywhere_password`, `libexec/anywhere-lib.sh`, called from
`scripts/mount-projects.sh`) makes the password and keeps it in
`<state dir>/anywhere-password` (0600), beside the state subdirectories and
not in one, because only those are mounted. It reaches the container as
`RIOTBOX_ANYWHERE_PASSWORD`, passed by name so it is not on the engine's argv;
`container/anywhere.sh` applies it with `--setup-auth` only when new (or `auth.json` is missing) and
prints it only when new. The hub (`signIn`, `internal/hub/proxy.go`) reads the
file and logs in for top-level navigations only, over the pinned transport.
A project set from before this change gets a new password on its next launch.

- **Consequence.** The hub token is the one key to sessions reached through
  the hub. Revoke it by deleting `~/.local/share/riotbox-hub/token` and
  restarting the hub. The password still guards each loopback port against
  the rest of the host.
- **The agent can read the password** in its container. It already controls
  its own Yep Anywhere, so this grants nothing.
- **Rejected: showing the password on the list.** The same exposure as
  signing in, with more taps.
- **Rejected: `--auth-disable`.** Every session's loopback port would hand
  agent control to anything on the host.
- **Rejected: Yep Anywhere's desktop token.** `/api/auth/status` ignores
  `X-Desktop-Token`, so the UI still shows its login page.
- **Failure falls back.** If sign-in fails, the navigation is proxied
  unchanged and Yep Anywhere's login page appears; the cause is logged.

## Trial run (2026-11-08)

`podman build` does not work in the development container, so the layer's
install (lockfile `npm ci --ignore-scripts`, SDK binaries deleted, shim) was
run by hand in a RiotBox container and started by `container/anywhere.sh`.

- **Found:** the server died at start, because `--https-self-signed` runs the
  `openssl` CLI and the image installed only `openssl-devel`. Fixed in the
  `Containerfile`, with a check in the layer.
- Over HTTPS the login page served and plain HTTP got no answer; the API
  answered 401 until login. A session created through the API ran the real
  Claude Code through the wrapper (its argv: `--dangerously-skip-permissions`
  before Yep Anywhere's `--permission-mode=default`) and wrote a file in the
  project with no approval prompt.
- Its project list is every project under the session's `~/.claude/projects`,
  which in a RiotBox session is that project set's own history.
- `riotbox hub` against podman listed a container launched with
  `anywhere_gate`'s flags (the port picker moved it to 3401, since 3400 was
  taken), with its recorded project, and left out a container labelled with
  another host's URL and one labelled with no published port. No token got
  401 and a foreign Host header got 421.
