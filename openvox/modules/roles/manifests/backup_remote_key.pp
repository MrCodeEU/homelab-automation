# Port of ansible/roles/backup-remote-key (cross-checked against its
# already-verified migration/spot port, commit 50b3c41). nuc only. One
# ed25519 keypair, generated once (regenerate: never - never overwritten
# once present), consumed by every backup-source host (mljr via
# roles::backup, nas via roles::unraid_backup_proxy) to reach ugreen as
# an on-prem backup target - see roles::backup_remote_target for the
# authorizing side of this handshake.
#
# The public half is NOT read back from this host at apply time - this
# is a masterless setup (no puppetserver/exported resources), so there's
# no Puppet-native mechanism to carry a value from nuc's catalog
# compilation into ugreen's. It's committed as plain hiera data instead
# (`backup_remote_pubkey` in data/common.yaml, read directly off this
# key's already-generated .pub file) - safe, since it's public key
# material, not a secret. If this key is ever genuinely rotated (it
# isn't today - regenerate: never, matching the Ansible role exactly),
# that data value needs updating by hand alongside it.
class roles::backup_remote_key (
  String $key_dir = '/opt/backup-remote/ssh',
) {
  file { $key_dir:
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0700',
  }

  exec { 'backup-remote-key-generate':
    command => "/usr/bin/ssh-keygen -t ed25519 -N '' -C homelab-backup-to-ugreen -f ${key_dir}/id_ed25519 -q",
    creates => "${key_dir}/id_ed25519",
    require => File[$key_dir],
  }

  file { "${key_dir}/id_ed25519":
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0600',
    require => Exec['backup-remote-key-generate'],
  }

  # 0600, not the more typical 0644 - matches the real key on disk
  # (confirmed live), most likely a product of whatever umask was in
  # effect when this key was first generated. Kept as-is rather than
  # "corrected" to avoid an unrequested permission change to a file no
  # prior port (Ansible or spot) ever touched either.
  file { "${key_dir}/id_ed25519.pub":
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0600',
    require => Exec['backup-remote-key-generate'],
  }
}
