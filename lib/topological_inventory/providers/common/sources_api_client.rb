require "sources-api-client"

module TopologicalInventory
  module Providers
    module Common
      class SourcesApiClient < ::SourcesApiClient::ApiClient
        delegate :update_source, :update_endpoint, :update_application, :to => :api

        INTERNAL_API_PATH = '//internal/v1.0'.freeze

        def initialize(identity = nil)
          super(::SourcesApiClient::Configuration.default)
          self.identity = identity
          self.api      = init_default_api
        end

        def init_default_api
          # TODO: remove this once PSK is set up everywhere.
          if identity.present?
            if psk
              parsed_identity = JSON.parse(Base64.decode64(identity.fetch('x-rh-identity')))

              default_headers.merge!(
                "x-rh-sources-psk"            => psk,
                "x-rh-sources-account-number" => parsed_identity['identity']['account_number']
              )
            else
              default_headers.merge!(identity)
            end
          end

          ::SourcesApiClient::DefaultApi.new(self)
        end

        def psk
          @psk ||= ENV.fetch("SOURCES_PSK", nil)
        end

        def fetch_default_endpoint(source_id)
          endpoints = api.list_source_endpoints(source_id)&.data || []
          endpoints.find(&:default)
        end

        def fetch_application(source_id)
          applications = api.list_source_applications(source_id)&.data || []
          applications.first
        end

        def fetch_authentication(source_id, default_endpoint = nil, authtype = nil)
          endpoint = default_endpoint || fetch_default_endpoint(source_id)
          return if endpoint.nil?

          endpoint_authentications = api.list_endpoint_authentications(endpoint.id.to_s).data || []
          return if endpoint_authentications.empty?

          auth_id = if authtype.nil?
                      endpoint_authentications.first&.id
                    else
                      endpoint_authentications.detect { |a| a.authtype = authtype }&.id
                    end
          return if auth_id.nil?

          fetch_authentication_with_password(auth_id)
        end

        private

        attr_accessor :identity, :api, :custom_base_path

        def fetch_authentication_with_password(auth_id)
          on_internal_api do
            local_var_path = "/authentications/#{auth_id}"

            query_params = "expose_encrypted_attribute[]=password"

            header_params = {'Accept' => select_header_accept(['application/json'])}
            return_type   = 'Authentication'
            data, _, _    = call_api(:GET, local_var_path,
                                     :header_params => header_params,
                                     :query_params  => query_params,
                                     :auth_names    => ['UserSecurity'],
                                     :return_type   => return_type)
            data
          end
        end

        def build_request_url(path)
          # Add leading and trailing slashes to path
          path = "/#{path}".gsub(/\/+/, '/')
          URI.encode((custom_base_url || @config.base_url) + path)
        end

        def custom_base_url
          return nil if custom_base_path.nil?

          url = "#{@config.scheme}://#{[@config.host, custom_base_path].join('/').gsub(/\/+/, '/')}".sub(/\/+\z/, '')
          URI.encode(url)
        end

        def on_internal_api
          self.custom_base_path = INTERNAL_API_PATH
          yield
        ensure
          self.custom_base_path = nil
        end
      end
    end
  end
end
