# Mailcow Configuration for Reverse Proxy

This directory contains the override configuration for running Mailcow behind Caddy reverse proxy.

## Setup Steps

1. **Install Mailcow** (if not already installed):
   ```bash
   cd /opt
   git clone https://github.com/mailcow/mailcow-dockerized mailcow
   cd mailcow
   ./generate_config.sh
   ```

2. **Copy the override file**:
   ```bash
   cp /path/to/configs/mailcow/docker-compose.override.yml /opt/mailcow/
   ```

3. **Update mailcow.conf**:
   ```bash
   cd /opt/mailcow
   # Set these variables in mailcow.conf:
   # HTTP_PORT=8081
   # HTTP_BIND=127.0.0.1
   # HTTPS_PORT=
   # SKIP_LETS_ENCRYPT=y
   ```

4. **Start Mailcow**:
   ```bash
   cd /opt/mailcow
   docker compose down
   docker compose up -d
   ```

## Caddy Configuration

The Caddy configuration automatically proxies `mail.mljr.eu` to `127.0.0.1:8081`.

## Troubleshooting

- **Port conflicts**: Ensure nginx-mailcow is NOT binding to ports 80/443
- **Check status**: `docker ps | grep nginx-mailcow`
- **View logs**: `docker logs mailcowdockerized-nginx-mailcow-1`
- **Test locally**: `curl -I http://127.0.0.1:8081`
