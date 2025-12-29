# Personal Homepage

A modern, lightweight personal homepage built with Svelte and Go. Features automatic data collection from GitHub, LinkedIn, and Strava.

## Features

- 🎨 **Modern UI** - Beautiful gradient design with smooth animations
- 📊 **Auto-Discovery** - Automatically fetches projects from GitHub
- 💼 **CV Integration** - Display experience and education from LinkedIn
- 🏃 **Activity Stats** - Show running stats from Strava
- 🐳 **Single Container** - Svelte frontend embedded in Go binary (~15MB)
- ⚡ **Fast** - Built with performance in mind

## Quick Start

### Development

1. **Install dependencies**:
   ```bash
   make install
   ```

2. **Run backend** (Terminal 1):
   ```bash
   make dev-backend
   ```

3. **Run frontend** (Terminal 2):
   ```bash
   make dev-frontend
   ```

4. **Visit**: http://localhost:5173

### Docker Build

```bash
# Build image
make build-docker

# Run container
make run-docker
```

## Architecture

```
Frontend (Svelte)
    ↓
API Endpoints (Go)
    ↓
Data Scrapers
    ↓
External APIs (GitHub, Strava, LinkedIn)
```

## Configuration

Copy `.env.example` to `.env` and fill in your API credentials:

```bash
cp .env.example .env
# Edit .env with your credentials
```

### Required for Production

- `GITHUB_TOKEN` - For GitHub API access
- `STRAVA_CLIENT_ID`, `STRAVA_CLIENT_SECRET`, `STRAVA_REFRESH_TOKEN` - For Strava integration

### Optional

- `LINKEDIN_API_KEY`, `LINKEDIN_API_SECRET` - For LinkedIn integration (v2)

## Project Structure

```
apps/homepage/
├── backend/               # Go application
│   ├── cmd/server/       # Entry point
│   ├── internal/
│   │   ├── api/          # HTTP handlers
│   │   ├── config/       # Configuration
│   │   ├── scrapers/     # Data collectors
│   │   └── storage/      # Cache layer
│   └── go.mod
├── frontend/             # Svelte application
│   ├── src/
│   │   ├── lib/
│   │   │   ├── components/
│   │   │   └── api.ts
│   │   └── routes/
│   └── package.json
├── Dockerfile            # Multi-stage build
└── Makefile              # Development commands
```

## Available Commands

- `make help` - Show all available commands
- `make install` - Install all dependencies
- `make dev-frontend` - Run frontend dev server
- `make dev-backend` - Run backend dev server
- `make build-docker` - Build Docker image
- `make test` - Run tests
- `make clean` - Clean build artifacts

## Deployment

This project is deployed via Ansible as part of the homelab-automation infrastructure. See the main repository for deployment instructions.

## License

MIT License - See LICENSE file for details
