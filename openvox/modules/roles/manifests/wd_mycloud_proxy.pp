# WD My Cloud EX2 Ultra has no agent and never will (BusyBox/ARMv7
# firmware, no package manager, no libc match for any Puppet-family
# runtime - see the FINAL DECISION section of the migration research for
# why). This class runs on a capable proxy host (nuc) and drives the
# device entirely over Tailscale SSH.
#
# Straight logic-port of spot/playbooks/wd-mycloud-tailscale.yml
# (migration/spot, already validated live in production) - same device
# paths, same watchdog/cron/boot-hook mechanics, same best-effort
# reconnect behavior. Each concern is a real script file under files/
# wd_mycloud/ deployed to this class's $work_dir on the proxy host,
# rather than embedded as escaped one-liners in this manifest - avoids
# nesting Puppet-string/local-shell/remote-shell quoting three levels
# deep, a real fragility already hit once this session with a much
# simpler single-quote case.
class roles::wd_mycloud_proxy (
  String $work_dir = '/usr/local/libexec/openvox-wd-mycloud',
) {
  file { $work_dir:
    ensure  => directory,
    mode    => '0755',
    recurse => true,
    purge   => true,
    source  => 'puppet:///modules/roles/wd_mycloud',
  }

  exec { 'wd-mycloud-tailscale-update':
    command => "${work_dir}/tailscale-update-apply.sh",
    unless  => "${work_dir}/tailscale-update-check.sh",
    path    => ['/usr/bin', '/bin'],
    require => File[$work_dir],
    timeout => 120,
  }

  exec { 'wd-mycloud-watchdog-script':
    command => "${work_dir}/watchdog-apply.sh",
    unless  => "${work_dir}/watchdog-check.sh",
    path    => ['/usr/bin', '/bin'],
    require => File[$work_dir],
  }

  exec { 'wd-mycloud-watchdog-cron':
    command => "${work_dir}/cron-apply.sh",
    unless  => "${work_dir}/cron-check.sh",
    path    => ['/usr/bin', '/bin'],
    require => File[$work_dir],
  }

  exec { 'wd-mycloud-clamav-hook':
    command => "${work_dir}/clamav-apply.sh",
    unless  => "${work_dir}/clamav-check.sh",
    path    => ['/usr/bin', '/bin'],
    require => File[$work_dir],
  }
}
