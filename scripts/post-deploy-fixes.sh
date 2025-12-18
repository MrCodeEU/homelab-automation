#!/bin/bash
# Apply environment-specific fixes for proper operation
# This script is idempotent - safe to run multiple times
# Integrated into deployment workflow

set -e

echo "=== Applying Environment Fixes ==="

# Fix 1: SELinux context for Caddy logs (only if SELinux is enforcing)
if command -v getenforce &> /dev/null && [ "$(getenforce)" = "Enforcing" ]; then
    echo "1. Checking SELinux context for Caddy logs..."
    
    # Check if context is already set
    if ! semanage fcontext -l | grep -q '/opt/caddy/logs'; then
        echo "   Setting SELinux context..."
        semanage fcontext -a -t httpd_log_t '/opt/caddy/logs(/.*)?'
        restorecon -Rv /opt/caddy/logs
        echo "   ✓ SELinux contexts configured"
    else
        echo "   ⊘ SELinux context already set, skipping"
        # Still restore in case files were created without proper context
        restorecon -R /opt/caddy/logs 2>/dev/null || true
    fi
else
    echo "1. ⊘ SELinux not enforcing, skipping"
fi

# Fix 2: Caddy log directory permissions (only if needed)
if [ -d /opt/caddy ]; then
    echo "2. Checking Caddy directory permissions..."
    
    # Check if caddy user exists and owns the directory
    if id -u caddy &>/dev/null; then
        CURRENT_OWNER=$(stat -c '%U' /opt/caddy 2>/dev/null || echo "unknown")
        
        if [ "$CURRENT_OWNER" != "caddy" ]; then
            echo "   Fixing ownership..."
            chown -R caddy:caddy /opt/caddy/
            chmod -R u+w /opt/caddy/logs/ 2>/dev/null || true
            echo "   ✓ Permissions fixed"
        else
            echo "   ⊘ Permissions already correct"
        fi
    else
        echo "   ⊘ Caddy user not found, skipping"
    fi
else
    echo "2. ⊘ /opt/caddy not found, skipping"
fi

# Fix 3: Regenerate Caddyfile with localhost (instead of sed replacement that breaks special configs)
if [ -f /etc/caddy/Caddyfile ]; then
    echo "3. Checking Caddyfile for Tailscale hostname usage..."
    
    # Check if file contains Tailscale hostnames for local services (excluding remote ones like pi.tail)
    TAILSCALE_HOSTNAME=$(hostname -f 2>/dev/null | grep '\.ts\.net' || echo "")
    
    if [ -n "$TAILSCALE_HOSTNAME" ] && grep -q "reverse_proxy ${TAILSCALE_HOSTNAME}:" /etc/caddy/Caddyfile; then
        echo "   Regenerating Caddyfile to use localhost..."
        
        # Regenerate the Caddyfile if generate-configs.sh exists
        if [ -f /tmp/homelab-deploy/scripts/generate-configs.sh ] && [ -f /tmp/homelab-deploy/configs/services.yml ]; then
            bash /tmp/homelab-deploy/scripts/generate-configs.sh /tmp/homelab-deploy/configs/services.yml >/dev/null 2>&1
            
            # Reload Caddy if it's a system service
            if systemctl is-active --quiet caddy 2>/dev/null; then
                systemctl reload caddy
                echo "   ✓ Caddyfile regenerated and reloaded"
            else
                echo "   ✓ Caddyfile regenerated"
            fi
        else
            echo "   ⚠️  Cannot regenerate - config files not found, using sed fallback"
            # Fallback to old method (but document the limitation)
            sed -i "s|reverse_proxy ${TAILSCALE_HOSTNAME}:|reverse_proxy 127.0.0.1:|g" /etc/caddy/Caddyfile
            
            if systemctl is-active --quiet caddy 2>/dev/null; then
                systemctl reload caddy
                echo "   ⚠️  Caddyfile updated with sed (special configs may be lost)"
            fi
        fi
    else
        echo "   ⊘ Caddyfile already using localhost or no Tailscale hostname found"
    fi
else
    echo "3. ⊘ /etc/caddy/Caddyfile not found, skipping"
fi

# Fix 4: Restart GoAccess to pick up configuration changes (only if running and config changed)
if docker ps --format '{{.Names}}' | grep -q '^goaccess$'; then
    echo "4. Checking GoAccess configuration..."
    
    # Check if GoAccess needs restart (look for recent config changes)
    GOACCESS_STATUS=$(docker inspect goaccess --format '{{.State.Status}}' 2>/dev/null || echo "not-found")
    
    if [ "$GOACCESS_STATUS" = "restarting" ] || [ "$GOACCESS_STATUS" = "exited" ]; then
        echo "   GoAccess not healthy, restarting..."
        docker restart goaccess
        echo "   ✓ GoAccess restarted"
    else
        echo "   ⊘ GoAccess running normally"
    fi
else
    echo "4. ⊘ GoAccess not running, skipping"
fi

echo ""
echo "=== Environment Fixes Complete ==="
