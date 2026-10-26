#!/bin/bash
# Carried over from the hand-made script; the remaining findings are style/info
# noise in code that works (exit-code checks via $?, read without -r, unused
# response variables, config variables set by read_config). Cleanup is part of
# the planned rewrite, not this move.
# shellcheck disable=SC1090,SC2034,SC2154,SC2155,SC2162,SC2181

# NAS Display State Controller with Immich Integration
# Managed by OpenVox (roles::unraid_aoostar_proxy, proxy-exec from nuc) - do not edit manually.
#
# Drives the AOOSTAR-X web UI (the vendor display driver) over HTTP: day/night
# mode, a rotating Immich photo, optional stats panels. Started by
# aoostar-ctl.sh; the credentials live in an env file that is NOT in the repo
# (mode 600, written once by hand):
#
#   /mnt/user/appdata/aoostar/controller.env
#     NAS_IP=192.168.50.80        (optional)
#     PORT=5123                   (optional)
#     USERNAME=admin              (optional)
#     PASSWORD=...                (AOOSTAR-X web UI login, required)
#     IMMICH_URL=https://immich.mljr.eu
#     IMMICH_API_KEY=...          (required, read-only key)
#     IMMICH_PERSON_NAMES=""      (optional, comma separated)

ENV_FILE="${AOOSTAR_ENV_FILE:-/mnt/user/appdata/aoostar/controller.env}"
if [[ -r "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi
NAS_IP="${NAS_IP:-192.168.50.80}"
PORT="${PORT:-5123}"
USERNAME="${USERNAME:-admin}"
PASSWORD="${PASSWORD:?PASSWORD missing, set it in $ENV_FILE}"
BASE_URL="http://${NAS_IP}:${PORT}"

IMMICH_URL="${IMMICH_URL:-https://immich.mljr.eu}"
IMMICH_API_KEY="${IMMICH_API_KEY:?IMMICH_API_KEY missing, set it in $ENV_FILE}"
IMMICH_PERSON_NAMES="${IMMICH_PERSON_NAMES:-}"  # Comma-separated names, e.g. "John,Jane" or empty for any random image

LOG_FILE="${AOOSTAR_CONTROLLER_LOG:-/var/log/aoostar-controller.log}"

# Cookies and temporary image files are written to the current directory, so
# work in a private scratch dir.
WORK_DIR="/tmp/aoostar-controller"
mkdir -p "$WORK_DIR" && cd "$WORK_DIR" || exit 1

# Get script directory for local executables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAGICK_CMD="magick"

# State file - use persistent location
CONFIG_FILE="/tmp/nas_display_state.conf"

# Initialize default state
init_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat > "$CONFIG_FILE" << EOF
display_on=true
image_panel=true
stats_panel=false
drive_stats_panel=false
auto_mode=true
last_image_update=0
current_image=""
EOF
        echo "Initialized config file: $CONFIG_FILE"
    fi
}

# Read config file
read_config() {
    init_config
    source "$CONFIG_FILE"
}

# Write config file
write_config() {
    cat > "$CONFIG_FILE" << EOF
display_on=$display_on
image_panel=$image_panel
stats_panel=$stats_panel
drive_stats_panel=$drive_stats_panel
auto_mode=$auto_mode
last_image_update=$last_image_update
current_image=$current_image
EOF
}

# Logging function
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Login function
login() {
    log_message "Logging in to ${BASE_URL}..."
    
    LOGIN_RESPONSE=$(curl -s -c cookies.txt \
        -X POST \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -d "username=${USERNAME}&password=${PASSWORD}" \
        "${BASE_URL}/")
    
    if [[ $? -eq 0 ]]; then
        log_message "Login successful"
        return 0
    else
        log_message "Login failed"
        return 1
    fi
}

# Test NAS connection
test_connection() {
    echo "=== Testing NAS Connection ==="
    echo "Target: $BASE_URL"
    
    # Test basic connectivity
    if curl -s --connect-timeout 5 "$BASE_URL" >/dev/null; then
        echo "✓ Network connection successful"
    else
        echo "✗ Network connection failed"
        return 1
    fi
    
    # Test login
    if login; then
        echo "✓ Authentication successful"
        rm -f cookies.txt
        return 0
    else
        echo "✗ Authentication failed"
        return 1
    fi
}

# Test Immich connection and API
test_immich() {
    echo "=== Testing Immich Connection ==="
    echo "Target: $IMMICH_URL"
    echo "Configured people: ${IMMICH_PERSON_NAMES:-'(none - will use random images)'}"
    
    # Check local magick executable availability (REQUIRED for 960x376 resizing)
    if command -v "$MAGICK_CMD" >/dev/null 2>&1; then
        echo "✓ Local magick executable found: $MAGICK_CMD"
        # Test magick version
        local magick_version
        magick_version=$("$MAGICK_CMD" -version 2>/dev/null | head -1 || echo "unknown")
        echo "  Version: $magick_version"
    else
        echo "✗ Local magick executable not found: $MAGICK_CMD"
        echo "Place the 'magick' executable next to this script for image resizing to 960x376"
        return 1
    fi
    
    # Test basic connectivity
    if curl -s --connect-timeout 5 "$IMMICH_URL" >/dev/null; then
        echo "✓ Network connection successful"
    else
        echo "✗ Network connection failed"
        return 1
    fi
    
    # Test API key by searching for random image
    echo "Testing API key..."
    local test_response
    test_response=$(curl -s \
        -X POST \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -H "x-api-key: $IMMICH_API_KEY" \
        -d '{"type": "IMAGE", "withDeleted": false, "size": 1}' \
        "${IMMICH_URL}/api/search/random")
    
    if [[ $? -eq 0 ]] && echo "$test_response" | grep -q '"id"'; then
        echo "✓ API key valid"
        local asset_count
        asset_count=$(echo "$test_response" | grep -o '"id"' | wc -l)
        echo "✓ Found $asset_count available images"
    else
        echo "✗ API key invalid or no images found"
        echo "Response: $test_response"
        return 1
    fi
    
    # Test person search if names are configured
    if [[ -n "$IMMICH_PERSON_NAMES" ]]; then
        echo "Testing person search..."
        IFS=',' read -ra NAMES <<< "$IMMICH_PERSON_NAMES"
        local found_people=0
        
        for name in "${NAMES[@]}"; do
            name=$(echo "$name" | xargs)
            local person_response
            person_response=$(curl -s \
                -H "Accept: application/json" \
                -H "x-api-key: $IMMICH_API_KEY" \
                "${IMMICH_URL}/api/search/person?name=${name}")
            
            if [[ $? -eq 0 ]] && echo "$person_response" | grep -q '"id"'; then
                echo "✓ Found person: $name"
                ((found_people++))
            else
                echo "✗ Person not found: $name"
            fi
        done
        
        if [[ $found_people -gt 0 ]]; then
            echo "✓ Found $found_people configured people"
        else
            echo "⚠ No configured people found - will use random images"
        fi
    fi
    
    return 0
}

# Configure Immich settings
configure_immich() {
    local setting="$2"
    local value="$3"
    
    case "$setting" in
        "url")
            if [[ -z "$value" ]]; then
                echo "Current Immich URL: $IMMICH_URL"
                read -p "Enter new Immich URL: " value
            fi
            sed -i "s|^IMMICH_URL=.*|IMMICH_URL=\"$value\"|" "$ENV_FILE"
            echo "✓ Immich URL updated to: $value"
            ;;
        "key"|"api-key")
            if [[ -z "$value" ]]; then
                echo "Current API key: ${IMMICH_API_KEY:0:10}..."
                read -s -p "Enter new API key: " value
                echo
            fi
            sed -i "s|^IMMICH_API_KEY=.*|IMMICH_API_KEY=\"$value\"|" "$ENV_FILE"
            echo "✓ API key updated"
            ;;
        "people"|"persons")
            if [[ -z "$value" ]]; then
                echo "Current people: ${IMMICH_PERSON_NAMES:-'(none)'}"
                read -p "Enter person names (comma-separated, or empty for random): " value
            fi
            sed -i "s|^IMMICH_PERSON_NAMES=.*|IMMICH_PERSON_NAMES=\"$value\"|" "$ENV_FILE"
            echo "✓ Person names updated to: ${value:-'(random images)'}"
            ;;
        *)
            echo "Configure Immich Settings"
            echo "Usage: $0 config {setting} [value]"
            echo ""
            echo "Settings:"
            echo "  url                 - Set Immich server URL"
            echo "  key                 - Set API key"
            echo "  people              - Set person names for filtering (comma-separated)"
            echo ""
            echo "Current Configuration:"
            echo "  URL: $IMMICH_URL"
            echo "  API Key: ${IMMICH_API_KEY:0:10}..."
            echo "  People: ${IMMICH_PERSON_NAMES:-'(random images)'}"
            echo ""
            echo "Examples:"
            echo "  $0 config url https://immich.example.com"
            echo "  $0 config key your-api-key-here"
            echo "  $0 config people 'John,Jane,Bob'"
            echo "  $0 config people ''  # Use random images"
            ;;
    esac
}

# Clear all panels first (cache busting)
clear_panels() {
    log_message "Clearing existing panels..."
    local empty_payload='{"panels": []}'
    
    curl -s -b cookies.txt \
        -X POST \
        -H 'Content-Type: application/json' \
        -H 'Cache-Control: no-cache' \
        -d "$empty_payload" \
        "${BASE_URL}/save_custom_panels" >/dev/null
    
    sleep 1  # Give it time to clear
}

# Manual clear command for debugging
manual_clear() {
    echo "=== Manual Panel Clear ==="
    login || return 1
    clear_panels
    rm -f cookies.txt
    echo "✓ All panels cleared"
}

# Send configuration to NAS
send_config() {
    read_config
    
    log_message "=== Sending Configuration ==="
    log_message "Display on: $display_on"
    log_message "Image panel: $image_panel" 
    log_message "Stats panel: $stats_panel"
    log_message "Drive stats panel: $drive_stats_panel"
    
    # Determine display and panel settings
    # NOTE: displayOff API is confusingly named - False=OFF, True=ON
    local off_display="True"  # Default: screen ON
    if [[ "$display_on" == "false" ]]; then
        off_display="False"  # Screen OFF
    fi
    
    local custom_panel="False"
    if [[ "$image_panel" == "true" ]]; then
        custom_panel="True"  # Will show custom image panel
    fi
    
    local control_params="False"
    if [[ "$stats_panel" == "true" ]]; then
        control_params="True"  # Will show main stats panel
    fi
    
    local control_disk_temp="False"
    if [[ "$drive_stats_panel" == "true" ]]; then
        control_disk_temp="True"  # Will show drive temperature panel
    fi
    
    # Login first
    login || return 1
    
    # Send basic config with all panel parameters
    CONFIG_RESPONSE=$(curl -s -b cookies.txt \
        -X POST \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -d "offDisplay=${off_display}&language=1&switchTime=10&theme=2&customPanel=${custom_panel}&controlParams=${control_params}&controlDiskTemp=${control_disk_temp}&operationMode=2&type=1" \
        "${BASE_URL}/config")
    
    if [[ $? -eq 0 ]]; then
        log_message "✓ Configuration sent successfully"
        
        # If custom panels are enabled, send panel configuration
        if [[ "$custom_panel" == "True" ]]; then
            send_panels
        fi
        
        rm -f cookies.txt
        return 0
    else
        log_message "✗ Configuration failed"
        rm -f cookies.txt
        return 1
    fi
}

# Send panel configuration with cache busting
send_panels() {
    read_config
    
    # Clear panels first to avoid caching issues
    clear_panels
    
    local image_checked="false"
    local image_data=""
    local image_filename=""
    
    if [[ "$image_panel" == "true" ]]; then
        image_checked="true"
        
        # Ensure we have an image
        if [[ -z "$current_image" ]]; then
            log_message "Warning: No image available, fetching new one..."
            get_new_image || {
                log_message "✗ Failed to get image, cannot activate image panel"
                return 1
            }
        fi
        
        image_data="$current_image"
        
        # Generate unique filename AND add timestamp for extra cache busting
        local timestamp=$(date +%s%N)
        local unique_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$timestamp" | md5sum | cut -c1-32)
        image_filename="${unique_id}_${timestamp}.png"
        log_message "Panels: Activating IMAGE panel (File: $image_filename)"
    fi
    
    # Generate unique panel ID to avoid caching
    local image_panel_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "image-$(date +%s%N)")
    
    # Create temporary file for JSON payload to avoid "Argument list too long" error
    local temp_json="temp_payload_$$.json"
    
    cat > "$temp_json" << EOF
{
  "panels": [
    {
      "id": "$image_panel_id", 
      "name": "Immich_$(date +%s)",
      "checked": $image_checked,
      "img": "$image_filename",
      "imgData": "data:image/png;base64,$image_data",
      "sensor": []
    }
  ]
}
EOF
    
    log_message "Sending panel configuration with unique ID..."
    log_message "Payload size: $(stat -c%s "$temp_json" 2>/dev/null || wc -c < "$temp_json") bytes"
    
    PANEL_RESPONSE=$(curl -s -b cookies.txt \
        -X POST \
        -H 'Content-Type: application/json' \
        -H 'Cache-Control: no-cache' \
        -H 'Pragma: no-cache' \
        --data-binary "@$temp_json" \
        "${BASE_URL}/save_custom_panels")
    
    local curl_exit_code=$?
    
    # Cleanup temp file
    rm -f "$temp_json"
    
    if [[ $curl_exit_code -eq 0 ]]; then
        log_message "✓ Panels updated successfully"
        return 0
    else
        log_message "✗ Panel update failed (exit code: $curl_exit_code)"
        return 1
    fi
}

# Get new image from Immich and convert to base64
get_new_image() {
    log_message "Getting new image from Immich..."
    
    local temp_file="temp_image_$$.jpg"
    local person_ids=""
    
    # Get person IDs if names are configured
    if [[ -n "$IMMICH_PERSON_NAMES" ]]; then
        log_message "Searching for people: $IMMICH_PERSON_NAMES"
        IFS=',' read -ra NAMES <<< "$IMMICH_PERSON_NAMES"
        local person_id_array=()
        
        for name in "${NAMES[@]}"; do
            # Trim whitespace
            name=$(echo "$name" | xargs)
            log_message "Looking up person: $name"
            
            # Search for person by name
            local person_response
            person_response=$(curl -s \
                -H "Accept: application/json" \
                -H "x-api-key: $IMMICH_API_KEY" \
                "${IMMICH_URL}/api/search/person?name=${name}")
            
            if [[ $? -ne 0 ]]; then
                log_message "✗ Failed to search for person: $name"
                continue
            fi
            
            # Extract person ID (assuming single match)
            local person_id
            person_id=$(echo "$person_response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
            
            if [[ -n "$person_id" ]]; then
                person_id_array+=("\"$person_id\"")
                log_message "Found person ID for $name: $person_id"
            else
                log_message "✗ No person found with name: $name"
            fi
        done
        
        if [[ ${#person_id_array[@]} -gt 0 ]]; then
            person_ids="[$(IFS=','; echo "${person_id_array[*]}")]"
            log_message "Using person IDs: $person_ids"
        else
            log_message "No valid person IDs found, using random image instead"
        fi
    fi
    
    # Search for random image
    log_message "Fetching random image..."
    local search_payload
    if [[ -n "$person_ids" ]]; then
        search_payload="{\"personIds\": $person_ids, \"type\": \"IMAGE\", \"withDeleted\": false, \"size\": 1}"
    else
        search_payload="{\"type\": \"IMAGE\", \"withDeleted\": false, \"size\": 1}"
    fi
    
    local random_response
    random_response=$(curl -s \
        -X POST \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -H "x-api-key: $IMMICH_API_KEY" \
        -d "$search_payload" \
        "${IMMICH_URL}/api/search/random")
    
    if [[ $? -ne 0 ]]; then
        log_message "✗ Failed to search for random image"
        return 1
    fi
    
    # Extract asset ID from response
    local asset_id
    asset_id=$(echo "$random_response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    
    if [[ -z "$asset_id" ]]; then
        log_message "✗ No asset ID found in response"
        log_message "Response: $random_response"
        return 1
    fi
    
    log_message "Found asset ID: $asset_id"
    
    # Download the asset
    log_message "Downloading asset from Immich..."
    local download_result
    download_result=$(curl -L \
        -H "Accept: application/octet-stream" \
        -H "x-api-key: $IMMICH_API_KEY" \
        -w "%{http_code}" \
        -o "$temp_file" \
        "${IMMICH_URL}/api/assets/${asset_id}/original" 2>&1)
    local curl_exit_code=$?
    
    log_message "Curl exit code: $curl_exit_code, HTTP response: $download_result"
    
    # Check if download was successful
    if [[ $curl_exit_code -eq 0 && -f "$temp_file" && -s "$temp_file" ]]; then
        local file_size
        file_size=$(stat -c%s "$temp_file" 2>/dev/null || wc -c < "$temp_file")
        log_message "Downloaded file size: $file_size bytes"
        
        # Verify it's actually an image
        if file "$temp_file" 2>/dev/null | grep -q -E "(JPEG|PNG|image)"; then
            log_message "File verified as image"
            
            # CRITICAL: Resize to EXACTLY 960x376 (required by API)
            local resized_file="resized_$temp_file"
            if command -v "$MAGICK_CMD" >/dev/null 2>&1; then
                log_message "Resizing image to exactly 960x376 with local magick..."
                
                # First: Auto-orient the image based on EXIF data, then resize with letterboxing
                if "$MAGICK_CMD" "$temp_file" \
                    -auto-orient \
                    -resize 960x376 \
                    -gravity center \
                    -background black \
                    -extent 960x376 \
                    "$resized_file" 2>/dev/null; then
                    
                    # Verify the dimensions are exactly correct
                    local dimensions
                    dimensions=$("$MAGICK_CMD" identify -format "%wx%h" "$resized_file" 2>/dev/null)
                    
                    if [[ "$dimensions" == "960x376" ]]; then
                        mv "$resized_file" "$temp_file"
                        log_message "✓ Image oriented and resized successfully to 960x376 with black letterboxing"
                    else
                        log_message "✗ Resize failed - got dimensions: $dimensions, expected: 960x376"
                        rm -f "$resized_file"
                        
                        # Fallback: Force exact size (may distort image)
                        log_message "Trying fallback resize method..."
                        if "$MAGICK_CMD" "$temp_file" -auto-orient -resize 960x376! "$resized_file" 2>/dev/null; then
                            local fallback_dimensions
                            fallback_dimensions=$("$MAGICK_CMD" identify -format "%wx%h" "$resized_file" 2>/dev/null)
                            if [[ "$fallback_dimensions" == "960x376" ]]; then
                                mv "$resized_file" "$temp_file"
                                log_message "✓ Fallback resize successful to 960x376"
                            else
                                log_message "✗ Both resize methods failed"
                                rm -f "$resized_file"
                                rm -f "$temp_file"
                                return 1
                            fi
                        else
                            log_message "✗ Fallback resize also failed"
                            rm -f "$temp_file"
                            return 1
                        fi
                    fi
                else
                    log_message "✗ Magick resize failed"
                    rm -f "$temp_file"
                    return 1
                fi
            else
                log_message "✗ Local magick executable not available - cannot resize to required 960x376"
                log_message "Place the 'magick' executable next to this script: $MAGICK_CMD"
                rm -f "$temp_file"
                return 1
            fi
            
            # Final verification of image dimensions
            if command -v "$MAGICK_CMD" >/dev/null 2>&1; then
                local final_dimensions
                final_dimensions=$("$MAGICK_CMD" identify -format "%wx%h" "$temp_file" 2>/dev/null)
                log_message "Final image dimensions: $final_dimensions"
                
                if [[ "$final_dimensions" != "960x376" ]]; then
                    log_message "✗ Final image dimensions incorrect: $final_dimensions (required: 960x376)"
                    rm -f "$temp_file"
                    return 1
                fi
            fi
            
            # Convert to base64
            log_message "Converting to base64..."
            current_image=$(base64 -w 0 "$temp_file" 2>/dev/null)
            
            if [[ -n "$current_image" ]]; then
                last_image_update=$(date +%s)
                
                # Update config file
                write_config
                
                # Cleanup temp files
                rm -f "$temp_file" "$resized_file"
                log_message "✓ New image loaded from Immich (${#current_image} chars, 960x376)"
                return 0
            else
                log_message "✗ Base64 conversion failed"
            fi
        else
            log_message "✗ Downloaded file is not a valid image"
            file "$temp_file" 2>/dev/null || log_message "File command not available"
        fi
    else
        log_message "✗ Download failed or file is empty"
        log_message "Asset ID: $asset_id"
        log_message "URL: ${IMMICH_URL}/api/assets/${asset_id}/original"
    fi
    
    # Cleanup on failure
    rm -f "$temp_file" "$resized_file"
    return 1
}

# Set night mode (screen OFF, keep current panels)
set_night() {
    read_config
    display_on="false"  # Screen OFF
    write_config
    echo "Night mode: Screen turned OFF (panels unchanged)"
}

# Set day mode (screen ON, keep current panels)
set_day() {
    read_config
    display_on="true"   # Screen ON
    write_config
    echo "Day mode: Screen turned ON (panels unchanged)"
}

# FIXED: Set image mode with optional panel/screen state parameter
set_image() {
    read_config
    local screen_state="$2"  # Parameter: 0=disable panel+screen OFF, 1=enable panel+screen ON
    
    # Handle panel and screen state parameter
    if [[ "$screen_state" == "0" ]]; then
        echo "Disabling image panel and turning screen OFF..."
        image_panel="false"
        display_on="false"
    elif [[ "$screen_state" == "1" ]]; then
        echo "Enabling image panel and turning screen ON..."
        image_panel="true"
        display_on="true"
        
        # Get a new image when enabling image panel
        echo "Fetching new image..."
        if ! get_new_image; then
            echo "✗ Failed to get new image, image panel not enabled"
            image_panel="false"
            write_config
            return 1
        fi
    else
        # No parameter given - enable panel, keep current screen state
        echo "Enabling image panel mode..."
        image_panel="true"
        echo "Screen state: unchanged ($display_on)"
        
        # Always get a new image when image mode is selected
        echo "Fetching new image..."
        if ! get_new_image; then
            echo "✗ Failed to get new image, image panel not enabled"
            image_panel="false"
            write_config
            return 1
        fi
    fi
    
    write_config
    echo "✓ Image panel: $([[ "$image_panel" == "true" ]] && echo 'ENABLED' || echo 'DISABLED')"
    echo "✓ Screen: $([[ "$display_on" == "true" ]] && echo 'ON' || echo 'OFF')"
    show_active_panels
    return 0
}

# FIXED: Set stats mode with optional panel/screen state parameter
set_stats() {
    read_config
    local screen_state="$2"  # Parameter: 0=disable panel+screen OFF, 1=enable panel+screen ON
    
    # Handle panel and screen state parameter
    if [[ "$screen_state" == "0" ]]; then
        echo "Disabling stats panel and turning screen OFF..."
        stats_panel="false"
    elif [[ "$screen_state" == "1" ]]; then
        echo "Enabling stats panel and turning screen ON..."
        stats_panel="true"
    else
        # No parameter given - enable panel, keep current screen state
        echo "Enabling stats panel..."
        stats_panel="true"
        echo "Screen state: unchanged ($display_on)"
    fi
    
    write_config
    echo "✓ Stats panel: $([[ "$stats_panel" == "true" ]] && echo 'ENABLED' || echo 'DISABLED')"
    echo "✓ Screen: $([[ "$display_on" == "true" ]] && echo 'ON' || echo 'OFF')"
    show_active_panels
}

# FIXED: Set drive stats mode with optional panel/screen state parameter  
set_drive_stats() {
    read_config
    local screen_state="$2"  # Parameter: 0=disable panel+screen OFF, 1=enable panel+screen ON
    
    # Handle panel and screen state parameter
    if [[ "$screen_state" == "0" ]]; then
        echo "Disabling drive stats panel and turning screen OFF..."
        drive_stats_panel="false"
        display_on="false"
    elif [[ "$screen_state" == "1" ]]; then
        echo "Enabling drive stats panel and turning screen ON..."
        drive_stats_panel="true"
        display_on="true"
    else
        # No parameter given - enable panel, keep current screen state
        echo "Enabling drive stats panel..."
        drive_stats_panel="true"
        echo "Screen state: unchanged ($display_on)"
    fi
    
    write_config
    echo "✓ Drive stats panel: $([[ "$drive_stats_panel" == "true" ]] && echo 'ENABLED' || echo 'DISABLED')"
    echo "✓ Screen: $([[ "$display_on" == "true" ]] && echo 'ON' || echo 'OFF')"
    show_active_panels
}

# Toggle specific panels on/off
toggle_image() {
    read_config
    if [[ "$image_panel" == "true" ]]; then
        image_panel="false"
        echo "Image panel disabled"
    else
        echo "Enabling image panel..."
        image_panel="true"
        get_new_image || {
            echo "✗ Failed to get image"
            return 1
        }
        echo "Image panel enabled"
    fi
    write_config
    show_active_panels
}

toggle_stats() {
    read_config
    if [[ "$stats_panel" == "true" ]]; then
        stats_panel="false"
        echo "Stats panel disabled"
    else
        stats_panel="true"
        echo "Stats panel enabled"
    fi
    write_config
    show_active_panels
}

toggle_drive_stats() {
    read_config
    if [[ "$drive_stats_panel" == "true" ]]; then
        drive_stats_panel="false"
        echo "Drive stats panel disabled"
    else
        drive_stats_panel="true"
        echo "Drive stats panel enabled"
    fi
    write_config
    show_active_panels
}

# Show currently active panels
show_active_panels() {
    read_config
    local active_panels=()
    
    [[ "$image_panel" == "true" ]] && active_panels+=("Image")
    [[ "$stats_panel" == "true" ]] && active_panels+=("Stats")
    [[ "$drive_stats_panel" == "true" ]] && active_panels+=("Drive Stats")
    
    if [[ ${#active_panels[@]} -eq 0 ]]; then
        echo "Active panels: None"
    else
        echo "Active panels: ${active_panels[*]} (will rotate automatically)"
    fi
}

# Robust daemon loop with better error handling
daemon_loop() {
    log_message "Starting daemon loop..."
    log_message "Config file: $CONFIG_FILE"
    log_message "Immich server: $IMMICH_URL"
    log_message "Auto schedule: Night 23:00-06:00 (screen OFF), Day 06:00-23:00 (screen ON + image panel)"
    log_message "Image rotation: Every 5 minutes when image panel active (fetched from Immich)"
    log_message "Press Ctrl+C to stop"
    
    # Cleanup on exit
    # cleanup() is defined above; one trap so it is not replaced (a second
    # `trap ... EXIT` silently drops the first).
    trap 'log_message "Daemon stopped"; cleanup; exit' INT TERM EXIT
    
    local last_config_hash=""
    local last_hour=-1
    local error_count=0
    local max_errors=10
    
    while true; do
        # The daemon logs a dozen lines a minute to a tmpfs file; keep it
        # bounded (truncating a file opened with >> is safe).
        if [[ -f "$LOG_FILE" ]] && (( $(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0) > 5242880 )); then
            : > "$LOG_FILE"
            log_message "Log truncated (over 5 MiB)"
        fi

        # Read config at start of each loop iteration
        if ! read_config; then
            log_message "✗ Failed to read config, retrying..."
            ((error_count++))
            if [[ $error_count -gt $max_errors ]]; then
                log_message "✗ Too many errors, stopping daemon"
                break
            fi
            sleep 60
            continue
        fi
        
        # Reset error count on successful config read
        error_count=0
        
        # Get current hour and force decimal interpretation (fix leading zero bug)
        local current_hour_str
        current_hour_str=$(date '+%H')
        local current_hour=$((10#$current_hour_str))  # Force decimal interpretation
        local config_changed=false
        
        log_message "Daemon loop: Hour=$current_hour, Image=$image_panel, Stats=$stats_panel, Display=$display_on"
        
        # Auto day/night mode (23:00-06:00 night, 06:00-23:00 day)
        if [[ "$auto_mode" == "true" ]]; then
            if [[ $current_hour -ge 23 || $current_hour -lt 6 ]]; then
                # Night time (23:00-06:00) - Screen OFF
                if [[ "$display_on" != "false" && "$current_hour" != "$last_hour" ]]; then
                    log_message "Auto: Switching to night mode - Screen OFF ($(date '+%H:%M'))"
                    display_on="false"
                    config_changed=true
                fi
            else
                # Day time (06:00-23:00) - Screen ON + Image Panel
                if [[ ("$display_on" != "true" || "$image_panel" != "true") && "$current_hour" != "$last_hour" ]]; then
                    log_message "Auto: Switching to day mode - Screen ON + Image Panel ($(date '+%H:%M'))"
                    display_on="true"
                    image_panel="true"
                    # Note: Keep other panels if they were manually enabled
                    config_changed=true
                fi
            fi
        fi
        
        # Image rotation (every 5 minutes when image panel is active)
        if [[ "$image_panel" == "true" ]]; then
            local current_time
            current_time=$(date +%s)
            local time_diff=$((current_time - last_image_update))
            
            log_message "Image check: last_update=$last_image_update, current=$current_time, diff=${time_diff}s"
            
            # Check if it's time to rotate (5 minutes = 300 seconds)
            if [[ $time_diff -gt 300 ]]; then
                log_message "Rotating image from Immich... ($(date '+%H:%M:%S')) - ${time_diff}s since last update"
                if get_new_image; then
                    config_changed=true
                    log_message "✓ Image rotation successful"
                else
                    log_message "✗ Image rotation failed, will retry next cycle"
                fi
            else
                log_message "Image rotation not due yet (${time_diff}s < 300s)"
            fi
        else
            log_message "Image panel disabled, skipping rotation"
        fi
        
        # Check if config changed
        local current_config_hash
        current_config_hash=$(md5sum "$CONFIG_FILE" 2>/dev/null | cut -d' ' -f1)
        
        if [[ "$config_changed" == "true" || "$current_config_hash" != "$last_config_hash" ]]; then
            log_message "Config changed, sending update... ($(date '+%H:%M:%S'))"
            write_config
            if send_config; then
                last_config_hash="$current_config_hash"
                log_message "✓ Config update successful"
            else
                log_message "✗ Config update failed, will retry next cycle"
            fi
        else
            log_message "No config changes detected"
        fi
        
        last_hour=$current_hour
        log_message "Sleeping for 60 seconds..."
        sleep 60
    done
    
    log_message "Daemon loop ended"
}

# Show current status
show_status() {
    read_config
    
    echo "=== NAS Display Status ==="
    echo "Config file: $CONFIG_FILE"
    echo "Current time: $(date '+%H:%M')"
    echo ""
    echo "Immich Configuration:"
    echo "  Server: $IMMICH_URL"
    echo "  People filter: ${IMMICH_PERSON_NAMES:-'(random images)'}"
    echo "  Magick executable: $(command -v "$MAGICK_CMD" >/dev/null 2>&1 && echo 'Available' || echo 'Missing') ($MAGICK_CMD)"
    echo ""
    echo "Current State:"
    echo "  Display: $([[ "$display_on" == "true" ]] && echo 'ON' || echo 'OFF')"
    echo "  Image panel: $image_panel"
    echo "  Stats panel: $stats_panel"
    echo "  Drive stats panel: $drive_stats_panel"
    echo "  Auto mode: $auto_mode"
    echo ""
    show_active_panels
    echo ""
    echo "Immich Image Info:"
    echo "  Last update: $(date -d "@$last_image_update" '+%H:%M:%S' 2>/dev/null || echo 'Never')"
    echo "  Image loaded: $([[ -n "$current_image" ]] && echo 'Yes' || echo 'No')"
    if [[ -n "$current_image" ]]; then
        echo "  Image size: ${#current_image} chars"
    fi
}

# Cleanup function
cleanup() {
    rm -f cookies.txt temp_image_* resized_* temp_payload_*.json
}

# Set up cleanup on exit
trap cleanup EXIT

# Command line interface
case "$1" in
    "test")
        test_connection
        ;;
    "test-immich")
        test_immich
        ;;
    "test-magick")
        echo "=== Testing Local Magick Executable ==="
        echo "Script directory: $SCRIPT_DIR"
        echo "Looking for: $MAGICK_CMD"
        
        if [[ -f "$MAGICK_CMD" ]]; then
            echo "✓ File exists"
            
            # Check file permissions
            if command -v "$MAGICK_CMD" >/dev/null 2>&1; then
                echo "✓ File is executable"
            else
                echo "✗ File is not executable - run: chmod +x $MAGICK_CMD"
                exit 1
            fi
            
            # Check file type and architecture
            echo "Checking file type and architecture..."
            file "$MAGICK_CMD" 2>/dev/null || echo "Unable to determine file type"
            
            # Check system architecture
            echo "System architecture: $(uname -m)"
            echo "System type: $(uname -s)"
            
            # Try to run magick with detailed error output
            echo "Testing magick version..."
            if "$MAGICK_CMD" -version >/dev/null 2>&1; then
                echo "✓ Magick executable works!"
                "$MAGICK_CMD" -version | head -3
            else
                echo "✗ Failed to run magick -version"
                echo "Detailed error output:"
                "$MAGICK_CMD" -version 2>&1 || true
                
                echo ""
                echo "Troubleshooting suggestions:"
                echo "1. Architecture mismatch - make sure you downloaded the Linux binary for your architecture"
                echo "2. Missing dependencies - the binary might need additional libraries"
                echo "3. Wrong binary type - if on WSL, ensure you have the Linux binary, not Windows"
                echo ""
                echo "Try downloading a different ImageMagick binary:"
                echo "- Static/AppImage: https://github.com/ImageMagick/ImageMagick/releases"
                echo "- Portable: https://imagemagick.org/script/download.php#linux"
                
                # Check for common dependency issues
                echo ""
                echo "Checking for common missing dependencies:"
                ldd "$MAGICK_CMD" 2>/dev/null | grep "not found" || echo "All dependencies seem to be available"
            fi
        else
            echo "✗ File not found"
            echo "Download ImageMagick portable binary and place as 'magick' next to this script"
            echo ""
            echo "Download options:"
            echo "1. AppImage (self-contained): https://github.com/ImageMagick/ImageMagick/releases"
            echo "2. Portable binary: https://imagemagick.org/script/download.php#linux"
            echo "3. Static build: https://johnvansickle.com/imagemagick/ (if available)"
        fi
        ;;
    "config")
        configure_immich "$@"
        ;;
    "night")
        set_night
        ;;
    "day")
        set_day
        ;;
    "image")
        set_image "$@"
        ;;
    "stats")
        set_stats "$@"
        ;;
    "drives"|"drive-stats")
        set_drive_stats "$@"
        ;;
    "toggle-image")
        toggle_image
        ;;
    "toggle-stats")
        toggle_stats
        ;;
    "toggle-drives")
        toggle_drive_stats
        ;;
    "clear")
        manual_clear
        ;;
    "send")
        send_config
        ;;
    "daemon")
        daemon_loop
        ;;
    "status")
        show_status
        ;;
    "--help"|"help")
        echo "NAS Display State Controller - Multi-Panel Support with Immich"
        echo "Usage: $0 {command} [options]"
        echo ""
        echo "DEFAULT: Runs in daemon mode when no command specified"
        echo ""
        echo "Display Commands:"
        echo "  night               - Turn screen OFF (keep current panels)"
        echo "  day                 - Turn screen ON (keep current panels)"
        echo ""
        echo "Panel Commands (can be combined):"
        echo "  image [0|1]         - 0=DISABLE image panel+screen OFF, 1=ENABLE panel+screen ON"
        echo "                       No param=ENABLE panel, screen unchanged"
        echo "  stats [0|1]         - 0=DISABLE stats panel+screen OFF, 1=ENABLE panel+screen ON" 
        echo "                       No param=ENABLE panel, screen unchanged"
        echo "  drives [0|1]        - 0=DISABLE drive stats+screen OFF, 1=ENABLE panel+screen ON"
        echo "                       No param=ENABLE panel, screen unchanged"
        echo ""
        echo "Toggle Commands:"
        echo "  toggle-image        - Toggle image panel on/off"
        echo "  toggle-stats        - Toggle main stats panel on/off"
        echo "  toggle-drives       - Toggle drive stats panel on/off"
        echo ""
        echo "Execution Commands:"
        echo "  send                - Send current config to NAS"
        echo "  test                - Test connection to NAS"
        echo "  test-immich         - Test Immich connection and API"
        echo "  test-magick         - Test local magick executable"
        echo "  config {setting}    - Configure Immich settings (url/key/people)"
        echo "  clear               - Clear all panels (debugging)"
        echo ""
        echo "Daemon Commands:"
        echo "  daemon              - Start background daemon (auto day/night + image rotation)"
        echo "  status              - Show current status"
        echo "  --help              - Show this help message"
        echo ""
        echo "Examples:"
        echo "  $0                  # Start daemon (default behavior)"
        echo "  $0 stats 0          # DISABLE stats panel + turn screen OFF"
        echo "  $0 stats 1          # ENABLE stats panel + turn screen ON"
        echo "  $0 image 1          # ENABLE image + get new photo + screen ON"
        echo "  $0 drives 0         # DISABLE drive stats + screen OFF"
        echo "  $0 send             # Apply current config to NAS"
        echo ""
        echo "Setup Requirements:"
        echo "  1. Place 'magick' executable in same directory as this script"
        echo "  2. Make it executable: chmod +x magick"
        echo "  3. Download from: https://imagemagick.org/script/download.php#linux"
        echo ""
        echo "Immich Configuration:"
        echo "  Current URL: $IMMICH_URL"
        echo "  People filter: ${IMMICH_PERSON_NAMES:-'(random images)'}"
        echo "  Magick executable: $(command -v "$MAGICK_CMD" >/dev/null 2>&1 && echo 'Found' || echo 'Missing') ($MAGICK_CMD)"
        echo ""
        echo "Note: Multiple panels can be active simultaneously!"
        echo "      The display will automatically rotate between them."
        echo "      Images are fetched from Immich server: $IMMICH_URL"
        echo "      Images resized to 960x376 with BLACK bars/background"
        echo "      Config persists across reboots in: $CONFIG_FILE"
        echo "      Auto daemon schedule:"
        echo "      Night (23:00-06:00): Screen OFF"
        echo "      Day (06:00-23:00): Screen ON + Image panel"
        ;;
    *)
        # Default: Start daemon mode
        echo "NAS Display Controller - Starting in daemon mode..."
        echo "Use '$0 --help' for command options"
        daemon_loop
        ;;
esac