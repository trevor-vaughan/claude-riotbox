# Contributing to RiotBox

Security vulnerabilities go through [`SECURITY.md`](SECURITY.md), not the issue
tracker.

## Before you start

Open an issue describing the bug or the change you want before writing a large
patch, so the approach can be agreed first. Name your branch after the issue,
for example `42-short-description`.

## Making a change

The [Development section of the README](README.md#development) lists the
prerequisites and every task. The short version:

```sh
task check    # lint, Go and venom tests, venom suite lint
```

- Run `task check` before opening a pull request. CI runs the same gates.
- A change in behavior comes with a test that fails without it: a Ginkgo spec
  for Go code under `internal/` and `cmd/`, a Venom suite under `tests/` for
  shell and end-to-end behavior.
- Update the README and the docs under `docs/` when usage or configuration
  changes. Maintainer documentation (how it works and why) lives in `docs/dev/`.
- Changes that affect a trust boundary (mounts, credentials, the container's
  privileges) need a matching update to [`THREAT_MODEL.md`](THREAT_MODEL.md).

## Commit messages

Commits follow [Conventional Commits](https://www.conventionalcommits.org):
`feat`, `fix`, `docs`, `refactor`, `test`, `perf`, `build`, `ci` or `chore`,
with an optional scope, for example `fix(egress): …`. Release versions and
`CHANGELOG.md` are generated from these messages by
[git-cliff](https://git-cliff.org) (see [`cliff.toml`](cliff.toml)), so the type
decides where a change appears and how the version is bumped.

Write the subject in the imperative mood, and use the body to explain why the
change is needed.

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE) that covers the project.
