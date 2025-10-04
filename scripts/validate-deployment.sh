#!/bin/bash

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

if [ "$#" -lt 2 ]; then
    echo -e "${RED}Usage: $0 <resource-group> <workspace-name>${NC}"
    exit 1
fi

RESOURCE_GROUP=$1
WORKSPACE_NAME=$2

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Deployment Validation${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

ERRORS=0
WARNINGS=0

echo -e "${BLUE}[1] Checking resource group...${NC}"
if az group show --name "$RESOURCE_GROUP" &>/dev/null; then
    echo -e "${GREEN}  Resource group exists${NC}"
else
    echo -e "${RED}  Resource group not found${NC}"
    ((ERRORS++))
fi

echo -e "${BLUE}[2] Checking Sentinel workspace...${NC}"
if az monitor log-analytics workspace show \
    --resource-group "$RESOURCE_GROUP" \
    --workspace-name "$WORKSPACE_NAME" &>/dev/null; then
    echo -e "${GREEN}  Workspace exists${NC}"
else
    echo -e "${RED}  Workspace not found${NC}"
    ((ERRORS++))
fi

echo -e "${BLUE}[3] Checking API connections...${NC}"
CONNECTIONS=$(az resource list \
    --resource-group "$RESOURCE_GROUP" \
    --resource-type "Microsoft.Web/connections" \
    --query "length([])" -o tsv)

if [ "$CONNECTIONS" -gt 0 ]; then
    echo -e "${GREEN}  Found $CONNECTIONS API connection(s)${NC}"
    
    DISCONNECTED=$(az resource list \
        --resource-group "$RESOURCE_GROUP" \
        --resource-type "Microsoft.Web/connections" \
        --query "[?properties.statuses[0].status != 'Connected'].name" -o tsv)
    
    if [ -n "$DISCONNECTED" ]; then
        echo -e "${YELLOW}  Warning: Some connections are not authorized:${NC}"
        echo "$DISCONNECTED" | while read conn; do
            echo -e "${YELLOW}    - $conn${NC}"
        done
        ((WARNINGS++))
    fi
else
    echo -e "${YELLOW}  No API connections found${NC}"
    ((WARNINGS++))
fi

echo -e "${BLUE}[4] Checking Logic Apps...${NC}"
LOGIC_APPS=$(az resource list \
    --resource-group "$RESOURCE_GROUP" \
    --resource-type "Microsoft.Logic/workflows" \
    --query "length([])" -o tsv)

if [ "$LOGIC_APPS" -gt 0 ]; then
    echo -e "${GREEN}  Found $LOGIC_APPS playbook(s)${NC}"
    
    DISABLED=$(az resource list \
        --resource-group "$RESOURCE_GROUP" \
        --resource-type "Microsoft.Logic/workflows" \
        --query "[?properties.state != 'Enabled'].name" -o tsv)
    
    if [ -n "$DISABLED" ]; then
        echo -e "${YELLOW}  Warning: Some playbooks are disabled:${NC}"
        echo "$DISABLED" | while read app; do
            echo -e "${YELLOW}    - $app${NC}"
        done
        ((WARNINGS++))
    fi
else
    echo -e "${RED}  No playbooks found${NC}"
    ((ERRORS++))
fi

echo -e "${BLUE}[5] Checking RBAC assignments...${NC}"
LOGIC_APP_NAMES=$(az resource list \
    --resource-group "$RESOURCE_GROUP" \
    --resource-type "Microsoft.Logic/workflows" \
    --query "[].name" -o tsv)

RBAC_ISSUES=0
for LOGIC_APP in $LOGIC_APP_NAMES; do
    IDENTITY=$(az resource show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$LOGIC_APP" \
        --resource-type "Microsoft.Logic/workflows" \
        --query "identity.type" -o tsv 2>/dev/null || echo "None")
    
    if [ "$IDENTITY" = "None" ] || [ -z "$IDENTITY" ]; then
        echo -e "${YELLOW}    $LOGIC_APP: No managed identity${NC}"
        ((RBAC_ISSUES++))
    fi
done

if [ "$RBAC_ISSUES" -gt 0 ]; then
    ((WARNINGS++))
else
    echo -e "${GREEN}  All playbooks have managed identities${NC}"
fi

echo -e "${BLUE}[6] Checking analytics rules...${NC}"
RULES_COUNT=$(az sentinel alert-rule list \
    --resource-group "$RESOURCE_GROUP" \
    --workspace-name "$WORKSPACE_NAME" \
    --query "length([])" -o tsv 2>/dev/null || echo "0")

if [ "$RULES_COUNT" -gt 0 ]; then
    echo -e "${GREEN}  Found $RULES_COUNT analytics rule(s)${NC}"
else
    echo -e "${YELLOW}  No analytics rules found${NC}"
    ((WARNINGS++))
fi

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Validation Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Errors:   ${RED}$ERRORS${NC}"
echo -e "Warnings: ${YELLOW}$WARNINGS${NC}"
echo ""

if [ "$ERRORS" -gt 0 ]; then
    echo -e "${RED}Deployment has errors that need to be fixed.${NC}"
    exit 1
elif [ "$WARNINGS" -gt 0 ]; then
    echo -e "${YELLOW}Deployment has warnings. Review and fix if needed.${NC}"
    exit 0
else
    echo -e "${GREEN}Deployment is healthy!${NC}"
    exit 0
fi

