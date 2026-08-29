# Standalone Authelia + Redis compose stack (mljr only), NOT part of the
# services: catalog services.yml-equivalent deploys. Ported from
# ansible/roles/authelia, logic cross-checked against the already-live
# migration/spot port (spot/playbooks/authelia.yml) which found the same
# quirks noted below.
#
# First role in this migration to actually consume a secret via
# hiera-eyaml - see scripts/install-openvox-eyaml.sh for the gem/key
# deploy this depends on (run once per host, not part of the general
# environment sync).
#
# FIXED 2026-08-29 (inherited from the Ansible role, not introduced by
# this port): the admin password hash uses a random salt every call
# (`authelia crypto hash generate argon2`), so users_database.yml's
# content differs on literally every run regardless of whether the
# password changed - the users-database exec used to have no guard and
# always reported CHANGED, restarting the authelia container on every
# single apply. Now guarded with `creates` (see the exec below): the
# file generates once, on first creation, and is left alone after that.
# Trade-off, accepted deliberately: rotating vault_authelia_admin_password
# no longer regenerates it automatically - delete
# ${config_path}/users_database.yml by hand to force a rebuild with the
# new password. configuration.yml and docker-compose.yml are real stable
# content and only trigger a restart when something actually changed.
class roles::authelia (
  String $config_path = '/opt/authelia',
  String $domain      = 'mljr.eu',
  String $email        = 'admin@mljr.eu',
  String $timezone     = 'Europe/Vienna',
  String $version      = 'latest',
  String $bind_addr    = '127.0.0.1',
  Integer $port         = 9091,
) {
  $jwt_secret     = Sensitive(lookup('vault_authelia_jwt_secret'))
  $session_secret = Sensitive(lookup('vault_authelia_session_secret'))
  $storage_key    = Sensitive(lookup('vault_authelia_storage_encryption_key'))
  $admin_password = Sensitive(lookup('vault_authelia_admin_password'))
  $smtp_host      = lookup('vault_smtp_host')
  $smtp_port      = lookup('vault_smtp_port', { 'default_value' => '587' })
  $smtp_user      = lookup('vault_smtp_user')
  $smtp_password  = Sensitive(lookup('vault_smtp_password'))
  $smtp_from      = lookup('vault_smtp_from', { 'default_value' => "notifications@${domain}" })

  file { $config_path:
    ensure => directory,
    mode   => '0755',
  }

  file { "${config_path}/db.sqlite3":
    ensure  => file,
    mode    => '0600',
    replace => false,
    require => File[$config_path],
  }

  $config_content = @("CONFIG"/L)
    ###############################################################################
    #                           Authelia Configuration                            #
    ###############################################################################

    server:
      host: 0.0.0.0
      port: 9091

    theme: light

    identity_validation:
      reset_password:
        jwt_secret: "${jwt_secret.unwrap}"

    authentication_backend:
      password_reset:
        disable: false
      file:
        path: /config/users_database.yml
        password:
          algorithm: argon2id
          iterations: 3
          memory: 65536
          parallelism: 4
          salt_length: 16

    # Two-factor authentication with TOTP
    totp:
      disable: false
      issuer: "${domain}"
      algorithm: sha1
      digits: 6
      period: 30
      skew: 1

    # WebAuthn (hardware keys) support
    webauthn:
      disable: false
      display_name: "${domain}"
      attestation_conveyance_preference: indirect
      user_verification: preferred

    access_control:
      default_policy: deny
      rules:
        # Allow public access to the authentication portal
        - domain: "auth.${domain}"
          policy: bypass

        # Require two-factor for admin-level services (optional - remove if not desired)
        # - domain:
        #     - "fail2ban.${domain}"
        #     - "docker.${domain}"
        #   policy: two_factor
        #   subject: "group:admins"

        # Allow all authenticated users to access everything else
        - domain: "*.${domain}"
          policy: one_factor

    session:
      secret: "${session_secret.unwrap}"
      cookies:
        - domain: "${domain}"
          authelia_url: "https://auth.${domain}"
          default_redirection_url: "https://${domain}"
      redis:
        host: authelia_redis
        port: 6379

    storage:
      encryption_key: "${storage_key.unwrap}"
      local:
        path: /config/db.sqlite3

    notifier:
      disable_startup_check: true
      smtp:
        address: "submission://${smtp_host}:${smtp_port}"
        username: "${smtp_user}"
        password: "${smtp_password.unwrap}"
        sender: "Authelia <${smtp_from}>"
        subject: "[Authelia] {title}"
        tls:
          skip_verify: true
    | CONFIG

  file { "${config_path}/configuration.yml":
    ensure  => file,
    mode    => '0600',
    content => Sensitive($config_content),
    require => File[$config_path],
    notify  => Exec['authelia-restart'],
  }

  $users_db_script = Sensitive(@("SCRIPT"/L$))
    set -euo pipefail
    HASH=$(docker run --rm authelia/authelia:latest authelia crypto hash generate argon2 --password "${admin_password.unwrap}" | awk -F': ' '/Digest:/ {print \$2}')
    if [ -z "\$HASH" ]; then
      echo "ERROR: failed to generate the admin password hash" >&2
      exit 1
    fi
    cat > ${config_path}/users_database.yml <<EOF
    users:
      admin:
        displayname: Admin
        password: "\$HASH"
        email: "${email}"
        groups:
          - admins
          - dev
      mrcode:
        displayname: mrcode
        password: "\$HASH"
        email: "${email}"
        groups:
          - admins
          - dev
    EOF
    chmod 600 ${config_path}/users_database.yml
    | SCRIPT

  exec { 'authelia-users-database':
    command  => $users_db_script,
    provider => shell,
    path     => ['/usr/bin', '/bin'],
    creates  => "${config_path}/users_database.yml",
    require  => File[$config_path],
    notify   => Exec['authelia-restart'],
  }

  $compose_content = @("COMPOSE"/L)
    services:
      authelia:
        image: authelia/authelia:${version}
        container_name: authelia
        volumes:
          - ./configuration.yml:/config/configuration.yml
          - ./users_database.yml:/config/users_database.yml
          - ./db.sqlite3:/config/db.sqlite3
          - ./notification.txt:/config/notification.txt
        ports:
          - "${bind_addr}:${port}:9091"
        environment:
          - TZ=${timezone}
        restart: unless-stopped
        healthcheck:
          disable: true
        depends_on:
          - redis
      
      redis:
        image: redis:alpine
        container_name: authelia_redis
        volumes:
          - redis_data:/data
        restart: unless-stopped
        expose:
          - 6379

    volumes:
      redis_data:
    | COMPOSE

  file { "${config_path}/docker-compose.yml":
    ensure  => file,
    mode    => '0644',
    content => $compose_content,
    require => File[$config_path],
    notify  => Exec['authelia-restart'],
  }

  # Bind-mounted config files don't trigger a compose recreate on content
  # change - a real restart is required to pick them up. refreshonly - only
  # runs when one of the 3 file/exec resources above actually changed.
  exec { 'authelia-restart':
    command     => 'docker compose pull && docker compose up -d && docker compose restart',
    provider    => shell,
    cwd         => $config_path,
    path        => ['/usr/bin', '/bin'],
    refreshonly => true,
    require     => File["${config_path}/docker-compose.yml"],
  }
}
