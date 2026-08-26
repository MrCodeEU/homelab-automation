# Port of ansible/roles/host-facts-endpoint (cross-checked against its
# already-verified migration/spot port, commit 5a3d4ac). mljr, nuc,
# ugreen - nas gets its own proxy-exec class,
# roles::unraid_host_facts_proxy, run from nuc (nas has no Puppet agent).
#
# Installs a read-only facts script and an SSH key restricted to running
# only that script, so healthreport (nuc) can read state that is
# otherwise loopback-bound (CrowdSec LAPI), root-only (nftables) or not
# a network resource at all (Unraid array/SMART state).
#
# The key grants exactly one capability: run this script. It takes no
# arguments and ignores SSH_ORIGINAL_COMMAND, so there is nothing to
# inject.
#
# IMPORTANT, carried over from the Ansible role's own header comment:
# Tailscale SSH is enabled on every host and terminates port 22 on the
# tailnet interface without ever reading authorized_keys - over the
# tailnet the real access control is therefore the Tailscale ACL, not
# this key. The forced command only applies to connections that reach a
# host's own real sshd (public IP, breakglass port); it's defense in
# depth, not the primary control.
class roles::host_facts_endpoint (
  String  $os_family,
  String  $hostname,
  # Real script location. Same as $bin_path on mljr/nuc; on ugreen this
  # is base_path/bin/homelab-facts, with $bin_path itself becoming a
  # symlink to it (ugreen's writable overlay hasn't been observed to
  # wipe /usr/local/bin the way Unraid's tmpfs root does, but storing
  # the canonical copy on the pool means a future vendor OS reset still
  # recovers on the next apply, same reasoning as the Ansible role's
  # own defaults).
  String  $dest,
  Boolean $needs_symlink       = false,
  # Only meaningful (and required) when $needs_symlink is true - the
  # directory $dest lives in, since no dirname()-style function is
  # available in this stdlib version to derive it from $dest itself.
  Optional[String] $dest_dir  = undef,
  String  $bin_path            = '/usr/local/bin/homelab-facts',
  # This is $host_facts_client_host's own Tailscale IP (nuc), pinned
  # into the authorized_keys `from=` restriction - not this host's own.
  String  $client_tailscale_ip = '100.100.10.1',
  String  $base_path           = '/opt',
  String  $backup_local_path   = '/opt/backups',
  # Only ever non-empty on nas (roles::unraid_host_facts_proxy passes
  # its own real unraid_backup_watch_dirs) - the Ansible role's own
  # default resolves to [] everywhere else too.
  Array[String] $facts_backup_watch_dirs = [],
  Array[String] $facts_backup_remotes    = ['pcloud', 'wd-cloud'],
  Array[String] $facts_backup_paths      = ['/mnt/user/backup', '/mnt/fastpool'],
) {
  # unraid-backup logs to base_path/backup/logs; the rocky backup role
  # logs to backup_local_path/logs - see the Ansible template's own
  # comment (reproduced in the rendered script) for why one parser
  # covers both. This class is never declared on nas (which gets the
  # unraid_host_facts_proxy variant instead), so this always resolves
  # to the rocky branch.
  $log_dir = "${backup_local_path}/logs"

  if $needs_symlink {
    file { $dest_dir:
      ensure => directory,
      mode   => '0755',
    }
  }

  $dest_requirement = $needs_symlink ? {
    true    => File[$dest_dir],
    default => undef,
  }

  file { $dest:
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0755',
    content => epp('roles/host_facts_endpoint/homelab-facts.py.epp', {
      'os_family'               => $os_family,
      'hostname'                => $hostname,
      'base_path'               => $base_path,
      'backup_local_path'       => $backup_local_path,
      'log_dir'                 => $log_dir,
      'facts_backup_watch_dirs' => $facts_backup_watch_dirs,
      'facts_backup_remotes'    => $facts_backup_remotes,
      'facts_backup_paths'      => $facts_backup_paths,
    }),
    require => $dest_requirement,
  }

  if $needs_symlink {
    file { $bin_path:
      ensure  => link,
      target  => $dest,
      require => File[$dest],
    }
  }

  $pubkey = lookup('healthreport_pubkey')

  # Native Puppet resource for exactly one authorized_key entry - unlike
  # the Ansible/spot ports' grep/rewrite-the-whole-file shell dance,
  # this only ever touches the one line it owns, leaving a real stale
  # leftover entry (an old, since-regenerated healthreport key, found
  # live on mljr/nuc/nas) untouched rather than deleting state this
  # role was never asked to own.
  # Title/comment must match Ansible's own original comment
  # ("homelab-healthreport") exactly - the provider matches existing
  # lines by this name, not by key content, so a different title here
  # would silently create a duplicate entry alongside the one already
  # deployed in production rather than adopting it.
  ssh_authorized_key { 'homelab-healthreport':
    ensure  => present,
    user    => 'root',
    type    => 'ssh-ed25519',
    key     => regsubst($pubkey, '^\S+\s+(\S+).*$', '\1'),
    options => ['restrict', "from=\"${client_tailscale_ip}\"", "command=\"${bin_path}\""],
    target  => '/root/.ssh/authorized_keys',
  }
}
