#!/bin/bash

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[PASS]${NC} $1"; ((TESTS_PASSED++)); }
log_warning() { echo -e "${YELLOW}[SKIP]${NC} $1"; ((TESTS_SKIPPED++)); }
log_error() { echo -e "${RED}[FAIL]${NC} $1"; ((TESTS_FAILED++)); }

test_resource_exists() {
    local resource_group=$1
    local resource_name=$2
    local resource_type=$3
    
    if az resource show \
        --resource-group "$resource_group" \
        --name "$resource_name" \
        --resource-type "$resource_type" &>/dev/null; then
        log_success "Resource exists: $resource_name"
        return 0
    else
        log_error "Resource not found: $resource_name"
        return 1
    fi
}

test_logic_app_enabled() {
    local resource_group=$1
    local logic_app=$2
    
    local state=$(az resource show \
        --resource-group "$resource_group" \
        --name "$logic_app" \
        --resource-type "Microsoft.Logic/workflows" \
        --query "properties.state" -o tsv 2>/dev/null || echo "Unknown")
    
    if [ "$state" = "Enabled" ]; then
        log_success "Logic App is enabled: $logic_app"
        return 0
    else
        log_error "Logic App not enabled: $logic_app (state: $state)"
        return 1
    fi
}

test_connection_authorized() {
    local resource_group=$1
    local connection_name=$2
    
    local status=$(az resource show \
        --resource-group "$resource_group" \
        --name "$connection_name" \
        --resource-type "Microsoft.Web/connections" \
        --query "properties.statuses[0].status" -o tsv 2>/dev/null || echo "Unknown")
    
    if [ "$status" = "Connected" ]; then
        log_success "Connection authorized: $connection_name"
        return 0
    else
        log_error "Connection not authorized: $connection_name (status: $status)"
        return 1
    fi
}

test_managed_identity() {
    local resource_group=$1
    local logic_app=$2
    
    local identity=$(az resource show \
        --resource-group "$resource_group" \
        --name "$logic_app" \
        --resource-type "Microsoft.Logic/workflows" \
        --query "identity.type" -o tsv 2>/dev/null || echo "None")
    
    if [ "$identity" = "SystemAssigned" ]; then
        log_success "Managed identity enabled: $logic_app"
        return 0
    else
        log_error "Managed identity not enabled: $logic_app"
        return 1
    fi
}

test_rbac_assignment() {
    local resource_group=$1
    local logic_app=$2
    local role=$3
    
    local principal_id=$(az resource show \
        --resource-group "$resource_group" \
        --name "$logic_app" \
        --resource-type "Microsoft.Logic/workflows" \
        --query "identity.principalId" -o tsv 2>/dev/null || echo "")
    
    if [ -z "$principal_id" ]; then
        log_error "No managed identity found for: $logic_app"
        return 1
    fi
    
    local assignments=$(az role assignment list \
        --assignee "$principal_id" \
        --query "[?roleDefinitionName=='$role'].roleDefinitionName" -o tsv 2>/dev/null || echo "")
    
    if [ -n "$assignments" ]; then
        log_success "RBAC role assigned: $role to $logic_app"
        return 0
    else
        log_error "RBAC role not assigned: $role to $logic_app"
        return 1
    fi
}

test_analytics_rule_enabled() {
    local resource_group=$1
    local workspace_name=$2
    local rule_name=$3
    
    local enabled=$(az sentinel alert-rule show \
        --resource-group "$resource_group" \
        --workspace-name "$workspace_name" \
        --alert-rule-id "$rule_name" \
        --query "enabled" -o tsv 2>/dev/null || echo "false")
    
    if [ "$enabled" = "true" ]; then
        log_success "Analytics rule enabled: $rule_name"
        return 0
    else
        log_error "Analytics rule not enabled: $rule_name"
        return 1
    fi
}

test_watchlist_exists() {
    local resource_group=$1
    local workspace_name=$2
    local watchlist_alias=$3
    
    if az sentinel watchlist show \
        --resource-group "$resource_group" \
        --workspace-name "$workspace_name" \
        --watchlist-alias "$watchlist_alias" &>/dev/null; then
        log_success "Watchlist exists: $watchlist_alias"
        return 0
    else
        log_error "Watchlist not found: $watchlist_alias"
        return 1
    fi
}

test_logic_app_can_run() {
    local resource_group=$1
    local logic_app=$2
    
    log_info "Testing Logic App execution: $logic_app"
    
    local callback_url=$(az rest --method POST \
        --uri "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$resource_group/providers/Microsoft.Logic/workflows/$logic_app/triggers/manual/listCallbackUrl?api-version=2019-05-01" \
        --query "value" -o tsv 2>/dev/null || echo "")
    
    if [ -n "$callback_url" ]; then
        log_info "  Callback URL retrieved"
        log_warning "  Skipping actual execution (manual trigger required)"
        return 0
    else
        log_error "  Could not retrieve callback URL"
        return 1
    fi
}

test_workspace_query() {
    local workspace_name=$1
    
    log_info "Testing workspace query access"
    
    local query='SecurityIncident | limit 1'
    
    if az monitor log-analytics query \
        --workspace "$workspace_name" \
        --analytics-query "$query" \
        --output json &>/dev/null; then
        log_success "Workspace query successful"
        return 0
    else
        log_error "Workspace query failed"
        return 1
    fi
}

run_integration_tests() {
    local resource_group=$1
    local workspace_name=$2
    
    log_info "Running integration tests..."
    echo ""
    
    log_info "Test Suite 1: Resource Existence"
    test_resource_exists "$resource_group" "azuresentinel-connection" "Microsoft.Web/connections" || true
    test_resource_exists "$resource_group" "azuread-connection" "Microsoft.Web/connections" || true
    test_resource_exists "$resource_group" "teams-connection" "Microsoft.Web/connections" || true
    
    echo ""
    log_info "Test Suite 2: API Connections"
    test_connection_authorized "$resource_group" "azuresentinel-connection" || true
    test_connection_authorized "$resource_group" "azuread-connection" || true
    test_connection_authorized "$resource_group" "teams-connection" || true
    
    echo ""
    log_info "Test Suite 3: Logic Apps"
    local logic_apps=$(az resource list \
        --resource-group "$resource_group" \
        --resource-type "Microsoft.Logic/workflows" \
        --query "[].name" -o tsv 2>/dev/null || echo "")
    
    while IFS= read -r app; do
        if [ -n "$app" ]; then
            test_logic_app_enabled "$resource_group" "$app" || true
            test_managed_identity "$resource_group" "$app" || true
            test_rbac_assignment "$resource_group" "$app" "Azure Sentinel Responder" || true
        fi
    done <<< "$logic_apps"
    
    echo ""
    log_info "Test Suite 4: Workspace"
    test_workspace_query "$workspace_name" || true
    
    echo ""
    log_info "Test Suite 5: Watchlists"
    local watchlists=$(az sentinel watchlist list \
        --resource-group "$resource_group" \
        --workspace-name "$workspace_name" \
        --query "[].watchlistAlias" -o tsv 2>/dev/null || echo "")
    
    while IFS= read -r wl; do
        if [ -n "$wl" ]; then
            test_watchlist_exists "$resource_group" "$workspace_name" "$wl" || true
        fi
    done <<< "$watchlists"
}

run_smoke_tests() {
    local resource_group=$1
    local workspace_name=$2
    
    log_info "Running smoke tests (quick validation)..."
    echo ""
    
    test_resource_exists "$resource_group" "$resource_group" "Microsoft.Resources/resourceGroups" || true
    
    if az monitor log-analytics workspace show \
        --resource-group "$resource_group" \
        --workspace-name "$workspace_name" &>/dev/null; then
        log_success "Workspace accessible"
    else
        log_error "Workspace not accessible"
    fi
    
    local connections=$(az resource list \
        --resource-group "$resource_group" \
        --resource-type "Microsoft.Web/connections" \
        --query "length([])" -o tsv 2>/dev/null || echo "0")
    
    if [ "$connections" -gt 0 ]; then
        log_success "API connections found: $connections"
    else
        log_error "No API connections found"
    fi
    
    local logic_apps=$(az resource list \
        --resource-group "$resource_group" \
        --resource-type "Microsoft.Logic/workflows" \
        --query "length([])" -o tsv 2>/dev/null || echo "0")
    
    if [ "$logic_apps" -gt 0 ]; then
        log_success "Logic Apps found: $logic_apps"
    else
        log_error "No Logic Apps found"
    fi
}

generate_test_report() {
    local output_file=${1:-"test-report.html"}
    
    cat > "$output_file" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Deployment Test Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .pass { color: green; }
        .fail { color: red; }
        .skip { color: orange; }
        table { border-collapse: collapse; width: 100%; margin: 20px 0; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #f2f2f2; }
    </style>
</head>
<body>
    <h1>Deployment Test Report</h1>
    <p>Generated: $(date)</p>
    
    <h2>Summary</h2>
    <table>
        <tr><th>Status</th><th>Count</th></tr>
        <tr class="pass"><td>Passed</td><td>$TESTS_PASSED</td></tr>
        <tr class="fail"><td>Failed</td><td>$TESTS_FAILED</td></tr>
        <tr class="skip"><td>Skipped</td><td>$TESTS_SKIPPED</td></tr>
    </table>
    
    <p>Test coverage: $(( (TESTS_PASSED * 100) / (TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED) ))%</p>
</body>
</html>
EOF
    
    log_success "Test report generated: $output_file"
}

show_usage() {
    echo "Usage: $0 <command> <resource-group> <workspace-name> [options]"
    echo ""
    echo "Commands:"
    echo "  smoke                - Quick smoke tests"
    echo "  integration          - Full integration tests"
    echo "  report [file]        - Generate HTML test report"
    echo ""
}

echo "========================================="
echo "  Deployment Testing Framework"
echo "========================================="
echo ""

if [ "$#" -lt 3 ]; then
    show_usage
    exit 1
fi

COMMAND=$1
RESOURCE_GROUP=$2
WORKSPACE=$3

case "$COMMAND" in
    smoke)
        run_smoke_tests "$RESOURCE_GROUP" "$WORKSPACE"
        ;;
    integration)
        run_integration_tests "$RESOURCE_GROUP" "$WORKSPACE"
        ;;
    report)
        run_integration_tests "$RESOURCE_GROUP" "$WORKSPACE"
        generate_test_report "${4:-test-report.html}"
        ;;
    *)
        show_usage
        exit 1
        ;;
esac

echo ""
echo "========================================="
echo "  Test Results"
echo "========================================="
echo -e "Passed:  ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed:  ${RED}$TESTS_FAILED${NC}"
echo -e "Skipped: ${YELLOW}$TESTS_SKIPPED${NC}"
echo ""

if [ $TESTS_FAILED -gt 0 ]; then
    echo -e "${RED}Tests FAILED${NC}"
    exit 1
else
    echo -e "${GREEN}All tests PASSED${NC}"
    exit 0
fi

