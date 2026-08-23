# Port of ansible/roles/homepage-data-sync (cross-checked against its
# already-verified migration/spot port, commit e7efaad). mljr only.
# Periodically clones/pulls the mljr-data repo (generated site-data.json
# + assets/) onto the host, so the homepage service's bind-mounted
# /opt/mljr-data hot-reloads live content without a rebuild or redeploy.
#
# Parameter named $sync_schedule, not $schedule - the latter collides
# with Puppet's own `schedule` metaparameter (valid on every resource
# type) and triggers a real compile warning if a class parameter uses
# that exact name.
class roles::homepage_data_sync (
  String $path     = '/opt/mljr-data',
  String $repo     = 'https://github.com/MrCodeEU/mljr-data.git',
  String $branch   = 'master',
  String $sync_schedule = '*:0/15',
) {
  file { '/etc/systemd/system/homepage-data-sync.service':
    ensure  => file,
    mode    => '0644',
    content => "[Unit]\nDescription=Sync mljr-data repo for homepage\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nType=oneshot\nExecStart=/bin/sh -c 'if [ -d ${path}/.git ]; then git -C ${path} fetch --depth 1 origin ${branch} && git -C ${path} reset --hard origin/${branch}; else git clone --depth 1 --branch ${branch} ${repo} ${path}; fi'\nStandardOutput=journal\nStandardError=journal\nNice=19\nIOSchedulingClass=idle\n\n[Install]\nWantedBy=multi-user.target\n",
  }

  file { '/etc/systemd/system/homepage-data-sync.timer':
    ensure  => file,
    mode    => '0644',
    content => "[Unit]\nDescription=Periodic sync of mljr-data repo for homepage\n\n[Timer]\nOnBootSec=2min\nOnCalendar=${sync_schedule}\nPersistent=true\nRandomizedDelaySec=2min\nUnit=homepage-data-sync.service\n\n[Install]\nWantedBy=timers.target\n",
  }

  # Puppet's systemd service provider does not run `daemon-reload` on
  # its own when a unit file changes underneath it - same gotcha
  # already documented in roles::hawser_agent.
  exec { 'homepage-data-sync-daemon-reload':
    command     => '/usr/bin/systemctl daemon-reload',
    refreshonly => true,
    subscribe   => [
      File['/etc/systemd/system/homepage-data-sync.service'],
      File['/etc/systemd/system/homepage-data-sync.timer'],
    ],
  }

  service { 'homepage-data-sync.timer':
    ensure    => running,
    enable    => true,
    subscribe => File['/etc/systemd/system/homepage-data-sync.timer'],
    require   => Exec['homepage-data-sync-daemon-reload'],
  }

  # Matches the Ansible role's own gating ("when: sync_service_created.changed
  # or sync_timer_created.changed") - only force an immediate sync when
  # the unit/timer content actually changed, not on every apply.
  exec { 'homepage-data-sync-initial-run':
    command     => '/usr/bin/systemctl start homepage-data-sync.service',
    refreshonly => true,
    subscribe   => [
      File['/etc/systemd/system/homepage-data-sync.service'],
      File['/etc/systemd/system/homepage-data-sync.timer'],
    ],
    require     => Service['homepage-data-sync.timer'],
  }
}
