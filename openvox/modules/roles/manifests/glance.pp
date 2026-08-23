# Standalone Glance dashboard (mljr only) - raw `docker run`, its own
# services: catalog entry has skip_deploy: true, not managed by
# services.yml. Port of ansible/roles/glance.
#
# glance.yml is rendered from a real EPP template
# (templates/glance.yml.epp, ported directly from
# ansible/roles/glance/templates/glance.yml.j2) against
# lookup('services_catalog') (data/common.yaml, the same catalog
# ansible/inventory/group_vars/all/all.yml's `services:` is the source
# of truth for) - not spot's pre-rendered Go output copied in as static
# content. A future catalog change now only needs data/common.yaml
# updated; this role picks it up on its own next apply.
#
# KNOWN LIMITATION, ported faithfully from the Ansible role and spot's
# port rather than fixed here: the container has zero idempotency
# guard - force-removed and recreated unconditionally on every single
# apply, not just when something changed. Same accepted shape as
# authelia's always-regenerating password hash and services*.yml's
# rsync-mtime false positive elsewhere in this migration.
class roles::glance (
  String $base_path = '/opt/glance',
  String $location  = 'Thaling, Austria',
  String $timezone  = 'Europe/Vienna',
  String $hostname  = 'mljr',
) {
  $services = lookup('services_catalog')

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
    content => epp('roles/glance.yml.epp', {
      'location' => $location,
      'timezone' => $timezone,
      'hostname' => $hostname,
      'services' => $services,
    }),
    require => File["${base_path}/config"],
  }

  exec { 'glance-run':
    command => "${work_dir}/run-apply.sh",
    path    => ['/usr/bin', '/bin'],
    require => [File["${base_path}/config/glance.yml"], Exec['glance-legacy-teardown']],
  }
}
