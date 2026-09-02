require 'spec_helper'

describe 'roles::glance' do
  let(:hiera_config) { File.expand_path('../fixtures/hiera.yaml', __dir__) }

  it { is_expected.to compile.with_all_deps }

  it 'renders enabled catalog services and uses a guarded legacy teardown' do
    is_expected.to contain_file('/opt/glance/config/glance.yml').with(
      content: %r{url: https://local\.example\.test},
    )
    is_expected.to contain_exec('glance-legacy-teardown').with(
      command: %r{legacy-teardown-apply\.sh},
      unless: %r{legacy-teardown-check\.sh},
    )
    is_expected.to contain_exec('glance-run').with(
      require: ['File[/opt/glance/config/glance.yml]', 'Exec[glance-legacy-teardown]'],
    )
  end
end
