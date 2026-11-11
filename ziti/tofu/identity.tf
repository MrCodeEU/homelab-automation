# --- Authelia (C15) -----------------------------------------------------------
# The controller fetches Authelia's keys over the public internet (it runs
# on mljr, next to Authelia). Audience and client id are the Authelia
# client; the ID token is used because Authelia's access tokens are opaque.
# A new device enrols with that login alone (enroll-to-cert or
# enroll-to-token); the identity is named after preferred_username, gets
# the Authelia groups as attributes and is matched by the OIDC sub.
resource "ziti_external_jwt_signer" "authelia" {
  name = "authelia"
  # The provider's default is false: without this, an apply disables the
  # signer and every login through it.
  enabled                          = true
  issuer                           = "https://auth.mljr.eu"
  jwks_endpoint                    = "https://auth.mljr.eu/jwks.json"
  audience                         = "ziti"
  client_id                        = "ziti"
  scopes                           = ["email", "groups", "profile"]
  target_token                     = "ID"
  claims_property                  = "sub"
  use_external_id                  = true
  external_auth_url                = "https://auth.mljr.eu"
  enroll_to_cert_enabled           = true
  enroll_to_token_enabled          = true
  enroll_name_claims_selector      = "/preferred_username"
  enroll_attribute_claims_selector = "/groups"
}

# One identity per Authelia user, matched by the OIDC sub; every device of
# that user logs in as it (ext-jwt-login after `add` with the network JWT).
# Needed because enroll-to-cert/-token fetches /network-jwts with the OS
# trust store, and the client API's certificate is from our private CA.
resource "ziti_identity" "idp_admin" {
  name            = "idp-admin"
  type            = "Default"
  external_id     = "4a76133b-3e28-4917-b53e-5f46367f23bc"
  role_attributes = ["admins"]
  auth_policy_id  = "default"
}

# --- GitHub Actions (C4) ------------------------------------------------------
# A workflow logs in with the job's own OIDC token. No identity uses it
# since the C4 PoC (ci-ziti-c4, ziti-c4.yml) was removed 2026-11-11; kept
# for a CI deploy path over Ziti, should one come. GitHub's issuer and keys
# are public; the audience is ours, so a token a job requested for any
# other service is refused. Matched by job_workflow_ref, so one identity
# belongs to one workflow file on one branch.
resource "ziti_external_jwt_signer" "github_actions" {
  name            = "github-actions"
  enabled         = true
  issuer          = "https://token.actions.githubusercontent.com"
  jwks_endpoint   = "https://token.actions.githubusercontent.com/.well-known/jwks"
  audience        = "ziti-homelab"
  claims_property = "job_workflow_ref"
  use_external_id = true
}

# That signer only: no certificate, no password.
resource "ziti_auth_policy" "ci_github" {
  name = "ci-github"
  primary = {
    cert = {
      allowed             = false
      allow_expired_certs = false
    }
    updb = {
      allowed      = false
      max_attempts = 0
    }
    ext_jwt = {
      allowed         = true
      allowed_signers = [ziti_external_jwt_signer.github_actions.id]
    }
  }
  secondary = {}
}
