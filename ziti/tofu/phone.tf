# The owner's Android phone (Ziti Mobile Edge): reaches what #admin reaches
# (policies.tf admin_dial). One-time token enrolment, shown as a QR code by
# scripts/ziti-enroll-phone.sh; the key stays in the phone's keystore. A
# lost phone: delete the identity here and apply.
#
# No second factor (owner decision 2026-11-17): Ziti Mobile Edge for
# Android cannot enrol TOTP, so an MFA posture check locked the phone out
# of every service. The phone's PIN/fingerprint lock and the non-exportable
# key are the protection. A real second factor would be an Authelia login
# as secondary auth (ext-jwt), which needs a public client API certificate
# first.
resource "ziti_identity" "phone" {
  name            = "phone-mrcode"
  type            = "Default"
  auth_policy_id  = "default"
  role_attributes = ["mobile"]
}

# Certificate plus an Authelia login (ext-jwt signer authelia) as second
# factor. The controller resolves the Authelia ID token by its sub to the
# identity's external id and refuses a token of anyone else, so the
# identity that uses this policy carries the owner's sub. Needs Ziti Mobile
# Edge for Android v0.26.0 or later (secondary ext-jwt fixed in ziti-sdk-c
# 1.22, #1172). The app asks for the login again when the ID token expires:
# 12 h (Authelia client ziti, id_token_lifespan in common.yaml).
resource "ziti_auth_policy" "phone_authelia" {
  name = "phone-authelia"
  primary = {
    cert = {
      allowed             = true
      allow_expired_certs = false
    }
    updb = {
      allowed      = false
      max_attempts = 0
    }
    ext_jwt = {
      allowed         = false
      allowed_signers = []
    }
  }
  secondary = {
    jwt_signer = ziti_external_jwt_signer.authelia.id
  }
}

resource "ziti_service_policy" "mobile_dial" {
  name          = "mobile-dial"
  type          = "Dial"
  semantic      = "AnyOf"
  identityroles = ["#mobile"]
  serviceroles  = ["#admin-services"]
}
