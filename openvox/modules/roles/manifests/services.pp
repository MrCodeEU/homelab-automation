# Docker Compose service deployment, ported from ansible/roles/services.
# Ansible reused this exact role for mljr/nuc/ugreen alike (one "Ugreen
# Services" play, gated on ugreen_enabled - see site.yml); the earlier
# spot/Ansible-parity notes in this migration's own memory calling it
# "rocky-only" described phase 1's actual scope, not a real architectural
# split. Puppet's masterless `puppet apply` reads `puppet:///` sources
# from the local, already-synced modulepath (not a live fileserver), so
# the UGOS-blocks-rsync--server constraint that shaped
# scripts/openvox-sync.sh's scp fallback never applies to this class
# itself - no separate services_ugreen role was needed once phase 2 (this
# revision) added ugreen. nas (Unraid) still has no real Puppet agent at
# all (see roles::unraid_proxy's own proxy-exec pattern) and is out of
# scope here for that reason, not a services-role reason.
#
# PHASE 1 - core deploy path: per-service directory sync from this
# module's own files/services/<name>/ (vendored once from
# services/<name>/, NOT read live from the repo the way Ansible's
# rsync-from-controller did - Puppet's compiler has no controller-side
# filesystem to read from at apply time, same constraint that shaped
# roles::caddy's staging catalog flag), EPP-rendered .env (ported
# from ansible/roles/services/templates/env.j2), Docker Hub + GHCR
# login, `docker compose up -d --remove-orphans`, non-blocking
# healthcheck.
#
# PHASE 2 (this revision) - post-deploy hooks (post_deploy_hook_services/
# critical_hook_services, ported 1:1 from group_vars/all/all.yml),
# orphaned-service cleanup (cleanup-check.sh/cleanup-apply.sh, gated by
# $cleanup_enabled), explicitly selected staging deploys (the 4 staging: true
# catalog entries to nuc regardless of their production host), and Kuma
# auto-provisioning (checksum-gated,
# venv + provisioning script). Still NOT ported: sysctl requirements (no
# live catalog entry needs one today).
#
# Catalog-driven throughout: filters lookup('services_catalog') (the
# same data roles::caddy/roles::glance already read) to this host's
# entries, then instantiates roles::services::service once per entry -
# a `define` over Hash data instead of ~30 hand-unrolled resource
# blocks, per the user's standing "use a defined type for a
# data-driven catalog" architecture decision for this role.
class roles::services (
  String $base_path   = '/opt',
  String $domain       = 'mljr.eu',
  String $email        = 'admin@mljr.eu',
  String $timezone     = 'Europe/Vienna',
  # Must match Ansible's inventory_hostname exactly ('mljr', 'nuc'), NOT
  # this box's real OS hostname - same reasoning/precedent as
  # roles::backup's own $hostname param.
  String $hostname     = $facts['networking']['hostname'],
  # This host's own Tailscale IP, used as BIND_ADDR for every service
  # except mljr (loopback-only, since Caddy is co-located there).
  String $tailscale_ip = '',
  # Ported 1:1 from ansible/inventory/group_vars/all/all.yml. `ollama` is
  # nas-hosted and stays out of this default - nas has no real Puppet
  # agent, so it's reached via the separate roles::services_nas class
  # instead (its own post_deploy_hook_services default covers ollama).
  Array[String] $post_deploy_hook_services = [
    'crowdsec', 'forgejo', 'grafana', 'speedtest', 'godrive-demo',
    'healthreport', 'backup-dashboard', 'mail-archiver', 'umami', 'nocturne',
    'syncthing-ugreen',
  ],
  Array[String] $critical_hook_services = ['crowdsec', 'forgejo', 'grafana', 'speedtest'],
  # Matches Ansible's own `cleanup_enabled | default(true)` - ugreen's own
  # class{} call in site.pp overrides this to false (matches
  # group_vars/ugreen.yml). nas is out of scope for this class entirely
  # (see roles::services_nas, which has no cleanup logic at all - nas's
  # cleanup_enabled is permanently false in Ansible too).
  Boolean $cleanup_enabled = true,
) {
  $work_dir = '/usr/local/libexec/openvox-services-common'

  file { $work_dir:
    ensure  => directory,
    mode    => '0755',
    recurse => true,
    purge   => true,
    source  => 'puppet:///modules/roles/services_common',
  }

  $dockerhub_user = lookup('vault_dockerhub_username', { 'default_value' => '' })
  $dockerhub_pass = Sensitive(lookup('vault_dockerhub_token', { 'default_value' => '' }))
  $github_user    = lookup('vault_github_username', { 'default_value' => '' })
  $github_token   = Sensitive(lookup('vault_github_token', { 'default_value' => '' }))

  exec { 'services-dockerhub-login':
    command     => "${work_dir}/dockerhub-login-apply.sh",
    environment => ["DOCKERHUB_USER=${dockerhub_user}", "DOCKERHUB_PASS=${dockerhub_pass.unwrap}"],
    logoutput   => false,
    require     => File[$work_dir],
  }

  exec { 'services-ghcr-login':
    command     => "${work_dir}/ghcr-login-apply.sh",
    environment => ["GHCR_USER=${github_user}", "GHCR_TOKEN=${github_token.unwrap}"],
    logoutput   => false,
    require     => File[$work_dir],
  }

  $catalog = lookup('services_catalog')
  $host_services = $catalog.filter |$s| {
    $s['host'] == $hostname
      and pick($s['enabled'], true)
      and pick($s['managed'], true)
      and !pick($s['skip_deploy'], false)
  }

  $bind_addr = $hostname ? {
    'mljr'  => '127.0.0.1',
    default => $tailscale_ip,
  }

  # Per-service secret mappings - ported 1:1 from env.j2's
  # `{% if service_name == 'X' %}` blocks. Only services with a real
  # secrets block are listed; everything else gets {} (env.epp then
  # only emits the common TZ/DOMAIN/EMAIL/BIND_ADDR/IMAGE_TAG section).
  $all_secrets = {
    'nocturne' => {
      'instance_key'               => lookup('vault_nocturne_instance_key', { 'default_value' => '' }),
      'base_domain'                => lookup('vault_nocturne_base_domain', { 'default_value' => 'nc.mljr.eu' }),
      'postgres_password'          => lookup('vault_nocturne_postgres_password', { 'default_value' => '' }),
      'postgres_app_password'      => lookup('vault_nocturne_postgres_app_password', { 'default_value' => '' }),
      'postgres_migrator_password' => lookup('vault_nocturne_postgres_migrator_password', { 'default_value' => '' }),
      'postgres_web_password'      => lookup('vault_nocturne_postgres_web_password', { 'default_value' => '' }),
    },
    'mail-archiver' => {
      'db_password'    => lookup('vault_mailarchiver_db_password', { 'default_value' => '' }),
      'admin_user'     => lookup('vault_mailarchiver_admin_user', { 'default_value' => 'admin' }),
      'admin_password' => lookup('vault_mailarchiver_admin_password', { 'default_value' => '' }),
    },
    'dmarc-monitor' => {
      'db_password' => lookup('vault_dmarcmonitor_db_password', { 'default_value' => '' }),
      'imap_host'   => lookup('vault_dmarcmonitor_imap_host', { 'default_value' => 'mail.mljr.eu' }),
      'imap_user'   => lookup('vault_dmarcmonitor_imap_user', { 'default_value' => 'dmarc-reports@mljr.eu' }),
      # dmarc-reports@ and noreply@ are deliberately the same mailbox
      # password by admin choice - reuses the shared SMTP secret rather
      # than duplicating it under a new key, same as newsletter/speedtest.
      'imap_password' => lookup('vault_smtp_password', { 'default_value' => '' }),
    },
    'sudoku' => {
      'api_user'     => lookup('vault_sudoku_api_user', { 'default_value' => '' }),
      'api_password' => lookup('vault_sudoku_api_password', { 'default_value' => '' }),
    },
    'homepage' => {
      'gh_token'             => lookup('vault_github_token', { 'default_value' => '' }),
      'strava_client_id'     => lookup('vault_strava_client_id', { 'default_value' => '' }),
      'strava_client_secret' => lookup('vault_strava_client_secret', { 'default_value' => '' }),
      'strava_refresh_token' => lookup('vault_strava_refresh_token', { 'default_value' => '' }),
      'umami_website_id'     => lookup('vault_homepage_umami_website_id', { 'default_value' => '' }),
      'tailscale_api_key'    => lookup('vault_homepage_tailscale_api_key', { 'default_value' => '' }),
      'smtp_host'            => lookup('vault_smtp_host', { 'default_value' => '' }),
      'smtp_port'            => lookup('vault_smtp_port', { 'default_value' => '587' }),
      'smtp_user'            => lookup('vault_smtp_user', { 'default_value' => '' }),
      'smtp_password'        => lookup('vault_smtp_password', { 'default_value' => '' }),
      'smtp_from'            => lookup('vault_smtp_from', { 'default_value' => "admin@${domain}" }),
      'contact_to'           => lookup('vault_homepage_contact_to', { 'default_value' => '' }),
    },
    'umami' => {
      'app_secret'        => lookup('vault_umami_app_secret', { 'default_value' => '' }),
      'postgres_password' => lookup('vault_umami_postgres_password', { 'default_value' => '' }),
    },
    'oxicloud' => {
      'postgres_password' => lookup('vault_oxicloud_postgres_password', { 'default_value' => '' }),
    },
    'forgejo' => {
      'postgres_password' => lookup('vault_forgejo_postgres_password', { 'default_value' => '' }),
      'runner_secret'     => lookup('vault_forgejo_runner_secret', { 'default_value' => '' }),
    },
    'kuma' => {
      'username' => lookup('vault_kuma_username', { 'default_value' => '' }),
      'password' => lookup('vault_kuma_password', { 'default_value' => '' }),
    },
    'grafana' => {
      'admin_user'     => lookup('vault_grafana_admin_user', { 'default_value' => 'admin' }),
      'admin_password' => lookup('vault_grafana_admin_password', { 'default_value' => '' }),
      # Same value as dmarc-monitor's own db_password - Grafana just needs
      # read access to that one Postgres instance for the DMARC dashboard,
      # not a separate credential.
      'dmarc_postgres_password' => lookup('vault_dmarcmonitor_db_password', { 'default_value' => '' }),
    },
    'crowdsec' => {
      'firewall_bouncer_key'       => lookup('vault_crowdsec_firewall_bouncer_key', { 'default_value' => '' }),
      'web_ui_password'            => lookup('vault_crowdsec_web_ui_password', { 'default_value' => '' }),
      'web_ui_notification_secret' => lookup('vault_crowdsec_web_ui_notification_secret', { 'default_value' => '' }),
    },
    'newsletter' => {
      'smtp_host'     => lookup('vault_smtp_host', { 'default_value' => '' }),
      'smtp_port'     => lookup('vault_smtp_port', { 'default_value' => '587' }),
      'smtp_user'     => lookup('vault_smtp_user', { 'default_value' => '' }),
      'smtp_password' => lookup('vault_smtp_password', { 'default_value' => '' }),
    },
    'speedtest' => {
      'admin_password' => lookup('vault_netronome_admin_password', { 'default_value' => '' }),
      'session_secret' => lookup('vault_netronome_session_secret', { 'default_value' => '' }),
      'smtp_host'      => lookup('vault_smtp_host', { 'default_value' => '' }),
      'smtp_port'      => lookup('vault_smtp_port', { 'default_value' => '587' }),
      'smtp_user'      => lookup('vault_smtp_user', { 'default_value' => '' }),
      'smtp_password'  => lookup('vault_smtp_password', { 'default_value' => '' }),
      'smtp_from'      => lookup('vault_smtp_from', { 'default_value' => "speedtest@${domain}" }),
    },
    'healthreport' => {
      'nuc_ip'                 => '100.100.10.1',
      'nas_ip'                 => '100.100.10.2',
      'mljr_ip'                => '100.100.20.1',
      'ugreen_ip'              => '100.100.10.4',
      'homeassistant_ip'       => '100.100.10.200',
      'kuma_api_key'           => lookup('vault_kuma_api_key', { 'default_value' => '' }),
      'healthreport_schedule'  => '*-*-* 06:00:00',
      'healthreport_model'     => 'qwen3:8b',
      'healthreport_llm_enabled' => 'true',
      'healthreport_llm_timeout' => '300',
      'backup_known_paths'     => lookup('unraid_backup_paths').map |$p| { $p['src'] }.join(','),
      'backup_excluded_paths'  => lookup('unraid_backup_excluded').map |$p| { $p['path'] }.join(','),
      'ha_excluded_clusters'   => lookup('ha_excluded_clusters', { 'default_value' => [] }).join(','),
      'lookback_hours'         => '24',
      'maintenance_windows'    => 'daily 00:00-00:10,sun 04:55-08:00',
      '5xx_hour_threshold'     => '100',
      'github_readonly_token'  => lookup('vault_github_readonly_token', { 'default_value' => '' }),
      'github_username'        => lookup('vault_github_username', { 'default_value' => '' }),
      'homeassistant_token'    => lookup('vault_homeassistant_token', { 'default_value' => '' }),
      'ntfy_url'               => 'https://ntfy.mljr.eu',
      'ntfy_topic'             => 'homelab-health',
      'ntfy_token'             => '',
      'smtp_host'              => lookup('vault_smtp_host', { 'default_value' => '' }),
      'smtp_port'              => lookup('vault_smtp_port', { 'default_value' => '587' }),
      'smtp_user'              => lookup('vault_smtp_user', { 'default_value' => '' }),
      'smtp_password'          => lookup('vault_smtp_password', { 'default_value' => '' }),
      'smtp_from'              => 'notifications@mljr.eu',
      'email_to'               => lookup('vault_healthreport_email_to', { 'default_value' => '' }),
    },
    'syncthing-ugreen' => {
      'nas_ip'                  => '100.100.10.2',
      'nas_syncthing_api_key'   => lookup('vault_syncthing_nas_api_key', { 'default_value' => '' }),
    },
    'backup-dashboard' => {
      'nuc_ip'           => '100.100.10.1',
      'mljr_ip'          => '100.100.20.1',
      'nas_ip'           => '100.100.10.2',
      'refresh_interval' => '*:0/15',
    },
  }

  # Vendored files that need +x - e.g. a static Go binary bind-mounted
  # straight into a container. See roles::services::service's own
  # comment for why this is scoped per-file rather than
  # source_permissions=>use on the whole deploy_path.
  $service_executables = {
    'goaccess'          => ['caddylog'],
    'syncthing-ugreen'  => ['hooks/provision-syncthing'],
    'healthreport'      => ['healthreport'],
    'backup-dashboard'  => ['backup-dashboard-collect'],
  }

  $host_services.each |$svc| {
    roles::services::service { $svc['name']:
      service              => $svc,
      base_path            => $base_path,
      domain               => $domain,
      email                => $email,
      timezone             => $timezone,
      bind_addr            => pick($svc['public_bind'], $bind_addr),
      work_dir             => $work_dir,
      secrets              => pick($all_secrets[$svc['name']], {}),
      run_post_deploy_hook => $svc['name'] in $post_deploy_hook_services,
      critical             => $svc['name'] in $critical_hook_services,
      executables          => pick($service_executables[$svc['name']], []),
      require              => [Exec['services-dockerhub-login'], Exec['services-ghcr-login']],
    }
  }

  $host_service_names = $host_services.map |$s| { $s['name'] }

  # Orphaned-service cleanup - ported from
  # ansible/roles/services/tasks/cleanup_orphaned.yml. Runs after every
  # one of this host's own services has been (re)deployed, so a
  # renamed/moved catalog entry never gets deleted mid-transition.
  if $cleanup_enabled {
    # "Active" here must match Ansible's own cleanup_orphaned.yml filter
    # exactly (host + enabled only) - NOT $host_service_names, which also
    # excludes skip_deploy/managed:false catalog entries for the deploy
    # loop above. skip_deploy services like authelia (deployed by their
    # own dedicated class, e.g. roles::authelia, but still cataloged here
    # under this same host for docs/backup/healthcheck purposes) and
    # managed:false ones (hand-run containers, cataloged for visibility
    # only) both have real directories this cleanup must never call
    # orphaned just because they're absent from $host_service_names.
    # Caught live: reusing $host_service_names here deleted /opt/authelia
    # for real on the first production apply of this cleanup exec.
    $host_active_names = $catalog.filter |$s| {
      $s['host'] == $hostname and pick($s['enabled'], true)
    }.map |$s| { $s['name'] }

    $all_names_csv  = join($catalog.map |$s| { $s['name'] }, ',')
    $host_names_csv = join($host_active_names, ',')

    exec { 'services-cleanup-orphaned':
      command => "${work_dir}/cleanup-apply.sh ${base_path} ${all_names_csv} ${host_names_csv}",
      unless  => "${work_dir}/cleanup-check.sh ${base_path} ${all_names_csv} ${host_names_csv}",
      path    => ['/usr/bin', '/bin'],
      timeout => 300,
      require => Roles::Services::Service[$host_service_names],
    }
  }

  # Staging deploys are opt-in per apply. A normal production apply must not
  # start or recreate every development instance. The selection comes from
  # OPENVOX_STAGING_SERVICES via FACTER_openvox_staging_services, validated by
  # openvox-sync.sh before it reaches a privileged remote shell.
  #
  # The staging host is fixed as nuc. Select from the whole catalog, not
  # $host_services, because a staging copy can target nuc while production is
  # on mljr (homepage, ui-showcase).
  if $hostname == 'nuc' {
    $staging_candidates = $catalog.filter |$s| {
      pick($s['staging'], false)
        and pick($s['enabled'], true)
        and pick($s['managed'], true)
        and !pick($s['skip_deploy'], false)
    }
    $requested_staging = $facts['openvox_staging_services'] ? {
      undef   => [],
      ''      => [],
      default => split($facts['openvox_staging_services'], ','),
    }
    $staging_candidate_names = $staging_candidates.map |$s| { $s['name'] }
    $unknown_staging = $requested_staging.filter |$name| { !($name in $staging_candidate_names) }
    if !empty($unknown_staging) {
      fail("Unknown or non-staging service selection: ${unknown_staging.join(', ')}")
    }
    $staging_services = $staging_candidates.filter |$s| { $s['name'] in $requested_staging }

    $staging_services.each |$svc| {
      roles::services::service { "${svc['name']}-staging":
        service   => $svc,
        base_path => $base_path,
        domain    => $domain,
        email     => $email,
        timezone  => $timezone,
        bind_addr => $tailscale_ip,
        work_dir  => $work_dir,
        secrets   => pick($all_secrets[$svc['name']], {}),
        staging   => true,
        require   => [Exec['services-dockerhub-login'], Exec['services-ghcr-login']],
      }
    }
  }

  # Kuma auto-provisioning - ported from
  # ansible/roles/services/tasks/main.yml's Kuma Provisioning block. Only
  # relevant on the host that actually runs kuma (nuc today).
  if 'kuma' in $host_service_names {
    $kuma_dir      = "${base_path}/kuma"
    $kuma_username = pick($all_secrets['kuma']['username'], '')
    $kuma_password = Sensitive(pick($all_secrets['kuma']['password'], ''))

    # Static host list mirrors ansible/inventory/hosts.yml's groups['all']
    # - Puppet's compiler has no live inventory to enumerate the way
    # Ansible's `groups['all']` does, so this is a fixed list instead
    # (same shape as the healthreport secrets block above, which already
    # hardcodes every host's Tailscale IP for the same reason).
    $kuma_hosts = [
      { 'node_name' => 'mljr',          'node_host' => 'mljr.tail33930.ts.net' },
      { 'node_name' => 'nuc',           'node_host' => 'nuc.tail33930.ts.net' },
      { 'node_name' => 'nas',           'node_host' => 'nas.tail33930.ts.net' },
      { 'node_name' => 'ugreen',        'node_host' => 'ugreen.tail33930.ts.net' },
      { 'node_name' => 'wd-mycloud',    'node_host' => 'wd-mycloud.tail33930.ts.net' },
      { 'node_name' => 'homeassistant', 'node_host' => 'homeassistant.tail33930.ts.net' },
    ]

    # Valid JSON is valid YAML, and provision-kuma.py only ever calls
    # yaml.safe_load() on this file - pretty JSON (same
    # stdlib::to_json_pretty() already proven live via
    # roles::backup_dashboard's own catalog file) round-trips without
    # needing a hand-written YAML template or a to_yaml function stdlib
    # doesn't provide.
    file { "${kuma_dir}/services.yml":
      ensure  => file,
      mode    => '0644',
      content => stdlib::to_json_pretty({ 'services' => $catalog, 'hosts' => $kuma_hosts }),
      require => Roles::Services::Service['kuma'],
    }

    # Puppet's own hash of the catalog, NOT a byte-exact replica of
    # Ansible's `services | to_json | hash('sha256')` - the first apply
    # after this port sees a checksum mismatch and does one harmless
    # one-time re-provision (Kuma's API is upsert-based), then stays
    # stable on Puppet's own consistent hash from then on.
    $kuma_services_hash = sha256(stdlib::to_json($catalog))

    if $kuma_username != '' and $kuma_password.unwrap != '' {
      exec { 'services-kuma-provision':
        command     => "${work_dir}/kuma-provision-apply.sh ${kuma_dir} ${kuma_services_hash}",
        unless      => "${work_dir}/kuma-provision-check.sh ${kuma_dir} ${kuma_services_hash}",
        environment => ["KUMA_USERNAME=${kuma_username}", "KUMA_PASSWORD=${kuma_password.unwrap}"],
        path        => ['/usr/bin', '/bin'],
        timeout     => 300,
        require     => File["${kuma_dir}/services.yml"],
      }
    }
  }
}
