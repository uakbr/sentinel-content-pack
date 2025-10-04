#!/bin/bash

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ERRORS=0
WARNINGS=0
CHECKS_PASSED=0
CHECKS_TOTAL=0

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    ((ERRORS++))
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    ((WARNINGS++))
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((CHECKS_PASSED++))
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

check_command() {
    local cmd=$1
    local install_hint=$2
    ((CHECKS_TOTAL++))
    
    if command -v "$cmd" &> /dev/null; then
        log_success "Found $cmd"
        return 0
    else
        log_error "$cmd not found. Install: $install_hint"
        return 1
    fi
}

check_az_extension() {
    local ext=$1
    ((CHECKS_TOTAL++))
    
    if az extension show --name "$ext" &>/dev/null; then
        log_success "Azure CLI extension '$ext' installed"
        return 0
    else
        log_warning "Azure CLI extension '$ext' not installed. Installing..."
        az extension add --name "$ext" --only-show-errors || {
            log_error "Failed to install extension '$ext'"
            return 1
        }
        log_success "Installed extension '$ext'"
        return 0
    fi
}

check_az_login() {
    ((CHECKS_TOTAL++))
    
    if az account show &>/dev/null; then
        ACCOUNT=$(az account show --query name -o tsv)
        SUBSCRIPTION_ID=$(az account show --query id -o tsv)
        TENANT_ID=$(az account show --query tenantId -o tsv)
        USER=$(az account show --query user.name -o tsv)
        
        log_success "Authenticated as: $USER"
        log_info "Subscription: $ACCOUNT ($SUBSCRIPTION_ID)"
        log_info "Tenant: $TENANT_ID"
        return 0
    else
        log_error "Not logged into Azure. Run: az login"
        return 1
    fi
}

check_permissions() {
    local resource_group=$1
    ((CHECKS_TOTAL++))
    
    log_info "Checking permissions for resource group: $resource_group"
    
    local user_object_id=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || echo "")
    if [ -z "$user_object_id" ]; then
        log_warning "Cannot verify permissions (not a user principal)"
        return 0
    fi
    
    local has_contributor=$(az role assignment list \
        --assignee "$user_object_id" \
        --query "[?roleDefinitionName=='Contributor' || roleDefinitionName=='Owner'].roleDefinitionName" \
        -o tsv 2>/dev/null || echo "")
    
    if [ -n "$has_contributor" ]; then
        log_success "User has required permissions"
        return 0
    else
        log_error "User lacks Contributor or Owner role on subscription/resource group"
        return 1
    fi
}

check_quota() {
    local location=$1
    ((CHECKS_TOTAL++))
    
    log_info "Checking resource quotas in $location"
    
    local logic_apps_quota=$(az vm list-usage --location "$location" --query "[?localName=='Standard Logic Apps Workflows'].currentValue" -o tsv 2>/dev/null || echo "0")
    local logic_apps_limit=$(az vm list-usage --location "$location" --query "[?localName=='Standard Logic Apps Workflows'].limit" -o tsv 2>/dev/null || echo "100")
    
    if [ "$logic_apps_quota" -lt "$logic_apps_limit" ]; then
        log_success "Quota available for Logic Apps ($logic_apps_quota / $logic_apps_limit)"
        return 0
    else
        log_warning "Logic Apps quota may be exhausted ($logic_apps_quota / $logic_apps_limit)"
        return 0
    fi
}

check_resource_providers() {
    ((CHECKS_TOTAL++))
    
    local required_providers=(
        "Microsoft.Logic"
        "Microsoft.Web"
        "Microsoft.OperationalInsights"
        "Microsoft.SecurityInsights"
        "Microsoft.OperationsManagement"
    )
    
    local all_registered=true
    for provider in "${required_providers[@]}"; do
        local state=$(az provider show --namespace "$provider" --query "registrationState" -o tsv 2>/dev/null || echo "NotRegistered")
        
        if [ "$state" != "Registered" ]; then
            log_warning "Provider $provider not registered. Registering..."
            az provider register --namespace "$provider" --wait --only-show-errors || {
                log_error "Failed to register provider $provider"
                all_registered=false
            }
        fi
    done
    
    if [ "$all_registered" = true ]; then
        log_success "All required resource providers registered"
        return 0
    else
        return 1
    fi
}

check_resource_locks() {
    local resource_group=$1
    ((CHECKS_TOTAL++))
    
    if ! az group show --name "$resource_group" &>/dev/null; then
        log_info "Resource group doesn't exist yet (will be created)"
        return 0
    fi
    
    local locks=$(az lock list --resource-group "$resource_group" --query "length([])" -o tsv 2>/dev/null || echo "0")
    
    if [ "$locks" -eq 0 ]; then
        log_success "No resource locks found"
        return 0
    else
        log_error "Found $locks resource lock(s) that may prevent deployment"
        az lock list --resource-group "$resource_group" --query "[].{Name:name, Level:level}" -o table
        return 1
    fi
}

check_azure_policy() {
    local resource_group=$1
    local location=$2
    ((CHECKS_TOTAL++))
    
    log_info "Checking for restrictive Azure Policies..."
    
    local deny_policies=$(az policy state list \
        --query "[?policyDefinitionAction=='deny' && complianceState=='NonCompliant'].policyDefinitionName" \
        -o tsv 2>/dev/null | wc -l || echo "0")
    
    if [ "$deny_policies" -eq 0 ]; then
        log_success "No blocking Azure Policies detected"
        return 0
    else
        log_warning "Found $deny_policies deny policies that may affect deployment"
        return 0
    fi
}

check_network_connectivity() {
    ((CHECKS_TOTAL++))
    
    log_info "Checking network connectivity to Azure..."
    
    if curl -s --connect-timeout 5 https://management.azure.com &>/dev/null; then
        log_success "Network connectivity to Azure verified"
        return 0
    else
        log_error "Cannot reach Azure endpoints. Check network/proxy settings"
        return 1
    fi
}

check_files() {
    ((CHECKS_TOTAL++))
    
    local missing_files=()
    
    [ ! -d "analytics" ] && missing_files+=("analytics/")
    [ ! -d "playbooks" ] && missing_files+=("playbooks/")
    [ ! -d "watchlists" ] && missing_files+=("watchlists/")
    [ ! -d "deployment" ] && missing_files+=("deployment/")
    [ ! -f "deployment/api-connections.json" ] && missing_files+=("deployment/api-connections.json")
    
    if [ ${#missing_files[@]} -eq 0 ]; then
        log_success "All required directories and files present"
        return 0
    else
        log_error "Missing files/directories: ${missing_files[*]}"
        return 1
    fi
}

validate_json_files() {
    ((CHECKS_TOTAL++))
    
    log_info "Validating JSON files..."
    
    local invalid_files=()
    while IFS= read -r file; do
        if ! jq empty "$file" 2>/dev/null; then
            invalid_files+=("$file")
        fi
    done < <(find . -name "*.json" -not -path "*/node_modules/*" -not -path "*/.git/*")
    
    if [ ${#invalid_files[@]} -eq 0 ]; then
        log_success "All JSON files are valid"
        return 0
    else
        log_error "Invalid JSON files found:"
        printf '%s\n' "${invalid_files[@]}"
        return 1
    fi
}

validate_csv_files() {
    ((CHECKS_TOTAL++))
    
    log_info "Validating CSV files..."
    
    local invalid_files=()
    for file in watchlists/*.csv; do
        if [ -f "$file" ]; then
            if ! head -n 1 "$file" | grep -q ","; then
                invalid_files+=("$file")
            fi
        fi
    done
    
    if [ ${#invalid_files[@]} -eq 0 ]; then
        log_success "All CSV files are valid"
        return 0
    else
        log_error "Invalid CSV files found:"
        printf '%s\n' "${invalid_files[@]}"
        return 1
    fi
}

check_sentinel_workspace() {
    local resource_group=$1
    local workspace_name=$2
    ((CHECKS_TOTAL++))
    
    log_info "Checking Sentinel workspace..."
    
    if ! az group show --name "$resource_group" &>/dev/null; then
        log_info "Resource group doesn't exist (will be created)"
        return 0
    fi
    
    if ! az monitor log-analytics workspace show \
        --resource-group "$resource_group" \
        --workspace-name "$workspace_name" &>/dev/null; then
        log_warning "Workspace '$workspace_name' not found. Must be created first."
        return 0
    fi
    
    local sentinel_enabled=$(az sentinel workspace-manager list \
        --resource-group "$resource_group" \
        --workspace-name "$workspace_name" \
        --query "length([])" -o tsv 2>/dev/null || echo "unknown")
    
    if [ "$sentinel_enabled" != "unknown" ]; then
        log_success "Sentinel workspace exists and is accessible"
        return 0
    else
        log_info "Workspace exists (Sentinel status unknown)"
        return 0
    fi
}

check_parameters_file() {
    local params_file=$1
    ((CHECKS_TOTAL++))
    
    if [ ! -f "$params_file" ]; then
        log_error "Parameters file not found: $params_file"
        log_info "Create from template: cp deployment/parameters.template.json $params_file"
        return 1
    fi
    
    if ! jq empty "$params_file" 2>/dev/null; then
        log_error "Parameters file is not valid JSON"
        return 1
    fi
    
    local required_params=(
        ".parameters.workspaceName.value"
        ".parameters.workspaceResourceGroup.value"
        ".parameters.location.value"
    )
    
    local missing_params=()
    for param in "${required_params[@]}"; do
        local value=$(jq -r "$param" "$params_file" 2>/dev/null || echo "null")
        if [ "$value" = "null" ] || [[ "$value" = "YOUR_"* ]]; then
            missing_params+=("$param")
        fi
    done
    
    if [ ${#missing_params[@]} -eq 0 ]; then
        log_success "Parameters file is valid and complete"
        return 0
    else
        log_error "Parameters file has missing/placeholder values:"
        printf '%s\n' "${missing_params[@]}"
        return 1
    fi
}

check_naming_conflicts() {
    local resource_group=$1
    ((CHECKS_TOTAL++))
    
    if ! az group show --name "$resource_group" &>/dev/null; then
        log_success "No naming conflicts (resource group doesn't exist)"
        return 0
    fi
    
    local existing_logic_apps=$(az resource list \
        --resource-group "$resource_group" \
        --resource-type "Microsoft.Logic/workflows" \
        --query "length([])" -o tsv 2>/dev/null || echo "0")
    
    if [ "$existing_logic_apps" -gt 0 ]; then
        log_warning "Found $existing_logic_apps existing Logic App(s). May cause naming conflicts."
        log_info "Existing deployments will be updated, not recreated."
        return 0
    else
        log_success "No existing Logic Apps found"
        return 0
    fi
}

check_region_availability() {
    local location=$1
    ((CHECKS_TOTAL++))
    
    log_info "Checking region availability for: $location"
    
    local available=$(az account list-locations \
        --query "[?name=='$location'].name" -o tsv 2>/dev/null || echo "")
    
    if [ -n "$available" ]; then
        log_success "Region '$location' is available"
        return 0
    else
        log_error "Region '$location' is not available in this subscription"
        log_info "Available regions: $(az account list-locations --query '[].name' -o tsv | tr '\n' ' ')"
        return 1
    fi
}

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Pre-Flight Checks${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

if [ "$#" -lt 2 ]; then
    echo -e "${YELLOW}Usage: $0 <resource-group> <workspace-name> [parameters-file] [location]${NC}"
    exit 1
fi

RESOURCE_GROUP=$1
WORKSPACE_NAME=$2
PARAMETERS_FILE=${3:-"deployment/parameters.json"}
LOCATION=${4:-"eastus"}

echo -e "${BLUE}Configuration:${NC}"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  Workspace: $WORKSPACE_NAME"
echo "  Parameters: $PARAMETERS_FILE"
echo "  Location: $LOCATION"
echo ""

echo -e "${BLUE}[1/17] Checking prerequisites...${NC}"
check_command "az" "https://docs.microsoft.com/cli/azure/install-azure-cli"
check_command "jq" "brew install jq (macOS) or apt-get install jq (Linux)"
check_command "curl" "should be pre-installed"
check_command "git" "https://git-scm.com/downloads"

echo -e "\n${BLUE}[2/17] Checking Azure CLI login...${NC}"
check_az_login

echo -e "\n${BLUE}[3/17] Checking Azure CLI extensions...${NC}"
check_az_extension "sentinel"

echo -e "\n${BLUE}[4/17] Checking permissions...${NC}"
check_permissions "$RESOURCE_GROUP"

echo -e "\n${BLUE}[5/17] Checking resource providers...${NC}"
check_resource_providers

echo -e "\n${BLUE}[6/17] Checking region availability...${NC}"
check_region_availability "$LOCATION"

echo -e "\n${BLUE}[7/17] Checking quotas...${NC}"
check_quota "$LOCATION"

echo -e "\n${BLUE}[8/17] Checking resource locks...${NC}"
check_resource_locks "$RESOURCE_GROUP"

echo -e "\n${BLUE}[9/17] Checking Azure Policies...${NC}"
check_azure_policy "$RESOURCE_GROUP" "$LOCATION"

echo -e "\n${BLUE}[10/17] Checking network connectivity...${NC}"
check_network_connectivity

echo -e "\n${BLUE}[11/17] Checking repository files...${NC}"
check_files

echo -e "\n${BLUE}[12/17] Validating JSON files...${NC}"
validate_json_files

echo -e "\n${BLUE}[13/17] Validating CSV files...${NC}"
validate_csv_files

echo -e "\n${BLUE}[14/17] Checking parameters file...${NC}"
check_parameters_file "$PARAMETERS_FILE"

echo -e "\n${BLUE}[15/17] Checking Sentinel workspace...${NC}"
check_sentinel_workspace "$RESOURCE_GROUP" "$WORKSPACE_NAME"

echo -e "\n${BLUE}[16/17] Checking for naming conflicts...${NC}"
check_naming_conflicts "$RESOURCE_GROUP"

echo -e "\n${BLUE}[17/17] Final validation...${NC}"
log_info "Checks complete"

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Pre-Flight Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Total Checks: $CHECKS_TOTAL"
echo -e "Passed:       ${GREEN}$CHECKS_PASSED${NC}"
echo -e "Warnings:     ${YELLOW}$WARNINGS${NC}"
echo -e "Errors:       ${RED}$ERRORS${NC}"
echo ""

if [ $ERRORS -gt 0 ]; then
    echo -e "${RED}Pre-flight checks FAILED. Fix errors before deploying.${NC}"
    exit 1
elif [ $WARNINGS -gt 0 ]; then
    echo -e "${YELLOW}Pre-flight checks passed with warnings.${NC}"
    echo -e "${YELLOW}Review warnings before proceeding.${NC}"
    exit 0
else
    echo -e "${GREEN}All pre-flight checks PASSED. Ready to deploy!${NC}"
    exit 0
fi

