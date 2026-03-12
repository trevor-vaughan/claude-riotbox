#!/usr/bin/env bash
# Lint .venom.yml and lib/*.yml files against structural conventions.
# Usage: bash lint.sh [directory]
# Exits 0 if all checks pass, 1 if any fail.
set -euo pipefail

dir="${1:-.}"
errors=0
checks=0

pass() { checks=$((checks + 1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { checks=$((checks + 1)); errors=$((errors + 1)); printf "  \033[31mFAIL\033[0m %s" "$1"; [ -n "${2:-}" ] && printf " — %s" "$2"; printf "\n"; }

# When running against the project root, skip fixtures/ entirely — both good and bad
# fixture files are tested individually by ci.venom.yml and should not be linted here.
# When targeting a fixture directory directly, include everything.
if [[ "$dir" == *fixtures* ]]; then
    exclude_fixtures=()
else
    exclude_fixtures=(-not -path '*/fixtures/*')
fi

# --- Collect files ---
# All yml files outside lib/ — to catch wrong-suffix venom suites
all_yml_files=()
while IFS= read -r -d '' f; do
    all_yml_files+=("$f")
done < <(find "$dir" -name '*.yml' -not -path '*/lib/*' "${exclude_fixtures[@]}" -print0 2>/dev/null | sort -z)

# User executor files in lib/
executor_files=()
while IFS= read -r -d '' f; do
    executor_files+=("$f")
done < <(find "$dir" -path '*/lib/*.yml' "${exclude_fixtures[@]}" -print0 2>/dev/null | sort -z)

if (( ${#all_yml_files[@]} == 0 && ${#executor_files[@]} == 0 )); then
    echo "No .venom.yml or lib/*.yml files found in $dir"
    exit 0
fi

# --- Check each yml file (suite naming + structure) ---
check_suite() {
    local file="$1"
    local label
    label="$(basename "$file")"
    local content
    content="$(cat "$file")"

    printf "\n%s\n" "$label"

    # 1. File naming: must end with .venom.yml
    if [[ "$file" == *.venom.yml ]]; then
        pass "File uses .venom.yml suffix"
    else
        fail "File uses .venom.yml suffix" "got: $(basename "$file")"
        # No point checking structure if naming is wrong — it may not be a venom suite at all
        return
    fi

    # 2. Suite has name: field
    if grep -qE '^name:' <<< "$content"; then
        pass "Suite has name: field"
    else
        fail "Suite has name: field"
    fi

    # 3. Suite has vars: block
    if grep -qE '^vars:' <<< "$content"; then
        pass "Suite has vars: block"
    else
        fail "Suite has vars: block"
    fi

    # 4. Every test case has name:
    local in_testcases=0
    local has_name=1
    local missing_name=0
    while IFS= read -r line; do
        if [[ "$line" =~ ^testcases: ]]; then
            in_testcases=1
            continue
        fi
        if (( in_testcases )); then
            if [[ "$line" =~ ^[[:space:]]{2}-[[:space:]] && ! "$line" =~ name: ]]; then
                has_name=0
            elif [[ "$line" =~ ^[[:space:]]{4}name: ]]; then
                has_name=1
            elif [[ "$line" =~ ^[[:space:]]{4}steps: && $has_name -eq 0 ]]; then
                missing_name=$((missing_name + 1))
            fi
        fi
    done <<< "$content"
    if (( missing_name == 0 )); then
        pass "Every test case has name:"
    else
        fail "Every test case has name:" "$missing_name test case(s) missing name"
    fi

    # 5. Every test case has steps:
    local testcase_count
    testcase_count=$(grep -cE '^[[:space:]]{2}- name:' <<< "$content" || true)
    local steps_count
    steps_count=$(grep -cE '^[[:space:]]{4}steps:' <<< "$content" || true)
    if (( testcase_count > 0 && steps_count >= testcase_count )); then
        pass "Every test case has steps:"
    elif (( testcase_count == 0 )); then
        fail "Every test case has steps:" "no test cases found"
    else
        fail "Every test case has steps:" "found $testcase_count test cases but only $steps_count steps: blocks"
    fi

    # 6. Every exec step has assertions:
    local exec_without_assertions=0
    local in_step=0
    local has_assertions=0
    local is_exec=0
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]{6}-[[:space:]] ]]; then
            if (( in_step && is_exec && !has_assertions )); then
                exec_without_assertions=$((exec_without_assertions + 1))
            fi
            in_step=1
            has_assertions=0
            is_exec=0
        fi
        if (( in_step )); then
            if [[ "$line" =~ type:[[:space:]]*exec ]] || [[ "$line" =~ ^[[:space:]]*script: ]]; then
                is_exec=1
            fi
            if [[ "$line" =~ ^[[:space:]]*assertions: ]]; then
                has_assertions=1
            fi
        fi
    done <<< "$content"
    if (( in_step && is_exec && !has_assertions )); then
        exec_without_assertions=$((exec_without_assertions + 1))
    fi
    if (( exec_without_assertions == 0 )); then
        pass "Every exec step has assertions:"
    else
        fail "Every exec step has assertions:" "$exec_without_assertions exec step(s) without assertions"
    fi

    # 7. No range with {{.value}} in script blocks
    if grep -qE '\{\{\.value\}\}' <<< "$content" && grep -qE '^[[:space:]]*range:' <<< "$content"; then
        fail "No range with {{.value}} in script blocks" "use user executors instead"
    else
        pass "No range with {{.value}} in script blocks"
    fi

    # 8. No hardcoded absolute paths in script blocks
    local hardcoded_paths
    hardcoded_paths=$(grep -nE 'script:.*/(usr|home|etc|opt|tmp)/' <<< "$content" | grep -v '{{' || true)
    if [[ -z "$hardcoded_paths" ]]; then
        pass "No hardcoded absolute paths in scripts"
    else
        fail "No hardcoded absolute paths in scripts" "use vars for paths"
    fi
}

# --- Check each user executor ---
check_executor() {
    local file="$1"
    local label
    label="lib/$(basename "$file")"
    local content
    content="$(cat "$file")"

    printf "\n%s\n" "$label"

    # 1. Has executor: field
    if grep -qE '^executor:' <<< "$content"; then
        pass "Has executor: field"
    else
        fail "Has executor: field"
    fi

    # 2. Has input: field
    if grep -qE '^input:' <<< "$content"; then
        pass "Has input: field"
    else
        fail "Has input: field"
    fi

    # 3. Has steps: field
    if grep -qE '^steps:' <<< "$content"; then
        pass "Has steps: field"
    else
        fail "Has steps: field"
    fi
}

for f in "${all_yml_files[@]}"; do
    check_suite "$f"
done

for f in "${executor_files[@]}"; do
    check_executor "$f"
done

# --- Summary ---
printf "\n%d checks, %d errors\n" "$checks" "$errors"
(( errors == 0 )) && exit 0 || exit 1
