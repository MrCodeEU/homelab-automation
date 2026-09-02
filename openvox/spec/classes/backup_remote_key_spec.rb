require 'spec_helper'

describe 'roles::backup_remote_key' do
  it { is_expected.to compile.with_all_deps }

  it 'creates a non-overwriting, owner-only backup transport key' do
    is_expected.to contain_file('/opt/backup-remote/ssh').with(
      ensure: 'directory', owner: 'root', group: 'root', mode: '0700',
    )
    is_expected.to contain_exec('backup-remote-key-generate').with(
      creates: '/opt/backup-remote/ssh/id_ed25519',
      require: 'File[/opt/backup-remote/ssh]',
    )
    ['/opt/backup-remote/ssh/id_ed25519', '/opt/backup-remote/ssh/id_ed25519.pub'].each do |path|
      is_expected.to contain_file(path).with(mode: '0600', require: 'Exec[backup-remote-key-generate]')
    end
  end
end
