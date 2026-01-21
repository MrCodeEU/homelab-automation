#!/bin/bash
# Keycloak post-deploy provisioning
# Provisions realm, client, and Google identity provider using Keycloak Admin API

set -eo pipefail

KEYCLOAK_URL="http://localhost:9732"
KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD}"
REALM_NAME="homelab"
CLIENT_ID="oauth2-proxy"
GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-}"
GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-}"
SERVICE_PATH="${SERVICE_PATH:-/opt/keycloak}"

log_info() { echo "[INFO] $1"; }
log_success() { echo "[SUCCESS] $1"; }
log_warn() { echo "[WARN] $1"; }
log_error() { echo "[ERROR] $1" >&2; }

# Helper function to make API calls with error checking
api_call() {
    local method="$1"
    local url="$2"
    local data="$3"
    local response
    local http_code

    if [ -n "$data" ]; then
        response=$(curl -s -w "\n%{http_code}" -X "$method" -H "$AUTH_HEADER" -H "Content-Type: application/json" "$url" -d "$data")
    else
        response=$(curl -s -w "\n%{http_code}" -X "$method" -H "$AUTH_HEADER" "$url")
    fi

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        log_error "API call failed: $method $url (HTTP $http_code)"
        log_error "Response: $body"
        return 1
    fi

    echo "$body"
    return 0
}

# Check for required secrets
if [ -z "$KEYCLOAK_ADMIN_PASSWORD" ]; then
    log_error "KEYCLOAK_ADMIN_PASSWORD not set - cannot provision Keycloak"
    log_error "Please set the secret and redeploy, or configure Keycloak manually"
    exit 1
fi

# Wait for Keycloak to be ready
log_info "Waiting for Keycloak to be ready..."
MAX_RETRIES=60
COUNT=0
until curl -sf "${KEYCLOAK_URL}/health/ready" > /dev/null 2>&1; do
    sleep 5
    COUNT=$((COUNT+1))
    if [ "$COUNT" -ge "$MAX_RETRIES" ]; then
        log_error "Timeout waiting for Keycloak after $((MAX_RETRIES * 5)) seconds"
        exit 1
    fi
    log_info "Waiting... ($COUNT/$MAX_RETRIES)"
done
log_success "Keycloak is ready"

# Get admin token
log_info "Authenticating as admin..."
TOKEN_RESPONSE=$(curl -sf -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" \
    -d "username=${KEYCLOAK_ADMIN}" \
    -d "password=${KEYCLOAK_ADMIN_PASSWORD}" \
    -d "grant_type=password" 2>&1) || {
    log_error "Failed to authenticate with Keycloak"
    log_error "Check KEYCLOAK_ADMIN_PASSWORD is correct"
    exit 1
}

TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token')

if [ -z "$TOKEN" ] || [ "$TOKEN" == "null" ]; then
    log_error "Failed to get admin token from response"
    log_error "Response: $TOKEN_RESPONSE"
    exit 1
fi
log_success "Authenticated successfully"

AUTH_HEADER="Authorization: Bearer $TOKEN"

# Check if realm exists
log_info "Checking if realm '${REALM_NAME}' exists..."
if curl -sf -H "$AUTH_HEADER" "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}" > /dev/null 2>&1; then
    log_info "Realm ${REALM_NAME} already exists"
else
    log_info "Creating realm: ${REALM_NAME}"
    if ! api_call "POST" "${KEYCLOAK_URL}/admin/realms" \
        "{\"realm\": \"${REALM_NAME}\", \"enabled\": true, \"displayName\": \"Homelab SSO\"}" > /dev/null; then
        log_error "Failed to create realm"
        exit 1
    fi
    log_success "Realm created"
fi

# Check if client exists
log_info "Checking if client '${CLIENT_ID}' exists..."
CLIENT_RESPONSE=$(api_call "GET" "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients?clientId=${CLIENT_ID}") || {
    log_error "Failed to query clients"
    exit 1
}
CLIENT_UUID=$(echo "$CLIENT_RESPONSE" | jq -r '.[0].id // empty')

if [ -z "$CLIENT_UUID" ]; then
    log_info "Creating client: ${CLIENT_ID}"

    # Generate client secret
    CLIENT_SECRET=$(openssl rand -base64 32 | tr -d '\n' | tr -- '+/' '-_')

    if ! api_call "POST" "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients" \
        "{
            \"clientId\": \"${CLIENT_ID}\",
            \"name\": \"OAuth2 Proxy\",
            \"enabled\": true,
            \"protocol\": \"openid-connect\",
            \"publicClient\": false,
            \"secret\": \"${CLIENT_SECRET}\",
            \"standardFlowEnabled\": true,
            \"directAccessGrantsEnabled\": false,
            \"serviceAccountsEnabled\": false,
            \"redirectUris\": [\"https://*.mljr.eu/oauth2/callback\"],
            \"webOrigins\": [\"https://*.mljr.eu\"],
            \"attributes\": {
                \"post.logout.redirect.uris\": \"https://*.mljr.eu/*\"
            }
        }" > /dev/null; then
        log_error "Failed to create client"
        exit 1
    fi

    log_success "Client created"
    echo ""
    echo "=============================================="
    echo "IMPORTANT: Save this client secret!"
    echo "OAUTH2_PROXY_CLIENT_SECRET=${CLIENT_SECRET}"
    echo "=============================================="
    echo ""

    # Save to durable location (service directory, not /tmp)
    mkdir -p "${SERVICE_PATH}"
    echo "OAUTH2_PROXY_CLIENT_SECRET=${CLIENT_SECRET}" > "${SERVICE_PATH}/client-secret.txt"
    chmod 600 "${SERVICE_PATH}/client-secret.txt"
    log_info "Client secret saved to ${SERVICE_PATH}/client-secret.txt"
else
    log_info "Client ${CLIENT_ID} already exists (UUID: ${CLIENT_UUID})"
fi

# Configure Google identity provider if credentials provided
if [ -n "$GOOGLE_CLIENT_ID" ] && [ -n "$GOOGLE_CLIENT_SECRET" ]; then
    log_info "Checking if Google identity provider exists..."
    if curl -sf -H "$AUTH_HEADER" "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/identity-provider/instances/google" > /dev/null 2>&1; then
        log_info "Google identity provider already configured"
    else
        log_info "Configuring Google identity provider"
        if ! api_call "POST" "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/identity-provider/instances" \
            "{
                \"alias\": \"google\",
                \"displayName\": \"Google\",
                \"providerId\": \"google\",
                \"enabled\": true,
                \"trustEmail\": true,
                \"firstBrokerLoginFlowAlias\": \"first broker login\",
                \"config\": {
                    \"clientId\": \"${GOOGLE_CLIENT_ID}\",
                    \"clientSecret\": \"${GOOGLE_CLIENT_SECRET}\",
                    \"defaultScope\": \"openid email profile\",
                    \"syncMode\": \"IMPORT\"
                }
            }" > /dev/null; then
            log_error "Failed to configure Google identity provider"
            exit 1
        fi
        log_success "Google identity provider configured"
    fi
else
    log_info "Google credentials not provided, skipping Google IdP configuration"
fi

log_success "Keycloak provisioning complete"
