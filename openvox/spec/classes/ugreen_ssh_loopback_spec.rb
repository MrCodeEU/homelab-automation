# frozen_string_literal: true

require 'spec_helper'

describe 'roles::ugreen_ssh_loopback' do
  let(:facts) { { os: { family: 'Debian' } } }

  it { is_expected.to compile.with_all_deps }
  it { is_expected.to contain_service('ugreen-ssh-loopback.timer').with(ensure: 'running', enable: true) }

  it 'accepts loopback only, idempotently' do
    content = catalogue.resource('File', '/usr/local/sbin/ugreen-ssh-loopback.sh')[:content]
    expect(content).to include('-C UG_SSH_INPUT -s 127.0.0.0/8 -p tcp --dport 22 -j ACCEPT')
    expect(content).to include('-I UG_SSH_INPUT 1 -s 127.0.0.0/8 -p tcp --dport 22 -j ACCEPT')
  end

  it do
    is_expected.to contain_exec('ugreen-ssh-loopback')
      .with_unless('/usr/sbin/iptables -C UG_SSH_INPUT -s 127.0.0.0/8 -p tcp --dport 22 -j ACCEPT')
  end
end
