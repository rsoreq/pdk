require 'spec_helper'
require 'pdk/module/release'
require 'puppet/modulebuilder'
require 'puppet_forge'

describe PDK::Module::Release do
  let(:module_path) { nil }
  let(:options) { {} }
  let(:instance) { described_class.new(module_path, options) }
  let(:module_root) { '/path/somewhere' }
  let(:metadata_hash) do
    {
      'name' => 'mock-module',
      'version' => '1.0.0',
      'pdk-version' => 'mock'
    }
  end
  let(:mock_metadata_object) do
    instance_double(
      PDK::Module::Metadata,
      data: metadata_hash,
      forge_ready?: true,
      write!: nil
    )
  end

  before do
    # Mimic PDK being run in the root of a module in current working directory
    allow(PDK::Util).to receive_messages(find_upwards: nil, in_module_root?: true)
    allow(Dir).to receive(:pwd).and_return(module_root)
    allow(PDK::Util::ChangelogGenerator).to receive(:changelog_content).and_return('This is a changelog')
    allow(PDK::Module::Metadata).to receive(:from_file).and_return(mock_metadata_object)
  end

  describe '#initialize' do
    context 'when passed a module path' do
      let(:module_path) { 'a/path' }

      it 'raises an error' do
        expect { instance }.to raise_error(PDK::CLI::ExitWithError)
      end
    end

    context 'when passed a nil module path' do
      it 'uses the module root from the current working directory' do
        expect(instance.module_path).to eq(module_root)
      end
    end
  end

  describe '#run' do
    let(:builder) { double(Puppet::Modulebuilder::Builder, package_file: 'package.tar.gz') } # rubocop:disable RSpec/VerifiedDoubles

    before do
      logger = Logger.new(File.open(File::NULL, 'w')) # rubocop:disable PDK/FileOpen
      allow(PDK).to receive(:logger).and_return(logger)
      allow(Puppet::Modulebuilder::Builder).to receive(:new).and_return(builder)
      # Stop any of the actual worker methods from running
      allow(instance).to receive(:run_validations)
      allow(instance).to receive(:run_documentation)
      allow(instance).to receive(:run_dependency_checker)
      allow(instance).to receive(:run_build)
      allow(instance).to receive(:run_publish)
      allow(PDK::Util::ChangelogGenerator).to receive(:generate_changelog)
      allow(builder).to receive_messages(file_directory?: true, file_readable?: true)
      allow(builder).to receive(:source)
      allow(builder).to receive(:metadata) do |instance|
        instance.instance_variable_set(:@metadata, metadata_hash)
      end
    end

    context 'when skipping everything' do
      let(:options) do
        {
          'skip-validation': true,
          'skip-changelog': true,
          'skip-documentation': true,
          'skip-dependency': true,
          'skip-build': true,
          'skip-publish': true
        }
      end

      it 'does not do anything' do
        expect(instance).not_to receive(:run_validations)
        expect(instance).not_to receive(:run_documentation)
        expect(instance).not_to receive(:run_dependency_checker)
        expect(instance).not_to receive(:run_build)
        expect(instance).not_to receive(:run_publish)
        expect(PDK::Util::ChangelogGenerator).not_to receive(:generate_changelog)

        instance.run
      end
    end

    context 'when skipping nothing and forcing the release' do
      let(:options) do
        {
          force: true,
          'forge-upload-url': 'https://localhost/api',
          'forge-token': '12345'
        }
      end

      it 'calls all release helpers' do
        expect(instance).to receive(:run_validations).once
        expect(instance).to receive(:run_documentation).once
        expect(instance).to receive(:run_dependency_checker).once
        expect(instance).to receive(:run_build).once
        expect(instance).to receive(:run_publish).once
        expect(PDK::Util::ChangelogGenerator).to receive(:generate_changelog).once

        instance.run
      end
    end

    context 'when not forcing the release' do
      let(:options) { { force: false } }

      context 'and the module is not PDK compatible' do
        before do
          allow(instance).to receive(:pdk_compatible?).and_return(false)
        end

        it 'raises an error' do
          expect { instance.run }.to raise_error(PDK::CLI::ExitWithError, /PDK compatible/)
        end
      end

      context 'and the module is not Forge compatible' do
        before do
          allow(instance).to receive(:forge_compatible?).and_return(false)
        end

        it 'raises an error' do
          expect { instance.run }.to raise_error(PDK::CLI::ExitWithError, /Forge compatible/)
        end
      end

      context 'and missing the forge url' do
        it 'raises an error' do
          expect { instance.run }.to raise_error(PDK::CLI::ExitWithError, /forge-upload-url/)
        end
      end

      context 'and missing the forge token' do
        before do
          allow(instance).to receive(:forge_upload_url).and_return('https://localhost')
        end

        it 'raises an error' do
          expect { instance.run }.to raise_error(PDK::CLI::ExitWithError, /forge-token/)
        end
      end
    end

    context 'when detecting the version number' do
      let(:new_version) { '2.0.0' }
      let(:options) { { 'skip-publish': true } }

      it 'returns a new version from Changelog Generator' do
        expect(PDK::Util::ChangelogGenerator).to receive(:latest_version).and_return('2.0.0')
        expect(PDK::Util::ChangelogGenerator).to receive(:compute_next_version).with('1.0.0').and_return(new_version)
        expect(mock_metadata_object).to receive(:write!)

        instance.run

        expect(instance.module_metadata.data['version']).to eq(new_version)
      end

      it 'does not save the version if it has not changed' do
        expect(PDK::Util::ChangelogGenerator).to receive(:compute_next_version).with('1.0.0').and_return('1.0.0')
        expect(mock_metadata_object).not_to receive(:write!)

        instance.run

        expect(instance.module_metadata.data['version']).to eq('1.0.0')
      end
    end

    context 'when skipping the build' do
      before do
        allow(instance).to receive_messages(skip_build?: true, forge_upload_url: 'https://localhost', forge_token: 'abc123')
      end

      it 'uses the default package filename when a file is not specified to publish' do
        expect(instance).to receive(:default_package_filename).and_return('default_path')
        expect(instance).to receive(:run_publish).with(Hash, 'default_path')
        instance.run
      end

      it 'uses the file is when specified to publish' do
        expect(instance).to receive(:specified_package).and_return('specific_path')
        expect(instance).to receive(:run_publish).with(Hash, 'specific_path')
        instance.run
      end
    end

    context 'when running the build helper' do
      before do
        allow(instance).to receive_messages(skip_build?: false, forge_upload_url: 'https://localhost', forge_token: 'abc123')
      end

      it 'uses the built tarball to publish' do
        expect(instance).to receive(:run_build).and_return('build_path')
        expect(instance).to receive(:run_publish).with(Hash, 'build_path')
        instance.run
      end
    end
  end

  describe '#module_metadata' do
    it 'returns a PDK::Module::Metadata object' do
      expect(instance.module_metadata).to be(mock_metadata_object)
    end
  end

  describe '#write_module_metadata!' do
    before do
      expect(mock_metadata_object).to receive(:write!).and_return(nil)
    end

    it 'writes the metadata' do
      instance.write_module_metadata!
    end

    it 'clears the cache' do
      expect(instance).to receive(:clear_cached_data)
      instance.write_module_metadata!
    end
  end

  describe '#default_package_filename' do
    let(:builder) { double(Puppet::Modulebuilder::Builder, package_file: 'package.tar.gz') } # rubocop:disable RSpec/VerifiedDoubles

    it 'calls Puppet::Modulebuilder::Builder' do
      expect(Puppet::Modulebuilder::Builder).to receive(:new).with(module_root, nil, logger).and_return(builder)
      expect(instance.default_package_filename).to eq('package.tar.gz')
    end
  end

  describe '#run_validations' do
    # Note that this test setup is quite fragile and indicates that the method
    # under test really needs to be refactored

    before do
      allow(PDK::CLI::Util).to receive_messages(validate_puppet_version_opts: nil, module_version_check: nil, puppet_from_opts_or_env: { gemset: {}, ruby_version: '1.2.3' })
      allow(PDK::Util::PuppetVersion).to receive(:fetch_puppet_dev).and_return(nil)
      allow(PDK::Util::RubyVersion).to receive(:use).and_return(nil)
      allow(PDK::Util::Bundler).to receive(:ensure_bundle!).and_return(nil)
    end

    it 'calls the validators' do
      expect(PDK::Validate).to receive(:invoke_validators_by_name).and_return(0)
      instance.run_validations({})
    end

    it 'raises when the validator returns a non-zero exit code' do
      expect(PDK::Validate).to receive(:invoke_validators_by_name).and_return(1)
      expect { instance.run_validations({}) }.to raise_error(PDK::CLI::ExitWithError)
    end
  end

  describe '#run_documentation' do
    let(:command) { double(PDK::CLI::Exec::InteractiveCommand, :context= => nil) } # rubocop:disable RSpec/VerifiedDoubles
    let(:command_stdout) { 'Success' }
    let(:command_exit_code) { 0 }

    before do
      expect(PDK::CLI::Exec::InteractiveCommand).to receive(:new).and_return(command)
      expect(command).to receive(:execute!).and_return(stdout: command_stdout, exit_code: command_exit_code)
    end

    it 'executes a command in the context of the module' do
      expect(command).to receive(:context=).with(:module)
      instance.run_documentation(options)
    end

    context 'when the command returns a non-zero exit code' do
      let(:command_stdout) { 'Fail' }
      let(:command_exit_code) { 1 }

      it 'raises' do
        expect { instance.run_documentation(options) }.to raise_error(PDK::CLI::ExitWithError)
      end
    end
  end

  describe '#run_dependency_checker' do
    let(:command) { double(PDK::CLI::Exec::Command, :context= => nil) } # rubocop:disable RSpec/VerifiedDoubles
    let(:command_stdout) { 'Success' }
    let(:command_exit_code) { 0 }

    before do
      expect(PDK::CLI::Exec::Command).to receive(:new).with('dependency-checker', 'metadata.json').and_return(command)
      expect(command).to receive(:execute!).and_return(stdout: command_stdout, exit_code: command_exit_code)
    end

    it 'executes a command in the context of the module' do
      expect(command).to receive(:context=).with(:module)
      instance.run_dependency_checker(options)
    end

    context 'when the command returns a non-zero exit code' do
      let(:command_stdout) { 'Fail' }
      let(:command_exit_code) { 1 }

      it 'raises' do
        expect { instance.run_dependency_checker(options) }.to raise_error(PDK::CLI::ExitWithError)
      end
    end
  end

  describe '#run_build' do
    let(:builder) { double(Puppet::Modulebuilder::Builder) } # rubocop:disable RSpec/VerifiedDoubles

    before do
      logger = Logger.new(File.open(File::NULL, 'w')) # rubocop:disable PDK/FileOpen
      allow(PDK).to receive(:logger).and_return(logger)
      allow(Puppet::Modulebuilder::Builder).to receive(:new).and_return(builder)
    end

    it 'calls Puppet::Modulebuilder::Builder.build' do
      expect(builder).to receive(:build)
      instance.run_build
    end
  end

  describe '#run_publish' do
    let(:tarball_path) { '/does/not/exist' }
    let(:http_response) { Net::HTTPSuccess.new(nil, nil, nil) }
    # Note that this test setup is quite fragile and indicates that the method
    # under test really needs to be refactored

    before do
      allow(instance).to receive_messages(forge_token: 'abc123', forge_upload_url: 'https://badapi.puppetlabs.com/v3/releases')
      allow(PDK::Util::Filesystem).to receive(:file?).with(tarball_path).and_return(true)
      allow(PDK::Util::Filesystem).to receive(:read_file).with(tarball_path, Hash).and_return('tarball_contents')
    end

    it 'uploads the tarball to the Forge' do
      expect(PuppetForge::V3::Release).to receive(:upload).with(tarball_path).and_return(http_response)
      instance.run_publish({}, tarball_path)
    end

    context 'when the tarball does not exist' do
      before do
        expect(PDK::Util::Filesystem).to receive(:file?).with(tarball_path).and_return(false)
      end

      it 'raises' do
        expect { instance.run_publish({}, tarball_path) }.to raise_error(PDK::CLI::ExitWithError)
      end
    end

    context 'when the Forge returns an error' do
      it 'raises' do
        expect(PuppetForge::V3::Release).to receive(:upload).with(tarball_path).and_raise(PuppetForge::ReleaseForbidden)
        expect { instance.run_publish({}, tarball_path) }.to raise_error(PDK::CLI::ExitWithError, /Error uploading to Puppet Forge/)
      end
    end
  end

  describe '#validate_publish_options!' do
    before do
      allow(instance).to receive(:skip_publish?).and_return(false)
    end

    it 'raises when missing the forge upload url' do
      allow(instance).to receive_messages(forge_upload_url: nil, forge_token: 'abc123')
      expect { instance.validate_publish_options! }.to raise_error(PDK::CLI::ExitWithError)
    end

    it 'raises when missing the forge token' do
      allow(instance).to receive_messages(forge_upload_url: 'https://localhost', forge_token: nil)
      expect { instance.validate_publish_options! }.to raise_error(PDK::CLI::ExitWithError)
    end

    it 'does not raise when publishing is skipped' do
      allow(instance).to receive_messages(skip_publish?: true, forge_upload_url: nil, forge_token: nil)
      expect { instance.validate_publish_options! }.not_to raise_error
    end
  end

  [
    { method: 'force?',              option_name: :force },
    { method: 'skip_build?',         option_name: :'skip-build' },
    { method: 'skip_changelog?',     option_name: :'skip-changelog' },
    { method: 'skip_dependency?',    option_name: :'skip-dependency' },
    { method: 'skip_documentation?', option_name: :'skip-documentation' },
    { method: 'skip_publish?',       option_name: :'skip-publish' },
    { method: 'skip_validation?',    option_name: :'skip-validation' },
    { method: 'specified_version',   option_name: :version },
    { method: 'specified_package',   option_name: :file },
    { method: 'forge_token',         option_name: :'forge-token' },
    { method: 'forge_upload_url',    option_name: :'forge-upload-url' }
  ].each do |testcase|
    describe "##{testcase[:method]}" do
      context "when the #{testcase[:option_name]} options is set" do
        let(:options) { { testcase[:option_name] => 'a_value' } }

        it 'returns the set value' do
          expect(instance.send(testcase[:method])).to eq('a_value')
        end
      end

      context "when the #{testcase[:option_name]} options is not set" do
        let(:options) { {} }

        it 'returns nil' do
          expect(instance.send(testcase[:method])).to be_nil
        end
      end
    end
  end

  describe '#forge_compatible?' do
    # This is a convenience method and is tested elsewhere
    it 'responds to' do
      expect(instance).to respond_to(:forge_compatible?)
    end
  end

  describe '#pdk_compatible?' do
    # This is a convenience method and is tested elsewhere
    it 'responds to' do
      expect(instance).to respond_to(:pdk_compatible?)
    end
  end
end
