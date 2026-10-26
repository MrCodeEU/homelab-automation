# AOOSTAR display driver on nas (Unraid) - proxy-exec, same shape as
# roles::unraid_proxy: this class runs on nuc and drives nas over Tailscale SSH
# through real script files (nas has no agent, see roles::unraid_proxy).
#
# The NAS has a small LCD driven by the vendor binary
# /mnt/user/appdata/aoostar/AOOSTAR-X (not in the repo, 179 MB). This class
# manages everything around it:
#   - aoostar-ctl.sh (start/stop/status) and aoostar-controller.sh (Immich
#     photo, day/night mode, optional stats panels) under appdata
#   - User Script "aoostar-display", At Startup of Array: starts both
#   - User Script "aoostar-display-stop", At Stopping of Array: stops both.
#     Unraid does not stop processes started from User Scripts, which used to
#     block every shutdown until the driver was killed by hand.
#   - retires the hand-made aoostar_display / aoostar_display_controller scripts
#
# Not managed here (deliberately, for now): the controller's credentials in
# /mnt/user/appdata/aoostar/controller.env (mode 600, written by hand, see the
# header of aoostar-controller.sh) and AOOSTAR-X's own config. Nothing is
# started by a deploy; the array's start event does that.
class roles::unraid_aoostar_proxy (
  String $work_dir = '/usr/local/libexec/openvox-unraid-aoostar',
) {
  file { $work_dir:
    ensure  => directory,
    mode    => '0755',
    recurse => true,
    purge   => true,
    source  => 'puppet:///modules/roles/unraid_aoostar',
  }

  exec { 'unraid-aoostar-scripts':
    command => "${work_dir}/scripts-apply.sh",
    unless  => "${work_dir}/scripts-check.sh",
    path    => ['/usr/bin', '/bin'],
    require => [File[$work_dir], Exec['unraid-array-started']],
  }

  exec { 'unraid-aoostar-schedule':
    command => "${work_dir}/schedule-apply.sh",
    unless  => "${work_dir}/schedule-check.sh",
    path    => ['/usr/bin', '/bin'],
    require => Exec['unraid-aoostar-scripts'],
  }
}
