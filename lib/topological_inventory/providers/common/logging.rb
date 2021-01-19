require "manageiq/loggers"

module TopologicalInventory
  module Providers
    module Common
      module LoggingFunctions
        def collecting(status, source, entity_type, refresh_state_uuid, total_parts = nil)
          msg = "[#{status.to_s.upcase}] Collecting #{entity_type}"
          msg += ", :total parts => #{total_parts}" if total_parts.present?
          msg += ", :source_uid => #{source}, :refresh_state_uuid => #{refresh_state_uuid}"
          info(msg)
        end

        def collecting_error(source, entity_type, refresh_state_uuid, exception)
          msg = "[ERROR] Collecting #{entity_type}, :source_uid => #{source}, :refresh_state_uuid => #{refresh_state_uuid}"
          msg += ":message => #{exception.message}\n#{exception.backtrace.join("\n")}"
          error(msg)
        end

        def sweeping(status, source, sweep_scope, refresh_state_uuid)
          msg = "[#{status.to_s.upcase}] Sweeping inactive records, :sweep_scope => #{sweep_scope}, :source_uid => #{source}, :refresh_state_uuid => #{refresh_state_uuid}"
          info(msg)
        end

        def availability_check(message, severity = :info)
          send("#{severity}_ext", "Source#availability_check", message)
        end

        %w[debug info warn error fatal].each do |severity|
          define_method("#{severity}_ext".to_sym) do |prefix, message|
            ext_message = [prefix, message].compact.join(' - ')
            send(severity, ext_message)
          end
        end

        def level=(severity)
          if severity.is_a?(Integer)
            @level = severity
          else
            case severity.to_s.downcase
            when 'debug'
              @level = self.class::DEBUG
            when 'info'
              @level = self.class::INFO
            when 'warn'
              @level = self.class::WARN
            when 'error'
              @level = self.class::ERROR
            when 'fatal'
              @level = self.class::FATAL
            when 'unknown'
              @level = self.class::UNKNOWN
            else
              raise ArgumentError, "invalid log level: #{severity}"
            end
          end
        end
      end

      class Logger < ManageIQ::Loggers::CloudWatch
        def self.new(*args)
          super.tap do |logger|
            logger.extend(TopologicalInventory::Providers::Common::LoggingFunctions)
            logger.level = ENV['LOG_LEVEL'] if ENV['LOG_LEVEL']
          end
        end
      end

      class << self
        attr_writer :logger
      end

      def self.logger
        @logger ||= TopologicalInventory::Providers::Common::Logger.new
      end

      module Logging
        def logger
          TopologicalInventory::Providers::Common.logger
        end
      end
    end
  end
end
