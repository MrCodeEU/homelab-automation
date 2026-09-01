require 'spec_helper'

describe 'roles::canary_decoys' do
  context 'on mljr' do
    let(:params) { { hostname: 'mljr' } }

    it { is_expected.to compile.with_all_deps }

    it 'places the root-only recovery-code decoy' do
      is_expected.to contain_file('/root/authelia-recovery-codes.docx').with(mode: '0600')
      is_expected.to contain_file('/root/network-diagram.svg').with(mode: '0644')
    end
  end

  context 'on ugreen' do
    let(:params) { { hostname: 'ugreen' } }

    it 'places the backup-share decoy with restrictive permissions' do
      is_expected.to contain_file('/volume1/homelab-backups/nas-admin-recovery.xlsx').with(mode: '0600')
    end
  end
end

describe 'roles::canary_decoys_nas' do
  it { is_expected.to compile.with_all_deps }

  it 'uses a read-only check before proxying decoy placement to Unraid' do
    is_expected.to contain_exec('canary-decoys-nas-place').with(
      command: %r{decoy-apply\.sh},
      unless: %r{decoy-check\.sh},
      require: 'File[/usr/local/libexec/openvox-canary-decoys-nas]',
    )
  end
end
