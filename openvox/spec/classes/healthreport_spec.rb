require 'spec_helper'

describe 'roles::healthreport' do
  it { is_expected.to compile.with_all_deps }

  it 'keeps report state outside service deployment paths and protects its SSH identity' do
    is_expected.to contain_file('/var/lib/healthreport').with(
      ensure: 'directory',
      owner: 'root',
      group: 'root',
      mode: '0755',
    )
    is_expected.to contain_file('/var/lib/healthreport/state/history').with(
      owner: 10001,
      group: 10001,
      mode: '0755',
      require: 'File[/var/lib/healthreport]',
    )
    is_expected.to contain_file('/var/lib/healthreport/ssh').with(
      owner: 10001,
      group: 10001,
      mode: '0700',
      require: 'File[/var/lib/healthreport]',
    )
    is_expected.to contain_file('/var/lib/healthreport/ssh/id_ed25519').with(
      owner: 10001,
      group: 10001,
      mode: '0600',
      require: 'Exec[healthreport-key-generate]',
    )
  end

  it 'generates the SSH key once without overwriting an existing identity' do
    is_expected.to contain_exec('healthreport-key-generate').with(
      command: %r{ssh-keygen -t ed25519},
      creates: '/var/lib/healthreport/ssh/id_ed25519',
      require: 'File[/var/lib/healthreport/ssh]',
    )
  end
end

describe 'roles::host_facts_endpoint' do
  let(:hiera_config) { File.expand_path('../fixtures/healthreport_hiera.yaml', __dir__) }
  let(:params) do
    {
      os_family: 'Rocky',
      hostname: 'mljr',
      dest: '/usr/local/bin/homelab-facts',
    }
  end

  it { is_expected.to compile.with_all_deps }

  it 'installs a root-owned facts command with one restricted client key' do
    is_expected.to contain_file('/usr/local/bin/homelab-facts').with(
      ensure: 'file',
      owner: 'root',
      group: 'root',
      mode: '0755',
    )
    is_expected.to contain_ssh_authorized_key('homelab-healthreport').with(
      ensure: 'present',
      user: 'root',
      type: 'ssh-ed25519',
      key: 'AAAAC3NzaC1lZDI1NTE5AAAAITestHealthreportKey',
      options: [
        'restrict',
        'from="100.100.10.1"',
        'command="/usr/local/bin/homelab-facts"',
      ],
      target: '/root/.ssh/authorized_keys',
    )
  end

  context 'on Ugreen persistent storage' do
    let(:params) do
      {
        os_family: 'Debian',
        hostname: 'ugreen',
        dest: '/opt/homelab/bin/homelab-facts',
        needs_symlink: true,
        dest_dir: '/opt/homelab/bin',
      }
    end

    it 'writes the canonical script persistently and links the standard path to it' do
      is_expected.to contain_file('/opt/homelab/bin').with(ensure: 'directory', mode: '0755')
      is_expected.to contain_file('/usr/local/bin/homelab-facts').with(
        ensure: 'link',
        target: '/opt/homelab/bin/homelab-facts',
        require: 'File[/opt/homelab/bin/homelab-facts]',
      )
    end
  end
end
