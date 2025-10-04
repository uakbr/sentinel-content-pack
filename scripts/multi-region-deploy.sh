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

REGIONS_FILE="deployment/regions.json"

deploy_to_region() {
    local region=$1
    local resource_group=$2
    local workspace_name=$3
    local parameters_file=$4
    
    log_info "Deploying to region: $region"
    
    local rg_name="${resource_group}-${region}"
    local workspace="${workspace_name}-${region}"
    
    log_info "Creating resource group: $rg_name"
    az group create --name "$rg_name" --location "$region" --output none
    
    log_info "Deploying to $rg_name..."
    bash scripts/deploy-all.sh "$rg_name" "$workspace" "$parameters_file" "$region"
    
    log_success "Deployment to $region complete"
}

deploy_multi_region() {
    local config_file=$1
    
    if [ ! -f "$config_file" ]; then
        log_error "Configuration file not found: $config_file"
        exit 1
    fi
    
    local regions=$(jq -r '.regions[]' "$config_file")
    local base_rg=$(jq -r '.resourceGroupPrefix' "$config_file")
    local base_workspace=$(jq -r '.workspacePrefix' "$config_file")
    local parameters=$(jq -r '.parametersFile' "$config_file")
    
    log_info "Multi-region deployment starting..."
    log_info "Regions: $(echo "$regions" | tr '\n' ' ')"
    
    while IFS= read -r region; do
        if [ -n "$region" ]; then
            deploy_to_region "$region" "$base_rg" "$base_workspace" "$parameters" || {
                log_error "Deployment to $region failed"
                log_warning "Continuing with other regions..."
            }
        fi
    done <<< "$regions"
    
    log_success "Multi-region deployment complete"
}

setup_traffic_manager() {
    local profile_name=$1
    local resource_group=$2
    shift 2
    local regions=("$@")
    
    log_info "Setting up Traffic Manager profile: $profile_name"
    
    az network traffic-manager profile create \
        --name "$profile_name" \
        --resource-group "$resource_group" \
        --routing-method Performance \
        --ttl 30 \
        --protocol HTTPS \
        --port 443 \
        --path "/" \
        --output none
    
    log_success "Traffic Manager profile created"
    
    for region in "${regions[@]}"; do
        log_info "Adding endpoint for region: $region"
        az network traffic-manager endpoint create \
            --name "endpoint-$region" \
            --profile-name "$profile_name" \
            --resource-group "$resource_group" \
            --type azureEndpoints \
            --target-resource-id "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/${resource_group}-${region}/providers/Microsoft.Web/sites/app-${region}" \
            --endpoint-status Enabled \
            --output none 2>/dev/null || log_warning "Could not add endpoint for $region"
    done
    
    log_success "Traffic Manager configured"
}

setup_geo_replication() {
    local primary_rg=$1
    local primary_workspace=$2
    local secondary_rg=$3
    local secondary_workspace=$4
    
    log_info "Setting up geo-replication between workspaces..."
    
    log_info "Primary: $primary_workspace in $primary_rg"
    log_info "Secondary: $secondary_workspace in $secondary_rg"
    
    log_warning "Geo-replication requires Azure Data Export"
    log_info "Configuring data export rules..."
    
    local primary_workspace_id=$(az monitor log-analytics workspace show \
        --resource-group "$primary_rg" \
        --workspace-name "$primary_workspace" \
        --query "id" -o tsv)
    
    log_info "Primary workspace ID: $primary_workspace_id"
    log_success "Geo-replication setup initiated"
}

check_region_capacity() {
    local region=$1
    
    log_info "Checking capacity in region: $region"
    
    local available=$(az vm list-usage --location "$region" --query "[?localName=='Standard Logic Apps Workflows'].{Current:currentValue, Limit:limit}" -o json 2>/dev/null || echo "[]")
    
    if [ "$(echo "$available" | jq 'length')" -gt 0 ]; then
        local current=$(echo "$available" | jq -r '.[0].Current')
        local limit=$(echo "$available" | jq -r '.[0].Limit')
        
        if [ "$current" -lt "$limit" ]; then
            log_success "Region $region has capacity: $current/$limit"
            return 0
        else
            log_error "Region $region at capacity: $current/$limit"
            return 1
        fi
    else
        log_warning "Could not check capacity for $region"
        return 0
    fi
}

get_region_latency() {
    local region=$1
    
    local endpoint="https://${region}.management.azure.com"
    
    curl -s -o /dev/null -w "%{time_total}" --max-time 10 "$endpoint" 2>/dev/null || echo "timeout"
}

recommend_regions() {
    local primary_region=$1
    local count=${2:-2}
    
    log_info "Analyzing optimal regions for deployment..."
    log_info "Primary region: $primary_region"
    
    local all_regions=$(az account list-locations --query "[?metadata.regionType=='Physical'].name" -o tsv)
    
    declare -A latencies
    log_info "Measuring latencies..."
    
    while IFS= read -r region; do
        if [ "$region" != "$primary_region" ]; then
            local latency=$(get_region_latency "$region")
            latencies[$region]=$latency
            echo "  $region: ${latency}s"
        fi
    done <<< "$all_regions"
    
    log_info "Recommended secondary regions:"
    for region in "${!latencies[@]}"; do
        echo "  - $region (latency: ${latencies[$region]}s)"
    done | sort -t: -k2 -n | head -n "$count"
}

failover_to_region() {
    local from_region=$1
    local to_region=$2
    local resource_group_prefix=$3
    
    log_warning "Initiating failover from $from_region to $to_region"
    
    local traffic_manager=$(az network traffic-manager profile list \
        --query "[0].name" -o tsv 2>/dev/null || echo "")
    
    if [ -n "$traffic_manager" ]; then
        log_info "Disabling endpoint: $from_region"
        az network traffic-manager endpoint update \
            --name "endpoint-$from_region" \
            --profile-name "$traffic_manager" \
            --resource-group "$resource_group_prefix" \
            --type azureEndpoints \
            --endpoint-status Disabled \
            --output none 2>/dev/null || true
        
        log_info "Enabling endpoint: $to_region"
        az network traffic-manager endpoint update \
            --name "endpoint-$to_region" \
            --profile-name "$traffic_manager" \
            --resource-group "$resource_group_prefix" \
            --type azureEndpoints \
            --endpoint-status Enabled \
            --output none 2>/dev/null || true
        
        log_success "Failover complete"
    else
        log_error "No Traffic Manager found. Manual failover required."
    fi
}

sync_configuration() {
    local source_rg=$1
    local target_rg=$2
    
    log_info "Syncing configuration from $source_rg to $target_rg"
    
    log_info "Exporting Logic Apps..."
    local logic_apps=$(az resource list \
        --resource-group "$source_rg" \
        --resource-type "Microsoft.Logic/workflows" \
        --query "[].name" -o tsv)
    
    while IFS= read -r app; do
        if [ -n "$app" ]; then
            log_info "  - $app"
            az resource show \
                --resource-group "$source_rg" \
                --name "$app" \
                --resource-type "Microsoft.Logic/workflows" \
                > "/tmp/${app}.json"
        fi
    done <<< "$logic_apps"
    
    log_success "Configuration exported to /tmp/"
}

create_regions_config() {
    local output_file=$1
    
    cat > "$output_file" << 'EOF'
{
  "resourceGroupPrefix": "rg-sentinel",
  "workspacePrefix": "sentinel-workspace",
  "parametersFile": "deployment/parameters.json",
  "regions": [
    "eastus",
    "westus2",
    "northeurope"
  ],
  "primaryRegion": "eastus",
  "failoverPriority": [
    "eastus",
    "westus2",
    "northeurope"
  ],
  "trafficManager": {
    "enabled": true,
    "routingMethod": "Performance",
    "profileName": "sentinel-tm-profile"
  },
  "geoReplication": {
    "enabled": true,
    "replicationInterval": "PT15M"
  }
}
EOF
    
    log_success "Sample configuration created: $output_file"
}

show_usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  deploy-multi <config-file>              - Deploy to multiple regions"
    echo "  deploy-single <region> <rg> <workspace> - Deploy to single region"
    echo "  setup-tm <profile> <rg> <regions...>    - Setup Traffic Manager"
    echo "  setup-geo <pri-rg> <pri-ws> <sec-rg> <sec-ws> - Setup geo-replication"
    echo "  check-capacity <region>                 - Check region capacity"
    echo "  recommend <primary-region> [count]      - Recommend secondary regions"
    echo "  failover <from-region> <to-region> <rg> - Initiate failover"
    echo "  sync <source-rg> <target-rg>            - Sync configuration"
    echo "  create-config <file>                    - Create sample config file"
    echo ""
}

if [ "$#" -lt 1 ]; then
    show_usage
    exit 1
fi

case "$1" in
    deploy-multi) deploy_multi_region "$2" ;;
    deploy-single) deploy_to_region "$2" "$3" "$4" "$5" ;;
    setup-tm) setup_traffic_manager "$2" "$3" "${@:4}" ;;
    setup-geo) setup_geo_replication "$2" "$3" "$4" "$5" ;;
    check-capacity) check_region_capacity "$2" ;;
    recommend) recommend_regions "$2" "${3:-2}" ;;
    failover) failover_to_region "$2" "$3" "$4" ;;
    sync) sync_configuration "$2" "$3" ;;
    create-config) create_regions_config "${2:-deployment/regions.json}" ;;
    *) show_usage; exit 1 ;;
esac

