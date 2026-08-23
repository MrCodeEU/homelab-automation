# Port of ansible/roles/backup-remote-target (cross-checked against its
# already-verified migration/spot port, commit 50b3c41). ugreen only.
# A dedicated, shell-less, password-locked user that owns exactly one
# directory, authorized with only the public half of the keypair
# roles::backup_remote_key generates on nuc.
#
# IMPORTANT, carried over from the Ansible role's own header comment,
# verified by hand before this role existed in its current form:
# Tailscale SSH is enabled here too and intercepts port 22 on the
# tailnet interface, handling every real connection this backup
# pipeline actually makes (nuc/mljr/nas -> ugreen) itself - none of
# sshd_config/authorized_keys/ChrootDirectory below is ever consulted
# for that path. The real boundary is Tailscale's ACL policy plus plain
# Unix file permissions on this user's home directory. The sshd Match
# block is defense-in-depth only, for the one case it DOES cover: a
# leaked private key used from off the tailnet, where the real sshd
# (which does honor ChrootDirectory) is what answers port 22.
#
# Consequence: the user's real home directory must be a genuine,
# absolute, writable path, not a chroot-relative one - Tailscale SSH's
# sftp mode uses it directly (`--home-dir=<passwd home>`). ChrootDirectory
# then reuses that same absolute path as its jail root for the
# defense-in-depth path.
class roles::backup_remote_target (
  String $backup_user = 'rclone-backup',
  String $chroot       = '/volume1/homelab-backups',
  String $data_dir     = "${chroot}/data",
  String $pubkey       = lookup('backup_remote_pubkey'),
) {
  $work_dir = '/usr/local/libexec/openvox-backup-remote-target'

  # Rocky hosts get /usr/local/libexec for free (ships with the base
  # filesystem package); this Debian box doesn't - declared explicitly
  # here since Puppet's file resource won't create missing parents on
  # its own (confirmed live: the work_dir create failed outright without
  # this).
  file { '/usr/local/libexec':
    ensure => directory,
    mode   => '0755',
  }

  file { $work_dir:
    ensure  => directory,
    mode    => '0755',
    recurse => true,
    purge   => true,
    source  => 'puppet:///modules/roles/backup_remote_target',
    require => File['/usr/local/libexec'],
  }

  group { $backup_user:
    ensure => present,
    system => true,
  }

  # Locked (no valid password hash) - matches Ansible's password_lock: true
  # / spot's usermod --lock, confirmed live against the real account's
  # /etc/shadow entry (a bare '!').
  user { $backup_user:
    ensure     => present,
    system     => true,
    gid        => $backup_user,
    shell      => '/usr/sbin/nologin',
    home       => $data_dir,
    managehome => false,
    password   => '!',
    require    => Group[$backup_user],
  }

  # sshd requires the chroot root itself to be root-owned and not
  # group/world-writable; the user's actual write target is the data/
  # subdirectory it DOES own.
  file { $chroot:
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }

  file { $data_dir:
    ensure  => directory,
    owner   => $backup_user,
    group   => $backup_user,
    mode    => '0750',
    require => [File[$chroot], User[$backup_user]],
  }

  file { "${data_dir}/.ssh":
    ensure  => directory,
    owner   => $backup_user,
    group   => $backup_user,
    mode    => '0700',
    require => File[$data_dir],
  }

  # Comment-stripped, matching ansible.posix.authorized_key's own
  # normalization (confirmed live: the real deployed file has no
  # comment even though id_ed25519.pub does) - keeps this idempotent
  # against the file both prior implementations already wrote. That
  # normalization also leaves a trailing space before the newline
  # (confirmed byte-exact live via `od -c`/`cat -A` against the real
  # file - an empty fourth "comment" field the module still joins in),
  # reproduced here deliberately rather than "cleaned up".
  # Owned by the target user, not root: sshd reads authorized_keys with
  # its privileges dropped to that user, so a root-owned file is
  # unreadable to the read itself on the fallback (real sshd) path -
  # confirmed the hard way during the Ansible role's own development
  # ("Permission denied (publickey)" in sshd's debug log).
  file { "${data_dir}/.ssh/authorized_keys":
    ensure  => file,
    owner   => $backup_user,
    group   => $backup_user,
    mode    => '0600',
    content => "${regsubst($pubkey, '^(\\S+\\s+\\S+).*$', '\\1')} \n",
    require => File["${data_dir}/.ssh"],
  }

  exec { 'backup-remote-target-sshd-match-block':
    command => "${work_dir}/sshd-match-block-apply.sh",
    unless  => "${work_dir}/sshd-match-block-check.sh",
    require => File[$work_dir],
  }
}
