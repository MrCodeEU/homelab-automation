# One instance per catalog entry - see roles::services for how the
# catalog is filtered and this is instantiated. Kept as a defined type
# (not hand-unrolled per-service resources) precisely because the
# catalog is data, not logic: ~30 near-identical resource groups differ
# only in their Hash inputs.
#
# Phase 1 scope was core deploy path only (directory sync + .env
# generation + `docker compose up` + non-blocking healthcheck). Phase 2
# (this revision) adds post-deploy hooks and staging/dev instances. Still
# NOT ported: sysctl requirements (no live catalog entry needs one
# today), per-service allow_failure (deployment-summary-only behavior in
# Ansible, no real gating effect worth replicating).
define roles::services::service (
  Hash $service,
  String $base_path,
  String $domain,
  String $email,
  String $timezone,
  String $bind_addr,
  String $work_dir,
  Hash $secrets = {},
  # When true, deploys this catalog entry's `dev/` compose file under
  # base_path/staging/<name> instead of base_path/<name> - see
  # roles::services' own staging_services block. Staging skips production
  # post-deploy hooks but receives its own non-blocking health probe.
  Boolean $staging = false,
  Boolean $run_post_deploy_hook = false,
  Boolean $critical = false,
  # Paths (relative to deploy_path) that need +x - e.g. a vendored static
  # Go binary bind-mounted straight into a container (services/goaccess's
  # caddylog). recurse=>remote below deliberately doesn't set
  # source_permissions=>use (that applies to the *whole* vendored tree,
  # and on this catalog's mixed ownership - see the file resource's own
  # comment - it silently reset every service directory's owner/group
  # from 1001:1000 to Puppet's own default on the first real apply).
  # This forces the mode on just the listed file(s) instead.
  Array[String] $executables = [],
) {
  # $title is only a unique resource identifier - for a service that's
  # both nuc-hosted in production AND staging-enabled (speedtest,
  # service-template), the prod and staging instances share a host and
  # need distinct titles ("speedtest" vs "speedtest-staging"). $real_name
  # is the actual catalog service name, used everywhere that must match
  # the on-disk vendored tree, the catalog's own secrets keys, or the
  # container's real identity.
  $svc_name = $title
  $real_name = $service['name']
  $deploy_subpath = $staging ? { true => "staging/${real_name}", default => $real_name }
  $deploy_path = "${base_path}/${deploy_subpath}"
  $source_subtree = $staging ? { true => "services_staging/${real_name}", default => "services/${real_name}" }
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
    source  => "puppet:///modules/roles/${source_subtree}",
  }

  # A `file` resource here (ensure => file, mode => '0755', no
  # content/source) would race the parent's own recurse copy for the same
  # path: on a brand-new file it can "win" with no content declared,
  # permanently pinning it at 0 bytes since nothing ever re-declares real
  # content afterwards - caught live when provision-syncthing on ugreen
  # deployed as an empty file on its very first run. An `exec` guarded by
  # `unless test -x` only ever touches the mode bit, never content.
  $executables.each |$exe| {
    exec { "${deploy_path}/${exe}-chmod":
      command => "/bin/chmod 0755 '${deploy_path}/${exe}'",
      unless  => "/usr/bin/test -x '${deploy_path}/${exe}'",
      require => File[$deploy_path],
    }
  }

  file { "${deploy_path}/.env":
    ensure  => file,
    mode    => '0600',
    content => Sensitive(epp('roles/services/env.epp', {
      'service_name' => $real_name,
      'domain'       => $domain,
      'email'        => $email,
      'timezone'     => $timezone,
      'bind_addr'    => $bind_addr,
      'project_name' => $real_name,
      'secrets'      => $secrets,
    })),
    require => File[$deploy_path],
  }

  # Unconditional, no unless-guard - `docker compose up -d` is itself
  # idempotent (only recreates a container when its resolved spec
  # actually changed), same accepted shape as roles::mailcow's
  # mailcow-services-up.
  # See compose-deploy.sh's own header for why staging passes an explicit
  # project name (adopts the already-running <name>-staging containers)
  # while prod leaves it blank (directory-basename project naming,
  # unchanged from phase 1).
  $compose_project = $staging ? { true => "${real_name}-staging", default => '' }

  exec { "services-${svc_name}-deploy":
    command => "${work_dir}/compose-deploy.sh ${deploy_path} ${build_from_source} ${compose_project}",
    timeout => 300,
    require => [File[$deploy_path], File["${deploy_path}/.env"]],
  }

  if pick($service['port'], 0) > 0 {
    $health_port = $staging ? {
      true    => $service['port'] + 10000,
      default => $service['port'],
    }
    exec { "services-${svc_name}-healthcheck":
      command => "${work_dir}/healthcheck.sh ${svc_name} ${health_port}",
      require => Exec["services-${svc_name}-deploy"],
    }
  }

  # Staging deliberately does not run production hooks: those may register a
  # public endpoint or mutate shared external state.
  if !$staging {
    # Unconditional, like compose-deploy.sh itself - the hook script is
    # expected to be idempotent (registration/convergence checks), not a
    # one-time bootstrap step. Non-critical failures are swallowed inside
    # post-deploy-hook.sh itself; only critical => true propagates a
    # non-zero exit here and fails the catalog run.
    if $run_post_deploy_hook {
      exec { "services-${svc_name}-post-deploy-hook":
        command => "${work_dir}/post-deploy-hook.sh ${svc_name} ${deploy_path} ${critical}",
        timeout => 600,
        require => Exec["services-${svc_name}-deploy"],
      }
    }
  }
}
