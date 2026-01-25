#!/bin/bash
# Post-deploy hook for speedtest service
# Adds all managed homelab hosts as devices for network monitoring

set -e

API_URL="http://localhost:8089/api"
MAX_RETRIES=30
RETRY_INTERVAL=2

echo "Speedtest post-deploy: Waiting for service to be ready..."

# Wait for API to be available
for i in $(seq 1 $MAX_RETRIES); do
    if curl -s -o /dev/null -w "%{http_code}" "${API_URL}/devices" | grep -q "200"; then
        echo "Speedtest API is ready"
        break
    fi
    if [ $i -eq $MAX_RETRIES ]; then
        echo "ERROR: Speedtest API did not become ready in time"
        exit 1
    fi
    echo "Waiting for API... (attempt $i/$MAX_RETRIES)"
    sleep $RETRY_INTERVAL
done

# Function to add or update a device
add_device() {
    local name=$1
    local hostname=$2
    local ip=$3
    local ssh_user=$4
    local ssh_port=${5:-22}

    # Check if device already exists and get its ID
    existing_device=$(curl -s "${API_URL}/devices" | grep -o "{[^}]*\"name\":\"${name}\"[^}]*}" || true)

    if [ -n "$existing_device" ]; then
        # Extract device ID
        device_id=$(echo "$existing_device" | grep -o '"id":[0-9]*' | grep -o '[0-9]*')

        if [ -n "$device_id" ]; then
            echo "Updating existing device '${name}' (id: ${device_id})"

            response=$(curl -s -w "\n%{http_code}" -X PUT "${API_URL}/devices/${device_id}" \
                -H "Content-Type: application/json" \
                -d "{
                    \"name\": \"${name}\",
                    \"hostname\": \"${hostname}\",
                    \"ip\": \"${ip}\",
                    \"ssh_user\": \"${ssh_user}\",
                    \"ssh_port\": ${ssh_port}
                }")

            http_code=$(echo "$response" | tail -n1)
            body=$(echo "$response" | sed '$d')

            if [ "$http_code" = "200" ]; then
                echo "Successfully updated device: ${name}"
            else
                echo "Warning: Failed to update device ${name} (HTTP ${http_code}): ${body}"
            fi
            return 0
        fi
    fi

    echo "Adding device: ${name} (${hostname} / ${ip})"

    response=$(curl -s -w "\n%{http_code}" -X POST "${API_URL}/devices" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"${name}\",
            \"hostname\": \"${hostname}\",
            \"ip\": \"${ip}\",
            \"ssh_user\": \"${ssh_user}\",
            \"ssh_port\": ${ssh_port}
        }")

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
        echo "Successfully added device: ${name}"
    else
        echo "Warning: Failed to add device ${name} (HTTP ${http_code}): ${body}"
    fi
}

echo "Adding managed hosts as devices..."

# Note: We use IP addresses for hostnames because the Docker container
# doesn't have access to Tailscale MagicDNS for resolving .ts.net hostnames

# Managed Rocky Linux hosts
add_device "mljr" "100.100.20.1" "100.100.20.1" "root" 22
add_device "nuc" "100.100.10.1" "100.100.10.1" "root" 22

# Unraid NAS
add_device "nas" "100.100.10.2" "100.100.10.2" "root" 22

echo "Speedtest post-deploy complete"
