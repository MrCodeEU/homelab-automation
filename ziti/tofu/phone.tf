# The owner's Android phone (Ziti Mobile Edge): reaches what #admin reaches
# (policies.tf admin_dial), but only with a TOTP code. One-time token
# enrolment, shown as a QR code by scripts/ziti-enroll-phone.sh; the key
# stays in the phone's keystore. A lost phone: delete the identity here and
# apply. Login through Authelia (C15) instead waits for a public client API
# certificate, and Android's ext-jwt support had open bugs (2026-11).
resource "ziti_identity" "phone" {
  name            = "phone-mrcode"
  type            = "Default"
  auth_policy_id  = "default"
  role_attributes = ["mobile"]
}

# Asked once per session and again after 12 h. The code comes from the
# authenticator enrolled in the app (Bitwarden); the recovery codes go to
# Bitwarden as well.
resource "ziti_posture_check_mfa" "mobile" {
  name             = "mfa-mobile"
  role_attributes  = []
  prompt_on_unlock = false
  prompt_on_wake   = false
  timeout_seconds  = 43200
}

# Not part of admin_dial: that one has no posture check, and #mobile must
# never dial without the TOTP.
resource "ziti_service_policy" "mobile_dial" {
  name              = "mobile-dial"
  type              = "Dial"
  semantic          = "AnyOf"
  identityroles     = ["#mobile"]
  serviceroles      = ["#admin-services"]
  posturecheckroles = ["@${ziti_posture_check_mfa.mobile.id}"]
}
