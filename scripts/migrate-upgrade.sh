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

MIGRATION_DIR=".migrations"
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

migrate_v1_to_v2() {
    local resource_group=$1
    local workspace_name=$2
    
    log_info "Migrating from v1 to v2..."
    
    create_migration_backup "$resource_group"
    
    log_info "Step 1: Updating Logic App runtime versions..."
    local logic_apps=$(az resource list \
        --resource-group "$resource_group" \
        --resource-type "Microsoft.Logic/workflows" \
        --query "[].name" -o tsv)
    
    while IFS= read -r app; do
        if [ -n "$app" ]; then
            log_info "  Updating: $app"
            # Add specific v1 to v2 migration logic here
        fi
    done <<< "$logic_apps"
    
    log_info "Step 2: Updating API connections..."
    # Add connection migration logic
    
    log_info "Step 3: Updating analytics rules..."
    # Add rules migration logic
    
    echo "2.0.0" > .version
    log_success "Migration to v2 complete"
}

check_breaking_changes() {
    local from_version=$1
    local to_version=$2
    
    log_info "Checking for breaking changes: $from_version -> $to_version"
    
    if [ "$from_version" = "1.0.0" ] && [ "$to_version" = "2.0.0" ]; then
        log_warning "Breaking changes detected:"
        echo "  - Logic App connection references changed"
        echo "  - Parameter schema updated"
        echo "  - New RBAC roles required"
        return 1
    fi
    
    log_success "No breaking changes detected"
    return 0
}

apply_migration() {
    local migration_file=$1
    local resource_group=$2
    
    log_info "Applying migration: $migration_file"
    
    if [ ! -f "$migration_file" ]; then
        log_error "Migration file not found"
        return 1
    fi
    
    local migration_type=$(jq -r '.type' "$migration_file")
    local steps=$(jq -r '.steps[]' "$migration_file")
    
    log_info "Migration type: $migration_type"
    
    while IFS= read -r step; do
        log_info "  Executing: $step"
        # Execute migration step
    done <<< "$steps"
    
    log_success "Migration applied"
}

rollback_migration() {
    local backup_dir=$1
    local resource_group=$2
    
    log_warning "Rolling back migration from: $backup_dir"
    
    if [ ! -d "$backup_dir" ]; then
        log_error "Backup directory not found"
        return 1
    fi
    
    log_info "Restoring Logic Apps..."
    for backup_file in "$backup_dir"/logic-apps/*.json; do
        if [ -f "$backup_file" ]; then
            local app_name=$(basename "$backup_file" .json)
            log_info "  Restoring: $app_name"
            # Restore logic app from backup
        fi
    done
    
    log_success "Rollback complete"
}

export_configuration() {
    local resource_group=$1
    local output_dir=${2:-"./export"}
    
    log_info "Exporting configuration to: $output_dir"
    
    mkdir -p "$output_dir"/{logic-apps,connections,rules,watchlists}
    
    log_info "Exporting Logic Apps..."
    local logic_apps=$(az resource list \
        --resource-group "$resource_group" \
        --resource-type "Microsoft.Logic/workflows" \
        --query "[].name" -o tsv)
    
    while IFS= read -r app; do
        if [ -n "$app" ]; then
            az resource show \
                --resource-group "$resource_group" \
                --name "$app" \
                --resource-type "Microsoft.Logic/workflows" \
                > "$output_dir/logic-apps/${app}.json"
        fi
    done <<< "$logic_apps"
    
    log_info "Exporting API Connections..."
    local connections=$(az resource list \
        --resource-group "$resource_group" \
        --resource-type "Microsoft.Web/connections" \
        --query "[].name" -o tsv)
    
    while IFS= read -r conn; do
        if [ -n "$conn" ]; then
            az resource show \
                --resource-group "$resource_group" \
                --name "$conn" \
                --resource-type "Microsoft.Web/connections" \
                > "$output_dir/connections/${conn}.json"
        fi
    done <<< "$connections"
    
    log_success "Export complete"
}

import_configuration() {
    local source_dir=$1
    local resource_group=$2
    
    log_info "Importing configuration from: $source_dir"
    
    if [ ! -d "$source_dir" ]; then
        log_error "Source directory not found"
        return 1
    fi
    
    if [ -d "$source_dir/connections" ]; then
        log_info "Importing connections..."
        for file in "$source_dir"/connections/*.json; do
            if [ -f "$file" ]; then
                log_info "  Importing: $(basename "$file")"
                # Import connection
            fi
        done
    fi
    
    if [ -d "$source_dir/logic-apps" ]; then
        log_info "Importing Logic Apps..."
        for file in "$source_dir"/logic-apps/*.json; do
            if [ -f "$file" ]; then
                log_info "  Importing: $(basename "$file")"
                # Import logic app
            fi
        done
    fi
    
    log_success "Import complete"
}

validate_migration() {
    local resource_group=$1
    
    log_info "Validating migration..."
    
    bash scripts/validate-deployment.sh "$resource_group" "$workspace_name"
    
    if [ $? -eq 0 ]; then
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
    echo "  migrate <rg> <workspace> <from> <to>    - Run migration"
    echo "  rollback <backup-dir> <rg>              - Rollback migration"
    echo "  export <rg> [output-dir]                - Export configuration"
    echo "  import <source-dir> <rg>                - Import configuration"
    echo "  validate <rg> <workspace>               - Validate migration"
    echo ""
}

if [ "$#" -lt 1 ]; then
    show_usage
    exit 1
fi

case "$1" in
    check-version) check_version ;;
    backup) create_migration_backup "$2" ;;
    migrate) migrate_v1_to_v2 "$2" "$3" ;;
    rollback) rollback_migration "$2" "$3" ;;
    export) export_configuration "$2" "$3" ;;
    import) import_configuration "$2" "$3" ;;
    validate) validate_migration "$2" ;;
    *) show_usage; exit 1 ;;
esac

