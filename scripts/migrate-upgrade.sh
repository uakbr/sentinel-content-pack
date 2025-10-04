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

BACKUP_DIR=".migration-backups"

check_version() {
    local version_file=".version"
    
    if [ ! -f "$version_file" ]; then
        echo "unknown"
        return
    fi
    
    cat "$version_file"
}

create_migration_backup() {
    local resource_group=$1
    local backup_name="${BACKUP_DIR}/migration_$(date +%Y%m%d_%H%M%S)"
    
    mkdir -p "$backup_name"
    
    log_info "Creating migration backup..."
    
    az resource list \
        --resource-group "$resource_group" \
        > "$backup_name/resources.json"
    
    local logic_apps=$(az resource list \
        --resource-group "$resource_group" \
        --resource-type "Microsoft.Logic/workflows" \
        --query "[].name" -o tsv)
    
    mkdir -p "$backup_name/logic-apps"
    while IFS= read -r app; do
        if [ -n "$app" ]; then
            az resource show \
                --resource-group "$resource_group" \
                --name "$app" \
                --resource-type "Microsoft.Logic/workflows" \
                > "$backup_name/logic-apps/${app}.json"
        fi
    done <<< "$logic_apps"
    
    log_success "Backup created: $backup_name"
    echo "$backup_name"
}

upgrade_logic_app() {
    local resource_group=$1
    local logic_app=$2
    local new_definition=$3
    
    log_info "Upgrading Logic App: $logic_app"
    
    local backup_file="/tmp/${logic_app}_backup_$(date +%Y%m%d_%H%M%S).json"
    
    az resource show \
        --resource-group "$resource_group" \
        --name "$logic_app" \
        --resource-type "Microsoft.Logic/workflows" \
        > "$backup_file"
    
    log_info "  Backup saved: $backup_file"
    
    log_info "  Applying new definition..."
    az deployment group create \
        --resource-group "$resource_group" \
        --template-file "$new_definition" \
        --output none
    
    log_success "  Upgrade complete"
}

export_configuration() {
    local resource_group=$1
    local output_dir=${2:-"./export"}
    
    log_warning "Export functionality is not yet implemented"
    log_info "Planned: Export Logic Apps and connections to: $output_dir"
    return 1
}

import_configuration() {
    local source_dir=$1
    local resource_group=$2
    
    log_warning "Import functionality is not yet implemented"
    log_info "Planned: Import configuration from: $source_dir to $resource_group"
    return 1
}

validate_migration() {
    local resource_group=$1
    local workspace_name=${2:-""}
    
    log_info "Validating migration..."
    
    if [ -z "$workspace_name" ]; then
        log_error "Workspace name required for validation"
        return 1
    fi
    
    if bash scripts/validate-deployment.sh "$resource_group" "$workspace_name"; then
        log_success "Migration validation passed"
        return 0
    else
        log_error "Migration validation failed"
        return 1
    fi
}

show_usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  check-version                           - Show current version"
    echo "  backup <rg>                             - Create migration backup"
    echo "  export <rg> [output-dir]                - Export configuration"
    echo "  import <source-dir> <rg>                - Import configuration"
    echo "  validate <rg> <workspace>               - Validate migration"
    echo ""
    echo "Note: v1 to v2 migration is not yet implemented."
    echo ""
}

if [ "$#" -lt 1 ]; then
    show_usage
    exit 1
fi

case "$1" in
    check-version) check_version ;;
    backup) create_migration_backup "$2" ;;
    export) export_configuration "$2" "$3" ;;
    import) import_configuration "$2" "$3" ;;
    validate) validate_migration "$2" "$3" ;;
    *) show_usage; exit 1 ;;
esac

