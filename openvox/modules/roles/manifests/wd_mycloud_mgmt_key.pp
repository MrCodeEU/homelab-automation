# nuc's SSH access to WD My Cloud over Ziti (docs/ZERO_TRUST_PLAN.md,
# Phase 5), replacing Tailscale SSH for the management scripts of
# roles::wd_mycloud_proxy, ::wd_mycloud_node_exporter_proxy and
# ::wd_mycloud_ziti_proxy (owner decision 2026-11-22: a dedicated key; the
# device cannot run opkssh).
#
# Path: `ssh wd-mycloud-mgmt` -> 127.0.0.1:2425 (services/ziti-proxy-nuc,
# m2m-nuc) -> wd-mycloud-ssh -> the device's own sshd on 127.0.0.1:22.
# The device authorizes the key for from="127.0.0.1" only, i.e. for
# connections its tunneler forwards (roles::wd_mycloud_proxy writes it
# next to the break-glass keys).
#
# The private key was generated on nuc and lives in nuc's eyaml
# (vault_wd_mycloud_mgmt_ssh_key), so a rebuild restores the same key; its
# public half is plain hiera data (wd_mycloud_mgmt_pubkey), as with
# roles::backup_remote_key. The device's host key is pinned
# (wd_mycloud_host_key): it is persistent on the device, so no TOFU.
class roles::wd_mycloud_mgmt_key (
  String $key_dir = '/opt/wd-mycloud-mgmt/ssh',
  Integer $port   = 2425,
) {
  $key = Sensitive(lookup('vault_wd_mycloud_mgmt_ssh_key', { 'default_value' => '' }))
  $host_key = lookup('wd_mycloud_host_key', String[1])

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
    content => "wd-mycloud ${host_key}\n",
  }

  file { '/etc/ssh/ssh_config.d/40-wd-mycloud-mgmt.conf':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => @("CONF"),
      # Managed by OpenVox (roles::wd_mycloud_mgmt_key)
      Host wd-mycloud-mgmt
          HostName 127.0.0.1
          Port ${port}
          User root
          IdentityFile ${key_dir}/id_ed25519
          IdentitiesOnly yes
          HostKeyAlias wd-mycloud
          UserKnownHostsFile ${key_dir}/known_hosts
          StrictHostKeyChecking yes
          ConnectTimeout 15
      | CONF
  }
}
