#!/bin/bash
# Common functions and variables for homelab automation scripts

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_header() {
    echo -e "\n${CYAN}==================================================${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}==================================================${NC}\n"
}

# Error handling
handle_error() {
    local line_no=$1
    local command=$2
    local error_code=$3
    log_error "Error on line $line_no: Command '$command' failed with exit code $error_code"
    exit $error_code
}

# Set up error trap
# Usage: set_error_trap
set_error_trap() {
    trap 'handle_error ${LINENO} "$BASH_COMMAND" $?' ERR
}

# Check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Detect OS
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    else
        echo "unknown"
    fi
}

# Send ntfy notification
# Usage: send_ntfy "title" "message" "priority" "tags"
send_ntfy() {
    local title="$1"
    local message="$2"
    local priority="${3:-3}"
    local tags="${4:-info}"
    local ntfy_url="${NTFY_URL:-https://ntfy.mljr.eu}"
    local ntfy_topic="${NTFY_TOPIC:-deployment}"

    # Only send if ntfy is reachable
    if command -v curl &> /dev/null; then
        curl -s -X POST \
            -H "Title: $title" \
            -H "Priority: $priority" \
            -H "Tags: $tags" \
            -d "$message" \
            "$ntfy_url/$ntfy_topic" >/dev/null 2>&1 || true
    fi
}
