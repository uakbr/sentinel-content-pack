#!/bin/bash

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_logic_app_health() {
    local resource_group=$1
    local logic_app=$2
    
    local state=$(az resource show \
        --resource-group "$resource_group" \
        --name "$logic_app" \
        --resource-type "Microsoft.Logic/workflows" \
        --query "properties.state" -o tsv 2>/dev/null || echo "Unknown")
    
    if [ "$state" = "Enabled" ]; then
        log_success "$logic_app is enabled"
        return 0
    else
        log_error "$logic_app is $state"
        return 1
    fi
}

get_logic_app_run_history() {
    local resource_group=$1
    local logic_app=$2
    local hours=${3:-24}
    
    log_info "Fetching run history for $logic_app (last $hours hours)..."
    
    az rest --method GET \
        --uri "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$resource_group/providers/Microsoft.Logic/workflows/$logic_app/runs?api-version=2019-05-01" \
        --query "value[?properties.startTime >= '$(date -u -v-${hours}H +%Y-%m-%dT%H:%M:%SZ)'].{name:name, status:properties.status, startTime:properties.startTime, endTime:properties.endTime}" \
        -o table 2>/dev/null || log_warning "Could not retrieve run history"
}

calculate_success_rate() {
    local resource_group=$1
    local logic_app=$2
    
    local runs=$(az rest --method GET \
        --uri "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$resource_group/providers/Microsoft.Logic/workflows/$logic_app/runs?api-version=2019-05-01&\$top=50" \
        --query "value[].properties.status" -o tsv 2>/dev/null || echo "")
    
    if [ -z "$runs" ]; then
        echo "N/A"
        return
    fi
    
    local total=$(echo "$runs" | wc -l | xargs)
    local succeeded=$(echo "$runs" | grep -c "Succeeded" || echo "0")
    
    if [ "$total" -gt 0 ]; then
        local rate=$(awk "BEGIN {printf \"%.1f\", ($succeeded/$total)*100}")
        echo "${rate}% ($succeeded/$total)"
    else
        echo "N/A"
    fi
}

check_connection_health() {
    local resource_group=$1
    
    log_info "Checking API connection health..."
    
    local connections=$(az resource list \
        --resource-group "$resource_group" \
        --resource-type "Microsoft.Web/connections" \
        --query "[].name" -o tsv)
    
    local healthy=0
    local unhealthy=0
    
    while IFS= read -r conn; do
        if [ -n "$conn" ]; then
            local status=$(az resource show \
                --resource-group "$resource_group" \
                --name "$conn" \
                --resource-type "Microsoft.Web/connections" \
                --query "properties.statuses[0].status" -o tsv 2>/dev/null || echo "Unknown")
            
            if [ "$status" = "Connected" ]; then
                log_success "$conn: Connected"
                ((healthy++))
            else
                log_error "$conn: $status"
                ((unhealthy++))
            fi
        fi
    done <<< "$connections"
    
    echo ""
    echo "Connection Health: $healthy healthy, $unhealthy unhealthy"
}

check_analytics_rules() {
    local resource_group=$1
    local workspace_name=$2
    
    log_info "Checking analytics rules..."
    
    local rules=$(az sentinel alert-rule list \
        --resource-group "$resource_group" \
        --workspace-name "$workspace_name" \
        --query "[].{Name:name, Enabled:enabled, Severity:severity}" -o json 2>/dev/null || echo "[]")
    
    local total=$(echo "$rules" | jq 'length')
    local enabled=$(echo "$rules" | jq '[.[] | select(.Enabled==true)] | length')
    local disabled=$((total - enabled))
    
    log_info "Analytics Rules: $enabled enabled, $disabled disabled"
    
    if [ $disabled -gt 0 ]; then
        log_warning "Some rules are disabled:"
        echo "$rules" | jq -r '.[] | select(.Enabled==false) | "  - \(.Name)"'
    fi
}

check_workspace_health() {
    local resource_group=$1
    local workspace_name=$2
    
    log_info "Checking workspace health..."
    
    local state=$(az monitor log-analytics workspace show \
        --resource-group "$resource_group" \
        --workspace-name "$workspace_name" \
        --query "provisioningState" -o tsv 2>/dev/null || echo "Unknown")
    
    if [ "$state" = "Succeeded" ]; then
        log_success "Workspace is healthy"
    else
        log_error "Workspace state: $state"
    fi
}

check_incident_volume() {
    local resource_group=$1
    local workspace_name=$2
    
    log_info "Checking incident volume (last 24 hours)..."
    
    local query='SecurityIncident | where TimeGenerated > ago(24h) | summarize count() by Severity'
    
    az monitor log-analytics query \
        --workspace "$workspace_name" \
        --analytics-query "$query" \
        --output table 2>/dev/null || log_warning "Could not query incidents"
}

generate_health_report() {
    local resource_group=$1
    local workspace_name=$2
    local output_file=${3:-"health-report.html"}
    
    log_info "Generating health report..."
    
    cat > "$output_file" << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Sentinel Health Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .healthy { color: green; }
        .warning { color: orange; }
        .error { color: red; }
        table { border-collapse: collapse; width: 100%; margin: 20px 0; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #f2f2f2; }
        h1 { color: #333; }
        .timestamp { color: #666; font-size: 0.9em; }
    </style>
</head>
<body>
    <h1>Sentinel Health Report</h1>
    <p class="timestamp">Generated: $(date)</p>
    
    <h2>Logic Apps</h2>
    <table>
        <tr><th>Name</th><th>State</th><th>Success Rate</th></tr>
EOF
    
    local logic_apps=$(az resource list \
        --resource-group "$resource_group" \
        --resource-type "Microsoft.Logic/workflows" \
        --query "[].name" -o tsv)
    
    while IFS= read -r app; do
        if [ -n "$app" ]; then
            local state=$(az resource show \
                --resource-group "$resource_group" \
                --name "$app" \
                --resource-type "Microsoft.Logic/workflows" \
                --query "properties.state" -o tsv)
            
            local success_rate=$(calculate_success_rate "$resource_group" "$app")
            
            local state_class="healthy"
            [ "$state" != "Enabled" ] && state_class="error"
            
            echo "        <tr><td>$app</td><td class=\"$state_class\">$state</td><td>$success_rate</td></tr>" >> "$output_file"
        fi
    done <<< "$logic_apps"
    
    cat >> "$output_file" << 'EOF'
    </table>
    
    <h2>API Connections</h2>
    <table>
        <tr><th>Name</th><th>Status</th></tr>
EOF
    
    local connections=$(az resource list \
        --resource-group "$resource_group" \
        --resource-type "Microsoft.Web/connections" \
        --query "[].name" -o tsv)
    
    while IFS= read -r conn; do
        if [ -n "$conn" ]; then
            local status=$(az resource show \
                --resource-group "$resource_group" \
                --name "$conn" \
                --resource-type "Microsoft.Web/connections" \
                --query "properties.statuses[0].status" -o tsv 2>/dev/null || echo "Unknown")
            
            local status_class="healthy"
            [ "$status" != "Connected" ] && status_class="error"
            
            echo "        <tr><td>$conn</td><td class=\"$status_class\">$status</td></tr>" >> "$output_file"
        fi
    done <<< "$connections"
    
    cat >> "$output_file" << 'EOF'
    </table>
</body>
</html>
EOF
    
    log_success "Health report generated: $output_file"
}

setup_monitoring_alerts() {
    local resource_group=$1
    local workspace_name=$2
    local email=$3
    
    log_info "Setting up monitoring alerts..."
    
    log_info "Creating action group for notifications..."
    az monitor action-group create \
        --name "Sentinel-Alerts" \
        --resource-group "$resource_group" \
        --short-name "SentinelAG" \
        --email-receiver "security-team" "$email" \
        --output none
    
    log_info "Creating alert for failed playbook runs..."
    az monitor metrics alert create \
        --name "PlaybookFailureAlert" \
        --resource-group "$resource_group" \
        --scopes "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$resource_group" \
        --condition "count Microsoft.Logic/workflows > 0 where status == 'Failed'" \
        --window-size 5m \
        --evaluation-frequency 1m \
        --action-group "Sentinel-Alerts" \
        --description "Alert when playbook execution fails" \
        --output none 2>/dev/null || log_warning "Could not create alert (requires Azure Monitor)"
    
    log_success "Monitoring alerts configured"
}

continuous_monitor() {
    local resource_group=$1
    local workspace_name=$2
    local interval=${3:-300}
    
    log_info "Starting continuous monitoring (interval: ${interval}s)"
    log_info "Press Ctrl+C to stop"
    
    while true; do
        clear
        echo "==================================="
        echo "Sentinel Health Monitor"
        echo "Time: $(date)"
        echo "==================================="
        echo ""
        
        check_workspace_health "$resource_group" "$workspace_name"
        echo ""
        check_connection_health "$resource_group"
        echo ""
        check_analytics_rules "$resource_group" "$workspace_name"
        echo ""
        
        local logic_apps=$(az resource list \
            --resource-group "$resource_group" \
            --resource-type "Microsoft.Logic/workflows" \
            --query "[].name" -o tsv)
        
        echo "Logic Apps Status:"
        while IFS= read -r app; do
            if [ -n "$app" ]; then
                check_logic_app_health "$resource_group" "$app"
            fi
        done <<< "$logic_apps"
        
        sleep "$interval"
    done
}

show_usage() {
    echo "Usage: $0 <command> <resource-group> <workspace-name> [options]"
    echo ""
    echo "Commands:"
    echo "  check-all                   - Run all health checks"
    echo "  check-logic-apps            - Check Logic Apps health"
    echo "  check-connections           - Check API connections"
    echo "  check-rules                 - Check analytics rules"
    echo "  run-history <app-name>      - Show run history for Logic App"
    echo "  generate-report [file]      - Generate HTML health report"
    echo "  setup-alerts <email>        - Configure monitoring alerts"
    echo "  monitor [interval]          - Continuous monitoring (default 300s)"
    echo ""
}

if [ "$#" -lt 3 ]; then
    show_usage
    exit 1
fi

COMMAND=$1
RESOURCE_GROUP=$2
WORKSPACE=$3
shift 3

case "$COMMAND" in
    check-all)
        check_workspace_health "$RESOURCE_GROUP" "$WORKSPACE"
        check_connection_health "$RESOURCE_GROUP"
        check_analytics_rules "$RESOURCE_GROUP" "$WORKSPACE"
        check_incident_volume "$RESOURCE_GROUP" "$WORKSPACE"
        ;;
    check-logic-apps)
        logic_apps=$(az resource list --resource-group "$RESOURCE_GROUP" --resource-type "Microsoft.Logic/workflows" --query "[].name" -o tsv)
        while IFS= read -r app; do
            [ -n "$app" ] && check_logic_app_health "$RESOURCE_GROUP" "$app"
        done <<< "$logic_apps"
        ;;
    check-connections)
        check_connection_health "$RESOURCE_GROUP"
        ;;
    check-rules)
        check_analytics_rules "$RESOURCE_GROUP" "$WORKSPACE"
        ;;
    run-history)
        get_logic_app_run_history "$RESOURCE_GROUP" "$1" "${2:-24}"
        ;;
    generate-report)
        generate_health_report "$RESOURCE_GROUP" "$WORKSPACE" "${1:-health-report.html}"
        ;;
    setup-alerts)
        setup_monitoring_alerts "$RESOURCE_GROUP" "$WORKSPACE" "$1"
        ;;
    monitor)
        continuous_monitor "$RESOURCE_GROUP" "$WORKSPACE" "${1:-300}"
        ;;
    *)
        show_usage
        exit 1
        ;;
esac

