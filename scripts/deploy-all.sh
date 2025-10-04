#!/bin/bash

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Sentinel Content Pack Deployment${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

if [ "$#" -lt 2 ]; then
    echo -e "${RED}Usage: $0 <resource-group> <workspace-name> [parameters-file]${NC}"
    echo ""
    echo "Example:"
    echo "  $0 rg-sentinel sentinel-workspace-prod deployment/parameters.json"
    exit 1
fi

RESOURCE_GROUP=$1
WORKSPACE_NAME=$2
PARAMETERS_FILE=${3:-"deployment/parameters.json"}
LOCATION=${4:-"eastus"}
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

if [ ! -f "$PARAMETERS_FILE" ]; then
    echo -e "${YELLOW}Parameters file not found. Creating from template...${NC}"
    cp deployment/parameters.template.json "$PARAMETERS_FILE"
    echo -e "${YELLOW}Please edit $PARAMETERS_FILE with your values and run again.${NC}"
    exit 1
fi

echo -e "${GREEN}Subscription:${NC} $SUBSCRIPTION_ID"
echo -e "${GREEN}Resource Group:${NC} $RESOURCE_GROUP"
echo -e "${GREEN}Workspace:${NC} $WORKSPACE_NAME"
echo -e "${GREEN}Location:${NC} $LOCATION"
echo ""

read -p "Continue with deployment? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Deployment cancelled."
    exit 1
fi

echo -e "${BLUE}[1/6] Creating resource group (if not exists)...${NC}"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
echo -e "${GREEN}Resource group ready${NC}"

echo -e "${BLUE}[2/6] Deploying API connections...${NC}"
CONNECTION_DEPLOYMENT=$(az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file deployment/api-connections.json \
  --parameters workspaceName="$WORKSPACE_NAME" \
  --parameters workspaceResourceGroup="$RESOURCE_GROUP" \
  --parameters location="$LOCATION" \
  --query 'properties.outputs' \
  --output json)

echo -e "${GREEN}API connections created${NC}"

echo -e "${BLUE}[3/6] Deploying analytics rules...${NC}"
for rule in analytics/*.json; do
    if [ -f "$rule" ]; then
        RULE_NAME=$(basename "$rule" .json)
        echo "  - Deploying $RULE_NAME..."
        az sentinel alert-rule create \
          --resource-group "$RESOURCE_GROUP" \
          --workspace-name "$WORKSPACE_NAME" \
          --alert-rule-template @"$rule" \
          --output none 2>/dev/null || echo "    (Rule may already exist)"
    fi
done
echo -e "${GREEN}Analytics rules deployed${NC}"

echo -e "${BLUE}[4/6] Deploying playbooks...${NC}"
for playbook in playbooks/*.json; do
    if [ -f "$playbook" ]; then
        PLAYBOOK_NAME=$(basename "$playbook" .json)
        echo "  - Deploying $PLAYBOOK_NAME..."
        az deployment group create \
          --resource-group "$RESOURCE_GROUP" \
          --template-file "$playbook" \
          --parameters @"$PARAMETERS_FILE" \
          --parameters logicAppName="$PLAYBOOK_NAME" \
          --parameters location="$LOCATION" \
          --output none
    fi
done
echo -e "${GREEN}Playbooks deployed${NC}"

echo -e "${BLUE}[5/6] Importing watchlists...${NC}"
for watchlist in watchlists/*.csv; do
    if [ -f "$watchlist" ]; then
        WATCHLIST_NAME=$(basename "$watchlist" .csv)
        echo "  - Importing $WATCHLIST_NAME..."
        az sentinel watchlist create \
          --resource-group "$RESOURCE_GROUP" \
          --workspace-name "$WORKSPACE_NAME" \
          --watchlist-alias "$WATCHLIST_NAME" \
          --display-name "$WATCHLIST_NAME" \
          --provider "Sentinel Content Pack" \
          --source "LocalFile" \
          --source-type "Local file" \
          --output none 2>/dev/null || echo "    (Watchlist may already exist)"
        
        az sentinel watchlist-item create \
          --resource-group "$RESOURCE_GROUP" \
          --workspace-name "$WORKSPACE_NAME" \
          --watchlist-alias "$WATCHLIST_NAME" \
          --properties-file "$watchlist" \
          --output none 2>/dev/null || true
    fi
done
echo -e "${GREEN}Watchlists imported${NC}"

echo -e "${BLUE}[6/6] Configuring RBAC permissions...${NC}"
bash scripts/configure-rbac.sh "$RESOURCE_GROUP" "$WORKSPACE_NAME"
echo -e "${GREEN}RBAC configured${NC}"

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Deployment Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Authenticate API connections in Azure Portal:"
echo "   - Go to Resource Group > Connections"
echo "   - Click each connection and authorize"
echo ""
echo "2. Configure automation rules in Sentinel:"
echo "   - Sentinel > Configuration > Automation"
echo "   - Create rules to trigger playbooks"
echo ""
echo "3. Review deployed content:"
echo "   - Analytics: Sentinel > Analytics"
echo "   - Playbooks: Resource Group > Logic Apps"
echo "   - Watchlists: Sentinel > Watchlists"
echo ""

