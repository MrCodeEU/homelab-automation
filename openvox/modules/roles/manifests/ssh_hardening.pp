# Break-glass SSH keys + optional password-login lockout for hosts sshd can
# be reached on without Tailscale (LAN, or mljr's public break-glass port).
#
# Daily access goes over Tailscale SSH, which does not use sshd's password
# or key files. This class covers the case where Tailscale and every device
# are gone: the keys in `breakglass_pubkeys` (an offline recovery key in
# Bitwarden, plus FIDO2 YubiKey keys) must still open a shell, so password
# login can then be switched off.
#
# Two phases, so a bad key can never lock the host out:
#   1. disable_passwords: false  - install the key and the key lookup path
#   2. disable_passwords: true   - after a real key login was tested by hand
#
# nas (Unraid) has no OpenVox agent and is NOT managed here. Done by hand on
# 2026-10-25: the recovery key sits in /root/.ssh/authorized_keys (the same
# file as /boot/config/ssh/root/authorized_keys), and PasswordAuthentication /
# KbdInteractiveAuthentication are 'no' in /etc/ssh/sshd_config AND in
# /boot/config/ssh/sshd_config, which rc.sshd copies back over /etc/ssh at
# every boot. Pre-change backup: /boot/config/sshd_config.pre-hardening-20261025.
#
# The key lives in /etc/ssh/authorized_keys.d/<user> because ugreen (UGOS) has
# an immutable, empty /home and so no ~/.ssh for its admin user.
class roles::ssh_hardening (
  String           $recovery_user     = 'root',
  Boolean          $disable_passwords = false,
  Optional[String] $permit_root_login = undef,
) {
  $breakglass_pubkeys = lookup('breakglass_pubkeys', Array[String, 1])

  file { '/etc/ssh/authorized_keys.d':
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }

  # sshd refuses key files that are group/world writable or not owned by
  # root or the user; root-owned 0644 is accepted for any user.
  file { "/etc/ssh/authorized_keys.d/${recovery_user}":
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => "${breakglass_pubkeys.join("\n")}\n",
  }

  $password_lines = $disable_passwords ? {
    true    => "PasswordAuthentication no\nKbdInteractiveAuthentication no\n",
    default => '',
  }

  # mljr's pre-OpenVox drop-in set this; keep it when taking the file over.
  $root_login_line = $permit_root_login ? {
    undef   => '',
    default => "PermitRootLogin ${permit_root_login}\n",
  }

  file { '/etc/ssh/sshd_config.d/00-openvox-hardening.conf':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0600',
    content => "# Managed by OpenVox (roles::ssh_hardening)\nAuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys.d/%u\n${password_lines}${root_login_line}",
    require => File["/etc/ssh/authorized_keys.d/${recovery_user}"],
    notify  => Exec['ssh-hardening-reload'],
  }

  # Debian calls the unit ssh, Rocky sshd. Validate first so a typo can
  # never take sshd down.
  exec { 'ssh-hardening-reload':
    command     => '/bin/sh -c "/usr/sbin/sshd -t && (systemctl reload sshd 2>/dev/null || systemctl reload ssh)"',
    path        => ['/usr/sbin', '/usr/bin', '/bin'],
    refreshonly => true,
  }
}
