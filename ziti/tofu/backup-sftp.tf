# SFTP to ugreen for the backups' on-prem leg (roles::backup's [ugreen]
# rclone remote, roles::backup_remote_target). Not a catalog entry:
# backup-sftp-ugreen, sftp.ugreen.int.mljr.eu:22 -> 127.0.0.1:22 on ugreen,
# bound by ugreen's router only (host networking). The real sshd answers
# there, with the rclone-backup user's chroot and key, unlike over the
# tailnet, where Tailscale SSH took the connection. Dialled by the host
# proxies on mljr and nuc (m2m.tf). nas stays on the tailnet until Phase 5.
resource "ziti_intercept_v1_config" "backup_sftp" {
  name      = "backup-sftp-ugreen-intercept"
  addresses = ["sftp.ugreen.int.mljr.eu"]
  protocols = ["tcp"]
  port_ranges = [{
    low  = 22
    high = 22
  }]
}

resource "ziti_host_v1_config" "backup_sftp" {
  name     = "backup-sftp-ugreen-host"
  protocol = "tcp"
  address  = "127.0.0.1"
  port     = 22
}

resource "ziti_service" "backup_sftp" {
  name            = "backup-sftp-ugreen"
  configs         = sort([ziti_intercept_v1_config.backup_sftp.id, ziti_host_v1_config.backup_sftp.id])
  role_attributes = ["admin-services"]
}

resource "ziti_service_policy" "backup_sftp_bind" {
  name          = "backup-sftp-ugreen-bind"
  type          = "Bind"
  semantic      = "AnyOf"
  identityroles = [local.router["ugreen"]]
  serviceroles  = ["@${ziti_service.backup_sftp.id}"]
}
