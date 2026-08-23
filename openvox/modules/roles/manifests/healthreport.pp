# Port of ansible/roles/healthreport (cross-checked against its
# already-verified migration/spot port, commit 5a3d4ac). nuc only -
# host-side state for the healthreport agent (a compose service deployed
# by roles::services): the facts history/seen-state that makes the
# day-over-day diff possible, and the SSH keypair it uses to reach every
# other host's restricted facts endpoint.
#
# NOT under /opt/healthreport: roles::services::service's own directory
# resource recurses (remote) from this module's vendored source tree, so
# a services-role redeploy never touches this state either way - but it
# still doesn't belong inside a service's own deploy directory, same
# posture as roles::backup_dashboard.
#
# Real state already on disk (confirmed live before writing this): 27
# days of facts history (2026-07-28 onward), a real seen-state
# observations.json, and an existing ed25519 keypair - this is a
# verify-and-preserve port, not a fresh bootstrap.
class roles::healthreport (
  String  $root = '/var/lib/healthreport',
  # The container runs unprivileged as this uid (see
  # services/healthreport/Dockerfile) - the state directory and the SSH
  # key must be owned by it, or the agent cannot write facts and ssh
  # refuses the key. Matches roles::backup_dashboard's own uid
  # deliberately, not a separate one - see that role's own header
  # comment for why (it reads this key read-only).
  Integer $uid  = 10001,
) {
  $state_dir = "${root}/state"
  $ssh_dir   = "${root}/ssh"
  $key_path  = "${ssh_dir}/id_ed25519"

  # The root stays root-owned; only what the container must write does not.
  file { $root:
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }

  file { [$state_dir, "${state_dir}/history", "${state_dir}/seen"]:
    ensure  => directory,
    owner   => $uid,
    group   => $uid,
    mode    => '0755',
    require => File[$root],
  }

  file { $ssh_dir:
    ensure  => directory,
    owner   => $uid,
    group   => $uid,
    mode    => '0700',
    require => File[$root],
  }

  # Restricted to a forced command on every other host's end (see the
  # not-yet-ported roles::host_facts_endpoint), but still generated and
  # treated as a real private key: owned by the agent's own uid, 0600,
  # regenerate-never semantics (no code path here ever overwrites an
  # existing key).
  exec { 'healthreport-key-generate':
    command => "/usr/bin/ssh-keygen -t ed25519 -N '' -C homelab-healthreport -f ${key_path} -q",
    creates => $key_path,
    require => File[$ssh_dir],
  }

  file { $key_path:
    ensure  => file,
    owner   => $uid,
    group   => $uid,
    mode    => '0600',
    require => Exec['healthreport-key-generate'],
  }

  # 0600, not the more typical 0644 - matches the real key on disk
  # (confirmed live), same likely umask-at-generation-time artifact
  # already documented in roles::backup_remote_key for its own .pub
  # file. Kept as-is to avoid an unrequested permission change.
  file { "${key_path}.pub":
    ensure  => file,
    owner   => $uid,
    group   => $uid,
    mode    => '0600',
    require => Exec['healthreport-key-generate'],
  }
}
