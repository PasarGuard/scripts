#!/usr/bin/env bash
# =============================================================================
# run_all.sh - Master unit test runner for PasarGuard test suites
# =============================================================================
set -u

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${TESTS_DIR}/.." && pwd)"

SUITES=(
    "unit_lib_common.sh"
    "unit_lib_env.sh"
    "unit_lib_github.sh"
    "unit_lib_system.sh"
    "unit_pasarguard.sh"
    "unit_pgnode.sh"
    "unit_pgnode_service.sh"
    "unit_restore_archive_safety.sh"
    "test_script_update_safety.sh"
)

TOTAL=${#SUITES[@]}
PASSED=0
FAILED=0
FAILED_LIST=()

printf "\n==============================================\n"
printf "   Running PasarGuard Test Suites (%d total)   \n" "$TOTAL"
printf "==============================================\n\n"

for suite in "${SUITES[@]}"; do
    suite_path="$TESTS_DIR/$suite"
    if [ ! -f "$suite_path" ]; then
        printf "[WARN] Suite not found: %s\n" "$suite"
        continue
    fi

    printf "▶ Running %s...\n" "$suite"
    if bash "$suite_path"; then
        printf "✔ %s passed.\n\n" "$suite"
        PASSED=$((PASSED + 1))
    else
        printf "✖ %s FAILED.\n\n" "$suite"
        FAILED=$((FAILED + 1))
        FAILED_LIST+=("$suite")
    fi
done

printf "==============================================\n"
printf "Test Summary: %d passed, %d failed out of %d suites.\n" "$PASSED" "$FAILED" "$TOTAL"
if [ "$FAILED" -gt 0 ]; then
    printf "Failed suites:\n"
    for failed_suite in "${FAILED_LIST[@]}"; do
        printf "  - %s\n" "$failed_suite"
    done
    printf "==============================================\n\n"
    exit 1
fi

printf "All unit test suites completed successfully!\n"
printf "==============================================\n\n"
exit 0
