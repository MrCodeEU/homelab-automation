# node_exporter monitoring agent on the WD My Cloud EX2 Ultra - same
# no-agent-possible device as roles::wd_mycloud_proxy (BusyBox/ARMv7,
# no package manager), so this too runs on nuc and drives the device
# entirely over Tailscale SSH. Kept as its own class (rather than folded
# into roles::wd_mycloud_proxy) to preserve the 1:1 mapping with
# ansible/roles/wd-mycloud-node-exporter, same as roles::unraid_proxy vs
# roles::unraid_backup_proxy both targeting nas separately.
#
# Straight logic-port of spot/playbooks/wd-mycloud-node-exporter.yml
# (migration/spot, already validated live in production) - same device
# paths, same watchdog/cron/boot-hook mechanics. Unlike the tailscale
# update, node_exporter is not the SSH transport, so its update script
# runs synchronously in a single ssh session (see files/
# wd_mycloud_node_exporter/update-apply.sh) - no nohup/disown/poll dance
# needed the way the tailscale update required.
class roles::wd_mycloud_node_exporter_proxy (
  String $work_dir = '/usr/local/libexec/openvox-wd-mycloud-node-exporter',
) {
  file { $work_dir:
    ensure  => directory,
    mode    => '0755',
    recurse => true,
    purge   => true,
    source  => 'puppet:///modules/roles/wd_mycloud_node_exporter',
  }

  exec { 'wd-mycloud-node-exporter-update':
    command => "${work_dir}/update-apply.sh",
    unless  => "${work_dir}/update-check.sh",
    path    => ['/usr/bin', '/bin'],
    require => File[$work_dir],
    timeout => 300,
  }

  exec { 'wd-mycloud-node-exporter-watchdog-script':
    command => "${work_dir}/watchdog-apply.sh",
    unless  => "${work_dir}/watchdog-check.sh",
    path    => ['/usr/bin', '/bin'],
    require => File[$work_dir],
  }

  exec { 'wd-mycloud-node-exporter-watchdog-cron':
    command => "${work_dir}/cron-apply.sh",
    unless  => "${work_dir}/cron-check.sh",
    path    => ['/usr/bin', '/bin'],
    require => File[$work_dir],
  }

  exec { 'wd-mycloud-node-exporter-clamav-hook':
    command => "${work_dir}/clamav-apply.sh",
    unless  => "${work_dir}/clamav-check.sh",
    path    => ['/usr/bin', '/bin'],
    require => File[$work_dir],
  }
}
