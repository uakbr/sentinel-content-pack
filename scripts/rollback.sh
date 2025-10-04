#!/bin/bash

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

BACKUP_DIR=".deployment-backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

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

create_backup() {
    local resource_group=$1
    local backup_file="$BACKUP_DIR/${resource_group}_${TIMESTAMP}.json"
    
    mkdir -p "$BACKUP_DIR"
    
    log_info "Creating backup of current resources..."
    
    az resource list \
        --resource-group "$resource_group" \
        --query "[].{id:id, name:name, type:type, location:location, tags:tags}" \
        > "$backup_file" 2>/dev/null || true
    
    log_success "Backup saved to: $backup_file"
    echo "$backup_file"
}

delete_logic_apps() {
    local resource_group=$1
    local force=$2
    
    log_info "Finding Logic Apps to delete..."
    
    local logic_apps=$(az resource list \
        --resource-group "$resource_group" \
        --resource-type "Microsoft.Logic/workflows" \
        --query "[].name" -o tsv 2>/dev/null || echo "")
    
    if [ -z "$logic_apps" ]; then
        log_info "No Logic Apps found"
        return 0
    fi
    
    echo -e "${YELLOW}Found Logic Apps:${NC}"
    echo "$logic_apps" | while read app; do
        echo "  - $app"
    done
    
    if [ "$force" != "true" ]; then
        echo ""
        read -p "Delete these Logic Apps? (yes/no): " confirm
        if [ "$confirm" != "yes" ]; then
            log_info "Skipping Logic Apps deletion"
            return 0
        fi
    fi
    
    echo "$logic_apps" | while read app; do
        log_info "Deleting Logic App: $app"
        az resource delete \
            --resource-group "$resource_group" \
            --name "$app" \
            --resource-type "Microsoft.Logic/workflows" \
            --verbose &>/dev/null || log_error "Failed to delete $app"
    done
    
    log_success "Logic Apps deleted"
}

delete_api_connections() {
    local resource_group=$1
    local force=$2
    
    log_info "Finding API connections to delete..."
    
    local connections=$(az resource list \
        --resource-group "$resource_group" \
        --resource-type "Microsoft.Web/connections" \
        --query "[].name" -o tsv 2>/dev/null || echo "")
    
    if [ -z "$connections" ]; then
        log_info "No API connections found"
        return 0
    fi
    
    echo -e "${YELLOW}Found API connections:${NC}"
    echo "$connections" | while read conn; do
        echo "  - $conn"
    done
    
    if [ "$force" != "true" ]; then
        echo ""
        read -p "Delete these connections? (yes/no): " confirm
        if [ "$confirm" != "yes" ]; then
            log_info "Skipping API connections deletion"
            return 0
        fi
    fi
    
    echo "$connections" | while read conn; do
        log_info "Deleting connection: $conn"
        az resource delete \
            --resource-group "$resource_group" \
            --name "$conn" \
            --resource-type "Microsoft.Web/connections" \
            --verbose &>/dev/null || log_error "Failed to delete $conn"
    done
    
    log_success "API connections deleted"
}

delete_analytics_rules() {
    local resource_group=$1
    local workspace_name=$2
    local force=$3
    
    log_info "Finding analytics rules to delete..."
    
    local rules=$(az sentinel alert-rule list \
        --resource-group "$resource_group" \
        --workspace-name "$workspace_name" \
        --query "[].name" -o tsv 2>/dev/null || echo "")
    
    if [ -z "$rules" ]; then
        log_info "No analytics rules found"
        return 0
    fi
    
    echo -e "${YELLOW}Found analytics rules:${NC}"
    echo "$rules" | while read rule; do
        echo "  - $rule"
    done
    
    if [ "$force" != "true" ]; then
        echo ""
        read -p "Delete these rules? (yes/no): " confirm
        if [ "$confirm" != "yes" ]; then
            log_info "Skipping analytics rules deletion"
            return 0
        fi
    fi
    
    echo "$rules" | while read rule; do
        log_info "Deleting rule: $rule"
        az sentinel alert-rule delete \
            --resource-group "$resource_group" \
            --workspace-name "$workspace_name" \
            --alert-rule-id "$rule" \
            --yes \
            &>/dev/null || log_error "Failed to delete $rule"
    done
    
    log_success "Analytics rules deleted"
}

delete_watchlists() {
    local resource_group=$1
    local workspace_name=$2
    local force=$3
    
    log_info "Finding watchlists to delete..."
    
    local watchlists=$(az sentinel watchlist list \
        --resource-group "$resource_group" \
        --workspace-name "$workspace_name" \
        --query "[].watchlistAlias" -o tsv 2>/dev/null || echo "")
    
    if [ -z "$watchlists" ]; then
        log_info "No watchlists found"
        return 0
    fi
    
    echo -e "${YELLOW}Found watchlists:${NC}"
    echo "$watchlists" | while read wl; do
        echo "  - $wl"
    done
    
    if [ "$force" != "true" ]; then
        echo ""
        read -p "Delete these watchlists? (yes/no): " confirm
        if [ "$confirm" != "yes" ]; then
            log_info "Skipping watchlists deletion"
            return 0
        fi
    fi
    
    echo "$watchlists" | while read wl; do
        log_info "Deleting watchlist: $wl"
        az sentinel watchlist delete \
            --resource-group "$resource_group" \
            --workspace-name "$workspace_name" \
            --watchlist-alias "$wl" \
            --yes \
            &>/dev/null || log_error "Failed to delete $wl"
    done
    
    log_success "Watchlists deleted"
}

remove_rbac_assignments() {
    local resource_group=$1
    local force=$2
    
    log_info "Finding RBAC assignments for Logic Apps..."
    
    local logic_apps=$(az resource list \
        --resource-group "$resource_group" \
        --resource-type "Microsoft.Logic/workflows" \
        --query "[].name" -o tsv 2>/dev/null || echo "")
    
    if [ -z "$logic_apps" ]; then
        log_info "No Logic Apps found"
        return 0
    fi
    
    local removed=0
    for app in $logic_apps; do
        local principal_id=$(az resource show \
            --resource-group "$resource_group" \
            --name "$app" \
            --resource-type "Microsoft.Logic/workflows" \
            --query "identity.principalId" -o tsv 2>/dev/null || echo "")
        
        if [ -n "$principal_id" ] && [ "$principal_id" != "null" ]; then
            log_info "Removing RBAC assignments for: $app"
            
            local assignments=$(az role assignment list \
                --assignee "$principal_id" \
                --query "[].id" -o tsv 2>/dev/null || echo "")
            
            if [ -n "$assignments" ]; then
                echo "$assignments" | while read assignment; do
                    az role assignment delete --ids "$assignment" &>/dev/null || true
                    ((removed++))
                done
            fi
        fi
    done
    
    if [ $removed -gt 0 ]; then
        log_success "Removed $removed RBAC assignment(s)"
    else
        log_info "No RBAC assignments to remove"
    fi
}

list_backups() {
    if [ ! -d "$BACKUP_DIR" ]; then
        echo "No backups found"
        return
    fi
    
    echo -e "${BLUE}Available backups:${NC}"
    ls -lh "$BACKUP_DIR" | tail -n +2 | awk '{print $9, "(" $5 ")"}'
}

restore_from_backup() {
    local backup_file=$1
    
    if [ ! -f "$backup_file" ]; then
        log_error "Backup file not found: $backup_file"
        return 1
    fi
    
    log_info "Restoring from backup: $backup_file"
    log_warning "Restore functionality is limited to resource metadata"
    log_warning "Full state restoration requires manual intervention"
    
    cat "$backup_file" | jq -r '.[] | "\(.type): \(.name) in \(.location)"'
}

show_usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  backup <resource-group>                    - Create backup before rollback"
    echo "  delete-all <resource-group> <workspace>    - Delete all deployed resources"
    echo "  delete-logic-apps <resource-group>         - Delete only Logic Apps"
    echo "  delete-connections <resource-group>        - Delete only API connections"
    echo "  delete-rules <resource-group> <workspace>  - Delete only analytics rules"
    echo "  delete-watchlists <resource-group> <workspace> - Delete only watchlists"
    echo "  remove-rbac <resource-group>               - Remove RBAC assignments"
    echo "  list-backups                               - List available backups"
    echo "  restore <backup-file>                      - Show backup contents"
    echo ""
    echo "Options:"
    echo "  --force    Skip confirmation prompts"
    echo ""
    echo "Examples:"
    echo "  $0 backup rg-sentinel"
    echo "  $0 delete-all rg-sentinel sentinel-workspace"
    echo "  $0 delete-logic-apps rg-sentinel --force"
}

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Rollback & Cleanup Utility${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

if [ "$#" -lt 1 ]; then
    show_usage
    exit 1
fi

COMMAND=$1
FORCE=false

for arg in "$@"; do
    if [ "$arg" = "--force" ]; then
        FORCE=true
    fi
done

case "$COMMAND" in
    backup)
        if [ "$#" -lt 2 ]; then
            echo "Usage: $0 backup <resource-group>"
            exit 1
        fi
        create_backup "$2"
        ;;
    
    delete-all)
        if [ "$#" -lt 3 ]; then
            echo "Usage: $0 delete-all <resource-group> <workspace-name> [--force]"
            exit 1
        fi
        
        RESOURCE_GROUP=$2
        WORKSPACE=$3
        
        echo -e "${RED}WARNING: This will delete ALL deployed Sentinel content!${NC}"
        if [ "$FORCE" != "true" ]; then
            read -p "Are you absolutely sure? Type 'DELETE' to confirm: " confirm
            if [ "$confirm" != "DELETE" ]; then
                echo "Aborted"
                exit 0
            fi
        fi
        
        create_backup "$RESOURCE_GROUP"
        delete_watchlists "$RESOURCE_GROUP" "$WORKSPACE" "$FORCE"
        delete_analytics_rules "$RESOURCE_GROUP" "$WORKSPACE" "$FORCE"
        remove_rbac_assignments "$RESOURCE_GROUP" "$FORCE"
        delete_logic_apps "$RESOURCE_GROUP" "$FORCE"
        delete_api_connections "$RESOURCE_GROUP" "$FORCE"
        
        log_success "Rollback complete"
        ;;
    
    delete-logic-apps)
        if [ "$#" -lt 2 ]; then
            echo "Usage: $0 delete-logic-apps <resource-group> [--force]"
            exit 1
        fi
        delete_logic_apps "$2" "$FORCE"
        ;;
    
    delete-connections)
        if [ "$#" -lt 2 ]; then
            echo "Usage: $0 delete-connections <resource-group> [--force]"
            exit 1
        fi
        delete_api_connections "$2" "$FORCE"
        ;;
    
    delete-rules)
        if [ "$#" -lt 3 ]; then
            echo "Usage: $0 delete-rules <resource-group> <workspace-name> [--force]"
            exit 1
        fi
        delete_analytics_rules "$2" "$3" "$FORCE"
        ;;
    
    delete-watchlists)
        if [ "$#" -lt 3 ]; then
            echo "Usage: $0 delete-watchlists <resource-group> <workspace-name> [--force]"
            exit 1
        fi
        delete_watchlists "$2" "$3" "$FORCE"
        ;;
    
    remove-rbac)
        if [ "$#" -lt 2 ]; then
            echo "Usage: $0 remove-rbac <resource-group> [--force]"
            exit 1
        fi
        remove_rbac_assignments "$2" "$FORCE"
        ;;
    
    list-backups)
        list_backups
        ;;
    
    restore)
        if [ "$#" -lt 2 ]; then
            echo "Usage: $0 restore <backup-file>"
            exit 1
        fi
        restore_from_backup "$2"
        ;;
    
    *)
        echo "Unknown command: $COMMAND"
        show_usage
        exit 1
        ;;
esac

