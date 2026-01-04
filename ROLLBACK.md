# Rollback Procedures

This document describes how to rollback or recover from failed deployments.

## Quick Rollback

If a deployment fails or causes issues, follow these steps:

### 1. Stop Affected Services

```bash
# Stop all services on a host
cd /opt/<service-name>
docker compose down

# Or stop specific service
docker compose stop <service-name>
```

### 2. Restore from Backup

```bash
# List available backups
/opt/backups/scripts/restore.sh --list

# Restore specific service
/opt/backups/scripts/restore.sh --service <service-name>

# Force restore (overwrites existing data)
/opt/backups/scripts/restore.sh --force --service <service-name>
```

### 3. Revert to Previous Configuration

```bash
# Check recent commits
cd /path/to/homelab-automation
git log --oneline -10

# Checkout previous version
git checkout <previous-commit>

# Redeploy
cd ansible
ansible-playbook playbooks/site.yml --limit <host>
```

## Service-Specific Rollback

### Caddy (Reverse Proxy)

```bash
# Caddy keeps backups of Caddyfile
ls -la /etc/caddy/Caddyfile*

# Restore previous version
sudo cp /etc/caddy/Caddyfile.backup /etc/caddy/Caddyfile
sudo systemctl reload caddy

# Check status
sudo systemctl status caddy
curl -I https://yourdomain.com
```

### Docker Services

```bash
# View previous container versions
docker images <service-name> --format "{{.Tag}} {{.CreatedAt}}"

# Rollback to specific version by updating docker-compose.yml
cd /opt/<service-name>
vim docker-compose.yml  # Change image tag
docker compose up -d
```

### Mailcow

```bash
# Mailcow has its own backup/restore
cd /opt/mailcow-dockerized
./helper-scripts/backup_and_restore.sh backup all

# Restore
./helper-scripts/backup_and_restore.sh restore
```

## Database Rollback

### PostgreSQL (if used)

```bash
# List backups
ls -la /opt/backups/volumes/

# Stop service
docker compose -f /opt/<service>/docker-compose.yml down

# Restore volume
docker volume rm <service>_db_data
docker volume create <service>_db_data
docker run --rm -v <service>_db_data:/data -v /opt/backups/volumes/<service>:/backup alpine sh -c "cd /data && tar xvf /backup/db_data.tar.gz"

# Start service
docker compose -f /opt/<service>/docker-compose.yml up -d
```

## Full System Recovery

### 1. Fresh Install Recovery

If you need to completely rebuild a host:

```bash
# On the new/fresh host, the deployment will automatically detect it's new
# and restore from backup (if /opt/.homelab-initialized doesn't exist)

# From your local machine or CI/CD
cd homelab-automation/ansible
ansible-playbook playbooks/site.yml --limit <host>
```

### 2. Manual Fresh Install

```bash
# On the target host, remove initialization flag
sudo rm /opt/.homelab-initialized

# Run deployment - will trigger auto-restore
ansible-playbook playbooks/site.yml --limit <host>
```

### 3. Selective Restore

```bash
# Restore only critical services
ansible-playbook playbooks/site.yml --limit <host> --tags backup -e "force_restore=true"
```

## Configuration Rollback

### Revert group_vars Changes

```bash
cd homelab-automation
git diff HEAD~1 ansible/inventory/group_vars/

# If changes broke something, revert
git checkout HEAD~1 -- ansible/inventory/group_vars/
git commit -m "Revert: config changes"
git push

# Redeploy
cd ansible
ansible-playbook playbooks/site.yml
```

## Verification After Rollback

```bash
# Check service status
ansible all -m shell -a "docker ps --format '{{.Names}} {{.Status}}'"

# Check service health
curl -I https://service.yourdomain.com

# Check logs
docker compose -f /opt/<service>/docker-compose.yml logs --tail=50

# Test Caddy
curl -I https://yourdomain.com
sudo journalctl -u caddy -n 50
```

## Emergency Contact & Monitoring

1. **Check monitoring dashboards**:
   - Uptime Kuma: https://uptime.mljr.eu
   - Glance Dashboard: https://dash.mljr.eu

2. **Check notifications**:
   - ntfy: https://ntfy.mljr.eu

3. **Access logs**:
   - Caddy logs: `/var/log/caddy/access.log`
   - Service logs: `docker compose logs`

## Prevention

### Before Deployment

1. **Test in staging first**:
   ```bash
   ansible-playbook playbooks/site.yml -e is_staging_deployment=true
   ```

2. **Run in check mode**:
   ```bash
   ansible-playbook playbooks/site.yml --check
   ```

3. **Limit scope**:
   ```bash
   ansible-playbook playbooks/site.yml --limit <host> --tags <specific-tags>
   ```

### Backup Strategy

- Automated daily backups run at 3 AM
- Backups stored in pCloud: `homelab-backups/`
- Retention: 30 days
- Manual backup before major changes:
  ```bash
  /opt/backups/scripts/backup.sh
  ```

## Common Issues & Solutions

### Issue: Service won't start after deployment

```bash
# Check logs
docker compose -f /opt/<service>/docker-compose.yml logs

# Check .env file
cat /opt/<service>/.env

# Verify secrets are set
docker compose -f /opt/<service>/docker-compose.yml config
```

### Issue: Caddy returns 502 Bad Gateway

```bash
# Check if backend service is running
docker ps | grep <service>

# Check Caddy logs
sudo journalctl -u caddy -f

# Test backend directly
curl http://localhost:<port>
```

### Issue: Database connection failed

```bash
# Check if database container is running
docker ps | grep postgres

# Check database logs
docker compose logs db

# Verify database exists
docker exec -it <db-container> psql -U <user> -l
```

## Support

If rollback doesn't resolve the issue:

1. Check GitHub Issues: https://github.com/MrCodeEU/homelab-automation/issues
2. Review deployment logs in GitHub Actions
3. Check service-specific documentation in `services/<name>/README.md`
