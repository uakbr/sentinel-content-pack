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

create_keyvault() {
    local resource_group=$1
    local keyvault_name=$2
    local location=$3
    
    log_info "Creating Key Vault: $keyvault_name"
    
    if az keyvault show --name "$keyvault_name" &>/dev/null; then
        log_warning "Key Vault already exists"
        return 0
    fi
    
    az keyvault create \
        --name "$keyvault_name" \
        --resource-group "$resource_group" \
        --location "$location" \
        --enable-rbac-authorization false \
        --enabled-for-template-deployment true \
        --output none
    
    log_success "Key Vault created"
}

store_secret() {
    local keyvault_name=$1
    local secret_name=$2
    local secret_value=$3
    
    log_info "Storing secret: $secret_name"
    
    az keyvault secret set \
        --vault-name "$keyvault_name" \
        --name "$secret_name" \
        --value "$secret_value" \
        --output none
    
    log_success "Secret stored"
}

get_secret() {
    local keyvault_name=$1
    local secret_name=$2
    
    az keyvault secret show \
        --vault-name "$keyvault_name" \
        --name "$secret_name" \
        --query "value" -o tsv 2>/dev/null || echo ""
}

rotate_secret() {
    local keyvault_name=$1
    local secret_name=$2
    local new_value=$3
    
    log_info "Rotating secret: $secret_name"
    
    local old_value=$(get_secret "$keyvault_name" "$secret_name")
    
    if [ -n "$old_value" ]; then
        store_secret "$keyvault_name" "${secret_name}-old" "$old_value"
    fi
    
    store_secret "$keyvault_name" "$secret_name" "$new_value"
    
    log_success "Secret rotated. Old value backed up as ${secret_name}-old"
}

grant_access() {
    local keyvault_name=$1
    local principal_id=$2
    local permissions=${3:-"get list"}
    
    log_info "Granting access to principal: $principal_id"
    
    az keyvault set-policy \
        --name "$keyvault_name" \
        --object-id "$principal_id" \
        --secret-permissions "$permissions" \
        --output none
    
    log_success "Access granted"
}

setup_for_deployment() {
    local resource_group=$1
    local keyvault_name=$2
    local location=$3
    
    create_keyvault "$resource_group" "$keyvault_name" "$location"
    
    log_info "Enter secrets for deployment (press Enter to skip):"
    
    read -p "Teams Webhook URL: " teams_webhook
    if [ -n "$teams_webhook" ]; then
        store_secret "$keyvault_name" "teams-webhook-url" "$teams_webhook"
    fi
    
    read -p "Decision Engine URL: " decision_engine
    if [ -n "$decision_engine" ]; then
        store_secret "$keyvault_name" "decision-engine-url" "$decision_engine"
    fi
    
    read -p "ServiceNow API Key: " servicenow_key
    if [ -n "$servicenow_key" ]; then
        store_secret "$keyvault_name" "servicenow-api-key" "$servicenow_key"
    fi
    
    read -p "Splunk HEC Token: " splunk_token
    if [ -n "$splunk_token" ]; then
        store_secret "$keyvault_name" "splunk-hec-token" "$splunk_token"
    fi
    
    log_success "Secrets configured in Key Vault"
}

generate_parameters_with_keyvault() {
    local keyvault_name=$1
    local output_file=$2
    
    local keyvault_id=$(az keyvault show --name "$keyvault_name" --query "id" -o tsv)
    
    cat > "$output_file" << EOF
{
  "\$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "teamsWebhookUrl": {
      "reference": {
        "keyVault": {
          "id": "$keyvault_id"
        },
        "secretName": "teams-webhook-url"
      }
    },
    "decisionEngineUrl": {
      "reference": {
        "keyVault": {
          "id": "$keyvault_id"
        },
        "secretName": "decision-engine-url"
      }
    }
  }
}
EOF
    
    log_success "Generated parameters file with Key Vault references: $output_file"
}

scan_for_secrets() {
    log_warning "Scanning for exposed secrets in files..."
    
    local patterns=(
        "https://hooks\\.slack\\.com/services/[A-Z0-9/]+"
        "https://.*\\.webhook\\.office\\.com/webhookb2/[a-f0-9-]+@[a-f0-9-]+/IncomingWebhook/[a-f0-9]+/[a-f0-9-]+"
        "Bearer [A-Za-z0-9_\\.\\-]{40,}"
        "ghp_[A-Za-z0-9]{40}"
        "ghs_[A-Za-z0-9]{40}"
        "gho_[A-Za-z0-9]{40}"
        "AIza[0-9A-Za-z_\\-]{35}"
        "AKIA[0-9A-Z]{16}"
    )
    
    local found=false
    for pattern in "${patterns[@]}"; do
        if grep -rE "$pattern" . --exclude-dir=.git --exclude-dir=node_modules 2>/dev/null; then
            log_error "Potential secret found matching pattern: $pattern"
            found=true
        fi
    done
    
    if [ "$found" = false ]; then
        log_success "No exposed secrets detected"
    else
        log_error "Secrets detected! Move them to Key Vault immediately"
    fi
}

encrypt_file() {
    local input_file=$1
    local output_file="${input_file}.enc"
    local password=$2
    
    if [ -z "$password" ]; then
        read -sp "Enter encryption password: " password
        echo ""
    fi
    
    # Use PBKDF2 for key derivation instead of deprecated -k
    openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -in "$input_file" -out "$output_file" -pass "pass:$password"
    log_success "File encrypted: $output_file"
}

decrypt_file() {
    local input_file=$1
    local output_file="${input_file%.enc}"
    local password=$2
    
    if [ -z "$password" ]; then
        read -sp "Enter decryption password: " password
        echo ""
    fi
    
    # Use PBKDF2 for key derivation instead of deprecated -k
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -in "$input_file" -out "$output_file" -pass "pass:$password"
    log_success "File decrypted: $output_file"
}

list_secrets() {
    local keyvault_name=$1
    
    log_info "Secrets in Key Vault: $keyvault_name"
    az keyvault secret list --vault-name "$keyvault_name" --query "[].{Name:name, Updated:attributes.updated}" -o table
}

backup_secrets() {
    local keyvault_name=$1
    local backup_file=$2
    
    log_info "Backing up secrets from: $keyvault_name"
    
    local secrets=$(az keyvault secret list --vault-name "$keyvault_name" --query "[].name" -o tsv)
    
    echo "{" > "$backup_file"
    local first=true
    while IFS= read -r secret; do
        if [ "$first" = false ]; then
            echo "," >> "$backup_file"
        fi
        first=false
        
        local value=$(get_secret "$keyvault_name" "$secret")
        echo "  \"$secret\": \"$value\"" >> "$backup_file"
    done <<< "$secrets"
    echo "}" >> "$backup_file"
    
    log_success "Secrets backed up to: $backup_file"
    log_warning "Protect this file carefully!"
}

show_usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  create-vault <rg> <vault-name> <location>   - Create Key Vault"
    echo "  store <vault-name> <secret-name> <value>    - Store a secret"
    echo "  get <vault-name> <secret-name>              - Retrieve a secret"
    echo "  rotate <vault-name> <secret-name> <value>   - Rotate a secret"
    echo "  grant <vault-name> <principal-id>           - Grant access to principal"
    echo "  setup <rg> <vault-name> <location>          - Interactive setup"
    echo "  generate-params <vault-name> <output-file>  - Generate ARM parameters"
    echo "  scan                                        - Scan for exposed secrets"
    echo "  list <vault-name>                           - List all secrets"
    echo "  backup <vault-name> <backup-file>           - Backup secrets to file"
    echo "  encrypt <file>                              - Encrypt file"
    echo "  decrypt <file.enc>                          - Decrypt file"
    echo ""
}

if [ "$#" -lt 1 ]; then
    show_usage
    exit 1
fi

case "$1" in
    create-vault) create_keyvault "$2" "$3" "$4" ;;
    store) store_secret "$2" "$3" "$4" ;;
    get) get_secret "$2" "$3" ;;
    rotate) rotate_secret "$2" "$3" "$4" ;;
    grant) grant_access "$2" "$3" "$4" ;;
    setup) setup_for_deployment "$2" "$3" "$4" ;;
    generate-params) generate_parameters_with_keyvault "$2" "$3" ;;
    scan) scan_for_secrets ;;
    list) list_secrets "$2" ;;
    backup) backup_secrets "$2" "$3" ;;
    encrypt) encrypt_file "$2" "$3" ;;
    decrypt) decrypt_file "$2" "$3" ;;
    *) show_usage; exit 1 ;;
esac

