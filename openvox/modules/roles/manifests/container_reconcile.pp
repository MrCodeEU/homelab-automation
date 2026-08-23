# Port of ansible/roles/container-reconcile (cross-checked against its
# already-verified migration/spot port, spot/playbooks/container-reconcile.yml
# commit 3ee852d). Removes standalone Docker containers - managed outside
# the generic roles::services catalog - that are no longer expected on a
# host, plus their leftover on-disk paths.
#
# The Ansible role is data-driven off homelab_standalone_containers/
# homelab_standalone_paths in group_vars/all/all.yml, each entry carrying
# its own host_groups filter. Today that list has exactly one entry
# (grafana-alloy, host_groups: [rocky]) and this class is only ever
# declared on mljr/nuc - so, same call the spot port already made, the
# entry is hardcoded below rather than porting the generic Jinja
# templating machinery. This shifts maintenance: adding a second
# standalone container from here on means editing this class too, not
# just all.yml - worth revisiting with real hiera data if that happens.
#
# Uses `docker inspect`/`docker rm` directly via exec, not a Puppet docker
# module - none is installed in this module path, and the CLI is already
# present on every rocky host (same "no external dependency" call as
# roles::mailcow/roles::services).
class roles::container_reconcile (
  Array[String] $expected = ['grafana-alloy'],
) {
  # All known standalone containers across the fleet, unfiltered - path
  # keyed by container name. Anything present here but not in $expected
  # gets removed on this host.
  $standalone = {
    'grafana-alloy' => '/opt/grafana-alloy',
  }

  $standalone.each |$name, $path| {
    unless $name in $expected {
      exec { "container-reconcile-rm-${name}":
        command => "/usr/bin/docker rm -f ${name}",
        onlyif  => "/usr/bin/docker inspect ${name}",
      }

      file { $path:
        ensure  => absent,
        force   => true,
        require => Exec["container-reconcile-rm-${name}"],
      }
    }
  }
}
