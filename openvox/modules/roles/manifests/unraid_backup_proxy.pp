# Unraid rclone backup (nas) - proxy-exec, same shape as
# roles::unraid_proxy. Logic-ported from ansible/roles/unraid-backup and
# its already-validated spot port (spot/playbooks/unraid-backup.yml on
# migration/spot).
#
# The backup-remote SSH keypair is generated once by
# ansible/roles/backup-remote-key (on nuc, regenerate: never) - not
# ported here since it already exists in production and this role only
# ever needs to read it. Because this whole class runs ON nuc (the proxy
# host itself), installing it on nas is a single direct scp from nuc's
# own local disk (/opt/backup-remote/ssh/id_ed25519) - no controller
# pull/push relay needed, unlike spot's model which ran from a separate
# machine and had to hop the key through an intermediate controller.
class roles::unraid_backup_proxy (
  String $work_dir = '/usr/local/libexec/openvox-unraid-backup',
) {
  file { $work_dir:
    ensure  => directory,
    mode    => '0755',
    recurse => true,
    purge   => true,
    source  => 'puppet:///modules/roles/unraid_backup',
  }

  exec { 'unraid-backup-key':
    command => "${work_dir}/key-apply.sh",
    unless  => "${work_dir}/key-check.sh",
    path    => ['/usr/bin', '/bin'],
    require => File[$work_dir],
  }

  exec { 'unraid-backup-logdir':
    command => "${work_dir}/logdir-apply.sh",
    unless  => "${work_dir}/logdir-check.sh",
    path    => ['/usr/bin', '/bin'],
    require => File[$work_dir],
  }

  exec { 'unraid-backup-script':
    command => "${work_dir}/backup-script-apply.sh",
    unless  => "${work_dir}/backup-script-check.sh",
    path    => ['/usr/bin', '/bin'],
    require => File[$work_dir],
  }

  exec { 'unraid-backup-schedule':
    command => "${work_dir}/schedule-apply.sh",
    unless  => "${work_dir}/schedule-check.sh",
    path    => ['/usr/bin', '/bin'],
    require => Exec['unraid-backup-script'],
  }
}
