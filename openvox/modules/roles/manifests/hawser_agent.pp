# Port of ansible/roles/hawser-agent (cross-checked against its
# already-verified migration/spot port, commit e7efaad). Rocky hosts only
# (mljr, nuc). Lightweight Docker agent for Dockhand remote management -
# listens on loopback; the central Dockhand instance on nas reaches it over
# Ziti (ziti/tofu/hawser.tf: this host's router dials 127.0.0.1:$port, only
# nas's m2m-nas proxy may dial it). Was this host's Tailscale IP.
#
# $token: Hawser's TOKEN (Dockhand authenticates with it), from this host's
# eyaml as vault_hawser_token_<host>. nuc's eyaml holds every host's token
# too, for Dockhand's side (roles::dockhand_environments).
class roles::hawser_agent (
  Optional[Sensitive[String[1]]] $token = undef,
  Stdlib::IP::Address::Nosubnet $bind_address = '127.0.0.1',
  Integer $port           = 2376,
  String  $install_script = 'https://raw.githubusercontent.com/Finsys/hawser/main/scripts/install.sh',
  String  $binary         = '/usr/local/bin/hawser',
) {
  # No package manager entry for this - it's a curl-piped vendor
  # installer, same as the Ansible/spot ports before it. `creates`
  # makes this idempotent (the installer itself is not re-run once the
  # binary exists).
  exec { 'hawser-agent-install':
    command => "/usr/bin/curl -sSL -o /tmp/hawser-install.sh ${install_script} && /usr/bin/bash /tmp/hawser-install.sh",
    creates => $binary,
  }

  $_token = $token ? {
    undef   => Sensitive(lookup("vault_hawser_token_${split($trusted['certname'], '[.]')[0]}")),
    default => $token,
  }

  # The installer's EnvironmentFile. Owned here so the token is set: the
  # installer generates none unless asked, and nuc's Hawser ran without one.
  file { '/etc/hawser/config':
    ensure    => file,
    owner     => 'root',
    group     => 'root',
    mode      => '0600',
    content   => Sensitive("# Managed by OpenVox (roles::hawser_agent)\nDOCKER_SOCKET=/var/run/docker.sock\nPORT=${port}\nTOKEN=${_token.unwrap}\n"),
    show_diff => false,
    require   => Exec['hawser-agent-install'],
  }

  file { '/etc/systemd/system/hawser.service.d':
    ensure  => directory,
    mode    => '0755',
    require => Exec['hawser-agent-install'],
  }

  # Note the em dash (not a hyphen) in the ProtectSystem comment below -
  # copied byte-exact from the real deployed file (and the Ansible
  # template before it). A prior port of a different role in this same
  # migration retyped an em dash as a plain ASCII hyphen in a comment
  # and it silently broke byte-exact idempotency checks despite reading
  # identically to a human - worth being deliberate about here too.
  # Hawser reads PORT and BIND_ADDRESS (`hawser --help`). The drop-in set
  # HAWSER_PORT/HAWSER_BIND_ADDRESS until 2026-11-22, which it ignores, so it
  # listened on 0.0.0.0 and only firewalld kept it off the LAN and the
  # internet. /etc/hawser/config (the installer's EnvironmentFile) sets PORT
  # too and wins over Environment=; it has no BIND_ADDRESS.
  file { '/etc/systemd/system/hawser.service.d/override.conf':
    ensure  => file,
    mode    => '0644',
    content => "[Service]\nEnvironment=PORT=${port}\nEnvironment=BIND_ADDRESS=${bind_address}\n# Disable namespace hardening — incompatible with some Rocky Linux kernels\nProtectSystem=false\nProtectHome=false\nReadWritePaths=\n",
    require => File['/etc/systemd/system/hawser.service.d'],
  }

  # Puppet's systemd service provider does not itself run
  # `daemon-reload` when a unit/drop-in file changes underneath it -
  # needs an explicit subscribe like this one, run before the service
  # resource acts on the (possibly stale, pre-reload) unit state.
  exec { 'hawser-agent-daemon-reload':
    command     => '/usr/bin/systemctl daemon-reload',
    refreshonly => true,
    subscribe   => File['/etc/systemd/system/hawser.service.d/override.conf'],
  }

  # The port was open in the trusted zone (the tailnet) while Hawser
  # listened there; loopback needs no rule.
  roles::firewalld::port { 'hawser-agent-tcp':
    ensure   => absent,
    zone     => 'trusted',
    port     => $port,
    protocol => 'tcp',
  }

  service { 'hawser':
    ensure    => running,
    enable    => true,
    subscribe => File['/etc/systemd/system/hawser.service.d/override.conf', '/etc/hawser/config'],
    require   => [
      Exec['hawser-agent-install'],
      Exec['hawser-agent-daemon-reload'],
      Roles::Firewalld::Port['hawser-agent-tcp'],
    ],
  }
}
