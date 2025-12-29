# ============================================
# Stage 1: Build Svelte Frontend
# ============================================
FROM node:20-alpine AS frontend-builder

WORKDIR /build/frontend

# Copy package files
COPY frontend/package*.json ./

# Install all dependencies (including devDependencies needed for build)
RUN npm ci

# Copy frontend source
COPY frontend/ ./

# Build static files
RUN npm run build

# Debug: List build output
RUN echo "=== Build output structure ===" && \
    ls -la build/ && \
    echo "=== Checking for _app directory ===" && \
    ls -la build/_app/ || echo "No _app directory found"

# ============================================
# Stage 2: Build Go Backend
# ============================================
FROM golang:1.23-alpine AS backend-builder

WORKDIR /build/backend

# Install build dependencies
RUN apk add --no-cache git

# Copy go mod files
COPY backend/go.mod backend/go.sum* ./
RUN go mod download

# Copy backend source
COPY backend/ ./

# Create static directory and copy frontend build
RUN mkdir -p cmd/server/static
COPY --from=frontend-builder /build/frontend/build ./cmd/server/static/

# Debug: Verify static files were copied
RUN echo "=== Static files copied to Go backend ===" && \
    ls -la cmd/server/static/ && \
    echo "=== Checking _app directory ===" && \
    ls -la cmd/server/static/_app/ || echo "No _app directory in static"

# Build Go binary with embedded static files
RUN CGO_ENABLED=0 GOOS=linux go build \
    -a -installsuffix cgo \
    -ldflags="-w -s" \
    -o homepage \
    ./cmd/server

# ============================================
# Stage 3: Runtime
# ============================================
FROM alpine:latest

# Install runtime dependencies
RUN apk --no-cache add ca-certificates tzdata

WORKDIR /app

# Copy binary from builder
COPY --from=backend-builder /build/backend/homepage .

# Create cache directory
RUN mkdir -p /data/cache

# Create non-root user
RUN addgroup -g 1000 appuser && \
    adduser -D -u 1000 -G appuser appuser && \
    chown -R appuser:appuser /app /data

USER appuser

# Expose port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:8080/api/health || exit 1

# Run the application
CMD ["./homepage"]
