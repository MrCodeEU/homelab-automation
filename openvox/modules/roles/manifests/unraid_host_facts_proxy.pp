# Port of ansible/roles/host-facts-endpoint's nas leg. Same proxy-exec
# shape as roles::unraid_backup_proxy: nas has no Puppet agent, so this
# class runs ON nuc and drives nas over ssh/scp.
#
# Unlike the vendored static scripts, the rendered facts script itself
# is host-specific (per-host base_path/backup paths/watch dirs baked
# into the EPP output), so it can't live under the purge-managed
# work_dir alongside the static scripts - it's rendered into a separate
# plain staging directory instead, and script-check.sh/script-apply.sh
# scp it from there before touching nas.
class roles::unraid_host_facts_proxy (
  String $work_dir     = '/usr/local/libexec/openvox-unraid-host-facts',
  String $staging_dir  = '/usr/local/libexec/openvox-unraid-host-facts-staging',
) {
  file { $work_dir:
    ensure  => directory,
    mode    => '0755',
    recurse => true,
    purge   => true,
    source  => 'puppet:///modules/roles/unraid_host_facts',
  }

  file { $staging_dir:
    ensure => directory,
    mode   => '0755',
  }

  file { "${staging_dir}/homelab-facts.py":
    ensure  => file,
    mode    => '0644',
    content => epp('roles/host_facts_endpoint/homelab-facts.py.epp', {
      'os_family'               => 'unraid',
      'hostname'                => 'nas',
      'base_path'               => '/mnt/user/appdata/homelab',
      'backup_local_path'       => '/opt/backups',
      'log_dir'                 => '/mnt/user/appdata/homelab/backup/logs',
      'facts_backup_watch_dirs' => lookup('unraid_backup_watch_dirs'),
      'facts_backup_remotes'    => ['pcloud', 'wd-cloud'],
      'facts_backup_paths'      => ['/mnt/user/backup', '/mnt/fastpool'],
      # Required by the shared template but never read on Unraid; its Btrfs
      # history collector is selected only for the Ugreen OS-family branch.
      'backup_history_root'     => '/volume1/homelab-backups',
    }),
    require => File[$staging_dir],
  }

  $pubkey       = lookup('healthreport_pubkey')
  $pubkey_bare  = regsubst($pubkey, '^(\S+\s+\S+).*$', '\1')
  $auth_entry   = "restrict,from=\"100.100.10.1\",command=\"/usr/local/bin/homelab-facts\" ${pubkey_bare} homelab-healthreport"

  exec { 'unraid-host-facts-script':
    command => "${work_dir}/script-apply.sh",
    unless  => "${work_dir}/script-check.sh",
    path    => ['/usr/bin', '/bin'],
    require => [File[$work_dir], File["${staging_dir}/homelab-facts.py"]],
  }

  exec { 'unraid-host-facts-key':
    command     => "${work_dir}/key-apply.sh",
    unless      => "${work_dir}/key-check.sh",
    path        => ['/usr/bin', '/bin'],
    environment => ["OPENVOX_HEALTHREPORT_AUTH_ENTRY=${auth_entry}"],
    require     => File[$work_dir],
  }

  exec { 'unraid-host-facts-persist':
    command => "${work_dir}/persist-apply.sh",
    unless  => "${work_dir}/persist-check.sh",
    path    => ['/usr/bin', '/bin'],
    require => Exec['unraid-host-facts-key'],
  }
}
