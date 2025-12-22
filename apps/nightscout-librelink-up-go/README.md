# Nightscout LibreLink Up Go

A lightweight, well-architected Go application that fetches blood glucose data from LibreLink Up and posts it to Nightscout.

## Features

- 🔒 Secure authentication with LibreLink Up
- 🩸 Automatic glucose data polling at configurable intervals
- 📊 Posts readings to Nightscout with trend arrows
- 🐳 Minimal Docker image (~10MB)
- ⚡ Built with Go 1.23 for performance
- 🔄 Graceful shutdown handling
- 📝 Comprehensive logging

## Architecture

```
LibreLink Up API → Go Application → Nightscout API
                   ├── config/     (configuration)
                   ├── librelink/  (LibreLink client)
                   └── nightscout/ (Nightscout client)
```

## Environment Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `LINK_UP_USERNAME` | LibreLink Up email address | - | ✅ |
| `LINK_UP_PASSWORD` | LibreLink Up password | - | ✅ |
| `LINK_UP_REGION` | Region (EU, US, DE, etc.) | `EU` | ❌ |
| `LINK_UP_TIME_INTERVAL` | Polling interval in minutes | `5` | ❌ |
| `NIGHTSCOUT_URL` | Nightscout URL (e.g., `nightscout:1337`) | - | ✅ |
| `NIGHTSCOUT_API_TOKEN` | Nightscout API secret (SHA1 hash) | - | ✅ |

## Supported Regions

- `AE` - United Arab Emirates
- `AP` - Asia-Pacific
- `AU` - Australia
- `CA` - Canada
- `DE` - Germany
- `EU` - Europe
- `EU2` - Europe 2
- `FR` - France
- `JP` - Japan
- `US` - United States
- `LA` - Latin America
- `RU` - Russia
- `CN` - China

## Building

### Local Build
```bash
go build -o nightscout-librelink-up-go .
```

### Docker Build
```bash
docker build -t ghcr.io/mrcodeeu/nightscout-librelink-up-go:latest .
```

## Running

### Using Docker
```bash
docker run -d \
  --name nightscout-librelink-up \
  -e LINK_UP_USERNAME="your@email.com" \
  -e LINK_UP_PASSWORD="yourpassword" \
  -e LINK_UP_REGION="EU" \
  -e LINK_UP_TIME_INTERVAL="5" \
  -e NIGHTSCOUT_URL="nightscout:1337" \
  -e NIGHTSCOUT_API_TOKEN="your-api-token" \
  ghcr.io/mrcodeeu/nightscout-librelink-up-go:latest
```

### Using Docker Compose
See the main `configs/nightscout/docker-compose.yml` in the homelab-automation repository.

## Development

### Project Structure
```
.
├── main.go              # Application entry point
├── config/
│   └── config.go       # Configuration handling
├── librelink/
│   └── client.go       # LibreLink Up API client
├── nightscout/
│   └── client.go       # Nightscout API client
├── Dockerfile          # Multi-stage Docker build
├── go.mod              # Go module definition
└── README.md           # This file
```

### Testing Locally
```bash
export LINK_UP_USERNAME="your@email.com"
export LINK_UP_PASSWORD="yourpassword"
export LINK_UP_REGION="EU"
export NIGHTSCOUT_URL="localhost:1337"
export NIGHTSCOUT_API_TOKEN="your-token"

go run main.go
```

## Differences from timoschlueter/nightscout-librelink-up

This Go implementation provides:
- **Smaller image size**: ~10MB vs ~500MB
- **Lower memory footprint**: ~5-10MB vs ~50-100MB
- **Faster startup**: Native Go vs Node.js
- **Better performance**: Compiled binary vs interpreted JavaScript
- **Type safety**: Go's strong typing vs JavaScript
- **Simpler deployment**: Single binary, no npm dependencies

## License

Part of the homelab-automation project by MrCodeEU.
