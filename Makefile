################################################################################
# Homelab Automation — Test Runner + OpenVox Deploy
#
# Testing:
#   make test              Fast local tests — no Docker needed (CI default)
#   make test-services     Ping all production services (requires VPN/Tailscale)
#
# OpenVox deploy (the real production deploy path - see openvox/README.md):
#   make openvox-check-<host>    Noop against one host (mljr|nuc|ugreen)
#   make openvox-deploy-<host>   Real apply against one host
#   make openvox-check / openvox-deploy   Same, against all 3 hosts in parallel
#   make openvox-recovery HOST=<mljr|nuc> SERVICE=<name>[,<name>...]
#   make openvox-rollback HOST=<host> [STEPS=1]
#
# `ansible/` is retained as a migration reference only - see the top-level
# README.md's "Migrating from Ansible" section. It is not wired into any
# target below and has no deployment path of its own anymore.
################################################################################

.PHONY: test test-quick test-services test-services-verbose test-healthreport \
        help \
        _check-validate _check-syntax _check-compose \
        openvox-check openvox-deploy openvox-recovery openvox-rollback

################################################################################
# DEFAULT: fast local tests (no Docker)
################################################################################

test: _check-validate _check-syntax _check-compose
	@echo ""
	@echo "All fast tests passed."

## 1. Pre-commit service definition validation (port/domain uniqueness etc.)
_check-validate:
	@echo "==> [1/3] Service definition validation"
	bash ./.githooks/pre-commit

## 2. OpenVox manifest/template syntax check
_check-syntax:
	@echo "==> [2/3] OpenVox syntax check"
	@if ! command -v puppet >/dev/null 2>&1; then \
	    echo "SKIP  puppet not found (install openvox-agent to enable, see scripts/install-openvox.sh)"; \
	else \
	    puppet parser validate openvox/manifests/site.pp \
	      openvox/modules/role/manifests/*.pp \
	      openvox/modules/roles/manifests/*.pp \
	      openvox/modules/roles/manifests/services/*.pp \
	      openvox/modules/roles/manifests/services_nas/*.pp && \
	    find openvox/modules/roles/templates -type f -name '*.epp' -print0 \
	      | xargs -0 -n1 puppet epp validate; \
	fi

## 3. YAML lint on all docker-compose.yml files
_check-compose:
	@echo "==> [3/3] docker-compose.yml syntax"
	@find services -name "docker-compose.yml" -print0 \
	    | xargs -0 -I{} sh -c 'python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" {} \
	      && echo "OK  {}" || (echo "FAIL  {}" && exit 1)'

################################################################################
# Production service reachability (requires Tailscale / VPN)
################################################################################

test-services:
	@echo "==> Checking production service reachability"
	cd tools && go run ./cmd/check-services $(SERVICE_ARGS)

test-services-verbose:
	@echo "==> Checking production service reachability (verbose)"
	cd tools && go run ./cmd/check-services --verbose

# Health report unit tests. Pure logic (severity rules + run-over-run diff),
# no network and no container needed.
test-healthreport:
	@echo "==> Health report: severity rules, diff engine, LLM validation"
	cd tools && go test ./internal/healthreport/...
	@echo "==> Health report: log signature normalization, maintenance windows"
	cd tools && go test ./internal/healthreport/collectors/...

################################################################################
# OpenVox (Puppet-family) - the real production deploy path.
# .github/workflows/deploy.yml calls openvox-sync.sh directly.
# nas/wd-mycloud have no agent at all and are driven by exec resources
# declared on nuc's own node block instead (see openvox/manifests/).
################################################################################

OPENVOX_HOSTS      := mljr.tail33930.ts.net nuc.tail33930.ts.net ugreen.tail33930.ts.net

# Runs all 3 hosts in parallel (xargs -P4), then prints one pass/fail line
# per host so a `make openvox-check`/`openvox-deploy` run has a scannable
# fleet-wide result instead of just each host's own banner buried in the
# (now per-line-prefixed, see openvox-sync.sh) combined output above it.
# Exits non-zero if any host failed - fine to use in a script/CI context.
define openvox_run
	@results=$$(mktemp); \
	echo "$(OPENVOX_HOSTS)" | tr ' ' '\n' | xargs -P4 -I{} sh -c \
	  './scripts/openvox-sync.sh {} $(1); echo "{} $$?" >> '"$$results"; \
	echo ""; \
	echo "==> fleet summary ($(1)):"; \
	fail=0; \
	while read -r host code; do \
	  label=$${host%%.*}; \
	  if [ "$$code" = "0" ]; then \
	    echo "    $$label: OK"; \
	  else \
	    echo "    $$label: FAILED (exit $$code)"; \
	    fail=1; \
	  fi; \
	done < "$$results"; \
	rm -f "$$results"; \
	exit $$fail
endef

openvox-check:
	$(call openvox_run,noop)

openvox-deploy:
	$(call openvox_run,apply)

openvox-recovery:
	@test -n "$(HOST)" && test -n "$(SERVICE)" || (echo "Usage: make openvox-recovery HOST=<mljr|nuc> SERVICE=<service>[,<service>...]" >&2; exit 2)
	@OPENVOX_RECOVERY_SERVICES="$(SERVICE)" ./scripts/openvox-sync.sh "$(HOST).tail33930.ts.net" apply

# Rolls a host's `production` symlink back to a previous release and
# re-applies (see scripts/openvox-rollback.sh). STEPS defaults to 1 (the
# release immediately before the current one).
openvox-rollback:
	@test -n "$(HOST)" || (echo "Usage: make openvox-rollback HOST=<mljr|nuc|ugreen> [STEPS=1]" >&2; exit 2)
	@./scripts/openvox-rollback.sh "$(HOST).tail33930.ts.net" $(if $(STEPS),$(STEPS),1)

# Single-host convenience targets, e.g. `make openvox-check-mljr`.
openvox-check-mljr:
	@./scripts/openvox-sync.sh mljr.tail33930.ts.net noop

openvox-check-nuc:
	@./scripts/openvox-sync.sh nuc.tail33930.ts.net noop

openvox-check-ugreen:
	@./scripts/openvox-sync.sh ugreen.tail33930.ts.net noop

openvox-deploy-mljr:
	@./scripts/openvox-sync.sh mljr.tail33930.ts.net apply

openvox-deploy-nuc:
	@./scripts/openvox-sync.sh nuc.tail33930.ts.net apply

openvox-deploy-ugreen:
	@./scripts/openvox-sync.sh ugreen.tail33930.ts.net apply

# Explicit staging deployment on nuc. Usage:
#   make openvox-staging SERVICE=homepage
openvox-staging:
	@test -n "$(SERVICE)" || (echo "Usage: make openvox-staging SERVICE=<service>[,<service>...]" >&2; exit 2)
	@OPENVOX_STAGING_SERVICES="$(SERVICE)" ./scripts/openvox-sync.sh nuc.tail33930.ts.net apply

# Keep the vendored OpenVox files tree equal to the deployable assets in
# services/. `make test` checks this automatically; use this target after
# changing a generic service Compose/config file.
sync-openvox-services:
	@./scripts/sync-openvox-service-files.sh sync

################################################################################
# Housekeeping
################################################################################

# Quick help
help:
	@echo "Testing:"
	@echo "  make test                    — fast local tests (no Docker)"
	@echo "  make test-services            — ping production services (needs VPN)"
	@echo "  make test-services-verbose    — same, verbose"
	@echo "  make test-healthreport        — health report unit tests"
	@echo ""
	@echo "OpenVox deploy (requires Tailscale, see openvox/README.md):"
	@echo "  make openvox-check-<host>    — noop, one host (mljr|nuc|ugreen)"
	@echo "  make openvox-deploy-<host>   — real apply, one host"
	@echo "  make openvox-check           — noop, all hosts (parallel)"
	@echo "  make openvox-deploy          — real apply, all hosts (parallel)"
	@echo "  make openvox-recovery HOST=<mljr|nuc> SERVICE=<name>[,<name>...]"
	@echo "  make openvox-rollback HOST=<host> [STEPS=1]"
	@echo "  make openvox-staging SERVICE=<name>[,<name>...]  — nuc only"
	@echo "  make sync-openvox-services   — sync openvox/ tree with services/"
