# Port of ansible/roles/hetrixtools-agent (cross-checked against its
# already-verified migration/spot port, commit e7efaad). mljr only.
# External uptime/server monitoring agent - curl-piped vendor installer,
# no package manager entry, so this stays a plain exec with a `creates`
# guard rather than a native package resource.
#
# Verification improvement carried over from the spot port: the Ansible
# role's own "Verify HetrixTools agent is running" check runs `crontab
# -l` as root and looks for `hetrixtools_agent.sh` - but the install
# script's cron entry actually lives under a dedicated `hetrixtools`
# system user, not root (confirmed live), so that check has always
# reported "NOT configured" even when the agent is installed and
# working correctly. This port checks the right user.
class roles::hetrixtools_agent (
  Sensitive[String] $api_token = Sensitive(lookup('vault_hetrixtools_api_token', { 'default_value' => '' })),
) {
  exec { 'hetrixtools-agent-install':
    command   => "/bin/bash -c \"curl -s https://raw.githubusercontent.com/hetrixtools/agent/master/hetrixtools_install.sh | bash -s '${api_token.unwrap}' 0 0 0 0 0 0\"",
    creates   => '/etc/hetrixtools/hetrixtools_agent.sh',
    # Never log this command's own text - it embeds the raw API token as
    # a literal argv string, unlike lookup()'d values used only as an
    # environment variable elsewhere in this migration (mailcow/services'
    # docker logins). logoutput => on_failure keeps stdout out of a
    # successful run's log while still surfacing it if the install fails.
    logoutput => on_failure,
  }

  # Read-only, always runs regardless of noop/real (same unconditional,
  # side-effect-free shape as roles::services' own healthchecks) -
  # matches the Ansible role's own unconditional status-report step.
  exec { 'hetrixtools-agent-verify-cron':
    command   => "/bin/sh -c \"crontab -u hetrixtools -l 2>/dev/null | grep -q hetrixtools_agent.sh && echo 'HEALTHY: hetrixtools agent cron entry configured' || echo 'WARNING: hetrixtools agent cron entry NOT configured'\"",
    logoutput => true,
    require   => Exec['hetrixtools-agent-install'],
  }
}
