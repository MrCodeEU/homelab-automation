# Example Service

This is an example service demonstrating the hooks-based deployment system.

**Note:** This service is for documentation purposes only and is not deployed by default.

## Structure

```
example-service/
├── docker-compose.yml       # Standard Docker Compose configuration
├── README.md               # This file
└── hooks/                  # Optional deployment hooks
    ├── pre-deploy.sh       # Runs before docker compose up
    ├── post-deploy.sh      # Runs after docker compose up
    └── validate.sh         # Runs after post-deploy for health checks
```

## Hooks

### pre-deploy.sh (Optional)
Runs **before** `docker compose up`.

**Use cases:**
- Create required directories
- Validate configuration
- Check dependencies
- Pull latest images
- Database migrations (before deployment)
- Backup current data

**Parameters:**
- `$1`: Service name (e.g., "example-service")
- `$2`: Path to services.yml
- `TARGET_DIR`: `/opt/<service-name>`

**Exit codes:**
- `0`: Success, continue with deployment
- `non-zero`: Failure, abort deployment

### post-deploy.sh (Optional)
Runs **after** `docker compose up`.

**Use cases:**
- Initialize database
- Create default users/data
- Run setup commands inside container
- Send deployment notifications
- Update external systems
- Warm up caches

**Parameters:**
- `$1`: Service name
- `$2`: Path to services.yml
- `TARGET_DIR`: `/opt/<service-name>`

**Exit codes:**
- `0`: Success
- `non-zero`: Failure (warning, doesn't stop deployment)

### validate.sh (Optional)
Runs **after** post-deploy to verify the service is working.

**Use cases:**
- HTTP health checks
- Database connectivity tests
- API smoke tests
- Log error checking
- Container status validation
- Integration tests

**Parameters:**
- `$1`: Service name
- `$2`: Path to services.yml
- `TARGET_DIR`: `/opt/<service-name>`

**Exit codes:**
- `0`: Validation passed
- `non-zero`: Validation failed (warning)

## Example Usage

To add this service to your deployment:

1. Enable it in `configs/services.yml`:
```yaml
services:
  - name: example-service
    enabled: true
    domain: "example.mljr.eu"
    port: 8888
    host: mljr
    description: "Example Service"
    icon: "mdi:test-tube"
```

2. Deploy:
```bash
./scripts/deploy-single.sh mljr root rocky all
```

3. The deployment will automatically:
   - Run `pre-deploy.sh` (if exists)
   - Copy files to `/opt/example-service`
   - Run `docker compose up -d`
   - Run `post-deploy.sh` (if exists)
   - Run `validate.sh` (if exists)

## Creating Your Own Service

1. Copy this folder structure:
```bash
cp -r configs/example-service configs/my-service
```

2. Edit `docker-compose.yml` with your service configuration

3. Customize hooks or remove them if not needed

4. Add to `services.yml`

5. Deploy!

## Notes

- All hooks are **optional** - standard services work without any hooks
- Hooks must be executable (`chmod +x`)
- Hooks run in the context of the deployment server
- Use `set -e` to fail fast on errors
- Test your hooks locally before deploying
- Hooks have access to common.sh functions (log_info, log_success, etc.)
