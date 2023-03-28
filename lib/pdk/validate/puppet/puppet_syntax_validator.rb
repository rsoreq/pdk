require 'pdk'

module PDK
  module Validate
    module Puppet
      class PuppetSyntaxValidator < ExternalCommandValidator
        # In Puppet >= 5.3.4, the error context formatting was changed to facilitate localization
        ERROR_CONTEXT = /(?:file:\s(?<file>.+?)|line:\s(?<line>.+?)|column:\s(?<column>.+?))/.freeze
        # In Puppet < 5.3.3, the error context was formatted in these variations:
        #   - "at file_path:line_num:col_num"
        #   - "at file_path:line_num"
        #   - "at line line_num"
        #   - "in file_path"
        ERROR_CONTEXT_LEGACY = /(?:at\sline\s(?<line>\d+)|at\s(?<file>.+?):(?<line>\d+):(?<column>\d+)|at\s(?<file>.+?):(?<line>\d+)|in\s(?<file>.+?))/.freeze

        PUPPET_LOGGER_PREFIX = /^(debug|info|notice|warning|error|alert|critical):\s.+?$/i.freeze
        PUPPET_SYNTAX_PATTERN = /^
          (?<severity>.+?):\s
          (?<message>.+?)
          (?:
            \s\(#{ERROR_CONTEXT}(,\s#{ERROR_CONTEXT})*\)| # attempt to match the new localisation friendly location
            \s#{ERROR_CONTEXT_LEGACY}| # attempt to match the old " at file:line:column" location
            $                                               # handle cases where the output has no location
          )
        $/x.freeze

        def name
          'puppet-syntax'
        end

        def cmd
          'puppet'
        end

        def pattern
          contextual_pattern('**/*.pp')
        end

        def pattern_ignore
          contextual_pattern('plans/**/*.pp')
        end

        def spinner_text_for_targets(_targets)
          format('Checking Puppet manifest syntax (%{pattern}).', pattern: pattern.join(' '))
        end

        def parse_options(targets)
          # Due to PDK-1266 we need to run `puppet parser validate` with an empty
          # modulepath. On *nix, Ruby treats `/dev/null` as an empty directory
          # however it doesn't do so with `NUL` on Windows. The workaround for
          # this to ensure consistent behaviour is to create an empty temporary
          # directory and use that as the modulepath.
          ['parser', 'validate', '--config', null_file, '--modulepath', validate_tmpdir].concat(targets)
        end

        def invoke(report)
          super
        ensure
          remove_validate_tmpdir
        end

        def validate_tmpdir
          require 'tmpdir'

          @validate_tmpdir ||= Dir.mktmpdir('puppet-parser-validate')
        end

        def remove_validate_tmpdir
          return unless @validate_tmpdir
          return unless PDK::Util::Filesystem.directory?(@validate_tmpdir)

          PDK::Util::Filesystem.remove_entry_secure(@validate_tmpdir)
          @validate_tmpdir = nil
        end

        def null_file
          Gem.win_platform? ? 'NUL' : '/dev/null'
        end

        def parse_output(report, result, targets)
          # Due to PUP-7504, we will have to programmatically construct the json
          # object from the text output for now.
          output = result[:stderr].split(/\r?\n/).reject(&:empty?)

          results_data = []
          output.each do |offense|
            offense_data = parse_offense(offense)
            results_data << offense_data
          end

          # puppet parser validate does not include files without problems in its
          # output, so we need to go through the list of targets and add passing
          # events to the report for any target not listed in the output.
          targets.reject { |target| results_data.any? { |j| j[:file] =~ /#{target}/ } }.each do |target|
            report.add_event(
              file: target,
              source: name,
              severity: :ok,
              state: :passed
            )
          end

          results_data.each do |offense|
            report.add_event(offense)
          end
        end

        def parse_offense(offense)
          sanitize_console_output(offense)

          offense_data = {
            source: name,
            state: :failure
          }

          if offense.match(PUPPET_LOGGER_PREFIX)
            attributes = offense.match(PUPPET_SYNTAX_PATTERN)

            attributes&.names&.each do |name|
              offense_data[name.to_sym] = attributes[name] unless attributes[name].nil?
            end
          else
            offense_data[:message] = offense
          end

          offense_data
        end

        def sanitize_console_output(line)
          line.gsub!(/\e\[([;\d]+)?m/, '')
        end
      end
    end
  end
end
