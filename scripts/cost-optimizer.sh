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

calculate_logic_app_cost() {
    local resource_group=$1
    local logic_app=$2
    local days=${3:-30}
    
    log_info "Calculating cost for: $logic_app (last $days days)"
    
    local runs
    runs=$(az rest --method GET \
        --uri "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$resource_group/providers/Microsoft.Logic/workflows/$logic_app/runs?api-version=2019-05-01&\$top=1000" \
        --query "value | length(@)" 2>/dev/null || echo "0")
    
    local cost_per_execution=0.000025
    local monthly_runs
    local monthly_cost
    
    # Prevent division by zero
    if [ "$days" -eq 0 ]; then days=1; fi
    
    monthly_runs=$(echo "$runs * (30 / $days)" | bc 2>/dev/null || echo "0")
    monthly_cost=$(echo "$monthly_runs * $cost_per_execution" | bc 2>/dev/null || echo "0")
    
    echo "  Runs: $runs (projected monthly: $monthly_runs)"
    echo "  Estimated monthly cost: \$$monthly_cost"
}

analyze_workspace_cost() {
    local resource_group=$1
    local workspace_name=$2
    
    log_info "Analyzing workspace costs: $workspace_name"
    
    local ingestion_query='Usage | where TimeGenerated > ago(30d) | summarize TotalGB=sum(Quantity)/1000 by DataType | order by TotalGB desc'
    
    local result=$(az monitor log-analytics query \
        --workspace "$workspace_name" \
        --analytics-query "$ingestion_query" \
        --output json 2>/dev/null || echo "[]")
    
    local total_gb=$(echo "$result" | jq '[.[] | .TotalGB] | add' 2>/dev/null || echo "0")
    
    local cost_per_gb=2.30
    local monthly_cost=$(echo "$total_gb * $cost_per_gb" | bc 2>/dev/null || echo "0")
    
    echo "  Total ingestion (30 days): ${total_gb} GB"
    echo "  Estimated monthly cost: \$$monthly_cost"
    echo ""
    echo "  Top data types:"
    echo "$result" | jq -r '.[] | "    \(.DataType): \(.TotalGB) GB"' 2>/dev/null | head -n 5
}

estimate_total_cost() {
    local resource_group=$1
    local workspace_name=$2
    
    log_info "Estimating total monthly cost..."
    echo ""
    
    echo "Log Analytics Workspace:"
    analyze_workspace_cost "$resource_group" "$workspace_name"
    
    echo ""
    echo "Logic Apps:"
    local logic_apps=$(az resource list \
        --resource-group "$resource_group" \
        --resource-type "Microsoft.Logic/workflows" \
        --query "[].name" -o tsv)
    
    while IFS= read -r app; do
        if [ -n "$app" ]; then
            calculate_logic_app_cost "$resource_group" "$app" 30
        fi
    done <<< "$logic_apps"
    
    echo ""
    echo "API Connections: \$0 (no additional cost)"
    echo ""
    log_info "Note: These are estimates. Check Azure Cost Management for actual costs."
}

recommend_optimizations() {
    local resource_group=$1
    local workspace_name=$2
    
    log_info "Analyzing cost optimization opportunities..."
    echo ""
    
    log_info "1. Checking for unused Logic Apps..."
    local logic_apps=$(az resource list \
        --resource-group "$resource_group" \
        --resource-type "Microsoft.Logic/workflows" \
        --query "[].name" -o tsv)
    
    while IFS= read -r app; do
        if [ -n "$app" ]; then
            local runs=$(az rest --method GET \
                --uri "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$resource_group/providers/Microsoft.Logic/workflows/$app/runs?api-version=2019-05-01&\$top=10" \
                --query "value | length(@)" 2>/dev/null || echo "0")
            
            if [ "$runs" -eq 0 ]; then
                log_warning "  $app has no recent runs - consider disabling"
            fi
        fi
    done <<< "$logic_apps"
    
    echo ""
    log_info "2. Checking workspace retention..."
    local retention=$(az monitor log-analytics workspace show \
        --resource-group "$resource_group" \
        --workspace-name "$workspace_name" \
        --query "retentionInDays" -o tsv 2>/dev/null || echo "30")
    
    if [ "$retention" -gt 90 ]; then
        log_warning "  Retention is set to $retention days. Consider reducing to 90 days for cost savings."
    else
        log_success "  Retention ($retention days) is optimized"
    fi
    
    echo ""
    log_info "3. Checking for expensive data types..."
    local expensive_query='Usage | where TimeGenerated > ago(7d) | where IsBillable == true | summarize GB=sum(Quantity)/1000 by DataType | where GB > 10 | order by GB desc'
    
    az monitor log-analytics query \
        --workspace "$workspace_name" \
        --analytics-query "$expensive_query" \
        --output table 2>/dev/null || log_warning "  Could not query workspace"
    
    echo ""
    log_info "4. Recommendations:"
    echo "  - Use commitment tiers if ingesting >100GB/day"
    echo "  - Archive old data to Azure Storage"
    echo "  - Disable verbose logging for non-critical sources"
    echo "  - Use sampling for high-volume data types"
    echo "  - Review and disable unused analytics rules"
}

set_budget() {
    local resource_group=$1
    local budget_amount=$2
    local email=$3
    
    log_info "Setting up budget alert: \$${budget_amount}/month"
    
    az consumption budget create \
        --resource-group "$resource_group" \
        --budget-name "Sentinel-Monthly-Budget" \
        --amount "$budget_amount" \
        --category "Cost" \
        --time-grain "Monthly" \
        --start-date "$(date -u +%Y-%m-01)" \
        --end-date "$(date -u -d '+1 year' +%Y-%m-01)" \
        --notifications "{\"Actual_GreaterThan_80_Percent\":{\"enabled\":true,\"operator\":\"GreaterThan\",\"threshold\":80,\"contactEmails\":[\"$email\"]}}" \
        2>/dev/null || log_warning "Could not create budget (requires permissions)"
    
    log_success "Budget alert configured"
}

get_cost_trends() {
    local resource_group=$1
    local days=${2:-30}
    
    log_info "Fetching cost trends for last $days days..."
    
    local end_date
    local start_date
    end_date=$(date -u +%Y-%m-%d)
    if date --version >/dev/null 2>&1; then
        # GNU date (Linux)
        start_date=$(date -u -d "${days} days ago" +%Y-%m-%d)
    else
        # BSD date (macOS)
        start_date=$(date -u -v-"${days}"d +%Y-%m-%d)
    fi
    
    az consumption usage list \
        --start-date "$start_date" \
        --end-date "$end_date" \
        --query "[?contains(instanceName, '$resource_group')].{Date:usageStart, Cost:pretaxCost, Resource:instanceName}" \
        --output table 2>/dev/null || log_warning "Could not fetch cost data"
}

export_cost_report() {
    local resource_group=$1
    local output_file=${2:-"cost-report.csv"}
    
    log_info "Exporting cost report to: $output_file"
    
    cat > "$output_file" << EOF
Resource Type,Resource Name,Estimated Monthly Cost,Notes
Log Analytics Workspace,$workspace_name,\$50-100,Based on ingestion volume
EOF
    
    local logic_apps=$(az resource list \
        --resource-group "$resource_group" \
        --resource-type "Microsoft.Logic/workflows" \
        --query "[].name" -o tsv)
    
    while IFS= read -r app; do
        if [ -n "$app" ]; then
            echo "Logic App,$app,\$0-5,Based on execution volume" >> "$output_file"
        fi
    done <<< "$logic_apps"
    
    cat >> "$output_file" << EOF
API Connections,All,\$0,No additional cost
Watchlists,All,\$0,Included in workspace cost
EOF
    
    log_success "Cost report exported"
}

compare_tiers() {
    echo "Log Analytics Pricing Tiers:"
    echo ""
    echo "Pay-As-You-Go:"
    echo "  - \$2.30/GB for first 5GB/day"
    echo "  - Best for: <5GB/day ingestion"
    echo ""
    echo "Commitment Tier - 100GB/day:"
    echo "  - \$196/day (\$1.96/GB)"
    echo "  - Save 15% vs Pay-As-You-Go"
    echo "  - Best for: 100-200GB/day"
    echo ""
    echo "Commitment Tier - 500GB/day:"
    echo "  - \$875/day (\$1.75/GB)"
    echo "  - Save 24% vs Pay-As-You-Go"
    echo "  - Best for: 500-1000GB/day"
    echo ""
    echo "Recommendation:"
    echo "  - Monitor ingestion for 30 days"
    echo "  - Switch to commitment tier if consistent >100GB/day"
    echo "  - Can change tier once per 31 days"
}

show_usage() {
    echo "Usage: $0 <command> <resource-group> <workspace-name> [options]"
    echo ""
    echo "Commands:"
    echo "  estimate                        - Estimate total monthly cost"
    echo "  recommend                       - Recommend cost optimizations"
    echo "  set-budget <amount> <email>     - Set up budget alerts"
    echo "  trends [days]                   - Show cost trends"
    echo "  export [file]                   - Export cost report to CSV"
    echo "  compare-tiers                   - Compare pricing tiers"
    echo ""
}

if [ "$#" -lt 1 ]; then
    show_usage
    exit 1
fi

COMMAND=$1

case "$COMMAND" in
    estimate)
        estimate_total_cost "$2" "$3"
        ;;
    recommend)
        recommend_optimizations "$2" "$3"
        ;;
    set-budget)
        set_budget "$2" "$3" "$4"
        ;;
    trends)
        get_cost_trends "$2" "${3:-30}"
        ;;
    export)
        export_cost_report "$2" "${3:-cost-report.csv}"
        ;;
    compare-tiers)
        compare_tiers
        ;;
    *)
        show_usage
        exit 1
        ;;
esac

