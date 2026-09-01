require 'spec_helper'

describe 'roles::mailcow' do
  def rendered_file(path)
    catalogue.resource('file', path)[:content]
  end

  it { is_expected.to compile.with_all_deps }

  it 'keeps the mailcow web listeners private and delegates certificates to Caddy' do
    override = rendered_file('/opt/mailcow-dockerized/docker-compose.override.yml')

    expect(override).to include(
      'HTTP_PORT=8092, HTTP_BIND=127.0.0.1',
      'HTTPS_PORT=8443, HTTPS_BIND=127.0.0.1',
      'SKIP_LETS_ENCRYPT=y',
      'SKIP_HTTP_VERIFICATION=y',
    )
  end

  it 'installs Caddy certificate keys privately and limits restarts to mail services' do
    cert_sync = rendered_file('/usr/local/bin/mailcow-cert-sync.sh')

    is_expected.to contain_file('/usr/local/bin/mailcow-cert-sync.sh').with(
      ensure: 'file',
      mode: '0755',
    )
    expect(cert_sync).to include(
      'install -m 600 "$CADDY_KEY" "$MAILCOW_KEY"',
      'docker compose restart postfix-mailcow dovecot-mailcow',
    )
    expect(cert_sync).not_to match(/docker compose restart (?!postfix-mailcow dovecot-mailcow)/)
  end

  it 'runs certificate sync and full updates only through persistent timers' do
    is_expected.to contain_file('/etc/systemd/system/mailcow-cert-sync.timer').with(
      content: %r{OnCalendar=\*-\*-\* 03,15:00:00},
    )
    is_expected.to contain_file('/etc/systemd/system/mailcow-update.timer').with(
      content: %r{OnCalendar=Sun \*-\*-\* 04:00:00},
    )
    is_expected.to contain_service('mailcow-cert-sync.timer').with(
      ensure: 'running',
      enable: true,
    )
    is_expected.to contain_service('mailcow-update.timer').with(
      ensure: 'running',
      enable: true,
    )
    is_expected.not_to contain_exec('mailcow-update')
  end

  it 'never logs the Docker Hub credential and preserves the service startup chain' do
    service_requirements = catalogue.resource('exec', 'mailcow-services-up')[:require].map(&:ref)

    expect(service_requirements).to include(
      'File[/opt/mailcow-dockerized/docker-compose.override.yml]',
      'Exec[mailcow-env-sync]',
      'Exec[mailcow-dockerhub-login]',
    )
    is_expected.to contain_exec('mailcow-dockerhub-login').with(
      logoutput: false,
      require: 'Exec[mailcow-clone]',
    )
    is_expected.to contain_exec('mailcow-health-check').with(
      environment: ['MAILCOW_HTTP_PORT=8092'],
      require: 'Exec[mailcow-cert-sync-initial]',
    )
  end
end
