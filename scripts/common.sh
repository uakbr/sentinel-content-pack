#!/bin/bash

# Common shell functions for Sentinel Content Pack scripts
# Source this file in other scripts: source "$(dirname "$0")/common.sh"

# Color definitions
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Logging functions
log_info() { 
    echo -e "${BLUE}[INFO]${NC} $1" 
}

log_success() { 
    echo -e "${GREEN}[SUCCESS]${NC} $1" 
}

log_warning() { 
    echo -e "${YELLOW}[WARNING]${NC} $1" 
}

log_error() { 
    echo -e "${RED}[ERROR]${NC} $1" 
}

# Portable date function that works on both Linux and macOS
portable_date_ago() {
    local amount=$1
    local unit=$2  # 'hours', 'days', 'months', 'years'
    local format=${3:-'+%Y-%m-%dT%H:%M:%SZ'}
    
    if date --version >/dev/null 2>&1; then
        # GNU date (Linux)
        date -u -d "$amount $unit ago" "$format"
    else
        # BSD date (macOS)
        case "$unit" in
            hours)  date -u -v-"${amount}H" "$format" ;;
            days)   date -u -v-"${amount}d" "$format" ;;
            months) date -u -v-"${amount}m" "$format" ;;
            years)  date -u -v-"${amount}y" "$format" ;;
            *)      echo "Unsupported unit: $unit" >&2; return 1 ;;
        esac
    fi
}

# Check if a resource exists
resource_exists() {
    local resource_group=$1
    local resource_name=$2
    local resource_type=$3
    
    az resource show \
        --resource-group "$resource_group" \
        --name "$resource_name" \
        --resource-type "$resource_type" \
        &>/dev/null
}

# Retry a command with exponential backoff
retry_with_backoff() {
    local max_attempts=${1:-3}
    local delay=${2:-2}
    shift 2
    local command=("$@")
    
    local attempt=1
    while [ "$attempt" -le "$max_attempts" ]; do
        if "${command[@]}"; then
            return 0
        fi
        
        if [ "$attempt" -lt "$max_attempts" ]; then
            local wait_time=$((delay * attempt))
            log_warning "Attempt $attempt failed. Retrying in ${wait_time}s..."
            sleep "$wait_time"
        fi
        
        ((attempt++))
    done
    
    log_error "Command failed after $max_attempts attempts"
    return 1
}

# Check if directory has files matching pattern
has_files() {
    local pattern=$1
    compgen -G "$pattern" > /dev/null
}

# Safe division (avoids division by zero)
safe_divide() {
    local numerator=$1
    local denominator=$2
    local precision=${3:-2}
    
    if [ "$denominator" -eq 0 ]; then
        echo "0"
        return 1
    fi
    
    echo "scale=$precision; $numerator / $denominator" | bc
}

# Wait for a condition to be true with timeout
wait_for_condition() {
    local timeout=$1
    local interval=${2:-2}
    shift 2
    local condition=("$@")
    
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if "${condition[@]}"; then
            return 0
        fi
        
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    
    return 1
}

# Validate JSON file
validate_json() {
    local file=$1
    jq empty "$file" 2>/dev/null
}

# Get Azure subscription ID
get_subscription_id() {
    az account show --query id -o tsv
}

# Check if running on Linux
is_linux() {
    [[ "$(uname -s)" == "Linux" ]]
}

# Check if running on macOS
is_macos() {
    [[ "$(uname -s)" == "Darwin" ]]
}
