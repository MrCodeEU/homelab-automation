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

  package { 'tailscale':
    ensure  => latest,
    require => Class['apt::update'],
  }

  # Read-only, always runs regardless of noop/real - matches the Ansible
  # role's own unconditional version-report step.
  exec { 'ugreen-tailscale-version':
    command   => '/usr/bin/tailscale version',
    logoutput => true,
    require   => Package['tailscale'],
  }
}
