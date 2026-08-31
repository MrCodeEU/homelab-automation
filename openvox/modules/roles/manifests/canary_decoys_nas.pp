# Decoy Canarytoken placement for nas (Unraid) - no real Puppet agent
# (see roles::unraid_proxy's own header for why), so this runs on nuc and
# drives nas entirely over Tailscale SSH via real script files, same
# proxy-exec shape as roles::unraid_proxy/roles::backup_remote_target.
#
# Placed at the top level of /mnt/user/Fotos - the single most-browsed
# share on this NAS (real user-facing content, not admin/backup-only),
# so a curious browsing intruder (or anyone poking around who shouldn't
# be) is the most plausible one to actually open it. See
# roles::canary_decoys' own header for the file's provenance - a real
# artifact from this fleet's self-hosted Canarytokens instance, vendored
# as-is, nothing templated or secret here.
class roles::canary_decoys_nas (
  String $work_dir = '/usr/local/libexec/openvox-canary-decoys-nas',
) {
  file { $work_dir:
    ensure  => directory,
    mode    => '0755',
    recurse => true,
    purge   => true,
    source  => 'puppet:///modules/roles/canary_decoys_nas',
  }

  exec { 'canary-decoys-nas-place':
    command => "${work_dir}/decoy-apply.sh",
    unless  => "${work_dir}/decoy-check.sh",
    path    => ['/usr/bin', '/bin'],
    require => File[$work_dir],
  }
}
