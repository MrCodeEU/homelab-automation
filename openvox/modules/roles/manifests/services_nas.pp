# Docker Compose service deployment for nas (Unraid) - ported from
# ansible/roles/services, invoked there by the "Unraid Services" play
# (site.yml) rather than reused wholesale the way ugreen turned out to be
# (see roles::services' own header for that correction). nas genuinely
# needs a separate role: it has no real Puppet agent at all (tmpfs root,
# Slackware base - see roles::unraid_proxy), so every mutating step here
# is a proxy-exec over SSH from nuc, not a Puppet-native local resource.
# roles::unraid_proxy must already have created the array-side base_path
# and its .docker credentials directory (unraid-bootstrap's Puppet port) -
# this class assumes that precondition, matching Ansible's own role
# ordering (unraid-bootstrap, unraid-backup, services in that order).
#
# IMPORTANT scope correction made before writing this: the services
# catalog has ~15 entries with `host: nas`, but only 4 have
# `managed: true` (nas-alloy, ollama, smartctl-exporter-nas,
# auto-media-sort) - the rest (`nas`, `immich`, `nextcloud`, `dockhand`,
# `syncthing`, `filerun`, `test-ocis`, `stats`, `projects`, `pairdrop`,
# `dawarich`) are `managed: false`: real containers, but ones someone set
# up by hand through the Unraid UI, listed in the catalog purely for
# health-report/backup-dashboard visibility - Ansible's own "Unraid
# Services" play header says as much ("The NAS is partially managed: most
# containers still belong to the Unraid UI"), and cleanup_enabled is
# forced false in group_vars/unraid.yml specifically so orphan cleanup
# can never touch them. Only the 4 `managed: true` entries are this
# class's job.
#
# No orphaned-service cleanup, no staging/dev deploys, no Kuma
# provisioning here - none of the managed nas services are staging-enabled
# or run kuma, and cleanup is permanently disabled for this host by
# design (see above), not just deferred.
class roles::services_nas (
  String $base_path = '/mnt/user/appdata/homelab',
  String $domain     = 'mljr.eu',
  String $email      = 'admin@mljr.eu',
  String $timezone   = 'Europe/Vienna',
  # nas's own Tailscale IP - used both as BIND_ADDR (so only Tailscale-
  # reachable hosts, like nuc's health report, can reach these services)
  # and as the healthcheck target host, since the healthcheck itself
  # curls from nuc rather than through an SSH proxy.
  String $bind_addr = '100.100.10.2',
  # Ported 1:1 from ansible/inventory/group_vars/all/all.yml's
  # post_deploy_hook_services, filtered to nas-managed entries only.
  Array[String] $post_deploy_hook_services = ['ollama'],
) {
  $work_dir = '/usr/local/libexec/openvox-services-nas'
  $staging_dir = '/var/lib/openvox-services-nas-staging'

  file { $work_dir:
    ensure  => directory,
    mode    => '0755',
    recurse => true,
    purge   => true,
    source  => 'puppet:///modules/roles/services_nas',
  }

  file { $staging_dir:
    ensure => directory,
    mode   => '0755',
  }

  # GHCR only - matches Ansible's own Unraid branch (no docker Python SDK
  # there, so no Docker Hub docker_login task runs against nas either;
  # every managed nas image is public except auto-media-sort's).
  $github_user  = lookup('vault_github_username', { 'default_value' => '' })
  $github_token = Sensitive(lookup('vault_github_token', { 'default_value' => '' }))

  exec { 'services-nas-ghcr-login':
    command     => "${work_dir}/ghcr-login-apply.sh",
    path        => ['/usr/bin', '/bin'],
    environment => ["GHCR_USER=${github_user}", "GHCR_TOKEN=${github_token.unwrap}"],
    logoutput   => false,
    require     => File[$work_dir],
  }

  $catalog = lookup('services_catalog')
  $nas_services = $catalog.filter |$s| {
    $s['host'] == 'nas'
      and pick($s['managed'], true)
      and pick($s['enabled'], true)
      and !pick($s['skip_deploy'], false)
  }

  # ollama is the only one of the 4 with a secrets/env need beyond the
  # common TZ/DOMAIN/EMAIL/BIND_ADDR block - matches env.j2's own
  # `{% if service_name == 'ollama' %}` being the only nas-specific block.
  $all_secrets = {
    'ollama' => {
      'healthreport_model' => 'qwen3:8b',
    },
  }

  $nas_services.each |$svc| {
    roles::services_nas::service { $svc['name']:
      service              => $svc,
      base_path            => $base_path,
      domain               => $domain,
      email                => $email,
      timezone             => $timezone,
      bind_addr            => $bind_addr,
      staging_dir          => $staging_dir,
      work_dir             => $work_dir,
      secrets              => pick($all_secrets[$svc['name']], {}),
      run_post_deploy_hook => $svc['name'] in $post_deploy_hook_services,
      require              => [Exec['services-nas-ghcr-login'], File[$staging_dir]],
    }
  }
}
