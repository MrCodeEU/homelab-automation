# Standalone self-hosted Canarytokens (thinkst/canarytokens-docker) compose
# stack, mljr only, NOT part of the services: catalog generic deploy loop -
# same "bespoke roles::* class, catalog entry only for Caddy/visibility"
# shape as roles::authelia. HTTP-triggered tokens only (web bug, decoy
# file/AWS-key links, cloned-site, QR): no DNS/SMTP token support, so the
# switchboard's DNS(53)/SMTP(25)/MySQL(3306)/mTLS(6443)/WireGuard(51820)
# listener ports are deliberately never published - only the HTTP trigger
# channel (8083) and the admin token-management UI (8082) are.
#
# The upstream compose (thinkst/canarytokens-docker) ships its own nginx
# container that does path-based routing between frontend (UI: /generate,
# /manage, /history, ...) and switchboard (catch-all: the actual trigger
# URLs) - that role is fully replaced here by roles::caddy, which already
# fronts every other mljr service. Since Caddy's per-service catalog model
# is one domain -> one upstream, not upstream's path-split, the frontend UI
# is deliberately NOT put on the public canary.mljr.eu vhost at all - only
# switchboard (the trigger catcher) is, via a skip_deploy:true catalog
# entry (see data/common.yaml, same pattern as roles::authelia's own
# catalog entry). The admin UI (frontend, port 8082) stays loopback-only,
# reached by SSH tunnel (`ssh -L 8101:localhost:8101 mljr`, then
# http://localhost:8101/generate - host port 8101, not the container's
# internal 8082, see the compose block below for why) when creating new
# tokens - it's an infrequent admin action, not something that needs its
# own public/Tailscale vhost for v1.
#
# Both frontend and switchboard read their config from two on-disk env
# files mounted into fixed container paths (/srv/frontend/frontend.env,
# /srv/switchboard/switchboard.env) - not from process env vars the way
# every roles::services catalog service does via its single generated
# .env - so this class renders both directly, rather than going through
# roles::services::service/env.epp's one-file-per-service convention.
#
# CANARY_WG_PRIVATE_KEY_SEED is a "Required Setting" per upstream even
# though the WireGuard token channel is never published here - switchboard
# apparently still derives WG key material at boot regardless. Since that
# channel is unreachable from outside this host, the seed's secrecy
# doesn't matter functionally - but a literal random-looking string in
# this manifest still trips generic-api-key gitleaks scanning on every
# future PR that touches this file. Generated once on mljr's own disk
# instead, via generate() (runs locally at catalog *compile* time, not
# apply time - masterless Puppet compiles the whole catalog upfront, so
# an exec's output can't feed back into a file resource's content in the
# same run the normal way). First compile: the file doesn't exist yet,
# so the shell one-liner creates it and echoes the fresh value in the
# same breath. Every compile after that: the shell finds the file and
# just cats it back, so switchboard.env's content - and therefore
# whether the container restarts - stays stable across runs instead of
# rotating (and restarting switchboard) on every single deploy.
class roles::canarytokens (
  String $config_path      = '/opt/canarytokens',
  String $domain            = 'mljr.eu',
  String $canary_subdomain  = 'canary',
  String $timezone          = 'Europe/Vienna',
  String $version           = 'latest',
  # Loopback-only, same as every other mljr-hosted, Caddy-fronted service
  # (services.pp's own mljr bind_addr default) - switchboard's public
  # reachability comes from roles::caddy's canarytokens catalog entry,
  # not from binding this host's real interface directly.
  String $bind_addr         = '127.0.0.1',
  # mljr's known public IP (matches data/nodes/mljr...yaml's
  # roles::base::public_ip) - only used by a handful of raw-IP token
  # types, not the DNS-domain-based ones this HTTP-only v1 deploys.
  String $public_ip         = '157.173.97.107',
) {
  $canary_domain = "${canary_subdomain}.${domain}"

  $wg_seed_file = "${config_path}/.wg_seed"
  $wg_key_seed = generate('/bin/bash', '-c', "mkdir -p ${config_path} && (test -s ${wg_seed_file} && cat ${wg_seed_file} || (openssl rand -base64 32 | tee ${wg_seed_file}))").strip

  $smtp_host     = lookup('vault_smtp_host', { 'default_value' => '' })
  $smtp_port     = lookup('vault_smtp_port', { 'default_value' => '587' })
  $smtp_user     = lookup('vault_smtp_user', { 'default_value' => '' })
  $smtp_password = Sensitive(lookup('vault_smtp_password', { 'default_value' => '' }))
  $smtp_from     = lookup('vault_smtp_from', { 'default_value' => "canarytokens@${domain}" })

  file { $config_path:
    ensure => directory,
    mode   => '0755',
  }

  $frontend_env_content = @("FRONTENDENV"/L)
    CANARY_PUBLIC_IP=${public_ip}
    CANARY_DOMAINS=${canary_domain}
    CANARY_NXDOMAINS=${canary_domain}
    LOG_FILE=frontend.log
    | FRONTENDENV

  file { "${config_path}/frontend.env":
    ensure    => file,
    mode      => '0600',
    show_diff => false,
    content   => Sensitive($frontend_env_content),
    require   => File[$config_path],
    notify    => Exec['canarytokens-restart'],
  }

  $switchboard_env_content = @("SWITCHBOARDENV"/L)
    CANARY_PUBLIC_DOMAIN=${canary_domain}
    CANARY_WG_PRIVATE_KEY_SEED=${wg_key_seed}
    LOG_FILE=switchboard.log
    CANARY_SMTP_SERVER=${smtp_host}
    CANARY_SMTP_PORT=${smtp_port}
    CANARY_SMTP_USERNAME=${smtp_user}
    CANARY_SMTP_PASSWORD=${smtp_password.unwrap}
    CANARY_ALERT_EMAIL_FROM_ADDRESS=${smtp_from}
    CANARY_ALERT_EMAIL_FROM_DISPLAY="Homelab Canarytokens"
    CANARY_ALERT_EMAIL_SUBJECT="Canarytoken triggered"
    | SWITCHBOARDENV

  file { "${config_path}/switchboard.env":
    ensure    => file,
    mode      => '0600',
    show_diff => false,
    content   => Sensitive($switchboard_env_content),
    require   => File[$config_path],
    notify    => Exec['canarytokens-restart'],
  }

  $compose_content = @("COMPOSE"/L)
    services:
      redis:
        image: redis:7.0.10
        container_name: canarytokens-redis
        restart: unless-stopped
        volumes:
          - redis-data:/data/
        command: redis-server --appendonly yes --protected-mode no --save 60 1

      frontend:
        image: thinkst/canarytokens:${version}
        container_name: canarytokens-frontend
        restart: unless-stopped
        depends_on:
          - redis
        ports:
          # Host port 8101 (not 8082 - that's already homepage's catalog
          # port on this host) mapped to the container's own fixed 8082.
          - "${bind_addr}:8101:8082"
        volumes:
          - ./frontend.env:/srv/frontend/frontend.env:ro
          - ./switchboard.env:/srv/switchboard/switchboard.env:ro
          - canarytokens-uploads:/uploads/
        command: bash -c "cd frontend; uv run --no-sync python -m uvicorn app:app --host 0.0.0.0 --port 8082"

      switchboard:
        image: thinkst/canarytokens:${version}
        container_name: canarytokens-switchboard
        restart: unless-stopped
        depends_on:
          - redis
        ports:
          # Host port 8100 (not 8083 - that's already ui-showcase's
          # catalog port on this host), matches the catalog entry's own
          # port field. Container's own fixed 8083 unchanged.
          - "${bind_addr}:8100:8083"
        volumes:
          - ./frontend.env:/srv/frontend/frontend.env:ro
          - ./switchboard.env:/srv/switchboard/switchboard.env:ro
          - canarytokens-uploads:/uploads/
        command: bash -c "cd switchboard; rm -f switchboard.pid; uv run --no-sync twistd -noy switchboard.tac --pidfile=switchboard.pid"

    volumes:
      redis-data:
      canarytokens-uploads:
    | COMPOSE

  file { "${config_path}/docker-compose.yml":
    ensure  => file,
    mode    => '0644',
    content => $compose_content,
    require => File[$config_path],
    notify  => Exec['canarytokens-restart'],
  }

  # Bind-mounted env files don't trigger a compose recreate on content
  # change - same "refreshonly restart" precedent as roles::authelia's
  # own authelia-restart exec.
  exec { 'canarytokens-restart':
    command     => 'docker compose pull && docker compose up -d && docker compose restart',
    provider    => shell,
    cwd         => $config_path,
    path        => ['/usr/bin', '/bin'],
    refreshonly => true,
    require     => File["${config_path}/docker-compose.yml"],
  }
}
