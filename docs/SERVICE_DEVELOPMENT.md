# Service Development Guide

This guide explains how to add new services to your homelab automation using the hooks-based deployment system.

## Table of Contents

- [Quick Start](#quick-start)
- [Service Structure](#service-structure)
- [Deployment Hooks](#deployment-hooks)
- [Best Practices](#best-practices)
- [Examples](#examples)
- [Troubleshooting](#troubleshooting)

## Quick Start

### 1. Create Service Directory

```bash
# Create service directory with hooks
mkdir -p configs/my-service/hooks

# Or copy the example
cp -r configs/example-service configs/my-service
```

### 2. Add Docker Compose Configuration

Create `configs/my-service/docker-compose.yml`:

```yaml
version: '3.8'

services:
  my-service:
    image: my-app:latest
    container_name: my-service
    restart: unless-stopped
    ports:
      - "8080:80"
    volumes:
      - my-service-data:/data
    networks:
      - caddy_network
    environment:
      - TZ=Europe/London

volumes:
  my-service-data:

networks:
  caddy_network:
    external: true
```

### 3. Add to services.yml

Edit `configs/services.yml`:

```yaml
services:
  - name: my-service
    enabled: true
    domain: "my-service.mljr.eu"
    port: 8080
    host: mljr
    description: "My Custom Service"
    icon: "mdi:application"
```

### 4. Deploy

```bash
./scripts/deploy-single.sh your-host.tailnet-xxx.ts.net root rocky all
```

## Service Structure

### Minimal Service (No Hooks)

```
configs/my-service/
├── docker-compose.yml    # Required
└── README.md            # Optional but recommended
```

### Service with Hooks

```
configs/my-service/
├── docker-compose.yml    # Required
├── .env.example         # Optional - template for secrets
├── config.yml           # Optional - service-specific config
├── README.md            # Recommended
└── hooks/               # Optional
    ├── pre-deploy.sh    # Run before docker compose up
    ├── post-deploy.sh   # Run after docker compose up
    └── validate.sh      # Run after post-deploy for validation
```

## Deployment Hooks

Hooks are **optional** bash scripts that run at specific points during deployment.

### Hook Execution Order

```
1. Check if service is enabled in services.yml
2. Check for custom setup script (legacy)
3. Run pre-deploy.sh ✓
4. Copy files to /opt/<service-name>
5. Handle .env file and secrets
6. Validate port configuration
7. Run docker compose pull
8. Run docker compose up -d
9. Run post-deploy.sh ✓
10. Run validate.sh ✓
```

### Pre-Deploy Hook

**File:** `hooks/pre-deploy.sh`
**When:** Before `docker compose up`
**Purpose:** Preparation, validation, dependency checks
**Exit Code:** Non-zero aborts deployment

**Parameters:**
- `$1`: Service name
- `$2`: Path to services.yml

**Available variables:**
- `TARGET_DIR`: `/opt/<service-name>`
- `SERVICE_CONFIG_DIR`: Source config directory
- All functions from `common.sh` (log_info, log_success, etc.)

**Example:**

```bash
#!/bin/bash
set -e

SERVICE_NAME="$1"
SERVICES_FILE="$2"
TARGET_DIR="/opt/$SERVICE_NAME"

log_info "Running pre-deploy checks..."

# Validate configuration
if [ ! -f "$TARGET_DIR/config.yml" ]; then
    log_error "config.yml is required!"
    exit 1
fi

# Create required directories
mkdir -p "$TARGET_DIR/data"
mkdir -p "$TARGET_DIR/logs"

# Pre-pull images
cd "$TARGET_DIR"
docker compose pull

log_success "Pre-deploy checks passed"
```

### Post-Deploy Hook

**File:** `hooks/post-deploy.sh`
**When:** After `docker compose up`
**Purpose:** Initialization, data migration, notifications
**Exit Code:** Non-zero logs warning (doesn't stop deployment)

**Parameters:**
- `$1`: Service name
- `$2`: Path to services.yml

**Example:**

```bash
#!/bin/bash
set -e

SERVICE_NAME="$1"
TARGET_DIR="/opt/$SERVICE_NAME"

log_info "Running post-deploy tasks..."

# Wait for service to start
sleep 3

# Initialize database
docker exec "$SERVICE_NAME" /app/init-db.sh

# Create default admin user
docker exec "$SERVICE_NAME" /app/create-admin.sh

# Send notification
curl -X POST -H "Title: Service Deployed" \
     -d "$SERVICE_NAME deployed successfully" \
     https://ntfy.mljr.eu/deployment

log_success "Post-deploy tasks completed"
```

### Validation Hook

**File:** `hooks/validate.sh`
**When:** After post-deploy
**Purpose:** Health checks, smoke tests, integration tests
**Exit Code:** Non-zero logs warning

**Parameters:**
- `$1`: Service name
- `$2`: Path to services.yml

**Example:**

```bash
#!/bin/bash
set -e

SERVICE_NAME="$1"

log_info "Validating deployment..."

# Check container is running
if ! docker ps | grep -q "$SERVICE_NAME"; then
    log_error "Container is not running"
    exit 1
fi

# HTTP health check
if ! curl -f -s http://localhost:8080/health > /dev/null; then
    log_error "Health check failed"
    exit 1
fi

# Check for errors in logs
if docker logs "$SERVICE_NAME" --tail 50 | grep -i "fatal\|error" > /dev/null; then
    log_warn "Found errors in logs"
fi

log_success "All validations passed"
```

## Best Practices

### 1. Hook Scripts

- ✅ **DO** use `set -e` to fail fast on errors
- ✅ **DO** make hooks executable: `chmod +x hooks/*.sh`
- ✅ **DO** use logging functions from common.sh
- ✅ **DO** validate inputs and configurations
- ✅ **DO** clean up on failure (where possible)
- ❌ **DON'T** assume the hook will run in a specific directory
- ❌ **DON'T** use interactive commands
- ❌ **DON'T** hardcode paths (use `$TARGET_DIR`, `$SERVICE_NAME`)

### 2. Docker Compose

- ✅ **DO** connect to `caddy_network` for reverse proxy
- ✅ **DO** use named volumes for data persistence
- ✅ **DO** set `restart: unless-stopped`
- ✅ **DO** expose ports to host (for Caddy to proxy)
- ✅ **DO** use environment variables for configuration
- ❌ **DON'T** use host networking unless absolutely necessary
- ❌ **DON'T** hardcode values (use .env files)

### 3. Configuration

- ✅ **DO** provide `.env.example` for required secrets
- ✅ **DO** document all environment variables
- ✅ **DO** use sensible defaults
- ✅ **DO** validate configuration before starting
- ❌ **DON'T** commit secrets to the repository

### 4. Documentation

- ✅ **DO** create a README.md for your service
- ✅ **DO** document required secrets
- ✅ **DO** explain what each hook does
- ✅ **DO** provide examples
- ✅ **DO** list dependencies

## Examples

### Example 1: Simple Service (No Hooks)

```yaml
# configs/simple-app/docker-compose.yml
version: '3.8'
services:
  simple-app:
    image: nginx:alpine
    container_name: simple-app
    restart: unless-stopped
    ports:
      - "8888:80"
    networks:
      - caddy_network

networks:
  caddy_network:
    external: true
```

### Example 2: Service with Database Initialization

```bash
# configs/db-app/hooks/post-deploy.sh
#!/bin/bash
set -e

SERVICE_NAME="$1"

log_info "Initializing database..."

# Wait for database to be ready
until docker exec "$SERVICE_NAME" pg_isready; do
    log_info "Waiting for database..."
    sleep 2
done

# Run migrations
docker exec "$SERVICE_NAME" npm run migrate

# Create default data
docker exec "$SERVICE_NAME" npm run seed

log_success "Database initialized"
```

### Example 3: Service with Health Check

```bash
# configs/api-service/hooks/validate.sh
#!/bin/bash
set -e

SERVICE_NAME="$1"

log_info "Validating API service..."

# Test API endpoint
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/health)

if [ "$RESPONSE" != "200" ]; then
    log_error "Health check returned $RESPONSE"
    exit 1
fi

# Test database connectivity
if ! docker exec "$SERVICE_NAME" node -e "require('./db').ping()"; then
    log_error "Database connectivity check failed"
    exit 1
fi

log_success "API service is healthy"
```

## Advanced Topics

### Conditional Hook Execution

You can use environment variables or service configuration to conditionally run hooks:

```bash
#!/bin/bash
set -e

SERVICE_NAME="$1"
SERVICES_FILE="$2"

# Read configuration from services.yml
INIT_DB=$(yq eval ".services[] | select(.name == \"$SERVICE_NAME\") | .init_db // false" "$SERVICES_FILE")

if [ "$INIT_DB" = "true" ]; then
    log_info "Initializing database..."
    docker exec "$SERVICE_NAME" /app/init-db.sh
else
    log_info "Skipping database initialization"
fi
```

### Shared Utilities

Create shared utility scripts that multiple services can use:

```bash
# hooks/pre-deploy.sh
SERVICE_NAME="$1"

# Source shared utilities
source "$(dirname "$0")/utils/wait-for-service.sh"

log_info "Running pre-deploy..."

# Use shared function
wait_for_service "database" 5432
```

### Multi-Container Services

For services with multiple containers:

```bash
# hooks/validate.sh
#!/bin/bash
set -e

SERVICE_NAME="$1"

log_info "Validating multi-container service..."

# Check all containers are running
for container in "${SERVICE_NAME}-app" "${SERVICE_NAME}-db" "${SERVICE_NAME}-cache"; do
    if ! docker ps | grep -q "$container"; then
        log_error "Container $container is not running"
        exit 1
    fi
    log_info "✓ $container is running"
done

log_success "All containers are running"
```

## Troubleshooting

### Hook Not Running

1. **Check hook exists and is executable:**
   ```bash
   ls -la configs/my-service/hooks/
   chmod +x configs/my-service/hooks/*.sh
   ```

2. **Check for syntax errors:**
   ```bash
   bash -n configs/my-service/hooks/pre-deploy.sh
   ```

3. **Check deployment logs:**
   Look for "Running pre-deploy hook..." in the deployment output

### Hook Failing

1. **Run hook manually:**
   ```bash
   cd /opt/my-service
   bash hooks/pre-deploy.sh my-service /tmp/homelab-deploy/configs/services.yml
   ```

2. **Add debugging:**
   ```bash
   #!/bin/bash
   set -ex  # Enable debug output
   ```

3. **Check logs:**
   ```bash
   docker logs my-service
   ```

### Service Not Starting

1. **Check docker compose configuration:**
   ```bash
   cd /opt/my-service
   docker compose config
   ```

2. **Check port conflicts:**
   ```bash
   netstat -tulpn | grep 8080
   ```

3. **Check networks:**
   ```bash
   docker network ls
   docker network inspect caddy_network
   ```

## Migration from Legacy Setup Scripts

If you have existing `scripts/setup-<service>.sh` files, you can migrate to hooks:

1. **Move setup logic to hooks:**
   - Pre-deploy preparation → `hooks/pre-deploy.sh`
   - Post-deployment tasks → `hooks/post-deploy.sh`
   - Health checks → `hooks/validate.sh`

2. **Update service directory:**
   ```bash
   mkdir -p configs/my-service/hooks
   # Move relevant code from setup-my-service.sh
   ```

3. **Test:**
   ```bash
   ./scripts/deploy-single.sh your-host root rocky all
   ```

4. **Remove legacy script:**
   ```bash
   rm scripts/setup-my-service.sh
   ```

**Note:** Legacy setup scripts are still supported for backward compatibility.

## Complete Example

See [configs/example-service](../configs/example-service/README.md) for a complete, working example with all hooks implemented.

## Additional Resources

- [Docker Compose Documentation](https://docs.docker.com/compose/)
- [Caddy Documentation](https://caddyserver.com/docs/)
- [Example Service](../configs/example-service/README.md)
- [Main README](../README.md)

## Need Help?

- Check existing services in `configs/` for examples
- Review deployment logs for errors
- Open an issue on GitHub
