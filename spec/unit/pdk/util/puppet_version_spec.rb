require 'spec_helper'
require 'pdk/util/puppet_version'

describe PDK::Util::PuppetVersion do
  shared_context 'with a mocked rubygems response' do
    before(:each) do
      mock_fetcher = instance_double(Gem::SpecFetcher)
      allow(Gem::SpecFetcher).to receive(:fetcher).and_return(mock_fetcher)

      mock_response = rubygems_versions.map do |version|
        [Gem::NameTuple.new('puppet', Gem::Version.new(version), Gem::Platform.local), nil]
      end

      allow(mock_fetcher).to receive(:detect).with(:released).and_return(mock_response)
    end
  end

  shared_context 'is not a package install' do
    before(:each) do
      allow(PDK::Util).to receive(:package_install?).and_return(false)
    end
  end

  shared_context 'is a package install' do
    before(:each) do
      allow(PDK::Util).to receive(:package_install?).and_return(true)
      allow(PDK::Util::RubyVersion).to receive(:versions).and_return('2.1.9' => '2.1.0', '2.4.3' => '2.4.0')

      instance219 = PDK::Util::RubyVersion.instance('2.1.9')
      instance243 = PDK::Util::RubyVersion.instance('2.4.3')

      versions219 = cache_versions.select { |r| r.start_with?('4') }.map { |r| Gem::Version.new(r) }
      versions243 = cache_versions.reject { |r| r.start_with?('4') }.map { |r| Gem::Version.new(r) }
      allow(instance219).to receive(:available_puppet_versions).and_return(versions219)
      allow(instance243).to receive(:available_puppet_versions).and_return(versions243)
    end

    after(:each) do
      PDK::Util::RubyVersion.instance_variable_set('@instance', nil)
      PDK::Util::RubyVersion.instance_variable_set('@active_ruby_version', nil)
    end
  end

  let(:rubygems_versions) do
    %w[
      5.4.0
      5.3.5 5.3.4 5.3.3 5.3.2 5.3.1 5.3.0
      5.2.0
      5.1.0
      5.0.1 5.0.0
      4.10.10 4.10.9 4.10.8 4.10.7 4.10.6 4.10.5 4.10.4 4.10.1 4.10.0
      4.9.4 4.9.3 4.9.2 4.9.1 4.9.0
      4.8.2 4.8.1 4.8.0
      4.7.1 4.7.0
      4.6.2 4.6.1 4.6.0
      4.5.3 4.5.2 4.5.1 4.5.0
      4.4.2 4.4.1 4.4.0
      4.3.2 4.3.1 4.3.0
      4.2.3 4.2.2 4.2.1 4.2.0
    ]
  end

  let(:cache_versions) do
    %w[5.4.0 5.3.5 4.10.10 4.8.1 4.9.4 4.7.0 4.5.3 4.4.2]
  end

  describe '.find_gem_for' do
    context 'when running from a package install' do
      include_context 'is a package install'

      it 'raises an ArgumentError if passed a non X.Y.Z version' do
        expect {
          described_class.find_gem_for('5')
        }.to raise_error(ArgumentError, %r{not a valid version number}i)
      end

      it 'returns the specified version if it exists in the cache' do
        expected_result = {
          gem_version:  Gem::Version.new('5.3.5'),
          ruby_version: '2.4.3',
        }
        expect(described_class.find_gem_for('5.3.5')).to eq(expected_result)
      end

      context 'when the specified version does not exist in the cache' do
        it 'notifies the user that it is using the latest Z release instead' do
          expect(logger).to receive(:info).with(a_string_matching(%r{using 5\.3\.5 instead}i))
          described_class.find_gem_for('5.3.1')
        end

        it 'returns the latest Z release' do
          expected_result = {
            gem_version:  Gem::Version.new('5.3.5'),
            ruby_version: '2.4.3',
          }
          expect(described_class.find_gem_for('5.3.1')).to eq(expected_result)
        end

        it 'raises an ArgumentError if no version can be found' do
          expect {
            described_class.find_gem_for('1.0.0')
          }.to raise_error(ArgumentError, %r{unable to find a puppet version}i)
        end
      end
    end

    context 'when not running from a package install' do
      include_context 'is not a package install'
      include_context 'with a mocked rubygems response'

      def result(version)
        {
          gem_version:  Gem::Version.new(version),
          ruby_version: PDK::Util::RubyVersion.default_ruby_version,
        }
      end

      it 'raises an ArgumentError if passed a non X.Y.Z version' do
        expect {
          described_class.find_gem_for('5')
        }.to raise_error(ArgumentError, %r{not a valid version number}i)
      end

      it 'returns the specified version if it exists on Rubygems' do
        expect(described_class.find_gem_for('4.9.0')).to eq(result('4.9.0'))
      end

      context 'when the specified version does not exist on Rubygems' do
        it 'notifies the user that it is using the latest Z release instead' do
          expect(logger).to receive(:info).with(a_string_matching(%r{using 4\.10\.10 instead}i))
          described_class.find_gem_for('4.10.999')
        end

        it 'returns the latest Z release' do
          expect(described_class.find_gem_for('4.10.999')).to eq(result('4.10.10'))
        end

        it 'raises an ArgumentError if no version can be found' do
          expect {
            described_class.find_gem_for('1.0.0')
          }.to raise_error(ArgumentError, %r{unable to find a puppet version}i)
        end
      end
    end
  end

  describe '.from_pe_version' do
    context 'when running from a package install' do
      include_context 'is a package install'

      def result(gem_version, ruby_version)
        {
          gem_version:  Gem::Version.new(gem_version),
          ruby_version: ruby_version,
        }
      end

      it 'raises an ArgumentError if passed a non X.Y.Z version' do
        expect {
          described_class.from_pe_version('5')
        }.to raise_error(ArgumentError, %r{not a valid version number}i)
      end

      it 'returns the latest Puppet Z release for PE 2017.3.x' do
        expect(described_class.from_pe_version('2017.3.1')).to eq(result('5.3.5', '2.4.3'))
      end

      it 'returns the latest Puppet Z release for PE 2017.2.x' do
        expect(described_class.from_pe_version('2017.2.1')).to eq(result('4.10.10', '2.1.9'))
      end

      it 'returns the latest Puppet Z release for PE 2017.1.x' do
        expect(described_class.from_pe_version('2017.1.1')).to eq(result('4.9.4', '2.1.9'))
      end

      it 'returns the latest Puppet Z release for PE 2016.5.x' do
        expect(described_class.from_pe_version('2016.5.1')).to eq(result('4.8.1', '2.1.9'))
      end

      it 'returns the latest Puppet Z release for PE 2016.4.x' do
        expect(described_class.from_pe_version('2016.4.1')).to eq(result('4.7.0', '2.1.9'))
      end

      it 'returns the latest Puppet Z release for PE 2016.2.x' do
        expect(described_class.from_pe_version('2016.2.1')).to eq(result('4.5.3', '2.1.9'))
      end

      it 'returns the latest Puppet Z release for PE 2016.1.x' do
        expect(described_class.from_pe_version('2016.1.1')).to eq(result('4.4.2', '2.1.9'))
      end

      it 'raises an ArgumentError if given an unknown PE version' do
        expect {
          described_class.from_pe_version('9999.1.1')
        }.to raise_error(ArgumentError, %r{unable to map puppet enterprise version}i)
      end
    end

    context 'when not running from a package install' do
      include_context 'is not a package install'
      include_context 'with a mocked rubygems response'

      def result(version)
        {
          gem_version:  Gem::Version.new(version),
          ruby_version: PDK::Util::RubyVersion.default_ruby_version,
        }
      end

      it 'raises an ArgumentError if passed a non X.Y.Z version' do
        expect {
          described_class.from_pe_version('5')
        }.to raise_error(ArgumentError, %r{not a valid version number}i)
      end

      it 'returns the latest Puppet Z release for PE 2017.3.x' do
        expect(described_class.from_pe_version('2017.3.1')).to eq(result('5.3.2'))
      end

      it 'returns the latest Puppet Z release for PE 2017.2.x' do
        expect(described_class.from_pe_version('2017.2.1')).to eq(result('4.10.1'))
      end

      it 'returns the latest Puppet Z release for PE 2017.1.x' do
        expect(described_class.from_pe_version('2017.1.1')).to eq(result('4.9.4'))
      end

      it 'returns the latest Puppet Z release for PE 2016.5.x' do
        expect(described_class.from_pe_version('2016.5.1')).to eq(result('4.8.1'))
      end

      it 'returns the latest Puppet Z release for PE 2016.4.x' do
        expect(described_class.from_pe_version('2016.4.1')).to eq(result('4.7.0'))
      end

      it 'returns the latest Puppet Z release for PE 2016.2.x' do
        expect(described_class.from_pe_version('2016.2.1')).to eq(result('4.5.2'))
      end

      it 'returns the latest Puppet Z release for PE 2016.1.x' do
        expect(described_class.from_pe_version('2016.1.1')).to eq(result('4.4.1'))
      end

      it 'raises an ArgumentError if given an unknown PE version' do
        expect {
          described_class.from_pe_version('9999.1.1')
        }.to raise_error(ArgumentError, %r{unable to map puppet enterprise version}i)
      end
    end
  end

  describe '.from_module_metadata' do
    let(:metadata) { PDK::Module::Metadata.new }

    context 'with default metadata' do
      after(:each) do
        described_class.from_module_metadata(metadata)
      end

      it 'searches for a Puppet gem >= 4.7.0 < 6.0.0' do
        requirement = Gem::Requirement.create(['>= 4.7.0', '< 6.0.0'])
        expect(described_class.instance).to receive(:find_gem).with(requirement)
      end
    end

    context 'with a pinned version requirement' do
      before(:each) do
        metadata.data['requirements'] = [{ 'name' => 'puppet', 'version_requirement' => '4.10.10' }]
      end

      after(:each) do
        described_class.from_module_metadata(metadata)
      end

      it 'searches for a Puppet gem matching the exact version' do
        expect(described_class.instance).to receive(:find_gem).with(Gem::Requirement.create('4.10.10'))
      end
    end

    context 'with an invalid version requirement' do
      before(:each) do
        metadata.data['requirements'] = [{ 'name' => 'puppet', 'version_requirement' => '' }]
      end

      it 'raises an ArgumentError' do
        expect {
          described_class.from_module_metadata(metadata)
        }.to raise_error(ArgumentError)
      end
    end
  end
end
