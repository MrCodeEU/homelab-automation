# Example Service

This is a template directory for adding your own Docker services.

## How to Add Your Own Service

1. **Create a new directory** in `configs/docker/`:
   ```bash
   mkdir configs/docker/your-service
   ```

2. **Create docker-compose.yml**:
   ```bash
   cp configs/docker/example-service/docker-compose.yml configs/docker/your-service/
   ```

3. **Edit the docker-compose.yml** with your service configuration

4. **Deploy**:
   ```bash
   ./scripts/deploy-single.sh <hostname> root docker
   ```

## Example Services You Might Want to Add

### Media Server
- Plex, Jellyfin, or Emby
- Sonarr, Radarr for media management
- Transmission or qBittorrent for downloads

### Home Automation
- Home Assistant
- Node-RED
- MQTT broker (Mosquitto)

### Monitoring
- Prometheus
- Grafana
- Uptime Kuma
- Netdata

### Productivity
- Nextcloud (file sync and share)
- Bookstack (wiki/documentation)
- Vaultwarden (password manager)

### Network Services
- Pi-hole (DNS ad blocker)
- WireGuard (VPN)
- Nginx Proxy Manager

### Development
- GitLab or Gitea
- Jenkins or Drone CI
- Code-server (VS Code in browser)

## Service Configuration Tips

1. **Use volumes for persistence**: Always map important data to volumes
2. **Set restart policies**: Use `restart: unless-stopped` for production
3. **Configure resource limits**: Prevent services from consuming all resources
4. **Use environment files**: Store secrets in `.env` files (add to .gitignore)
5. **Network isolation**: Use custom networks for service communication
6. **Health checks**: Add health checks for critical services

## Example: Adding Nextcloud

```yaml
version: '3.8'

services:
  nextcloud:
    image: nextcloud:latest
    container_name: nextcloud
    restart: unless-stopped
    ports:
      - "8081:80"
    volumes:
      - nextcloud_data:/var/www/html
    environment:
      - MYSQL_HOST=db
      - MYSQL_DATABASE=nextcloud
      - MYSQL_USER=nextcloud
      - MYSQL_PASSWORD=secure_password
  
  db:
    image: mariadb:10.5
    container_name: nextcloud-db
    restart: unless-stopped
    volumes:
      - db_data:/var/lib/mysql
    environment:
      - MYSQL_ROOT_PASSWORD=secure_root_password
      - MYSQL_DATABASE=nextcloud
      - MYSQL_USER=nextcloud
      - MYSQL_PASSWORD=secure_password

volumes:
  nextcloud_data:
  db_data:
```

## Resources

- [Docker Compose documentation](https://docs.docker.com/compose/)
- [Docker Hub](https://hub.docker.com/) - Find container images
- [Awesome-Selfhosted](https://github.com/awesome-selfhosted/awesome-selfhosted) - List of self-hosted services
