# One instance per nas-hosted, `managed: true` catalog entry - see
# roles::services_nas for how the catalog is filtered and this is
# instantiated. Mirrors roles::services::service's shape, but every
# mutating action is a proxy-exec over SSH from nuc instead of a
# Puppet-native local resource: nas (Unraid) has no real Puppet agent
# (tmpfs root, Slackware base, no supported OpenVox platform - see
# roles::unraid_proxy's own header).
#
# The directory sync still reuses Puppet's own idempotent local content
# management: `file { recurse => remote }` stages this service's vendored
# tree into a local staging directory on nuc (the host this class
# actually runs on), and only THEN does a dumb, always-safe `rsync -az`
# push it to nas - same "let Puppet do the diffing, let a plain shell
# command do the leaf mutation" split every other proxy-exec role in
# this migration already uses.
define roles::services_nas::service (
  Hash $service,
  String $base_path,
  String $domain,
  String $email,
  String $timezone,
  String $bind_addr,
  String $staging_dir,
  String $work_dir,
  Hash $secrets = {},
  Boolean $run_post_deploy_hook = false,
  Boolean $critical = false,
) {
  $svc_name = $title
  $local_dir = "${staging_dir}/${svc_name}"
  $remote_dir = "${base_path}/${svc_name}"
  $build_from_source = pick($service['build_from_source'], false)

  file { $local_dir:
    ensure  => directory,
    recurse => remote,
    source  => "puppet:///modules/roles/services/${svc_name}",
  }

  file { "${local_dir}/.env":
    ensure  => file,
    mode    => '0600',
    content => Sensitive(epp('roles/services/env.epp', {
      'service_name' => $svc_name,
      'domain'       => $domain,
      'email'        => $email,
      'timezone'     => $timezone,
      'bind_addr'    => $bind_addr,
      'project_name' => $svc_name,
      'secrets'      => $secrets,
    })),
    require => File[$local_dir],
  }

  # .env travels to nas over rsync/ssh (encrypted transport) alongside the
  # rest of the directory - same acceptable secret-transit precedent as
  # roles::unraid_backup_proxy's own scp of real SSH key material to nas.
  exec { "services-nas-${svc_name}-sync":
    command => "${work_dir}/rsync-deploy.sh ${local_dir} ${remote_dir}",
    path    => ['/usr/bin', '/bin'],
    timeout => 300,
    require => [File[$local_dir], File["${local_dir}/.env"]],
  }

  exec { "services-nas-${svc_name}-deploy":
    command => "${work_dir}/remote-compose-deploy.sh ${remote_dir} ${build_from_source}",
    path    => ['/usr/bin', '/bin'],
    timeout => 300,
    require => Exec["services-nas-${svc_name}-sync"],
  }

  if pick($service['port'], 0) > 0 {
    exec { "services-nas-${svc_name}-healthcheck":
      command => "${work_dir}/remote-healthcheck.sh ${svc_name} ${bind_addr} ${service['port']}",
      path    => ['/usr/bin', '/bin'],
      require => Exec["services-nas-${svc_name}-deploy"],
    }
  }

  if $run_post_deploy_hook {
    exec { "services-nas-${svc_name}-post-deploy-hook":
      command => "${work_dir}/remote-post-deploy-hook.sh ${svc_name} ${remote_dir} ${critical}",
      path    => ['/usr/bin', '/bin'],
      timeout => 600,
      require => Exec["services-nas-${svc_name}-deploy"],
    }
  }
}
