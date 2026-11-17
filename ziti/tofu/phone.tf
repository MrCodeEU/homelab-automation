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

resource "ziti_service_policy" "mobile_dial" {
  name          = "mobile-dial"
  type          = "Dial"
  semantic      = "AnyOf"
  identityroles = ["#mobile"]
  serviceroles  = ["#admin-services"]
}
