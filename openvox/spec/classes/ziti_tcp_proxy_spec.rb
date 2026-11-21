require 'spec_helper'

describe 'roles::ziti_tcp_proxy' do
  let(:node) { 'nuc.int.mljr.eu' }

  it { is_expected.to compile.with_all_deps }

  it 'installs the binary into the directory the sidecars mount' do
    is_expected.to contain_file('/usr/local/libexec/ziti-tcp-proxy').with_ensure('directory')
    is_expected.to contain_file('/usr/local/libexec/ziti-tcp-proxy/ziti-tcp-proxy')
      .with_mode('0755')
      .with_source('puppet:///modules/roles/ziti_tcp_proxy/ziti-tcp-proxy')
  end

  it 'restarts the labelled sidecars only when the binary changes' do
    is_expected.to contain_exec('ziti-tcp-proxy-restart-sidecars')
      .with_refreshonly(true)
      .with_command(%r{--filter label=homelab\.ziti-tcp-proxy=true \| xargs -r docker restart})
      .that_subscribes_to('File[/usr/local/libexec/ziti-tcp-proxy/ziti-tcp-proxy]')
  end
end
