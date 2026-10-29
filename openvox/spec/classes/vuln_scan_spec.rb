require 'spec_helper'

describe 'roles::vuln_scan' do
  let(:hiera_config) { File.expand_path('../fixtures/vuln_scan_hiera.yaml', __dir__) }
  let(:params) { { dojo_url: 'http://100.100.10.1:8101' } }

  it { is_expected.to compile.with_all_deps }

  it 'does not enrich findings unless asked to (only the DefectDojo host should)' do
    is_expected.not_to contain_file('/etc/systemd/system/dd-enrich.timer')
    is_expected.not_to contain_service('dd-enrich.timer')
  end

  context 'on the DefectDojo host' do
    let(:params) { super().merge(enrich_enabled: true) }

    it 'runs the EPSS/KEV enrichment daily after the night scans' do
      service = catalogue.resource('file', '/etc/systemd/system/dd-enrich.service')
      timer = catalogue.resource('file', '/etc/systemd/system/dd-enrich.timer')

      expect(service[:content]).to include(
        'Environment=DOJO_URL=http://100.100.10.1:8101',
        'ExecStart=/usr/bin/bash /usr/local/libexec/vuln-scan/dd-enrich.sh',
        'Type=oneshot',
      )
      expect(timer[:content]).to include('OnCalendar=*-*-* 05:55:00', 'Persistent=true')
      is_expected.to contain_service('dd-enrich.timer').with(ensure: 'running', enable: true)
    end

    it 'reloads systemd when the enrichment units change' do
      reload = catalogue.resource('exec', 'trivy-scan-daemon-reload')
      expect(reload[:subscribe].map(&:to_s)).to include(
        'File[/etc/systemd/system/dd-enrich.service]',
        'File[/etc/systemd/system/dd-enrich.timer]',
      )
    end
  end
end
