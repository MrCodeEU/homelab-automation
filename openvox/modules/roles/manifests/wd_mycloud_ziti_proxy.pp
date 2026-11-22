# OpenZiti tunneler on WD My Cloud (docs/ZERO_TRUST_PLAN.md, Phase 5): the
# armv7 ziti-edge-tunnel in run-host mode, so the device hosts its own
# services (ziti/tofu/wd-mycloud.tf) instead of being reached over
# Tailscale. Driven from the proxy host (nuc) like
# roles::wd_mycloud_node_exporter_proxy - same device mechanics (data
# partition, watchdog from cron and the clamAV boot hook).
#
# The identity is enrolled once on the device by
# scripts/ziti-enroll-wd-mycloud.sh; until then the watchdog does nothing.
# $version and $sha256 pin the release zip (ziti-edge-tunnel-Linux_arm.zip).
#
# Every exec guards its unless-script with `test -f`, so a --noop before
# the first real apply (scripts not on disk yet) reports "would run"
# instead of a "Could not find command" error.
class roles::wd_mycloud_ziti_proxy (
  String $work_dir                     = '/usr/local/libexec/openvox-wd-mycloud-ziti',
  Pattern[/\Av\d+\.\d+\.\d+\z/] $version = 'v1.20.0',
  Pattern[/\A\h{64}\z/] $sha256        = 'fb483a7c10448e02e262dac57aa7a3209de7634bc684acc468c381a64ea2c653',
) {
  file { $work_dir:
    ensure  => directory,
    mode    => '0755',
    recurse => true,
    purge   => true,
    source  => 'puppet:///modules/roles/wd_mycloud_ziti',
  }

  exec { 'wd-mycloud-ziti-install':
    command  => "/bin/bash ${work_dir}/install-apply.sh ${version} ${sha256}",
    unless   => "test -f ${work_dir}/install-check.sh && /bin/bash ${work_dir}/install-check.sh ${version}",
    provider => shell,
    path     => ['/usr/bin', '/bin'],
    require  => File[$work_dir],
    timeout  => 300,
  }

  ['watchdog', 'cron', 'clamav'].each |$step| {
    $resource = $step ? {
      'watchdog' => 'wd-mycloud-ziti-watchdog-script',
      'cron'     => 'wd-mycloud-ziti-watchdog-cron',
      default    => 'wd-mycloud-ziti-clamav-hook',
    }
    exec { $resource:
      command  => "/bin/bash ${work_dir}/${step}-apply.sh",
      unless   => "test -f ${work_dir}/${step}-check.sh && /bin/bash ${work_dir}/${step}-check.sh",
      provider => shell,
      path     => ['/usr/bin', '/bin'],
      require  => Exec['wd-mycloud-ziti-install'],
    }
  }
}
