require 'spec_helper'

describe 'roles::tcp_notsent_lowat' do
  it { is_expected.to compile.with_all_deps }

  it 'persists the cap and sets it at once when it differs' do
    is_expected.to contain_file('/etc/sysctl.d/60-homelab-tcp-notsent-lowat.conf').with_content(
      %r{^net\.ipv4\.tcp_notsent_lowat = 131072$},
    )
    is_expected.to contain_exec('tcp-notsent-lowat').with(
      command: 'sysctl -q -w net.ipv4.tcp_notsent_lowat=131072',
      unless: 'test "$(sysctl -n net.ipv4.tcp_notsent_lowat)" = 131072',
    )
  end
end
