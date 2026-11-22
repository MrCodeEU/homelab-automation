# SSH login to nas through the IdP with opkssh (Phase 3 C14), like
# roles::opkssh on the agent hosts. nas has no agent, so nuc stages the
# files and drives them over `ssh nas-mgmt` (roles::nas_mgmt_key):
#
# - the opkssh binary: nuc's own copy, pinned and checked by roles::opkssh
# - /etc/opk/{providers,auth_id,config.yml}: same providers, auth_ids and
#   cache settings as nuc (roles::opkssh's parameters)
# - setup.sh, which runs on nas, on every change and at every boot
#   (roles::unraid_proxy's bootstrap): Unraid's root is tmpfs, so the
#   opksshuser account, the binary and /etc/opk come back from the array
#   copy in /mnt/user/appdata/homelab/opkssh. It also adds the
#   AuthorizedKeysCommand lines to the flash and the live sshd_config.
#
# Reached as root@nas-ssh.ziti (ziti/tofu/nas-ssh.tf, #admin may dial it).
# The authorized_keys files (break-glass keys, nas-mgmt, facts) keep
# working: sshd tries them first.
class roles::nas_opkssh (
  String $staging_dir = '/var/lib/openvox-nas-opkssh',
  String $work_dir = '/usr/local/libexec/openvox-nas-opkssh',
) {
  include roles::opkssh

  $auth_id_lines = $roles::opkssh::auth_ids.map |$a| { "${a['user']} ${a['identity']} ${a['issuer']}\n" }

  file { [$staging_dir, "${staging_dir}/etc"]:
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0700',
  }

  file { "${staging_dir}/opkssh":
    ensure  => file,
    mode    => '0755',
    source  => '/usr/local/bin/opkssh',
    require => Exec['opkssh-binary'],
  }

  file { "${staging_dir}/setup.sh":
    ensure => file,
    mode   => '0755',
    source => 'puppet:///modules/roles/nas_opkssh/setup.sh',
  }

  file {
    "${staging_dir}/etc/providers":
      content => "# Managed by OpenVox (roles::nas_opkssh)\n# issuer client-id expiration-policy\n${roles::opkssh::providers.join("\n")}\n";
    "${staging_dir}/etc/auth_id":
      content => "# Managed by OpenVox (roles::nas_opkssh)\n# principal identity(sub) issuer\n${auth_id_lines.join}";
    "${staging_dir}/etc/config.yml":
      content => @("CFG");
      # Managed by OpenVox (roles::nas_opkssh)
      ---
      cache:
        base_dir: /var/cache/opkssh
        max_age: ${roles::opkssh::cache_max_age}
        fallback_max_age: ${roles::opkssh::cache_fallback}
      | CFG
    default:
      ensure => file,
      mode   => '0600',
  }

  file { $work_dir:
    ensure  => directory,
    mode    => '0755',
    recurse => true,
    purge   => true,
    source  => 'puppet:///modules/roles/nas_opkssh',
  }

  # Guarded like roles::nas_mgmt_key: a --noop before the first real apply
  # reports "would run" instead of a missing-command error.
  exec { 'nas-opkssh':
    command  => "/bin/bash ${work_dir}/apply.sh",
    unless   => "test -f ${work_dir}/check.sh && /bin/bash ${work_dir}/check.sh",
    provider => shell,
    path     => ['/usr/bin', '/bin'],
    require  => [
      File[$work_dir, "${staging_dir}/opkssh", "${staging_dir}/setup.sh"],
      File["${staging_dir}/etc/providers", "${staging_dir}/etc/auth_id", "${staging_dir}/etc/config.yml"],
      Class['roles::nas_mgmt_key'],
    ],
  }
}
