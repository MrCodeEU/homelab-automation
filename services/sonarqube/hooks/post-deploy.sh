#!/bin/bash
# Post-deploy hook for SonarQube to set initial admin password

SERVICE_NAME="${1:-sonarqube}"
SERVICE_PATH="${2:-.}"

# Load environment variables
if [ -f "${SERVICE_PATH}/.env" ]; then
    source "${SERVICE_PATH}/.env"
fi

# Check if admin password is set and not default
if [ -z "$SONARQUBE_ADMIN_PASSWORD" ] || [ "$SONARQUBE_ADMIN_PASSWORD" == "admin" ]; then
    echo "No custom admin password set. Skipping."
    exit 0
fi

URL="http://localhost:9000"
MAX_RETRIES=30
SLEEP_TIME=10

echo "Waiting for SonarQube to be ready..."
for ((i=1; i<=MAX_RETRIES; i++)); do
    STATUS=$(curl -s "$URL/api/system/status")
    if echo "$STATUS" | grep -q '"status":"UP"'; then
        echo "SonarQube is UP."
        break
    fi
    echo "Waiting for SonarQube... ($i/$MAX_RETRIES) Status: $STATUS"
    sleep $SLEEP_TIME
done

if [ $i -gt $MAX_RETRIES ]; then
    echo "SonarQube did not start in time."
    exit 1
fi

echo "Attempting to change admin password..."

# Try to change password assuming default credentials (admin:admin)
# We use -f to fail on HTTP errors (like 401 Unauthorized which implies wrong password)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -u admin:admin -X POST "$URL/api/users/change_password?login=admin&previousPassword=admin&password=$SONARQUBE_ADMIN_PASSWORD")

if [ "$HTTP_CODE" -eq 200 ] || [ "$HTTP_CODE" -eq 204 ]; then
    echo "Successfully changed admin password."
    echo "CHANGED"
elif [ "$HTTP_CODE" -eq 401 ]; then
    echo "Could not login with default credentials (admin:admin). Password might already be changed."
    
    # Verify if new password works
    HTTP_CODE_NEW=$(curl -s -o /dev/null -w "%{http_code}" -u admin:$SONARQUBE_ADMIN_PASSWORD "$URL/api/users/search?q=admin")
    if [ "$HTTP_CODE_NEW" -eq 200 ]; then
         echo "Verified: Admin password is already correctly set."
         exit 0
    else
         echo "Warning: Current password is neither 'admin' nor the configured new password."
         exit 0
    fi
else
    echo "Failed to change password. HTTP Code: $HTTP_CODE"
    # Don't fail the deployment, just warn
    exit 0
fi
