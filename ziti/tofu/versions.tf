# Ziti services and policies as code (docs/ZERO_TRUST_PLAN.md Phase 4).
# Run only through scripts/ziti-tofu.sh: OpenTofu runs on mljr against the
# controller's admin API on 127.0.0.1:8440, because the provider skips TLS
# verification on every management call (C3). State lives on mljr in
# /opt/ziti-controller/tofu/, encrypted, and rides in the controller's cold
# backup, so a restored controller and its state match.
#
# Not managed here, on purpose: routers and their identities and system
# policies (scripts/ziti-enroll-router.sh), enrolled device identities
# (laptop-mrcode, scripts/ziti-laptop-tunnel.sh), the Default auth policy
# and Default Admin.
#
# Role lists: the controller stores @name as @<id> and returns role lists
# sorted, and the provider compares ordered lists, so every list goes
# through sort() or it never converges (C3).

terraform {
  required_version = "~> 1.13.0"

  required_providers {
    ziti = {
      source  = "netfoundry/ziti"
      version = "= 2.2.1"
    }
  }

  encryption {
    key_provider "pbkdf2" "state" {
      passphrase = var.state_passphrase
    }
    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }
    state {
      method   = method.aes_gcm.state
      enforced = true
    }
    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }
}

# ZITI_API_HOST, ZITI_API_USERNAME, ZITI_API_PASSWORD from the environment.
provider "ziti" {}

# ZITI_TOFU_KEY in mljr's /opt/ziti-controller/.env (eyaml
# vault_ziti_tofu_key, copy in Bitwarden: "homelab ziti tofu state key").
variable "state_passphrase" {
  type      = string
  sensitive = true
}
