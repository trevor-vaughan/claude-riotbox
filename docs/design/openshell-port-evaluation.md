# OpenShell Port Evaluation — What Would Make It Viable

**Status:** Port abandoned in RiotBox 0.5.x — see [Why we abandoned](#why-we-abandoned). This document records what an "OpenShell-as-engine" port of RiotBox would require, so a future re-evaluation starts from concrete requirements rather than fresh assumptions.

**Evaluation date:** 2026-05-07
**Evaluated against:** [NVIDIA/OpenShell](https://github.com/NVIDIA/OpenShell) v0.0.36, base image `ghcr.io/nvidia/openshell-community/sandboxes/base@sha256:11c73b5a...c67c68` (revision `8f7d0da`, 2026-04-03).

## TL;DR

RiotBox needs a "split local/container workflow": the host edits files in real time, the sandboxed agent operates against the same files, and changes are mutually visible immediately so the user can run tests, observe IDE updates, and intervene without ceremony. OpenShell 0.0.36 cannot serve this pattern because (a) its CLI exposes no host bind mount or environment injection surface, and (b) its runtime is k3s + containerd inside a privileged container, so sandboxes are Kubernetes pods rather than host-resolvable containers — there is no host-side mechanism for adding bind mounts post-create.

For a port to become viable, OpenShell needs either:

1. CLI-level bind mounts (`--mount` / `-v`) plus environment injection (`--env`), exposing host filesystem state to sandboxes in a live, bidirectional way; or
2. A documented and stable CRD-level integration path so that RiotBox can become a `Sandbox`-resource consumer rather than a CLI wrapper.

Neither exists today. The gap is structural, not incidental.

## What "split local/container workflow" means

RiotBox exists because the user wants this exact interaction loop:

1. The user opens their project in their IDE on the host. Files are real host files.
2. They ask the agent (Claude / opencode / etc.) to do something — fix a bug, add a feature, run a refactor.
3. The agent runs in a sandboxed container that mirrors the host's toolchain (nvm/uv/Go/Rust/Ruby — all matched at RiotBox image build time).
4. As the agent edits files, **those edits land directly on the host filesystem in real time**. The IDE picks them up, file watchers (jest, webpack, cargo-watch) see them, `git status` shows them.
5. The user can, at any moment, run a test or build on the host against the live state without waiting for the sandbox to finish.
6. The agent's container is isolated from host secrets and credentials by default but has writeback access to its own credential file (so OAuth refresh flows work).

Every one of those points except #2 and #6 depends on **shared filesystem state between host and container with low latency and standard semantics**. Anything with a sync window — even a fast one — breaks #4 and #5.

## What OpenShell provides today (0.0.36)

Verified in [research artifacts](#research-artifacts).

- `openshell sandbox create --from <image-or-Dockerfile> --name <n> --policy <yaml>`
- `--upload <local-path>[:<sandbox-path>]` — **one-shot copy** of host files into the sandbox at create time. No live binding. No writeback. No refresh.
- `--forward [bind:]port` — host-port-to-sandbox port forward.
- `--provider <name>` — attach a credential bundle (managed via `openshell provider create --type … --from-existing`). Bundles are injected as environment values at runtime; the sandbox filesystem never gets the credential file.
- `--policy <yaml>` — Landlock-based filesystem allow/deny lists, network egress rules, process restrictions, inference routing rules. Enforced inside the sandbox.
- `Privacy router` — routes inference traffic through a controlled backend (default behavior not characterized in this evaluation; see Spike #8 in research artifacts).
- Backend: `openshell gateway start` brings up a privileged container running k3s + flannel + containerd + Helm. Sandboxes are scheduled as Kubernetes pods inside that container, managed by `agent-sandbox-controller` via a `Sandbox` CRD.

What is missing for the RiotBox use case:

- **No host bind mount surface.** No `--mount`, `-v`, `--volume`, `--bind`, or any equivalent. `--upload` is the only host→sandbox file path and it is one-shot.
- **No environment variable injection from the CLI.** The protobuf at `proto/openshell.proto` has `SandboxSpec.environment` and `SandboxTemplate.environment` map fields, but `crates/openshell-cli/src/run.rs` builds `CreateSandboxRequest` with `SandboxSpec::default()` — the CLI never populates env. RiotBox passes ~15 env vars per sandbox today (`ANTHROPIC_API_KEY`, `CLAUDE_CODE_USE_VERTEX`, `GOOGLE_APPLICATION_CREDENTIALS`, `AWS_PROFILE`, etc.). None of those reach the sandbox.
- **No host-resolvable sandbox container.** Because OpenShell's runtime is k3s, the host's container engine never sees a "sandbox container" it could `exec` into to retrofit a bind mount. The host sees one container — the cluster — which contains the entire k8s control plane and all sandbox pods. Three namespaces of separation between the host and the sandbox process.
- **No bidirectional file sync mechanism.** A `--forward`-tunneled rclone/SFTP/9p arrangement is technically feasible (run a server on host, mount inside sandbox) but introduces a cache and sync-flush window that breaks the "run tests on host instantly" requirement. Confirmed against the user's stated constraint.
- **No documented CRD integration path for external consumers.** The `Sandbox` CRD exists and is loaded by `agent-sandbox-controller:v0.1.0`, but the schema, stability guarantees, and supported integration patterns aren't documented in the repo's user-facing material. Building against it today would mean reverse-engineering and binding to internals.

## Why we abandoned

The two findings together — CLI surface lacks the primitives we need, and the runtime architecture forecloses the obvious workaround — make adoption a fork-or-rewrite job:

- **Adopt as-is** would force the workflow to either (a) lose live host↔sandbox sync (using `--upload` and an exit-time sync-back), or (b) tunnel a network filesystem through `--forward` (rclone/SSHFS/9p), trading native FS performance and semantics for portability we don't currently need. Both regress the RiotBox UX in ways the user explicitly rejected.
- **Adopt and patch** would require coordinated changes across the CLI (env injection, mount flag), the protobuf schema (host-mount field on `SandboxSpec`), the gRPC plumbing, the agent-sandbox controller (translate the new field into pod hostPath mounts), and the policy engine (the Landlock layer would need to allow the new mounts). That is a multi-component upstream contribution against an alpha project, with our work blocked behind it.
- **Adopt at the CRD level** is the architecturally correct path if the goal is "RiotBox uses OpenShell." RiotBox would write `Sandbox` CRDs against the cluster, with hostPath / PVC mounts in the pod template. But the CRD's schema isn't documented for external use, the stability guarantees are unclear, and RiotBox's control loop becomes a Kubernetes operator. That is a much bigger project than the original "wrap the CLI" port — well beyond the scope under consideration.

The spec and plan written for this port are preserved on disk under `docs/superpowers/specs/2026-05-07-openshell-port-design.md` and `docs/superpowers/plans/2026-05-07-openshell-port.md` (gitignored — local working notes). They remain useful as a record of the intended design.

## What would make a port viable

Three independent paths, in increasing order of upstream investment.

### Path 1 — CLI surface additions (smallest delta)

OpenShell adds, at the CLI level:

- `--mount <host>:<sandbox>[:ro]` (and/or `-v`, matching the `docker run` convention). Live bidirectional bind mount, host filesystem visible inside the sandbox in real time. Read-only flag for plugin / config injection.
- `--env <KEY=VAL>` and/or `--env-file <path>`. Wires through `SandboxSpec.environment` (the proto field already exists; CLI plumbing is missing).
- Optional but high-value: `--mount-secret <host>:<sandbox>` — a bind mount that is excluded from filesystem-policy-enforced read/write tracking, intended for credential-style files where the user has accepted that the file itself is privileged.

This is the smallest set of CLI features that would let RiotBox layer on top of OpenShell without architectural compromise. The proto additions for `--mount` are non-trivial (need to land in `SandboxSpec` / `SandboxTemplate`, propagate through the controller into pod hostPath mounts, and have the policy engine reason about them); `--env` is comparatively trivial (proto field exists, just needs CLI wiring).

If Path 1 lands, the existing RiotBox-on-OpenShell spec at `docs/superpowers/specs/2026-05-07-openshell-port-design.md` becomes broadly applicable again with minor adjustments — the rest of Phase 0 (Spikes 3–8) would need re-running but the high-level architecture stands.

### Path 2 — Stable CRD-level integration

OpenShell publishes:

- A documented, versioned `Sandbox` CRD schema with explicit support for external consumers (RiotBox is one such consumer; others would be CI systems, internal developer platforms, etc.).
- A supported way to install just the controller + CRD without the CLI/gateway (so consumers can integrate with their own k8s cluster rather than spinning up the bundled k3s).
- Stability guarantees for the CRD shape (semver, deprecation policy).

RiotBox in this world becomes a Kubernetes operator: the user's command (`riotbox run …`) translates into creating a `Sandbox` resource with hostPath mounts in the pod template, then waiting on its status. Considerably more infrastructure to manage but the cleanest separation of concerns long-term.

The reach of this path is wider than the RiotBox use case — it would unlock a lot of "use OpenShell as a sandbox primitive" use cases beyond ours.

### Path 3 — Direct-runtime mode

OpenShell adds an optional non-k8s backend — direct podman or direct Docker — for users who don't want the cluster overhead. The CLI gains a `--backend=podman|k3s` flag (or it's an install-time choice). Sandboxes in `podman` mode are first-class host podman containers, accessible via the host's container engine.

This is the most invasive change for OpenShell (a parallel runtime path through the codebase) but it would also serve a lot of users who want OpenShell's policy/router story without paying for k8s in environments where it's overkill.

If Path 3 lands, RiotBox can use OpenShell as a host-side sandbox runner with all the same workflows we have today (post-create bind via host podman becomes feasible because the sandbox is now a real host podman container).

## Re-evaluation criteria

Concrete signals from upstream that warrant a re-look at this port:

- **CLI bind mounts:** any release where `openshell sandbox create --help` lists `--mount`, `-v`, or `--volume`. Almost-immediate trigger to re-run Phase 0.
- **Env injection:** `--env` in `sandbox create --help`, or `SandboxSpec.environment` populated from CLI args (visible in `crates/openshell-cli/src/run.rs`). Smaller signal but reduces the implementation gap.
- **CRD documentation:** an upstream `docs/crd-reference.md`, `docs/integration.md`, or equivalent that describes the `Sandbox` CRD shape with stability guarantees. Triggers a Path 2 evaluation.
- **Non-k8s backend:** any release notes mentioning a `direct podman` / `direct docker` mode, or a `--backend` CLI flag. Triggers a Path 3 evaluation.
- **OpenShell exits alpha.** Today's [README](https://github.com/NVIDIA/OpenShell) says "Alpha software — single-player mode" with explicit "expect breaking changes." A move to beta with stability commitments is itself a signal.

A passive monitoring approach (one or two checks per quarter) is sufficient — there is no rush.

## Upstream issues we should file

If we want to push the project toward Path 1 (the most likely-to-succeed near-term path), two concrete issues:

### Issue 1: Wire `SandboxSpec.environment` from CLI to gRPC

> **Title:** Expose `SandboxSpec.environment` via `openshell sandbox create --env` (and/or `--env-file`)
>
> **Background:** `proto/openshell.proto` defines `SandboxSpec.environment` as `map<string, string>`. The gRPC server, controller, and pod-spec rendering paths all handle it correctly when populated. However, `crates/openshell-cli/src/run.rs` constructs `CreateSandboxRequest` with `SandboxSpec::default()` and never sets `environment`, so the field is unreachable from the CLI.
>
> **Use case:** Tooling that wraps `openshell` to manage agent sandboxes (Claude Code, opencode, etc.) needs to pass per-session env vars: `ANTHROPIC_API_KEY`, `CLAUDE_CODE_USE_VERTEX`, cloud SDK config locations, etc. Today these can only be baked into the BYOC image, which doesn't work for per-session values.
>
> **Proposed change:** Add `--env <KEY=VAL>` (repeatable) and `--env-file <path>` flags to `openshell sandbox create`. Populate `SandboxSpec.environment` from the merged map.

### Issue 2: Add host bind mount support

> **Title:** Add host bind mount support to `openshell sandbox create` (`--mount` / `-v`)
>
> **Background:** `--upload` is one-shot, `--provider` injects credentials but not arbitrary files, and there is no live host filesystem path into a sandbox. This rules out workflows where the host and sandbox share state continuously — common for IDE-driven development (host edits in real time, sandboxed agent operates against the same files, host runs tests against live state).
>
> **Proposed change:** Add `--mount <host>:<sandbox>[:ro]` (and `-v` alias). Plumb through `SandboxSpec` / `SandboxTemplate` (new `mounts` field), through the gRPC layer, through `agent-sandbox-controller` into pod-spec `volumes` / `volumeMounts` using `hostPath`. The Landlock policy layer needs to learn about the new mount points (probably by treating them as additional read/write roots that the policy YAML can reference).
>
> Read-only support is essential for plugin / config injection scenarios where the host file should not be mutated by the sandbox.

Both issues should reference this evaluation document for context.

## Research artifacts

The following local-only documents (under `docs/superpowers/research/`, gitignored per project convention for `docs/superpowers/`) hold the raw findings:

- `2026-05-07-openshell-spike-1-base-image.md` — base image is `ghcr.io/nvidia/openshell-community/sandboxes/base@sha256:11c73b5a...c67c68`, Ubuntu 24.04, USER `sandbox`, WORKDIR `/sandbox`, all four agents pre-installed, image size ~3.34 GB.
- `2026-05-07-openshell-spike-2-byoc-surface.md` — full `--help` capture for `sandbox create`, proof of `--mount`/`--env` absence, citations to proto + CLI source where the CLI hardcodes empty env.
- `2026-05-07-openshell-spike-6-version-pin.md` — CLI version pin chosen (v0.0.36), full release listing, install command.
- `2026-05-07-openshell-spike-7-postcreate-bind.md` — direct inspection of the `cluster:0.0.36` image, evidence that the runtime is k3s+containerd, and the architectural argument that B1 (post-create bind via host podman) does not work even on a real host.

If a future contributor wants to re-run the evaluation, the relevant `tmp/spike-*/` directories from the original work are gitignored; recreate them by following the steps in the research artifacts.

## Decision

For RiotBox 0.5.x: stay on direct podman. The OpenShell port is not viable today and the architectural premise needs upstream movement before it becomes so. File the two issues above when convenient. Set a quarterly reminder to skim OpenShell's release notes for the re-evaluation signals.
