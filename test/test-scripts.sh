#!/usr/bin/env bash

# Basic smoke tests for shell scripts

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/../scripts"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

test_script_syntax() {
    local script=$1
    echo -n "Testing syntax: $(basename "$script")... "
    
    if bash -n "$script" 2>/dev/null; then
        echo -e "${GREEN}PASS${NC}"
        ((TESTS_PASSED++))
        return 0
    else
        echo -e "${RED}FAIL${NC}"
        ((TESTS_FAILED++))
        return 1
    fi
}

test_common_functions() {
    echo -n "Testing common.sh functions... "
    
    # Source common functions
    if source "$SCRIPTS_DIR/common.sh"; then
        # Test logging functions exist
        if declare -f log_info >/dev/null && \
           declare -f log_error >/dev/null && \
           declare -f portable_date_ago >/dev/null; then
            echo -e "${GREEN}PASS${NC}"
            ((TESTS_PASSED++))
            return 0
        fi
    fi
    
    echo -e "${RED}FAIL${NC}"
    ((TESTS_FAILED++))
    return 1
}

test_portable_date() {
    echo -n "Testing portable date function... "
    
    source "$SCRIPTS_DIR/common.sh"
    
    # Test that it returns a date
    local result
    result=$(portable_date_ago 1 days '+%Y-%m-%d')
    
    if [[ "$result" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo -e "${GREEN}PASS${NC}"
        ((TESTS_PASSED++))
        return 0
    else
        echo -e "${RED}FAIL (got: $result)${NC}"
        ((TESTS_FAILED++))
        return 1
    fi
}

test_safe_divide() {
    echo -n "Testing safe divide... "
    
    source "$SCRIPTS_DIR/common.sh"
    
    # Test division by zero returns 0
    local result
    result=$(safe_divide 10 0)
    
    if [ "$result" = "0" ]; then
        echo -e "${GREEN}PASS${NC}"
        ((TESTS_PASSED++))
        return 0
    else
        echo -e "${RED}FAIL${NC}"
        ((TESTS_FAILED++))
        return 1
    fi
}

echo "========================================"
echo "  Running Shell Script Tests"
echo "========================================"
echo ""

# Test syntax of all scripts
for script in "$SCRIPTS_DIR"/*.sh; do
    test_script_syntax "$script" || true
done

echo ""
echo "Testing common functions..."
test_common_functions || true
test_portable_date || true
test_safe_divide || true

echo ""
echo "========================================"
echo "  Test Results"
echo "========================================"
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
echo ""

if [ "$TESTS_FAILED" -gt 0 ]; then
    echo -e "${RED}Tests FAILED${NC}"
    exit 1
else
    echo -e "${GREEN}All tests PASSED${NC}"
    exit 0
fi
