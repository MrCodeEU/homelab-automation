# Port of ansible/roles/ugreen-tailscale (cross-checked against its
# already-verified migration/spot port, commit 370267a). ugreen only.
#
# ugreen stays deliberately unmanaged for general OS patching (UGOS's own
# A/B overlay update mechanism owns that, same posture as Unraid) -
# Tailscale is the one exception: it's the security-relevant network
# boundary, apt already has it as a real package here, and a
# single-package upgrade never touches anything else UGOS manages.
#
# Native `package { ensure => latest }` instead of Ansible/spot's shell
# "compare installed vs candidate, apt-get install --only-upgrade" dance -
# this is exactly what Puppet's package resource already expresses
# declaratively, no procedural script needed (`update => { frequency =>
# 'always' }` keeps the apt cache fresh enough for `latest` to see a real
# candidate version every run, matching Ansible's own `update_cache:
# true` - not just its `cache_valid_time: 3600` optimization).
class roles::ugreen_tailscale {
  class { 'apt':
    update => { frequency => 'always' },
  }

  # UGOS also sets GODEBUG=tlskyber=0 for every unit
  # (/etc/systemd/system.conf DefaultEnvironment). On 2026-11-05 a
  # tailscale upgrade built with a newer Go made tailscaled exit with
  # "removed GODEBUG tlskyber" at start, and ugreen stayed off the tailnet
  # for 10h until break-glass SSH over the LAN. The drop-in clears the
  # variable for tailscaled only; system.conf stays UGOS-owned. It is in
  # place before the package, so the upgrade's own restart already uses
  # it. No restart from here: this apply itself runs over tailscale SSH.
  file { '/etc/systemd/system/tailscaled.service.d':
    ensure => directory,
    mode   => '0755',
  }

  file { '/etc/systemd/system/tailscaled.service.d/10-godebug.conf':
    ensure  => file,
    mode    => '0644',
    content => "[Service]\nEnvironment=GODEBUG=\n",
    require => File['/etc/systemd/system/tailscaled.service.d'],
  }

  exec { 'ugreen-tailscaled-daemon-reload':
    command     => '/usr/bin/systemctl daemon-reload',
    refreshonly => true,
    subscribe   => File['/etc/systemd/system/tailscaled.service.d/10-godebug.conf'],
  }

  package { 'tailscale':
    ensure  => latest,
    require => [Class['apt::update'], Exec['ugreen-tailscaled-daemon-reload']],
  }

  # Read-only, always runs regardless of noop/real - matches the Ansible
  # role's own unconditional version-report step.
  #
  # GODEBUG= clears ugreen's system-wide GODEBUG=tlskyber=0
  # (/etc/profile.d/go.sh): current Go releases treat that removed setting
  # as fatal, so every Go binary - tailscale included - dies with
  # "removed GODEBUG tlskyber" under the inherited environment. That failed
  # the 2026-10-18 weekly deploy. Same workaround as
  # services/syncthing-ugreen/hooks/post-deploy.sh.
  exec { 'ugreen-tailscale-version':
    command     => '/usr/bin/tailscale version',
    environment => ['GODEBUG='],
    logoutput   => true,
    require     => Package['tailscale'],
  }
}
