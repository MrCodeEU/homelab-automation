# nas management SSH (roles::nas_mgmt_key): nuc's management scripts reach
# nas's sshd over Ziti instead of Tailscale SSH. Hosted by nas's own
# router, which dials 192.168.50.80:22 on nas itself: Unraid's sshd listens
# on its interface addresses, not on loopback. Dialed by m2m-nuc (m2m.tf)
# and #admin.
resource "ziti_intercept_v1_config" "nas_ssh" {
  name      = "nas-ssh-intercept"
  addresses = ["ssh.nas.int.mljr.eu", "nas-ssh.ziti"]
  protocols = ["tcp"]
  port_ranges = [{
    low  = 22
    high = 22
  }]
}

resource "ziti_host_v1_config" "nas_ssh" {
  name     = "nas-ssh-host"
  protocol = "tcp"
  address  = "192.168.50.80"
  port     = 22
}

resource "ziti_service" "nas_ssh" {
  name            = "nas-ssh"
  configs         = sort([ziti_intercept_v1_config.nas_ssh.id, ziti_host_v1_config.nas_ssh.id])
  role_attributes = ["admin-services"]
}

resource "ziti_service_policy" "nas_ssh_bind" {
  name          = "nas-ssh-bind"
  type          = "Bind"
  semantic      = "AnyOf"
  identityroles = [local.router["nas"]]
  serviceroles  = ["@${ziti_service.nas_ssh.id}"]
}
