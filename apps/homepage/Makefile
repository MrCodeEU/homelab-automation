.PHONY: help dev-frontend dev-backend build-docker run-docker clean install \
	test test-frontend test-backend lint lint-frontend lint-backend format check-all

help:
	@echo "Homepage Development Commands:"
	@echo ""
	@echo "Development:"
	@echo "  make install          - Install dependencies (frontend + backend)"
	@echo "  make dev-frontend     - Run frontend dev server (port 5173)"
	@echo "  make dev-backend      - Run backend dev server (port 8080)"
	@echo ""
	@echo "Testing:"
	@echo "  make test             - Run all tests (frontend + backend)"
	@echo "  make test-frontend    - Run frontend tests"
	@echo "  make test-backend     - Run backend tests"
	@echo "  make test-watch       - Run frontend tests in watch mode"
	@echo ""
	@echo "Linting & Formatting:"
	@echo "  make lint             - Run all linters"
	@echo "  make lint-frontend    - Lint frontend code"
	@echo "  make lint-backend     - Lint backend code"
	@echo "  make format           - Format all code"
	@echo "  make check-all        - Run all checks (lint + test + type-check)"
	@echo ""
	@echo "Docker:"
	@echo "  make build-docker     - Build Docker image"
	@echo "  make run-docker       - Run Docker container"
	@echo ""
	@echo "Utilities:"
	@echo "  make clean            - Clean build artifacts"
	@echo ""

install:
	@echo "Installing frontend dependencies..."
	cd frontend && npm install
	@echo "Downloading Go dependencies..."
	cd backend && go mod download
	@echo "✅ Dependencies installed"

dev-frontend:
	@echo "Starting frontend dev server on http://localhost:5173"
	cd frontend && npm run dev

dev-backend:
	@echo "Starting backend dev server on http://localhost:8080"
	cd backend && go run cmd/server/main.go

build-docker:
	@echo "Building Docker image..."
	docker build -t homepage:latest .
	@echo "✅ Docker image built: homepage:latest"

run-docker:
	@echo "Stopping existing container if running..."
	docker stop homepage && docker rm homepage || true
	@echo "Running Docker container..."
	docker run -d \
		--name homepage \
		-p 8080:8080 \
		-e PORT=8080 \
		-e GITHUB_USERNAME=mrcodeeu \
		homepage:latest
	@echo "✅ Container running: http://localhost:8080"
	@echo "View logs: docker logs -f homepage"
	@echo "Stop: docker stop homepage && docker rm homepage"

# Testing
test: test-backend test-frontend
	@echo "✅ All tests passed"

test-backend:
	@echo "Running backend tests..."
	cd backend && go test -v -race -coverprofile=coverage.out ./...
	@echo "✅ Backend tests passed"

test-frontend:
	@echo "Running frontend tests..."
	cd frontend && npm run test
	@echo "✅ Frontend tests passed"

test-watch:
	@echo "Running frontend tests in watch mode..."
	cd frontend && npm run test:watch

# Linting
lint: lint-backend lint-frontend
	@echo "✅ All linting passed"

lint-backend:
	@echo "Linting backend code..."
	@if ! command -v golangci-lint &> /dev/null; then \
		echo "golangci-lint not found. Installing..."; \
		go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest; \
	fi
	cd backend && golangci-lint run ./...
	@echo "✅ Backend linting passed"

lint-frontend:
	@echo "Linting frontend code..."
	cd frontend && npm run lint
	@echo "✅ Frontend linting passed"

# Formatting
format:
	@echo "Formatting code..."
	cd frontend && npm run format
	cd backend && gofmt -w .
	@echo "✅ Code formatted"

# Comprehensive check
check-all: lint test
	@echo "Running type checks..."
	cd frontend && npm run check
	@echo "✅ All checks passed"

clean:
	@echo "Cleaning build artifacts..."
	rm -rf frontend/build
	rm -rf frontend/.svelte-kit
	rm -rf frontend/node_modules
	rm -f backend/homepage
	@echo "✅ Clean complete"

# Quick development setup
dev: install
	@echo "Starting development environment..."
	@echo "Open two terminals:"
	@echo "  Terminal 1: make dev-backend"
	@echo "  Terminal 2: make dev-frontend"
	@echo "Then visit: http://localhost:5173"
