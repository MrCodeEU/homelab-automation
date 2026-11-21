# Netronome is retired (2026-11-20, docs/ZERO_TRUST_PLAN.md Phase 4):
# services/speedtest-metrics replaced its speedtests, and Alloy already
# covers its host metrics. This removes what roles::netronome_agent and the
# speedtest catalog entry left on a host, data included (owner decision
# 2026-11-20: no export). Idempotent; remove the class once every host has
# applied it.
#
# Every host: the agent and its vnstat sidecar, with $base_path/netronome-agent
# (compose file and vnstat db). $server (nuc): the speedtest server and its
# staging copy, their volumes and directories. The services role's orphan
# cleanup would stop the server but keep the volumes.
class roles::netronome_teardown (
  String  $base_path       = '/opt',
  Boolean $manage_firewall = true,
  Boolean $server          = false,
) {
  $agent_dir = "${base_path}/netronome-agent"
  $agent_ps  = 'docker ps -aq --filter name=^netronome-agent$ --filter name=^netronome-vnstat$'

  exec { 'netronome-agent-teardown':
    command => "/bin/sh -c 'docker rm -f \$(${agent_ps}) 2>/dev/null; rm -rf ${agent_dir}; test -z \"\$(${agent_ps})\"'",
    onlyif  => "/bin/sh -c 'test -e ${agent_dir} || test -n \"\$(${agent_ps})\"'",
    path    => ['/usr/bin', '/bin', '/usr/local/bin'],
  }

  if $manage_firewall {
    roles::firewalld::port { 'netronome-agent-tcp':
      ensure   => absent,
      zone     => 'trusted',
      port     => 8200,
      protocol => 'tcp',
    }
  }

  if $server {
    $server_ps = 'docker ps -aq --filter name=^speedtest$ --filter name=^speedtest-staging$'
    $volumes   = 'docker volume ls -q --filter name=^netronome-data$ --filter name=^netronome-staging-data$ --filter name=^speedtest-staging_speedtest-data$'
    $dirs      = "${base_path}/speedtest ${base_path}/staging/speedtest"

    exec { 'netronome-server-teardown':
      command => "/bin/sh -c 'docker rm -f \$(${server_ps}) 2>/dev/null; docker volume rm \$(${volumes}) 2>/dev/null; rm -rf ${dirs}; test -z \"\$(${server_ps})\$(${volumes})\"'",
      onlyif  => "/bin/sh -c 'for d in ${dirs}; do test -e \$d && exit 0; done; test -n \"\$(${server_ps})\$(${volumes})\"'",
      path    => ['/usr/bin', '/bin', '/usr/local/bin'],
    }
  }
}
