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
# The controller's credentials in /mnt/user/appdata/aoostar/controller.env come
# from eyaml (vault_aoostar_*), and the vendor UI login in Monitor3.json is
# synced from it at every start. Nothing is started by a deploy; the array's
# start event does that.
# The `unless` guards test for the check script first: on the very first run
# (and its noop) the work dir does not exist yet, and a missing guard would be
# an evaluation error instead of "work needed".
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
    command  => "${work_dir}/scripts-apply.sh",
    unless   => "test -x ${work_dir}/scripts-check.sh && ${work_dir}/scripts-check.sh",
    path     => ['/usr/bin', '/bin'],
    provider => shell,
    require  => [File[$work_dir], Exec['unraid-array-started']],
  }

  # controller.env (vendor UI login + Immich key) is rendered from eyaml on
  # nuc and written to nas; aoostar-ctl.sh then syncs the vendor login from it
  # at every start. Both guard and command need the secrets in their
  # environment, which exec's `environment` gives them.
  $ui_password    = Sensitive(lookup('vault_aoostar_ui_password', { 'default_value' => '' }))
  $immich_api_key = Sensitive(lookup('vault_aoostar_immich_api_key', { 'default_value' => '' }))

  exec { 'unraid-aoostar-env':
    command     => "${work_dir}/env-apply.sh",
    unless      => "test -x ${work_dir}/env-check.sh && ${work_dir}/env-check.sh",
    path        => ['/usr/bin', '/bin'],
    provider    => shell,
    environment => [
      "AOOSTAR_UI_PASSWORD=${ui_password.unwrap}",
      "AOOSTAR_IMMICH_API_KEY=${immich_api_key.unwrap}",
    ],
    logoutput   => false,
    require     => [File[$work_dir], Exec['unraid-array-started'], Exec['unraid-aoostar-scripts']],
  }

  exec { 'unraid-aoostar-schedule':
    command  => "${work_dir}/schedule-apply.sh",
    unless   => "test -x ${work_dir}/schedule-check.sh && ${work_dir}/schedule-check.sh",
    path     => ['/usr/bin', '/bin'],
    provider => shell,
    require  => Exec['unraid-aoostar-scripts'],
  }
}
