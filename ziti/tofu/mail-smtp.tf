# Inbound SMTP (mailcow's postfix on mljr, port 25) for Kuma's SMTP check
# on nuc (m2m.tf, kuma-nuc): nuc's home network cannot reach port 25 on the
# public IP. mail-smtp.mljr.int.mljr.eu:25 -> 127.0.0.1:25, bound by mljr's
# router (host networking). Not a catalog entry: mailcow's catalog port is
# its web UI.
resource "ziti_intercept_v1_config" "mail_smtp_mljr" {
  name      = "mail-smtp-mljr-intercept"
  addresses = ["mail-smtp.mljr.int.mljr.eu"]
  protocols = ["tcp"]
  port_ranges = [{
    low  = 25
    high = 25
  }]
}

resource "ziti_host_v1_config" "mail_smtp_mljr" {
  name     = "mail-smtp-mljr-host"
  protocol = "tcp"
  address  = "127.0.0.1"
  port     = 25
}

resource "ziti_service" "mail_smtp_mljr" {
  name            = "mail-smtp-mljr"
  configs         = sort([ziti_intercept_v1_config.mail_smtp_mljr.id, ziti_host_v1_config.mail_smtp_mljr.id])
  role_attributes = ["admin-services"]
}

resource "ziti_service_policy" "mail_smtp_mljr_bind" {
  name          = "mail-smtp-mljr-bind"
  type          = "Bind"
  semantic      = "AnyOf"
  identityroles = [local.router["mljr"]]
  serviceroles  = ["@${ziti_service.mail_smtp_mljr.id}"]
}
