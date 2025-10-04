#!/bin/bash

set -e

RESOURCE_GROUP=$1
WORKSPACE_NAME=$2

if [ -z "$RESOURCE_GROUP" ] || [ -z "$WORKSPACE_NAME" ]; then
    echo "Usage: $0 <resource-group> <workspace-name>"
    exit 1
fi

echo "Configuring RBAC permissions..."

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
WORKSPACE_ID=$(az monitor log-analytics workspace show \
    --resource-group "$RESOURCE_GROUP" \
    --workspace-name "$WORKSPACE_NAME" \
    --query id -o tsv)

echo "Finding Logic Apps in resource group..."
LOGIC_APPS=$(az resource list \
    --resource-group "$RESOURCE_GROUP" \
    --resource-type "Microsoft.Logic/workflows" \
    --query "[].name" -o tsv)

if [ -z "$LOGIC_APPS" ]; then
    echo "No Logic Apps found in resource group."
    exit 0
fi

for LOGIC_APP in $LOGIC_APPS; do
    echo "Configuring permissions for: $LOGIC_APP"
    
    IDENTITY_ENABLED=$(az resource show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$LOGIC_APP" \
        --resource-type "Microsoft.Logic/workflows" \
        --query "identity.type" -o tsv 2>/dev/null || echo "None")
    
    if [ "$IDENTITY_ENABLED" = "None" ] || [ -z "$IDENTITY_ENABLED" ]; then
        echo "  Enabling managed identity..."
        az resource update \
            --resource-group "$RESOURCE_GROUP" \
            --name "$LOGIC_APP" \
            --resource-type "Microsoft.Logic/workflows" \
            --set identity.type=SystemAssigned \
            --output none
        
        # Wait for identity to be ready (poll instead of fixed sleep)
        timeout=30
        elapsed=0
        while [ "$elapsed" -lt "$timeout" ]; do
            identity_status=$(az resource show \
                --resource-group "$RESOURCE_GROUP" \
                --name "$LOGIC_APP" \
                --resource-type "Microsoft.Logic/workflows" \
                --query "identity.principalId" -o tsv 2>/dev/null || echo "")
            
            if [ -n "$identity_status" ] && [ "$identity_status" != "null" ]; then
                echo "  Identity ready after ${elapsed}s"
                break
            fi
            
            sleep 2
            elapsed=$((elapsed + 2))
        done
        
        if [ "$elapsed" -ge "$timeout" ]; then
            echo "  Warning: Identity may not be ready yet"
        fi
    fi
    
    PRINCIPAL_ID=$(az resource show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$LOGIC_APP" \
        --resource-type "Microsoft.Logic/workflows" \
        --query "identity.principalId" -o tsv)
    
    if [ -z "$PRINCIPAL_ID" ]; then
        echo "  Error: Could not get principal ID"
        continue
    fi
    
    echo "  Assigning Azure Sentinel Responder role..."
    az role assignment create \
        --assignee "$PRINCIPAL_ID" \
        --role "Azure Sentinel Responder" \
        --scope "$WORKSPACE_ID" \
        --output none 2>/dev/null || echo "    (Role may already be assigned)"
    
    echo "  Assigning Azure Sentinel Contributor role..."
    az role assignment create \
        --assignee "$PRINCIPAL_ID" \
        --role "Azure Sentinel Contributor" \
        --scope "$WORKSPACE_ID" \
        --output none 2>/dev/null || echo "    (Role may already be assigned)"
    
    echo "  Assigning User Access Administrator (for user disable)..."
    az role assignment create \
        --assignee "$PRINCIPAL_ID" \
        --role "User Access Administrator" \
        --scope "/subscriptions/$SUBSCRIPTION_ID" \
        --output none 2>/dev/null || echo "    (Role may already be assigned)"
    
    echo "  Assigning Security Admin (for Defender actions)..."
    az role assignment create \
        --assignee "$PRINCIPAL_ID" \
        --role "Security Admin" \
        --scope "/subscriptions/$SUBSCRIPTION_ID" \
        --output none 2>/dev/null || echo "    (Role may already be assigned)"
done

echo "RBAC configuration complete!"

