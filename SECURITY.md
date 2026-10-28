# Security policy

## Reporting a vulnerability

Report vulnerabilities privately through GitHub's
[private vulnerability reporting](https://github.com/trevor-vaughan/claude-riotbox/security/advisories/new).
Do not open a public issue, pull request or discussion for a suspected
vulnerability.

Include as much of the following as you can:

- the riotbox version (`riotbox --version`), host OS, and podman or docker version
- the agent and session mode involved (for example nested or socket mode)
- steps to reproduce, and what an attacker gains

## Supported versions

riotbox is pre-1.0. Fixes land on `main` and ship in the next release; only the
latest release receives them.

## Scope

RiotBox exists to contain an AI coding agent, so the most valuable reports are
ways out of that containment, for example:

- reading or writing host files outside the mounts the session was given
- reaching host credentials or session state that the container should not see
- tampering with a published release or bypassing its signature verification

[`THREAT_MODEL.md`](THREAT_MODEL.md) records the trust boundaries and the risks
already accepted. A report showing that one of those risks is worse than it says
is in scope.

To check that a release you downloaded is the one CI built, see
[Verifying a release by hand](docs/dev/riotbox-core.md#verifying-a-release-by-hand).
