# Testing & Quality Assurance

This document describes the testing and code quality tools configured for the homepage project.

## Quick Start

```bash
# Run all checks (recommended before committing)
make check-all

# Individual commands
make test           # Run all tests
make lint           # Run all linters
make format         # Format all code
```

## Backend (Go)

### Testing

We use Go's built-in testing framework with coverage reporting.

```bash
# Run tests
make test-backend

# Run with verbose output
cd backend && go test -v ./...

# Generate coverage report
cd backend && go test -coverprofile=coverage.out ./...
cd backend && go tool cover -html=coverage.out
```

**Test files:**
- `backend/cmd/server/main_test.go` - API handler tests
- `backend/internal/config/config_test.go` - Configuration tests

**Coverage target:** >80%

### Linting

We use [golangci-lint](https://golangci-lint.run/) with a comprehensive set of linters.

```bash
# Run linter
make lint-backend

# Install golangci-lint (auto-installed by Makefile if missing)
go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest
```

**Configuration:** `.golangci.yml`

**Enabled linters:**
- **Code quality:** errcheck, gosimple, govet, staticcheck, revive
- **Style:** gofmt, goimports, stylecheck
- **Security:** gosec
- **Performance:** bodyclose, noctx
- **Complexity:** gocyclo, dupl

### Formatting

```bash
# Format Go code
cd backend && gofmt -w .
```

## Frontend (Svelte + TypeScript)

### Testing

We use [Vitest](https://vitest.dev/) with Testing Library for component testing.

```bash
# Run tests
make test-frontend

# Watch mode
make test-watch

# With UI
cd frontend && npm run test -- --ui

# Coverage
cd frontend && npm run test -- --coverage
```

**Test files:**
- `frontend/src/lib/api.test.ts` - API client tests
- Add `*.test.ts` or `*.spec.ts` files next to components

**Configuration:** `frontend/vitest.config.ts`

### Linting

We use [ESLint](https://eslint.org/) with Svelte plugin and TypeScript support.

```bash
# Run linter
make lint-frontend

# Auto-fix issues
cd frontend && npm run lint:fix
```

**Configuration:** `frontend/eslint.config.js`

### Formatting

We use [Prettier](https://prettier.io/) with Svelte plugin.

```bash
# Format code
cd frontend && npm run format

# Check formatting
cd frontend && prettier --check .
```

**Configuration:** `frontend/.prettierrc`

### Type Checking

We use `svelte-check` for TypeScript validation.

```bash
# Check types
cd frontend && npm run check

# Watch mode
cd frontend && npm run check:watch
```

## Continuous Integration

GitHub Actions workflow runs automatically on push and PR:

**Workflow:** `.github/workflows/test.yml`

**Jobs:**
1. **backend** - Go tests and linting
2. **frontend** - TypeScript tests and linting
3. **build-docker** - Docker build test

**Status:** Check the Actions tab in GitHub

## Pre-commit Checklist

Before committing code, ensure:

```bash
# 1. Run all checks
make check-all

# Or individually:
make lint          # Check code style
make test          # Run all tests
make format        # Format code
```

## IDE Integration

### VS Code

Recommended extensions:
- **Go:** `golang.go`
- **Svelte:** `svelte.svelte-vscode`
- **ESLint:** `dbaeumer.vscode-eslint`
- **Prettier:** `esbenp.prettier-vscode`

Settings:
```json
{
  "editor.formatOnSave": true,
  "editor.defaultFormatter": "esbenp.prettier-vscode",
  "[go]": {
    "editor.defaultFormatter": "golang.go"
  },
  "[svelte]": {
    "editor.defaultFormatter": "svelte.svelte-vscode"
  }
}
```

### GoLand / WebStorm

- Enable golangci-lint integration
- Enable Prettier integration
- Enable ESLint integration

## Writing Tests

### Backend (Go)

```go
func TestHandleHealth(t *testing.T) {
    req := httptest.NewRequest(http.MethodGet, "/api/health", nil)
    w := httptest.NewRecorder()

    handleHealth(w, req)

    if w.Code != http.StatusOK {
        t.Errorf("Expected status 200, got %d", w.Code)
    }
}
```

### Frontend (TypeScript)

```typescript
import { describe, it, expect, vi } from 'vitest';
import { getCV } from './api';

describe('getCV', () => {
    it('should fetch CV data', async () => {
        global.fetch = vi.fn().mockResolvedValueOnce({
            ok: true,
            json: async () => ({ name: 'Test' })
        });

        const result = await getCV();
        expect(result.name).toBe('Test');
    });
});
```

## Coverage Reports

### Backend

```bash
cd backend
go test -coverprofile=coverage.out ./...
go tool cover -html=coverage.out
```

### Frontend

```bash
cd frontend
npm run test -- --coverage
# Open: coverage/index.html
```

## Troubleshooting

### golangci-lint not found

```bash
go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest
```

### Frontend tests fail with module errors

```bash
cd frontend
rm -rf node_modules package-lock.json
npm install
```

### Type errors in Svelte

```bash
cd frontend
npm run check
```

## Best Practices

1. **Write tests first** (TDD) when adding new features
2. **Run `make check-all`** before committing
3. **Keep coverage high** (>80% for critical paths)
4. **Fix linter warnings** - they catch real issues
5. **Use descriptive test names** - what, when, expected outcome
6. **Mock external dependencies** - tests should be fast and isolated
7. **Test edge cases** - empty data, errors, timeouts
8. **Review coverage reports** - ensure critical paths are tested

## Next Steps

- [ ] Add integration tests
- [ ] Add E2E tests with Playwright
- [ ] Set up mutation testing
- [ ] Configure test coverage thresholds in CI
- [ ] Add performance benchmarks
