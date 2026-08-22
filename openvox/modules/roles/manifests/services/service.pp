# One instance per catalog entry - see roles::services for how the
# catalog is filtered and this is instantiated. Kept as a defined type
# (not hand-unrolled per-service resources) precisely because the
# catalog is data, not logic: ~30 near-identical resource groups differ
# only in their Hash inputs.
#
# Phase 1 scope (core deploy path only, per the user's explicit phasing
# request): directory sync + .env generation + `docker compose up` +
# non-blocking healthcheck. NOT yet ported: pre/post-deploy hooks,
# sysctl requirements (no live catalog entry needs one today), staging/
# dev deploys, per-service allow_failure. Follow-up passes, not gaps
# introduced silently - see roles::services' own header.
define roles::services::service (
  Hash $service,
  String $base_path,
  String $domain,
  String $email,
  String $timezone,
  String $bind_addr,
  String $work_dir,
  Hash $secrets = {},
) {
  $svc_name = $title
  $deploy_path = "${base_path}/${svc_name}"
  $build_from_source = pick($service['build_from_source'], false)

  # Deliberately `recurse => remote`, not `true`, and NOT purge=>true -
  # unlike roles::caddy's conf.d (which only ever holds Puppet-exclusive
  # content), a service directory also holds real runtime state next to
  # its docker-compose.yml - bind-mounted app data, caches, a Python
  # venv. This migration's very first noop run against real production
  # caught two real hazards from a naive `recurse => true`: forgejo's
  # live runner-data/ (real Forgejo Actions runner cache, 4000+ files)
  # would have been deleted outright under purge=>true, and even
  # without purge, plain `recurse => true` still walked kuma's
  # provisioning venv (1863 files) and forgejo's runner-data again,
  # re-applying this resource's default mode/owner/SELinux context to
  # every pre-existing file under the whole tree - `recurse => remote`
  # scopes recursion to only what's actually present in `source`
  # (docker-compose.yml, hooks/, other vendored config), never touching
  # unrelated local-only content at all. Deliberately safer than
  # Ansible's own `rsync --delete` here too (that role only excludes
  # .env/venv/, so its rsync --delete would delete runner-data/ on
  # every single run - not something to replicate just because it's
  # what Ansible already does).
  file { $deploy_path:
    ensure  => directory,
    recurse => remote,
    source  => "puppet:///modules/roles/services/${svc_name}",
  }

  file { "${deploy_path}/.env":
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
    require => File[$deploy_path],
  }

  # Unconditional, no unless-guard - `docker compose up -d` is itself
  # idempotent (only recreates a container when its resolved spec
  # actually changed), same accepted shape as roles::mailcow's
  # mailcow-services-up.
  exec { "services-${svc_name}-deploy":
    command => "${work_dir}/compose-deploy.sh ${deploy_path} ${build_from_source}",
    timeout => 300,
    require => [File[$deploy_path], File["${deploy_path}/.env"]],
  }

  if pick($service['port'], 0) > 0 {
    exec { "services-${svc_name}-healthcheck":
      command => "${work_dir}/healthcheck.sh ${svc_name} ${service['port']}",
      require => Exec["services-${svc_name}-deploy"],
    }
  }
}
