# Unraid (nas) has no agent and never will (Slackware-based, no
# apt/dnf/yum, no Ruby, tmpfs root wiped on every reboot - confirmed live
# during the appliance-host architecture research; no supported OpenVox
# platform exists for it). Same proxy-exec shape as
# roles::wd_mycloud_proxy: this class runs on nuc and drives nas entirely
# over Tailscale SSH via real script files, no inline one-liners.
#
# Logic-ported from ansible/roles/unraid-bootstrap and its
# already-validated spot port (spot/playbooks/unraid-bootstrap.yml on
# migration/spot) - same array-state precondition, same array-side
# directory layout, same User Scripts bootstrap entry + schedule.json
# merge (still done as a real python3 script run on nas itself - no jq
# on this Slackware base, and reimplementing JSON merge/sort-keys logic
# in shell would be worse than just running Python where it already is).
class roles::unraid_proxy (
  String $work_dir = '/usr/local/libexec/openvox-unraid',
) {
  file { $work_dir:
    ensure  => directory,
    mode    => '0755',
    recurse => true,
    purge   => true,
    source  => 'puppet:///modules/roles/unraid',
  }

  # Hard precondition, not drift-gated - always runs (unless is a command
  # that can never succeed), fails the whole apply loudly if the array
  # isn't started rather than silently writing into a tmpfs root that
  # will lose everything on the next reboot.
  exec { 'unraid-array-started':
    command => "${work_dir}/array-check.sh",
    unless  => '/usr/bin/false',
    path    => ['/usr/bin', '/bin'],
    require => File[$work_dir],
  }

  exec { 'unraid-array-dirs':
    command => "${work_dir}/dirs-apply.sh",
    unless  => "${work_dir}/dirs-check.sh",
    path    => ['/usr/bin', '/bin'],
    require => Exec['unraid-array-started'],
  }

  exec { 'unraid-bootstrap-script':
    command => "${work_dir}/bootstrap-script-apply.sh",
    unless  => "${work_dir}/bootstrap-script-check.sh",
    path    => ['/usr/bin', '/bin'],
    require => Exec['unraid-array-started'],
  }

  exec { 'unraid-schedule-merge':
    command => "${work_dir}/schedule-apply.sh",
    unless  => "${work_dir}/schedule-check.sh",
    path    => ['/usr/bin', '/bin'],
    require => Exec['unraid-bootstrap-script'],
  }
}
