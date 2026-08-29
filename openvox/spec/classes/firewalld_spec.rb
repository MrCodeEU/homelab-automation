require 'spec_helper'

describe 'roles::firewalld' do
  it { is_expected.to compile.with_all_deps }

  it do
    is_expected.to contain_file('/usr/local/libexec/openvox-firewalld').with(
      ensure: 'directory',
      mode: '0755',
    )
  end

  [
    'zone-sources-check.sh',
    'zone-sources-apply.sh',
  ].each do |script|
    it do
      is_expected.to contain_file("/usr/local/libexec/openvox-firewalld/#{script}").with(
        ensure: 'file',
        mode: '0755',
        require: 'File[/usr/local/libexec/openvox-firewalld]',
      )
    end
  end

  it do
    is_expected.to contain_service('firewalld').with(
      ensure: 'running',
      enable: true,
    )
  end
end
