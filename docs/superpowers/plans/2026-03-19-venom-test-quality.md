# Venom Test Quality Improvements

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate duplication, replace grep-in-script with Venom assertions, and add missing negative test cases across the riotbox Venom test suites.

**Architecture:** Extract repeated setup boilerplate into shell helper scripts (following the established `git-test-helpers.sh` pattern), then rewrite test suites to use them. Move verification logic from inline grep to proper Venom `ShouldContainSubstring` assertions. Add negative test cases where missing.

**Tech Stack:** Venom v1.3, Bash, Taskfile

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `tests/lib/wrapper-test-helpers.sh` | Create | Setup mock task, install wrapper, capture args |
| `tests/lib/overlay-test-helpers.sh` | Create | Setup overlay session dir structure |
| `tests/lib/inject-test-helpers.sh` | Create | Setup inject-claude-md test environment |
| `tests/wrapper.venom.yml` | Rewrite | Use helpers, move grep to assertions |
| `tests/overlay.venom.yml` | Rewrite | Use helpers, reduce boilerplate |
| `tests/inject-claude-md.venom.yml` | Rewrite | Use helpers, reduce boilerplate |
| `tests/install.venom.yml` | Modify | Add negative test cases |
| `tests/setup.venom.yml` | Modify | Strengthen weak assertions |

Files NOT touched (already good):
- `tests/reown-commits.venom.yml` — gold standard, leave as-is
- `tests/checkpoint-reown.venom.yml` — uses helpers well, leave as-is
- `tests/lib/git-test-helpers.sh` — reference pattern, leave as-is

---

### Task 1: Create wrapper-test-helpers.sh

**Files:**
- Create: `tests/lib/wrapper-test-helpers.sh`

The wrapper test suite repeats a 13-line mock-task setup in all 25 test cases. This helper extracts it. Note: `RIOTBOX_DIR` is always available as a Venom var and exported in the test environment.

- [ ] **Step 1: Write the helper script**

```bash
#!/usr/bin/env bash
# Shared helpers for CLI wrapper Venom tests.
# Source this file at the top of each test script.
set -euo pipefail

# Create a test environment with the wrapper installed and a mock task binary.
# The mock captures all args to $MOCK_TASK_ARGS for assertion.
# Sets: TEST_DIR, MOCK_TASK_ARGS
# Exports: PATH (prepends TEST_DIR/bin)
setup_wrapper_test() {
    TEST_DIR="$(mktemp -d)"
    mkdir -p "${TEST_DIR}/bin" "${TEST_DIR}/projects/foo" "${TEST_DIR}/projects/bar"

    # Install the real wrapper
    "${RIOTBOX_DIR}/install.sh" "${TEST_DIR}/bin" >/dev/null

    # Create mock task that captures args.
    # Unquoted heredoc (<<MOCK) so MOCK_TASK_ARGS is expanded at write time,
    # making the mock self-contained (no runtime env dependency).
    MOCK_TASK_ARGS="${TEST_DIR}/task-args"
    cat > "${TEST_DIR}/bin/task" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${MOCK_TASK_ARGS}"
MOCK
    chmod +x "${TEST_DIR}/bin/task"
    export MOCK_TASK_ARGS PATH="${TEST_DIR}/bin:${PATH}"
}

# Print captured task args to stdout (for Venom assertions).
print_task_args() {
    cat "${MOCK_TASK_ARGS}"
}
```

Note: The `RIOTBOX_DIR` variable is set by the test runner (`run-tests.sh:29` passes `--var riotbox_dir=...`). Helpers use it directly since it's always available. The `helpers` var already passes the path to `git-test-helpers.sh`; we'll add a new var `wrapper_helpers` in the test runner.

- [ ] **Step 2: Verify the helper file exists and is syntactically valid**

Run: `bash -n tests/lib/wrapper-test-helpers.sh`
Expected: No output (syntax OK)

- [ ] **Step 3: Commit**

```
git add tests/lib/wrapper-test-helpers.sh
git commit -m "Add wrapper-test-helpers.sh for CLI wrapper test deduplication"
```

---

### Task 2: Create overlay-test-helpers.sh

**Files:**
- Create: `tests/lib/overlay-test-helpers.sh`

The overlay suite repeats a 12-line session directory setup in its 21 test cases.

- [ ] **Step 1: Write the helper script**

```bash
#!/usr/bin/env bash
# Shared helpers for overlay Venom tests.
# Source this file at the top of each test script.
set -euo pipefail

# Create an overlay test environment with a project and session directory.
# Args:
#   $1 — tmpdir base (default: /tmp). Use /dev/shm for whiteout tests.
# Sets: TEST_DIR, PROJECT, SESSION, OVERLAY
# Exports: XDG_DATA_HOME, ROOT_DIR
setup_overlay_test() {
    local tmpbase="${1:-/tmp}"
    TEST_DIR="$(mktemp -d --tmpdir="${tmpbase}")"

    PROJECT="${TEST_DIR}/myproject"
    mkdir -p "${PROJECT}"

    local session_key
    session_key="$(echo "${PROJECT}" | sed 's|/|-|g; s|^-||')"
    export XDG_DATA_HOME="${TEST_DIR}/data"
    SESSION="${XDG_DATA_HOME}/claude-riotbox/${session_key}"
    OVERLAY="${SESSION}/overlay/project"
    mkdir -p "${OVERLAY}/upper" "${OVERLAY}/work"
    echo "${PROJECT}" > "${SESSION}/.projects"

    export ROOT_DIR="${RIOTBOX_DIR}"
}
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n tests/lib/overlay-test-helpers.sh`
Expected: No output (syntax OK)

- [ ] **Step 3: Commit**

```
git add tests/lib/overlay-test-helpers.sh
git commit -m "Add overlay-test-helpers.sh for overlay test deduplication"
```

---

### Task 3: Create inject-test-helpers.sh

**Files:**
- Create: `tests/lib/inject-test-helpers.sh`

The inject-claude-md suite repeats a setup pattern across 16 test cases.

- [ ] **Step 1: Write the helper script**

```bash
#!/usr/bin/env bash
# Shared helpers for inject-claude-md Venom tests.
# Source this file at the top of each test script.
set -euo pipefail

# Create a test environment for inject-claude-md tests.
# Args:
#   $1 — prompt content (written to prompt.md)
# Sets: TEST_DIR, PROMPT_FILE, CLAUDE_MD
# Exports: CLAUDE_CONFIG_DIR, RIOTBOX_PROMPT, HOME
setup_inject_test() {
    local prompt_content="${1:-You are in a riotbox.}"
    TEST_DIR="$(mktemp -d)"
    mkdir -p "${TEST_DIR}/config"
    PROMPT_FILE="${TEST_DIR}/prompt.md"
    echo "${prompt_content}" > "${PROMPT_FILE}"
    CLAUDE_MD="${TEST_DIR}/config/CLAUDE.md"
    export CLAUDE_CONFIG_DIR="${TEST_DIR}/config"
    export RIOTBOX_PROMPT="${PROMPT_FILE}"
    export HOME="${TEST_DIR}"
}

# Run the inject script (sources it in current shell).
run_inject() {
    source "${RIOTBOX_DIR}/container/inject-claude-md.sh"
}
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n tests/lib/inject-test-helpers.sh`
Expected: No output (syntax OK)

- [ ] **Step 3: Commit**

```
git add tests/lib/inject-test-helpers.sh
git commit -m "Add inject-test-helpers.sh for inject-claude-md test deduplication"
```

---

### Task 4: Update test runner to pass new helper paths

**Files:**
- Modify: `tests/lib/wrapper-test-helpers.sh` — uses `RIOTBOX_DIR` directly (already passed as `--var riotbox_dir`)
- Modify: `.taskfiles/scripts/run-tests.sh:26-30` — add new `--var` flags

The helpers use `RIOTBOX_DIR` which is available via `--var riotbox_dir`. But helpers are sourced inside test scripts as `source "{{.wrapper_helpers}}"`, so we need to pass their paths.

- [ ] **Step 1: Add helper path vars to run-tests.sh**

In `.taskfiles/scripts/run-tests.sh`, add three new `--var` lines after line 30 (`--var helpers=...`):

```bash
            --var wrapper_helpers="${RIOTBOX_DIR}/tests/lib/wrapper-test-helpers.sh" \
            --var overlay_helpers="${RIOTBOX_DIR}/tests/lib/overlay-test-helpers.sh" \
            --var inject_helpers="${RIOTBOX_DIR}/tests/lib/inject-test-helpers.sh"
```

- [ ] **Step 2: Verify the script is syntactically valid**

Run: `bash -n .taskfiles/scripts/run-tests.sh`
Expected: No output

- [ ] **Step 3: Commit**

```
git add .taskfiles/scripts/run-tests.sh
git commit -m "Pass helper script paths to venom test runner"
```

---

### Task 5: Rewrite wrapper.venom.yml

**Files:**
- Modify: `tests/wrapper.venom.yml`

This is the biggest change. The suite has 25 test cases with near-identical 13-line setup blocks and inline grep verification. The rewrite:
1. Sources `wrapper-test-helpers.sh` instead of inline setup
2. Moves grep checks to `ShouldContainSubstring` assertions on `result.systemout`
3. Uses `print_task_args` to send captured args to stdout

- [ ] **Step 1: Add vars for helper paths**

Add to the `vars:` block at the top:

```yaml
vars:
  root: "."
  riotbox_dir: "{{.root}}"
  wrapper_helpers: "{{.root}}/tests/lib/wrapper-test-helpers.sh"
```

- [ ] **Step 2: Rewrite "No args shows help" test case**

This test doesn't use the mock task, so it stays simple:

```yaml
  - name: No args shows help
    steps:
      - type: exec
        script: |
          source "{{.wrapper_helpers}}"
          setup_wrapper_test
          trap 'rm -rf "${TEST_DIR}"' EXIT
          "${TEST_DIR}/bin/claude-riotbox" 2>&1
        assertions:
          - result.code ShouldEqual 0
          - result.systemout ShouldContainSubstring "Usage:"
```

- [ ] **Step 3: Rewrite routing tests (single path, multiple paths, dot, shell, run, resume, etc.)**

Each routing test follows this pattern. Example for "Single path routes to shell with that path":

```yaml
  - name: Single path routes to shell with that path
    steps:
      - type: exec
        script: |
          source "{{.wrapper_helpers}}"
          setup_wrapper_test
          trap 'rm -rf "${TEST_DIR}"' EXIT
          cd "${TEST_DIR}/projects"
          "${TEST_DIR}/bin/claude-riotbox" "${TEST_DIR}/projects/foo"
          print_task_args
        assertions:
          - result.code ShouldEqual 0
          - result.systemout ShouldContainSubstring "shell"
          - result.systemout ShouldContainSubstring "/projects/foo"
```

Apply this pattern to ALL routing test cases. For each test:
- Replace the 13-line inline setup with `source + setup_wrapper_test + trap`
- Replace inline `echo "${args}" | grep -q "..."` with `ShouldContainSubstring` assertions
- Call `print_task_args` to send args to stdout

The key assertion mappings per test case:

| Test case | ShouldContainSubstring values |
|-----------|------------------------------|
| Multiple paths | "shell", "/projects/foo", "/projects/bar" |
| Dot path | "shell", "." |
| Shell no projects | "shell", "." |
| Shell with project | "shell", "/projects/foo" |
| Run with prompt and project | "run", "implement the feature", "/projects/foo" |
| Run prompt only | "run", "do something" |
| Resume no projects | "resume", "." |
| Resume with project | "resume", "/projects/foo" |
| Session-list | "session-list" |
| Session-remove | "session-remove" |
| Session-remove --all | "session-remove", "--all" |
| Session-remove with path | "session-remove", "/projects/foo" |
| Session-reset | "session-reset" |
| Session-reset all force | "session-reset", "all", "force" |
| Reown no flags | "reown" |
| Reown --force | "reown", "--force" |
| Build | "build" |
| Test | "test" |
| Clean | "clean" |
| Namespaced task | "session:audit" |
| Separator | "session:nested-run", "--", "do something" |

- [ ] **Step 4: Rewrite edge case tests**

"Non-existent path is not treated as a project":

```yaml
  - name: Non-existent path is not treated as a project
    steps:
      - type: exec
        script: |
          source "{{.wrapper_helpers}}"
          setup_wrapper_test
          trap 'rm -rf "${TEST_DIR}"' EXIT
          cd "${TEST_DIR}/projects"
          "${TEST_DIR}/bin/claude-riotbox" "/nonexistent/path"
          print_task_args
        assertions:
          - result.code ShouldEqual 0
          - result.systemout ShouldNotContainSubstring "shell"
          - result.systemout ShouldContainSubstring "/nonexistent/path"
```

"Mix of path and non-path":

```yaml
  - name: Mix of path and non-path is not treated as all-paths
    steps:
      - type: exec
        script: |
          source "{{.wrapper_helpers}}"
          setup_wrapper_test
          trap 'rm -rf "${TEST_DIR}"' EXIT
          cd "${TEST_DIR}/projects"
          "${TEST_DIR}/bin/claude-riotbox" "${TEST_DIR}/projects/foo" "not-a-path"
          print_task_args
        assertions:
          - result.code ShouldEqual 0
          - result.systemout ShouldNotContainSubstring "shell"
```

- [ ] **Step 5: Run the lint**

Run: `bash ~/.claude/skills/venom/lint.sh tests/wrapper.venom.yml`
Expected: All PASS

- [ ] **Step 6: Run the tests locally**

Run: `venom run tests/wrapper.venom.yml --var root="$(pwd)" --var riotbox_dir="$(pwd)" --var wrapper_helpers="$(pwd)/tests/lib/wrapper-test-helpers.sh"`
Expected: All 25 tests PASS

- [ ] **Step 7: Commit**

```
git add tests/wrapper.venom.yml
git commit -m "Rewrite wrapper tests: extract helpers, replace grep with assertions"
```

---

### Task 6: Rewrite overlay.venom.yml

**Files:**
- Modify: `tests/overlay.venom.yml`

- [ ] **Step 1: Add vars for helper paths**

```yaml
vars:
  root: "."
  riotbox_dir: "{{.root}}"
  overlay_helpers: "{{.root}}/tests/lib/overlay-test-helpers.sh"
```

- [ ] **Step 2: Rewrite accept test cases using helper**

Example for "Accept copies new files":

```yaml
  - name: Accept copies new files from upper to project
    steps:
      - type: exec
        script: |
          source "{{.overlay_helpers}}"
          setup_overlay_test
          trap 'rm -rf "${TEST_DIR}"' EXIT
          echo "original" > "${PROJECT}/existing.txt"
          echo "new file content" > "${OVERLAY}/upper/newfile.txt"
          echo "y" | "{{.riotbox_dir}}/scripts/overlay-accept.sh" "${PROJECT}"
          echo "content=$(cat "${PROJECT}/newfile.txt")"
          echo "existing=$(cat "${PROJECT}/existing.txt")"
        assertions:
          - result.code ShouldEqual 0
          - result.systemout ShouldContainSubstring "content=new file content"
          - result.systemout ShouldContainSubstring "existing=original"
```

Apply similarly for all accept, reject, and diff tests. For whiteout tests (`Accept deletes files marked with whiteout`, `Accept handles opaque directory replacement`, `Diff shows D for deleted files`), pass `/dev/shm` to setup:

```bash
setup_overlay_test /dev/shm
```

- [ ] **Step 3: Rewrite list and resolve negative tests**

List tests set up their own XDG_DATA_HOME differently (no project dir), so they can use a simpler inline setup. Keep them short but consistent.

- [ ] **Step 4: Run the lint**

Run: `bash ~/.claude/skills/venom/lint.sh tests/overlay.venom.yml`
Expected: All PASS

- [ ] **Step 5: Run the tests locally**

Run: `venom run tests/overlay.venom.yml --var root="$(pwd)" --var riotbox_dir="$(pwd)" --var overlay_helpers="$(pwd)/tests/lib/overlay-test-helpers.sh"`
Expected: All 21 tests PASS

- [ ] **Step 6: Commit**

```
git add tests/overlay.venom.yml
git commit -m "Rewrite overlay tests: extract helpers, reduce boilerplate"
```

---

### Task 7: Rewrite inject-claude-md.venom.yml

**Files:**
- Modify: `tests/inject-claude-md.venom.yml`

- [ ] **Step 1: Add vars for helper paths**

```yaml
vars:
  root: "."
  riotbox_dir: "{{.root}}"
  in_riotbox: "no"
  inject_helpers: "{{.root}}/tests/lib/inject-test-helpers.sh"
```

- [ ] **Step 2: Rewrite test cases using helper**

Example for "Creates CLAUDE.md when it does not exist":

```yaml
  - name: Creates CLAUDE.md when it does not exist
    steps:
      - type: exec
        script: |
          source "{{.inject_helpers}}"
          setup_inject_test "You are in a riotbox."
          trap 'rm -rf "${TEST_DIR}"' EXIT
          run_inject
          test -f "${CLAUDE_MD}"
        assertions:
          - result.code ShouldEqual 0
```

The security test ("Ignores user-writable ~/.riotbox") and the "Does nothing when no prompt" test have unique setup (sudo, unset RIOTBOX_PROMPT) — keep their inline logic but still use the helper where applicable.

- [ ] **Step 3: Run the lint**

Run: `bash ~/.claude/skills/venom/lint.sh tests/inject-claude-md.venom.yml`
Expected: All PASS

- [ ] **Step 4: Run the tests locally**

Run: `venom run tests/inject-claude-md.venom.yml --var root="$(pwd)" --var riotbox_dir="$(pwd)" --var inject_helpers="$(pwd)/tests/lib/inject-test-helpers.sh"`
Expected: All 16 tests PASS

- [ ] **Step 5: Commit**

```
git add tests/inject-claude-md.venom.yml
git commit -m "Rewrite inject-claude-md tests: extract helpers, reduce boilerplate"
```

---

### Task 8: Add negative tests to install.venom.yml

**Files:**
- Modify: `tests/install.venom.yml`

The install suite has only one negative-ish test (PATH warning). Add three more covering error/edge paths.

- [ ] **Step 1: Add VERSION fallback test**

```yaml
  - name: Falls back to unknown when VERSION file is missing
    steps:
      - type: exec
        script: |
          TEST_DIR="$(mktemp -d)"
          trap 'rm -rf "${TEST_DIR}"' EXIT
          export HOME="${TEST_DIR}"
          export XDG_CONFIG_HOME="${TEST_DIR}/.config"
          # Create a copy of the riotbox dir without VERSION
          FAKE_RIOTBOX="${TEST_DIR}/riotbox"
          mkdir -p "${FAKE_RIOTBOX}/scripts/configs"
          cp "{{.riotbox_dir}}/install.sh" "${FAKE_RIOTBOX}/"
          cp "{{.riotbox_dir}}/scripts/configs/"* "${FAKE_RIOTBOX}/scripts/configs/"
          # Do NOT copy VERSION file
          "${FAKE_RIOTBOX}/install.sh" "${TEST_DIR}/bin"
          grep 'RIOTBOX_VERSION="unknown"' "${TEST_DIR}/bin/claude-riotbox"
          echo "version_fallback=pass"
        assertions:
          - result.code ShouldEqual 0
          - result.systemout ShouldContainSubstring "version_fallback=pass"
```

- [ ] **Step 2: Add missing stubs directory test**

Note: `install.sh` runs `mkdir -p "${CONFIG_DIR}"` unconditionally, so the dir will exist but should be empty (no stub files to copy). The test checks that no config files were created.

```yaml
  - name: Handles missing stubs directory gracefully
    steps:
      - type: exec
        script: |
          TEST_DIR="$(mktemp -d)"
          trap 'rm -rf "${TEST_DIR}"' EXIT
          export HOME="${TEST_DIR}"
          export XDG_CONFIG_HOME="${TEST_DIR}/.config"
          FAKE_RIOTBOX="${TEST_DIR}/riotbox"
          mkdir -p "${FAKE_RIOTBOX}"
          cp "{{.riotbox_dir}}/install.sh" "${FAKE_RIOTBOX}/"
          echo "0.0.0" > "${FAKE_RIOTBOX}/VERSION"
          "${FAKE_RIOTBOX}/install.sh" "${TEST_DIR}/bin"
          test -x "${TEST_DIR}/bin/claude-riotbox"
          [ ! -f "${TEST_DIR}/.config/claude-riotbox/config" ]
          [ ! -f "${TEST_DIR}/.config/claude-riotbox/mounts.conf" ]
          [ ! -f "${TEST_DIR}/.config/claude-riotbox/plugins.conf" ]
          echo "missing_stubs=pass"
        assertions:
          - result.code ShouldEqual 0
          - result.systemout ShouldContainSubstring "missing_stubs=pass"
```

- [ ] **Step 3: Add no-overwrite PATH test**

```yaml
  - name: Does not warn when target dir IS in PATH
    steps:
      - type: exec
        script: |
          TEST_DIR="$(mktemp -d)"
          trap 'rm -rf "${TEST_DIR}"' EXIT
          export HOME="${TEST_DIR}"
          export XDG_CONFIG_HOME="${TEST_DIR}/.config"
          export PATH="${TEST_DIR}/bin:${PATH}"
          "{{.riotbox_dir}}/install.sh" "${TEST_DIR}/bin" 2>&1
        assertions:
          - result.code ShouldEqual 0
          - result.systemout ShouldNotContainSubstring "not in your PATH"
```

- [ ] **Step 4: Run the lint**

Run: `bash ~/.claude/skills/venom/lint.sh tests/install.venom.yml`
Expected: All PASS

- [ ] **Step 5: Run the tests locally**

Run: `venom run tests/install.venom.yml --var root="$(pwd)" --var riotbox_dir="$(pwd)"`
Expected: All 16 tests PASS

- [ ] **Step 6: Commit**

```
git add tests/install.venom.yml
git commit -m "Add negative test cases to install test suite"
```

---

### Task 9: Strengthen setup.venom.yml assertions

**Files:**
- Modify: `tests/setup.venom.yml`

- [ ] **Step 1: Verify setup.sh output format and strengthen assertion**

First, check the actual output by running: `FAKE_HOME="$(mktemp -d)" && mkdir -p "${FAKE_HOME}/bin" && ANTHROPIC_API_KEY="sk-test" HOME="${FAKE_HOME}" ./setup.sh --yes --no-build 2>&1 | grep -i "looks good"` — this confirms the exact string. The `ok()` function writes to stdout with a `[ok]` prefix but `--yes` disables ANSI codes, so `ShouldContainSubstring` will match the plain text.

Add the assertion:

```yaml
        assertions:
          - result.code ShouldEqual 0
          - result.systemout ShouldContainSubstring "Everything looks good"
```

- [ ] **Step 2: Run the lint**

Run: `bash ~/.claude/skills/venom/lint.sh tests/setup.venom.yml`
Expected: All PASS

- [ ] **Step 3: Run the tests locally**

Run: `venom run tests/setup.venom.yml --var root="$(pwd)" --var riotbox_dir="$(pwd)"`
Expected: All tests PASS

- [ ] **Step 4: Commit**

```
git add tests/setup.venom.yml
git commit -m "Strengthen setup.sh test assertions"
```

---

### Task 10: Run full test suite and verify

- [ ] **Step 1: Run venom lint on all suites**

Run: `bash ~/.claude/skills/venom/lint.sh tests/`
Expected: All PASS, 0 errors

- [ ] **Step 2: Run all tests locally**

Run each suite individually since we don't have the test container:

```bash
COMMON="--var root=$(pwd) --var riotbox_dir=$(pwd) --var helpers=$(pwd)/tests/lib/git-test-helpers.sh"
venom run tests/install.venom.yml ${COMMON}
venom run tests/wrapper.venom.yml ${COMMON} --var wrapper_helpers="$(pwd)/tests/lib/wrapper-test-helpers.sh"
venom run tests/overlay.venom.yml ${COMMON} --var overlay_helpers="$(pwd)/tests/lib/overlay-test-helpers.sh"
venom run tests/inject-claude-md.venom.yml ${COMMON} --var inject_helpers="$(pwd)/tests/lib/inject-test-helpers.sh"
venom run tests/setup.venom.yml ${COMMON}
venom run tests/checkpoint-reown.venom.yml ${COMMON}
venom run tests/reown-commits.venom.yml ${COMMON}
```

Expected: All suites PASS

- [ ] **Step 3: Final commit (if any unstaged fixes remain)**

```
git add tests/lib/wrapper-test-helpers.sh tests/lib/overlay-test-helpers.sh tests/lib/inject-test-helpers.sh \
       tests/wrapper.venom.yml tests/overlay.venom.yml tests/inject-claude-md.venom.yml \
       tests/install.venom.yml tests/setup.venom.yml .taskfiles/scripts/run-tests.sh
git commit -m "Venom test quality: helpers, assertions, negative cases"
```
