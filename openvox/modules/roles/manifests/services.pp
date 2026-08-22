# Docker Compose service deployment - rocky hosts only (mljr, nuc),
# ported from ansible/roles/services. ugreen/nas each get their own
# separate role (services-ugreen, services-nas in the Ansible/spot
# world) with different sync mechanics (UGOS blocks rsync --server;
# nas is Unraid) - deliberately out of scope here, same phasing the
# user confirmed for this port.
#
# PHASE 1 (this commit) - core deploy path only: per-service directory
# sync from this module's own files/services/<name>/ (vendored once
# from services/<name>/, NOT read live from the repo the way Ansible's
# rsync-from-controller did - Puppet's compiler has no controller-side
# filesystem to read from at apply time, same constraint that shaped
# roles::caddy's dev_deploy catalog flag), EPP-rendered .env (ported
# from ansible/roles/services/templates/env.j2), Docker Hub + GHCR
# login, `docker compose up -d --remove-orphans`, non-blocking
# healthcheck. Deliberately NOT yet ported (follow-up passes):
# pre/post-deploy hooks, Kuma auto-provisioning, staging/dev deploys,
# orphaned-service cleanup, sysctl requirements (no live catalog entry
# needs one today).
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
      'healthreport_llm_enabled' => 'false',
      'healthreport_llm_timeout' => '300',
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
    'backup-dashboard' => {
      'nuc_ip'           => '100.100.10.1',
      'mljr_ip'          => '100.100.20.1',
      'nas_ip'           => '100.100.10.2',
      'refresh_interval' => '*:0/15',
    },
  }

  $host_services.each |$svc| {
    roles::services::service { $svc['name']:
      service   => $svc,
      base_path => $base_path,
      domain    => $domain,
      email     => $email,
      timezone  => $timezone,
      bind_addr => pick($svc['public_bind'], $bind_addr),
      work_dir  => $work_dir,
      secrets   => pick($all_secrets[$svc['name']], {}),
      require   => [Exec['services-dockerhub-login'], Exec['services-ghcr-login']],
    }
  }
}
