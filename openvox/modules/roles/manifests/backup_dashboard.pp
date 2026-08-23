# Port of ansible/roles/backup-dashboard (cross-checked against its
# already-verified migration/spot port, commit d70ceac). nuc only -
# host-side state for the backup-dashboard collector/web containers
# (deployed as compose services by roles::services). This role only
# owns what must outlive them: the rendered catalog and the state
# directory the collector writes its snapshot into.
#
# NOT under /opt/backup-dashboard: roles::services::service's own
# directory resource recurses (remote) from this module's vendored
# source tree, so anything written there outside that tree survives -
# but state genuinely doesn't belong inside a service's own deploy
# directory either, same reasoning ansible/roles/backup-dashboard's own
# header comment already gives (mirrors roles::healthreport's posture).
class roles::backup_dashboard (
  String  $root = '/var/lib/backup-dashboard',
  # The container runs unprivileged as this uid (see
  # services/backup-dashboard/Dockerfile) - the state directory must be
  # owned by it or the collector cannot write its snapshot. Matches
  # roles::healthreport's own uid deliberately, not a separate one: the
  # collector reads healthreport's SSH key (0600, owned by that uid)
  # read-only, and a mismatched uid here cannot open it.
  Integer $uid  = 10001,
) {
  $state_dir = "${root}/state"

  # The root stays root-owned; only what the container must write does not.
  file { $root:
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }

  file { $state_dir:
    ensure  => directory,
    owner   => $uid,
    group   => $uid,
    mode    => '0755',
    require => File[$root],
  }

  # nas's host-side folder backups - single source of truth, shared with
  # any future roles::unraid_backup port (see data/common.yaml's own
  # header comment on this key).
  $unraid_backup_paths = lookup('unraid_backup_paths')

  # Rocky-hosted, backup-managed services' volumes+paths only (name,
  # host, and just enough to build "source": [...]) - deliberately
  # duplicated from roles::backup's own private $backup_service_configs
  # Hash rather than shared via a lookup(), since that Hash also carries
  # Sensitive-wrapped pre/post/restore-hook shell bodies that have no
  # business in a read-only JSON status file. Keep this list in sync
  # with roles::backup's own $services param on each host's site.pp
  # node block, and with $backup_service_configs itself, whenever either
  # changes - same "hardcode a small derived dataset, document the
  # maintenance shift" call already made for roles::container_reconcile.
  $catalog_services = [
    { 'name' => 'authelia', 'host' => 'mljr', 'source' => ['authelia_redis_data', '/opt/authelia'] },
    { 'name' => 'mailcow', 'host' => 'mljr', 'source' => [
        'mailcowdockerized_vmail-vol-1', 'mailcowdockerized_mysql-vol-1',
        '/opt/backups/mailcow-dumps', '/opt/mailcow-dockerized/data',
    ] },
    { 'name' => 'ntfy', 'host' => 'mljr', 'source' => ['ntfy_ntfy-data', 'ntfy_ntfy-cache'] },
    { 'name' => 'goaccess', 'host' => 'mljr', 'source' => ['goaccess_goaccess-data', 'goaccess_goaccess-report'] },
    { 'name' => 'crowdsec', 'host' => 'mljr', 'source' => ['crowdsec-config', 'crowdsec-data', 'crowdsec-web-ui-data'] },
    { 'name' => 'newsletter', 'host' => 'mljr', 'source' => ['newsletter_newsletter-data'] },
    { 'name' => 'kuma', 'host' => 'nuc', 'source' => ['kuma_uptime-kuma-data'] },
    { 'name' => 'forgejo', 'host' => 'nuc', 'source' => ['forgejo-data', 'forgejo-db-data', '/opt/backups/forgejo-dumps'] },
    { 'name' => 'mail-archiver', 'host' => 'nuc', 'source' => ['mail-archiver_mail-archiver-dp-keys', '/opt/backups/mail-archiver-dumps'] },
    { 'name' => 'umami', 'host' => 'nuc', 'source' => ['umami_umami-db-data', '/opt/backups/umami-dumps'] },
    { 'name' => 'grafana', 'host' => 'nuc', 'source' => ['grafana-data', 'victoriametrics-data', 'loki-data'] },
    { 'name' => 'nocturne', 'host' => 'nuc', 'source' => ['nocturne_nocturne-postgres-data', '/opt/backups/nocturne-dumps'] },
  ]

  $folder_entries = $unraid_backup_paths.map |$p| {
    {
      'name'         => $p['name'],
      'type'         => 'folder',
      'host'         => 'nas',
      'source'       => $p['src'],
      'dest'         => $p['dest'],
      'destinations' => $p['destinations'],
    }
  }

  $service_entries = $catalog_services.map |$s| {
    {
      'name'         => $s['name'],
      'type'         => 'service',
      'host'         => $s['host'],
      'source'       => $s['source'],
      'destinations' => ['pcloud', 'ugreen'],
    }
  }

  # Built as real Puppet data and serialized with stdlib's
  # stdlib::to_json_pretty(), not hand-assembled EPP/string-concatenated JSON -
  # the same reasoning the Ansible template's own header comment gives
  # for using to_nice_json over manual per-line JSON: a trailing/missing
  # comma from an empty list is a real footgun that silently produces
  # invalid JSON the collector then fails to parse.
  #
  # generated_at is real wall-clock time (Puppet core's own generate()
  # calling the real `date` binary at catalog-compile time, not a
  # gathered fact) - this means the file's content differs on literally
  # every apply regardless of whether the catalog itself changed, same
  # accepted-quirk shape already documented for authelia's password hash
  # and roles::glance's container recreate. Harmless here: nothing
  # restarts off this file changing, the collector just re-reads it.
  $generated_at = strip(generate('/usr/bin/date', '-u', '+%Y-%m-%dT%H:%M:%SZ'))

  file { "${root}/backup_catalog.json":
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => stdlib::to_json_pretty({
      'generated_at' => $generated_at,
      'entries'      => $folder_entries + $service_entries,
    }),
    require => File[$root],
  }
}
