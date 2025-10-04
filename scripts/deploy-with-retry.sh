#!/bin/bash

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

MAX_RETRIES=3
RETRY_DELAY=10
DRY_RUN=false
CONTINUE_ON_ERROR=false
STATE_FILE=".deployment-state.json"

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

save_state() {
    local step=$1
    local status=$2
    local error_message=$3
    
    local entry
    entry=$(jq -n \
        --arg step "$step" \
        --arg status "$status" \
        --arg error "$error_message" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{step: $step, status: $status, error: $error, timestamp: $timestamp}')
    
    if [ ! -f "$STATE_FILE" ]; then
        echo '{"deployment_history": []}' > "$STATE_FILE"
    fi
    
    # Atomic update with error handling
    if jq ".deployment_history += [$entry]" "$STATE_FILE" > "$STATE_FILE.tmp"; then
        mv -f "$STATE_FILE.tmp" "$STATE_FILE"
    else
        rm -f "$STATE_FILE.tmp"
        return 1
    fi
}

get_last_successful_step() {
    if [ ! -f "$STATE_FILE" ]; then
        echo "none"
        return
    fi
    
    jq -r '.deployment_history | map(select(.status == "success")) | last | .step // "none"' "$STATE_FILE"
}

retry_command() {
    local step_name=$1
    shift
    local command=("$@")
    
    local attempt=1
    
    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        log_info "[$step_name] Attempt $attempt/$MAX_RETRIES"
        
        if [ "$DRY_RUN" = true ]; then
            log_info "[DRY RUN] Would execute: ${command[*]}"
            save_state "$step_name" "success" ""
            return 0
        fi
        
        if "${command[@]}" 2>&1 | tee /tmp/deploy-output.log; then
            log_success "[$step_name] Completed successfully"
            save_state "$step_name" "success" ""
            return 0
        else
            local error_msg
            error_msg=$(tail -n 5 /tmp/deploy-output.log | tr '\n' ' ')
            log_error "[$step_name] Failed on attempt $attempt"
            
            if [ "$attempt" -lt "$MAX_RETRIES" ]; then
                log_warning "Retrying in $RETRY_DELAY seconds..."
                sleep "$RETRY_DELAY"
                ((attempt++))
            else
                log_error "[$step_name] Max retries reached"
                save_state "$step_name" "failed" "$error_msg"
                
                if [ "$CONTINUE_ON_ERROR" = true ]; then
                    log_warning "Continuing despite error"
                    return 1
                else
                    log_error "Aborting deployment"
                    exit 1
                fi
            fi
        fi
    done
    
    return 0
}

check_azure_status() {
    log_info "Checking Azure service health..."
    
    local status=$(curl -s --connect-timeout 10 --max-time 15 "https://status.azure.com/api/v2/status.json" 2>/dev/null || echo '{"status":"unknown"}')
    local health=$(echo "$status" | jq -r '.status // "unknown"')
    
    if [ "$health" = "healthy" ] || [ "$health" = "unknown" ]; then
        log_success "Azure services are operational"
        return 0
    else
        log_warning "Azure may be experiencing issues: $health"
        log_warning "Check https://status.azure.com for details"
        return 1
    fi
}

handle_rate_limiting() {
    local response_file=$1
    
    if grep -q "429" "$response_file" 2>/dev/null; then
        log_warning "Rate limit detected. Implementing exponential backoff..."
        
        local wait_time=60
        log_info "Waiting $wait_time seconds before retry..."
        sleep $wait_time
        
        return 1
    fi
    
    return 0
}

deploy_with_checkpoints() {
    local resource_group=$1
    local workspace_name=$2
    local parameters_file=$3
    local location=${4:-"eastus"}
    
    local last_step=$(get_last_successful_step)
    log_info "Resuming from last successful step: $last_step"
    
    local skip_until_found=false
    if [ "$last_step" != "none" ]; then
        skip_until_found=true
    fi
    
    if [ "$skip_until_found" = false ] || [ "$last_step" = "none" ]; then
        retry_command "create-resource-group" \
            az group create --name "$resource_group" --location "$location" --output none
    fi
    
    if [ "$skip_until_found" = false ] || [ "$last_step" = "create-resource-group" ]; then
        skip_until_found=false
        retry_command "deploy-api-connections" \
            az deployment group create \
                --resource-group "$resource_group" \
                --template-file deployment/api-connections.json \
                --parameters workspaceName="$workspace_name" \
                --parameters workspaceResourceGroup="$resource_group" \
                --parameters location="$location" \
                --output none
    fi
    
    if [ "$skip_until_found" = false ] || [ "$last_step" = "deploy-api-connections" ]; then
        skip_until_found=false
        log_info "Deploying analytics rules..."
        
        local rule_count=0
        for rule in analytics/*.json; do
            if [ -f "$rule" ]; then
                RULE_NAME=$(basename "$rule" .json)
                
                retry_command "deploy-rule-$RULE_NAME" \
                    az sentinel alert-rule create \
                        --resource-group "$resource_group" \
                        --workspace-name "$workspace_name" \
                        --alert-rule-template "@$rule" \
                        --output none || true
                
                ((rule_count++))
                
                if [ $((rule_count % 5)) -eq 0 ]; then
                    log_info "Deployed $rule_count rules. Pausing to avoid throttling..."
                    sleep 5
                fi
            fi
        done
        
        save_state "deploy-analytics-rules" "success" ""
    fi
    
    if [ "$skip_until_found" = false ] || [ "$last_step" = "deploy-analytics-rules" ]; then
        skip_until_found=false
        log_info "Deploying playbooks..."
        
        for playbook in playbooks/*.json; do
            if [ -f "$playbook" ]; then
                PLAYBOOK_NAME=$(basename "$playbook" .json)
                
                retry_command "deploy-playbook-$PLAYBOOK_NAME" \
                    az deployment group create \
                        --resource-group "$resource_group" \
                        --template-file "$playbook" \
                        --parameters "@$parameters_file" \
                        --parameters logicAppName="$PLAYBOOK_NAME" \
                        --parameters location="$location" \
                        --output none
                
                sleep 3
            fi
        done
        
        save_state "deploy-playbooks" "success" ""
    fi
    
    if [ "$skip_until_found" = false ] || [ "$last_step" = "deploy-playbooks" ]; then
        skip_until_found=false
        retry_command "configure-rbac" \
            bash scripts/configure-rbac.sh "$resource_group" "$workspace_name"
    fi
    
    if [ "$skip_until_found" = false ] || [ "$last_step" = "configure-rbac" ]; then
        skip_until_found=false
        log_info "Importing watchlists..."
        
        for watchlist in watchlists/*.csv; do
            if [ -f "$watchlist" ]; then
                WATCHLIST_NAME=$(basename "$watchlist" .csv)
                
                retry_command "import-watchlist-$WATCHLIST_NAME" \
                    az sentinel watchlist create \
                        --resource-group "$resource_group" \
                        --workspace-name "$workspace_name" \
                        --watchlist-alias "$WATCHLIST_NAME" \
                        --display-name "$WATCHLIST_NAME" \
                        --provider "Sentinel Content Pack" \
                        --source "LocalFile" \
                        --source-type "Local file" \
                        --output none || true
            fi
        done
        
        save_state "import-watchlists" "success" ""
    fi
    
    log_success "Deployment completed successfully!"
    save_state "deployment-complete" "success" ""
}

show_usage() {
    echo "Usage: $0 <resource-group> <workspace-name> [options]"
    echo ""
    echo "Options:"
    echo "  --parameters FILE      Parameters file (default: deployment/parameters.json)"
    echo "  --location LOCATION    Azure region (default: eastus)"
    echo "  --max-retries N        Maximum retries per step (default: 3)"
    echo "  --retry-delay N        Seconds between retries (default: 10)"
    echo "  --dry-run              Show what would be deployed without deploying"
    echo "  --continue-on-error    Continue deployment even if a step fails"
    echo "  --resume               Resume from last successful checkpoint"
    echo "  --reset-state          Reset deployment state and start fresh"
    echo ""
    echo "Examples:"
    echo "  $0 rg-sentinel sentinel-workspace"
    echo "  $0 rg-sentinel sentinel-workspace --dry-run"
    echo "  $0 rg-sentinel sentinel-workspace --resume"
    echo "  $0 rg-sentinel sentinel-workspace --max-retries 5"
}

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Resilient Deployment with Retry${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

if [ "$#" -lt 2 ]; then
    show_usage
    exit 1
fi

RESOURCE_GROUP=$1
WORKSPACE_NAME=$2
shift 2

PARAMETERS_FILE="deployment/parameters.json"
LOCATION="eastus"
RESET_STATE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --parameters)
            PARAMETERS_FILE="$2"
            shift 2
            ;;
        --location)
            LOCATION="$2"
            shift 2
            ;;
        --max-retries)
            MAX_RETRIES="$2"
            shift 2
            ;;
        --retry-delay)
            RETRY_DELAY="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --continue-on-error)
            CONTINUE_ON_ERROR=true
            shift
            ;;
        --reset-state)
            RESET_STATE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

if [ "$RESET_STATE" = true ]; then
    log_warning "Resetting deployment state..."
    rm -f "$STATE_FILE"
    log_success "State reset complete"
fi

if [ "$DRY_RUN" = true ]; then
    log_warning "DRY RUN MODE - No actual changes will be made"
fi

log_info "Configuration:"
log_info "  Resource Group: $RESOURCE_GROUP"
log_info "  Workspace: $WORKSPACE_NAME"
log_info "  Parameters: $PARAMETERS_FILE"
log_info "  Location: $LOCATION"
log_info "  Max Retries: $MAX_RETRIES"
log_info "  Retry Delay: ${RETRY_DELAY}s"
echo ""

check_azure_status

deploy_with_checkpoints "$RESOURCE_GROUP" "$WORKSPACE_NAME" "$PARAMETERS_FILE" "$LOCATION"

log_success "All done!"

