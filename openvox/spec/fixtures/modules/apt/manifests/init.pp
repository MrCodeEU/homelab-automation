# Minimal test double for puppetlabs-apt; roles::ugreen_tailscale only relies
# on its update class and package ordering.
class apt (
  Hash $update = {},
) {
  contain apt::update
}
