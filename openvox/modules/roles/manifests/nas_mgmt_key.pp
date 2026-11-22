# nuc's SSH access to nas over Ziti (docs/ZERO_TRUST_PLAN.md, Phase 5),
# replacing Tailscale SSH for the management scripts that drive nas from
# nuc (roles::services_nas, ::unraid_proxy, ::unraid_backup_proxy,
# ::unraid_host_facts_proxy, ::unraid_aoostar_proxy,
# ::canary_decoys_nas). Same pattern as roles::wd_mycloud_mgmt_key; a
# dedicated key until nas trusts opkssh.
#
# Path: `ssh nas-mgmt` -> 127.0.0.1:2427 (services/ziti-proxy-nuc,
# m2m-nuc) -> nas-ssh, hosted by nas's own router, which dials sshd on
# 192.168.50.80:22 (Unraid's sshd listens on its interface addresses, not
# loopback). The key is authorized for from="192.168.50.80" only: a
# connection from nas itself, i.e. one its router forwards; a LAN client
# has its own address.
#
# The private key was generated on nuc and lives in nuc's eyaml
# (vault_nas_mgmt_ssh_key); public half and nas's host key (persistent on
# the flash since 2025) are plain hiera data.
class roles::nas_mgmt_key (
  String $key_dir  = '/opt/nas-mgmt/ssh',
  String $work_dir = '/usr/local/libexec/openvox-nas-mgmt',
  Integer $port    = 2427,
) {
  $key = Sensitive(lookup('vault_nas_mgmt_ssh_key', { 'default_value' => '' }))
  $pubkey = lookup('nas_mgmt_pubkey', String[1])
  $host_key = lookup('nas_host_key', String[1])
  $entry = "from=\"192.168.50.80\",no-agent-forwarding,no-port-forwarding,no-X11-forwarding ${pubkey}"

  file { [dirname($key_dir), $key_dir]:
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0700',
  }

  if $key.unwrap != '' {
    file { "${key_dir}/id_ed25519":
      ensure    => file,
      owner     => 'root',
      group     => 'root',
      mode      => '0600',
      content   => Sensitive("${key.unwrap}\n"),
      show_diff => false,
    }
  }

  file { "${key_dir}/known_hosts":
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => "nas ${host_key}\n",
  }

  file { '/etc/ssh/ssh_config.d/40-nas-mgmt.conf':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => @("CONF"),
      # Managed by OpenVox (roles::nas_mgmt_key)
      Host nas-mgmt
          HostName 127.0.0.1
          Port ${port}
          User root
          IdentityFile ${key_dir}/id_ed25519
          IdentitiesOnly yes
          HostKeyAlias nas
          UserKnownHostsFile ${key_dir}/known_hosts
          StrictHostKeyChecking yes
          ConnectTimeout 15
      | CONF
  }

  file { $work_dir:
    ensure  => directory,
    mode    => '0755',
    recurse => true,
    purge   => true,
    source  => 'puppet:///modules/roles/nas_mgmt',
  }

  # Guarded like roles::wd_mycloud_ziti_proxy: a --noop before the first
  # real apply reports "would run" instead of a missing-command error.
  exec { 'nas-mgmt-key':
    command     => "/bin/bash ${work_dir}/key-apply.sh",
    unless      => "test -f ${work_dir}/key-check.sh && /bin/bash ${work_dir}/key-check.sh",
    provider    => shell,
    path        => ['/usr/bin', '/bin'],
    environment => ["OPENVOX_NAS_MGMT_ENTRY=${entry}"],
    require     => File[$work_dir],
  }
}
