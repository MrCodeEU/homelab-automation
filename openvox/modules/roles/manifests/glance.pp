# Standalone Glance dashboard (mljr only) - raw `docker run`, its own
# services: catalog entry has skip_deploy: true, not managed by
# services.yml. Port of ansible/roles/glance.
#
# Content is the resolved output of glance.yml.j2's services loop over
# ansible/inventory/group_vars/all/all.yml's `services:` catalog, taken
# directly from what the already-validated spot port applied for real
# to production (2026-08-21, see the spot migration's own memory entry -
# it found and fixed one stale "Bichon" entry left over from before
# bichon's retirement, confirmed absent here). Embedded as static
# content rather than re-parsing the catalog on the target at apply
# time - same call as authelia's static content, and the same tradeoff:
# a future catalog change needs this file re-generated too, not
# automatic. Exact trailing whitespace on ~13 blank-ish lines (real
# artifacts of the original Jinja template, not accidental) is
# preserved byte-for-byte - written via a raw file, not the Edit tool,
# which silently trims trailing whitespace (see the authelia port's
# docker-compose.yml fix for the same class of gotcha).
#
# KNOWN LIMITATION, ported faithfully from the Ansible role and spot's
# port rather than fixed here: the container has zero idempotency
# guard - force-removed and recreated unconditionally on every single
# apply, not just when something changed. Same accepted shape as
# authelia's always-regenerating password hash and services*.yml's
# rsync-mtime false positive elsewhere in this migration.
class roles::glance (
  String $base_path = '/opt/glance',
) {
  $work_dir = '/usr/local/libexec/openvox-glance'

  file { $work_dir:
    ensure  => directory,
    mode    => '0755',
    recurse => true,
    purge   => true,
    source  => 'puppet:///modules/roles/glance',
  }

  file { $base_path:
    ensure => directory,
    mode   => '0755',
  }

  file { "${base_path}/config":
    ensure  => directory,
    mode    => '0755',
    require => File[$base_path],
  }

  exec { 'glance-legacy-teardown':
    command => "${work_dir}/legacy-teardown-apply.sh",
    unless  => "${work_dir}/legacy-teardown-check.sh",
    path    => ['/usr/bin', '/bin'],
    require => File[$work_dir],
  }

  file { "${base_path}/config/glance.yml":
    ensure  => file,
    mode    => '0644',
    content => @(END),
    # Glance Dashboard Configuration
    # Auto-generated from services.yml
    # Customize this template to fit your needs

    server:
      port: 8080

    branding:
      logo-text: "⚡"
      hide-footer: false

    theme:
      background-color: 240 8 9
      primary-color: 43 50 70
      positive-color: 96 44 68
      negative-color: 359 68 71
      contrast-multiplier: 1.2

    pages:
      - name: Home
        width: default
        columns:
          # Left sidebar - Status & Quick Info
          - size: small
            widgets:
              # Weather widget
              - type: weather
                location: Thaling, Austria
                units: metric
                hour-format: 24h
                
              # Calendar
              - type: calendar
                first-day-of-week: monday
                
              # Clock with multiple timezones
              - type: clock
                hour-format: 24h
                timezones:
                  - timezone: Europe/Vienna
                    label: Home
                  - timezone: America/New_York
                    label: New York
                  - timezone: Asia/Tokyo
                    label: Tokyo
                    
              # Quick bookmarks
              - type: bookmarks
                groups:
                  - title: Quick Links
                    color: 43 50 70
                    links:
                      - title: GitHub
                        url: https://github.com
                        icon: si:github
                      - title: Reddit
                        url: https://reddit.com
                        icon: si:reddit
          
          # Main content area
          - size: full
            widgets:
              # Docker containers status
              - type: docker-containers
                title: Services
                hide-by-default: false
                format-container-names: true
                
              # Server stats
              - type: server-stats
                servers:
                  - type: local
                    name: mljr
                    hide-swap: false
                    
              # RSS Feed - Tech news
              - type: rss
                title: Tech News
                style: horizontal-cards
                limit: 6
                feeds:
                  - url: https://news.ycombinator.com/rss
                    title: Hacker News
                  - url: https://www.theverge.com/rss/index.xml
                    title: The Verge
                  - url: https://techcrunch.com/feed/
                    title: TechCrunch
          
          # Right sidebar - Monitoring & Updates
          - size: small
            widgets:
              # Monitor services
              - type: monitor
                title: Service Health
                cache: 1m
                sites:
                  - title: Authelia
                    url: https://auth.mljr.eu
                    icon: mdi:shield-account
                  - title: Glance
                    url: https://dash.mljr.eu
                    icon: mdi:view-dashboard
                  - title: Nocturne
                    url: https://nc.mljr.eu
                    icon: mdi:moon-waning-crescent
                  - title: Kuma
                    url: https://uptime.mljr.eu
                    icon: mdi:heart-pulse
                  - title: Backup-dashboard
                    url: https://backup.mljr.eu
                    icon: mdi:cloud-sync
                  - title: Grafana
                    url: https://monitor.mljr.eu
                    icon: mdi:chart-areaspline
                  - title: Ntfy
                    url: https://ntfy.mljr.eu
                    icon: mdi:bell-ring
                  - title: Goaccess
                    url: https://logs.mljr.eu
                    icon: mdi:chart-bar
                  - title: Homeassistant
                    url: https://home.mljr.eu
                    icon: mdi:home-assistant
                  - title: Mail-archiver
                    url: https://mail-archive.mljr.eu
                    icon: mdi:email
                  - title: Mailcow
                    url: https://mail.mljr.eu
                    icon: mdi:email-server
                  - title: Crowdsec
                    url: https://crowdsec.mljr.eu
                    icon: mdi:shield-search
                  - title: Cockpit
                    url: https://cockpit.mljr.eu
                    icon: mdi:desktop-classic
                  - title: Homepage
                    url: https://mljr.eu
                    icon: mdi:account-circle
                  - title: Umami
                    url: https://umami.mljr.eu
                    icon: mdi:chart-bar
                  - title: Forgejo
                    url: https://git.mljr.eu
                    icon: mdi:git
                  - title: Ui-showcase
                    url: https://ui.mljr.eu
                    icon: mdi:palette-swatch
                  - title: Regex
                    url: https://regex.mljr.eu
                    icon: mdi:regex
                  - title: Cron
                    url: https://cron.mljr.eu
                    icon: mdi:timer-outline
                  - title: Codec
                    url: https://codec.mljr.eu
                    icon: mdi:code-braces
                  - title: Newsletter
                    url: https://newsletter.mljr.eu
                    icon: mdi:email-newsletter
                  - title: Weather-cli
                    url: https://weather-cli.mljr.eu
                    icon: mdi:weather-partly-cloudy
                  - title: Speedtest
                    url: https://speedtest.mljr.eu
                    icon: mdi:speedometer
                  - title: Nas
                    url: https://nas.mljr.eu
                    icon: mdi:server
                  - title: Immich
                    url: https://immich.mljr.eu
                    icon: mdi:image-multiple
                  - title: Auto-media-sort
                    url: https://sort.mljr.eu
                    icon: mdi:folder-move-outline
                  - title: Nextcloud
                    url: https://cloud.mljr.eu
                    icon: mdi:cloud
                  - title: Dockhand
                    url: https://dockhand.mljr.eu
                    icon: mdi:docker
                  - title: Syncthing
                    url: https://sync.mljr.eu
                    icon: mdi:sync
                  - title: Projects
                    url: https://projects.mljr.eu
                    icon: mdi:clipboard-list
                  - title: Dawarich
                    url: https://dawarich.mljr.eu
                    icon: mdi:map-marker-path
                  - title: Nuc-webui
                    url: https://nuc.mljr.eu
                    icon: mdi:monitor-dashboard
                  - title: Wordwiz
                    url: https://wordwiz.mljr.eu
                    icon: mdi:alphabetical-variant
                  - title: Sudoku
                    url: https://sudoku.mljr.eu
                    icon: mdi:grid
                  - title: Gameoflife
                    url: https://gameoflife.mljr.eu
                    icon: mdi:grain
                  - title: Cglab
                    url: https://cglab.mljr.eu
                    icon: mdi:cube-outline
                  - title: Godrive-demo
                    url: https://godrive.mljr.eu
                    icon: mdi:folder-network-outline
                  - title: Service-template
                    url: https://template.mljr.eu
                    icon: mdi:shape-outline
                  - title: Status
                    url: https://status.mljr.eu
                    icon: mdi:list-status
                  - title: GitHub
                    url: https://github.com
                    icon: si:github
                  - title: Docker Hub
                    url: https://hub.docker.com
                    icon: si:docker
                    
              # GitHub releases
              - type: releases
                title: Software Updates
                limit: 5
                collapse-after: 3
                repositories:
                  - glanceapp/glance
                  - docker/compose
                  - caddyserver/caddy
      
      # Monitoring page
      - name: Monitoring
        width: default
        columns:
          - size: full
            widgets:
              # Placeholder for Uptime Kuma integration
              - type: bookmarks
                title: Monitoring Tools
                groups:
                  - links:
                      - title: Setup Uptime Kuma
                        url: https://github.com/louislam/uptime-kuma
                        icon: mdi:heart-pulse
                        description: Uptime monitoring (to be added)
                      - title: Setup Glances
                        url: https://github.com/nicolargo/glances
                        icon: mdi:eye
                        description: System monitoring (alternative)
      
      # News & Social
      - name: News
        width: default  
        columns:
          - size: full
            widgets:
              # Hacker News
              - type: hacker-news
                limit: 20
                collapse-after: 10
                sort-by: top
                
              # Reddit feed
              - type: reddit
                subreddit: selfhosted
                style: vertical-list
                show-thumbnails: true
                limit: 15
                collapse-after: 7
                
              # Lobsters
              - type: lobsters
                limit: 15
                collapse-after: 7
                sort-by: hot
    | END
    require => File["${base_path}/config"],
  }

  exec { 'glance-run':
    command => "${work_dir}/run-apply.sh",
    path    => ['/usr/bin', '/bin'],
    require => [File["${base_path}/config/glance.yml"], Exec['glance-legacy-teardown']],
  }
}
