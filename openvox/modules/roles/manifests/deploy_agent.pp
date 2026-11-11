# Pull side of deploys (docs/DEPLOY_AGENT.md): deploy-agent polls the
# branch deploy/<host>, checks each request and runs scripts/openvox-apply.sh
# from the verified commit. $mode noop runs it next to the push during the
# rollout; apply makes it the deploy path.
#
# The unit is never restarted from here: when the agent itself runs the
# apply that changes it, a restart would kill that apply (same cgroup).
# The agent exits after a poll once its binary or env file changed, and
# Restart=always brings up the new version.
class roles::deploy_agent (
  Enum['noop', 'apply'] $mode = 'noop',
) {
  $certname = $trusted['certname']
  $host     = $certname.split('\.')[0]

  $mail = {
    'to'        => lookup('vault_healthreport_email_to', { 'default_value' => '' }),
    'host'      => lookup('vault_smtp_host', { 'default_value' => '' }),
    'port'      => lookup('vault_smtp_port', { 'default_value' => '587' }),
    'user'      => lookup('vault_smtp_user', { 'default_value' => '' }),
    'password'  => lookup('vault_smtp_password', { 'default_value' => '' }),
    'from'      => 'notifications@mljr.eu',
    'host2'     => lookup('vault_healthreport_smtp2_host', { 'default_value' => '' }),
    'port2'     => lookup('vault_healthreport_smtp2_port', { 'default_value' => '587' }),
    'user2'     => lookup('vault_healthreport_smtp2_user', { 'default_value' => '' }),
    'password2' => lookup('vault_healthreport_smtp2_password', { 'default_value' => '' }),
    'from2'     => lookup('vault_healthreport_smtp2_from', { 'default_value' => '' }),
  }

  file { '/usr/local/bin/deploy-agent':
    ensure => file,
    mode   => '0755',
    source => 'puppet:///modules/roles/deploy_agent/deploy-agent',
  }

  file { '/etc/homelab-deploy':
    ensure => directory,
    mode   => '0700',
  }

  # GitHub's web-flow signing keys (https://github.com/web-flow.gpg): they
  # sign the squash merges on main and the createCommitOnBranch requests.
  file { '/etc/homelab-deploy/keyring.asc':
    ensure => file,
    mode   => '0644',
    source => 'puppet:///modules/roles/deploy_agent/github-web-flow.asc',
  }

  file { '/etc/homelab-deploy/agent.env':
    ensure    => file,
    mode      => '0600',
    show_diff => false,
    content   => Sensitive(epp('roles/deploy_agent/agent.env.epp', {
      'host'     => $host,
      'mode'     => $mode,
      'certname' => $certname,
      'mail'     => $mail,
    })),
  }

  file { '/etc/systemd/system/deploy-agent.service':
    ensure  => file,
    mode    => '0644',
    content => "[Unit]\nDescription=Deploy agent (pull deploys from deploy/${host})\nWants=network-online.target\nAfter=network-online.target\n\n[Service]\nType=simple\nEnvironmentFile=/etc/homelab-deploy/agent.env\nExecStart=/usr/local/bin/deploy-agent\nStateDirectory=homelab-deploy\nStateDirectoryMode=0700\nRestart=always\nRestartSec=30\n\n[Install]\nWantedBy=multi-user.target\n",
  }

  # Same gotcha as roles::hawser_agent: the service provider does not
  # daemon-reload on its own when a unit file changes.
  exec { 'deploy-agent-daemon-reload':
    command     => '/usr/bin/systemctl daemon-reload',
    refreshonly => true,
    subscribe   => File['/etc/systemd/system/deploy-agent.service'],
  }

  service { 'deploy-agent':
    ensure  => running,
    enable  => true,
    require => [
      File['/usr/local/bin/deploy-agent', '/etc/homelab-deploy/keyring.asc', '/etc/homelab-deploy/agent.env'],
      Exec['deploy-agent-daemon-reload'],
    ],
  }
}
