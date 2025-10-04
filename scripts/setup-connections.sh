#!/bin/bash

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$#" -lt 1 ]; then
    echo -e "${YELLOW}Usage: $0 <resource-group>${NC}"
    exit 1
fi

RESOURCE_GROUP=$1

echo -e "${BLUE}Authorizing API Connections...${NC}"
echo ""

CONNECTIONS=$(az resource list \
    --resource-group "$RESOURCE_GROUP" \
    --resource-type "Microsoft.Web/connections" \
    --query "[].name" -o tsv)

if [ -z "$CONNECTIONS" ]; then
    echo -e "${YELLOW}No connections found in resource group.${NC}"
    exit 0
fi

echo -e "${YELLOW}The following connections need to be authorized in your browser:${NC}"
for CONNECTION in $CONNECTIONS; do
    echo "  - $CONNECTION"
done
echo ""

for CONNECTION in $CONNECTIONS; do
    echo -e "${BLUE}Processing: $CONNECTION${NC}"
    
    CONNECTION_ID=$(az resource show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$CONNECTION" \
        --resource-type "Microsoft.Web/connections" \
        --query id -o tsv)
    
    STATUS=$(az resource show \
        --ids "$CONNECTION_ID" \
        --query "properties.statuses[0].status" -o tsv 2>/dev/null || echo "Unknown")
    
    if [ "$STATUS" = "Connected" ]; then
        echo -e "${GREEN}  Already connected${NC}"
        continue
    fi
    
    CONSENT_LINK=$(az rest \
        --method POST \
        --uri "${CONNECTION_ID}/listConsentLinks?api-version=2016-06-01" \
        --body '{"parameters":[]}' \
        --query "value[0].link" -o tsv 2>/dev/null || echo "")
    
    if [ -n "$CONSENT_LINK" ]; then
        echo -e "${YELLOW}  Opening authorization page...${NC}"
        echo -e "${BLUE}  URL: $CONSENT_LINK${NC}"
        
        if command -v open &> /dev/null; then
            open "$CONSENT_LINK"
        elif command -v xdg-open &> /dev/null; then
            xdg-open "$CONSENT_LINK"
        else
            echo -e "${YELLOW}  Please open this URL manually:${NC}"
            echo "  $CONSENT_LINK"
        fi
        
        read -p "  Press Enter after authorizing..."
        echo ""
    else
        echo -e "${YELLOW}  Manual authorization required${NC}"
        echo -e "${BLUE}  Go to: Azure Portal > Resource Groups > $RESOURCE_GROUP > Connections > $CONNECTION${NC}"
        read -p "  Press Enter after authorizing..."
        echo ""
    fi
done

echo -e "${GREEN}Connection authorization complete!${NC}"

