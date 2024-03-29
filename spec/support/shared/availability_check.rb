require "topological_inventory/providers/common/operations/source"

RSpec.shared_examples "availability_check" do
  let(:host_url) { 'https://cloud.redhat.com' }
  let(:sources_api_path) { '/api/sources/v3.0' }
  let(:sources_internal_api_path) { '/internal/v1.0' }
  let(:sources_api_url) { "#{host_url}#{sources_api_path}" }

  let(:external_tenant) { '11001' }
  let(:kafka_client) { TopologicalInventory::Providers::Common::MessagingClient.default.client }
  let(:identity) { {'x-rh-identity' => Base64.strict_encode64({'identity' => {'account_number' => external_tenant, 'user' => {'is_org_admin' => true}}}.to_json)} }
  let(:identity_with_psk) { { "x-rh-sources-account-number" => external_tenant, "x-rh-sources-psk" => '1234' } }
  let(:headers) { ENV['SOURCES_PSK'] ? {'Content-Type' => 'application/json'}.merge(identity_with_psk) : {'Content-Type' => 'application/json'}.merge(identity)  }
  let(:status_available) { described_class::STATUS_AVAILABLE }
  let(:status_unavailable) { described_class::STATUS_UNAVAILABLE }
  let(:error_message) { 'error_message' }
  let(:source_id) { '123' }
  let(:endpoint_id) { '234' }
  let(:application_id) { '345' }
  let(:authentication_id) { '345' }
  let(:payload) do
    {
      'params' => {
        'source_id'       => source_id,
        'external_tenant' => external_tenant,
        'timestamp'       => Time.now.utc
      }
    }
  end

  let(:list_endpoints_response) { "{\"data\":[{\"default\":true,\"host\":\"10.0.0.1\",\"id\":\"#{endpoint_id}\",\"path\":\"/\",\"role\":\"ansible\",\"scheme\":\"https\",\"source_id\":\"#{source_id}\",\"tenant\":\"#{external_tenant}\"}]}" }
  let(:list_endpoint_authentications_response) { "{\"data\":[{\"authtype\":\"username_password\",\"id\":\"#{authentication_id}\",\"resource_id\":\"#{endpoint_id}\",\"resource_type\":\"Endpoint\",\"username\":\"admin\",\"tenant\":\"#{external_tenant}\"}]}" }
  let(:list_endpoint_authentications_response_empty) { "{\"data\":[]}" }
  let(:internal_api_authentication_response) { "{\"authtype\":\"username_password\",\"id\":\"#{authentication_id}\",\"resource_id\":\"#{endpoint_id}\",\"resource_type\":\"Endpoint\",\"username\":\"admin\",\"tenant\":\"#{external_tenant}\",\"password\":\"xxx\"}" }
  let(:list_applications_response) { {:data => [{:id => "345", :availability_status => "available"}]}.to_json }
  let(:list_applications_unavailable_response) { {:data => [{:id => "345", :availability_status => "unavailable"}]}.to_json }

  subject { described_class.new(payload["params"]) }

  def kafka_message(resource_type, resource_id, status, error_message = nil)
    res = {
      :service => described_class::KAFKA_TOPIC_NAME,
      :event   => described_class::EVENT_AVAILABILITY_STATUS,
      :payload => {
        :resource_type => resource_type,
        :resource_id   => resource_id,
        :status        => status
      },
      :headers => {
        "x-rh-identity" => "eyJpZGVudGl0eSI6eyJhY2NvdW50X251bWJlciI6IjExMDAxIiwidXNlciI6eyJpc19vcmdfYWRtaW4iOnRydWV9fX0="
      }
    }
    res[:payload][:error] = error_message if error_message
    res[:payload] = res[:payload].to_json
    res
  end

  before do
    allow(subject).to receive(:messaging_client).and_return(kafka_client)
  end

  context "when not checked recently" do
    before do
      allow(subject).to receive(:checked_recently?).and_return(false)
    end

    context 'kafka' do
      it 'updates Source and Endpoint when available' do
        stub_get(:endpoint, list_endpoints_response)
        stub_get(:application, list_applications_response)

        expect(subject).to receive(:connection_status).and_return([status_available, ''])

        expect(kafka_client).to receive(:publish_topic).with(
          kafka_message("Source", source_id, status_available)
        )

        expect(kafka_client).to receive(:publish_topic).with(
          kafka_message("Endpoint", endpoint_id, status_available, '')
        )

        expect(kafka_client).to receive(:publish_topic).with(
          kafka_message("Application", application_id, status_available)
        )

        subject.availability_check
      end


      it "updates Source and Endpoint when unavailable" do
        stub_get(:endpoint, list_endpoints_response)
        stub_get(:application, list_applications_response)

        expect(subject).to receive(:connection_status).and_return([status_unavailable, error_message])

        expect(kafka_client).to receive(:publish_topic).with(
          kafka_message("Source", source_id, status_unavailable)
        )

        expect(kafka_client).to receive(:publish_topic).with(
          kafka_message("Endpoint", endpoint_id, status_unavailable, error_message)
        )

        expect(kafka_client).to receive(:publish_topic).with(
          kafka_message("Application", application_id, status_unavailable)
        )

        subject.availability_check
      end

      it "updates only Source to 'unavailable' status if Endpoint not found" do
        stub_not_found(:endpoint)
        stub_not_found(:application)

        expect(subject).to receive(:connection_status).and_return([status_unavailable, error_message])

        expect(kafka_client).to receive(:publish_topic).with(
          kafka_message("Source", source_id, status_unavailable)
        )

        expect(subject.logger).to receive(:availability_check).with("Updating source [#{source_id}] status [#{status_unavailable}] message [#{error_message}]")
        expect(subject.logger).to receive(:availability_check).with("Completed: Source #{source_id} is #{status_unavailable}")

        subject.availability_check
      end

      it "updates Source and Endpoint to 'unavailable' if Authentication not found" do
        stub_get(:endpoint, list_endpoints_response)
        stub_not_found(:application)

        expect(subject).to receive(:connection_status).and_return([status_unavailable, error_message])

        expect(kafka_client).to receive(:publish_topic).with(
          kafka_message("Source", source_id, status_unavailable)
        )

        expect(kafka_client).to receive(:publish_topic).with(
          kafka_message("Endpoint", endpoint_id, status_unavailable, error_message)
        )

        expect(subject.logger).to receive(:availability_check).with("Updating source [#{source_id}] status [#{status_unavailable}] message [#{error_message}]")
        expect(subject.logger).to receive(:availability_check).with("Completed: Source #{source_id} is #{status_unavailable}")

        subject.availability_check
      end
    end

    context 'sources_api' do
      before do
        subject.send(:updates_via_kafka=, false)
      end

      it "updates Source and Endpoint when available" do
        # GET
        stub_get(:endpoint, list_endpoints_response)
        stub_get(:authentication, list_endpoint_authentications_response)
        stub_get(:password, internal_api_authentication_response)
        stub_not_found(:application)

        # PATCH
        source_patch_body   = {'availability_status' => described_class::STATUS_AVAILABLE, 'last_available_at' => subject.send(:check_time), 'last_checked_at' => subject.send(:check_time)}.to_json
        endpoint_patch_body = {'availability_status' => described_class::STATUS_AVAILABLE, 'availability_status_error' => '', 'last_available_at' => subject.send(:check_time), 'last_checked_at' => subject.send(:check_time)}.to_json

        stub_patch(:source, source_patch_body)
        stub_patch(:endpoint, endpoint_patch_body)

        # Check ---
        expect(subject).to receive(:connection_check).and_return([described_class::STATUS_AVAILABLE, nil])

        subject.availability_check

        assert_patch(:source, source_patch_body)
        assert_patch(:endpoint, endpoint_patch_body)
      end

      it "updates Source and Endpoint when unavailable" do
        # GET
        stub_get(:endpoint, list_endpoints_response)
        stub_get(:authentication, list_endpoint_authentications_response)
        stub_get(:password, internal_api_authentication_response)
        stub_not_found(:application)

        # PATCH
        connection_error_message = "Some connection error"
        source_patch_body        = {'availability_status' => described_class::STATUS_UNAVAILABLE, 'last_checked_at' => subject.send(:check_time)}.to_json
        endpoint_patch_body      = {'availability_status' => described_class::STATUS_UNAVAILABLE, 'availability_status_error' => connection_error_message, 'last_checked_at' => subject.send(:check_time)}.to_json

        stub_patch(:source, source_patch_body)
        stub_patch(:endpoint, endpoint_patch_body)

        # Check ---
        expect(subject).to receive(:connection_check).and_return([described_class::STATUS_UNAVAILABLE, connection_error_message])

        subject.availability_check

        assert_patch(:source, source_patch_body)
        assert_patch(:endpoint, endpoint_patch_body)
      end

      it "updates only Source to 'unavailable' status if Endpoint not found" do
        # GET
        stub_not_found(:endpoint)
        stub_not_found(:application)

        # PATCH
        source_patch_body = {'availability_status' => described_class::STATUS_UNAVAILABLE, 'last_checked_at' => subject.send(:check_time)}.to_json
        stub_patch(:source, source_patch_body)

        # Check
        api_client = subject.send(:sources_api)
        expect(api_client).not_to receive(:update_endpoint)

        subject.availability_check

        assert_patch(:source, source_patch_body)
      end

      it "updates Source and Endpoint to 'unavailable' if Authentication not found" do
        # GET
        stub_get(:endpoint, list_endpoints_response)
        stub_get(:authentication, list_endpoint_authentications_response_empty)
        stub_not_found(:application)

        # PATCH
        source_patch_body   = {'availability_status' => described_class::STATUS_UNAVAILABLE, 'last_checked_at' => subject.send(:check_time)}.to_json
        endpoint_patch_body = {'availability_status' => described_class::STATUS_UNAVAILABLE, 'availability_status_error' => described_class::ERROR_MESSAGES[:authentication_not_found], 'last_checked_at' => subject.send(:check_time)}.to_json

        stub_patch(:source, source_patch_body)
        stub_patch(:endpoint, endpoint_patch_body)

        # Check
        expect(subject).not_to receive(:connection_check)
        subject.availability_check

        assert_patch(:source, source_patch_body)
        assert_patch(:endpoint, endpoint_patch_body)
      end
    end
  end

  context "when checked recently" do
    before do
      allow(subject).to receive(:checked_recently?).and_return(true)
      subject.send(:updates_via_kafka=, false)
    end

    it "doesn't do connection check" do
      expect(subject).not_to receive(:connection_check)
      expect(WebMock).not_to have_requested(:patch, "#{sources_api_url}/sources/#{source_id}")
      expect(WebMock).not_to have_requested(:patch, "#{sources_api_url}/endpoints/#{endpoint_id}")

      subject.availability_check
    end
  end

  context "when there is an application" do
    context "when it is available" do
      context 'kafka' do
        it "updates the availability status to available" do
          stub_not_found(:endpoint)
          stub_get(:application, list_applications_response)

          expect(subject).to receive(:connection_status).and_return([status_available, ''])

          expect(kafka_client).to receive(:publish_topic).with(
            kafka_message("Source", source_id, status_available)
          )

          expect(kafka_client).to receive(:publish_topic).with(
            kafka_message("Application", application_id, status_available)
          )

          expect(subject.logger).to receive(:availability_check).with("Updating source [#{source_id}] status [#{status_available}] message []")
          expect(subject.logger).to receive(:availability_check).with("Completed: Source #{source_id} is #{status_available}")

          subject.availability_check
        end
      end

      context 'sources_api' do
        before do
          subject.send(:updates_via_kafka=, false)
        end

        it "updates the availability status to available" do
          # GET
          stub_not_found(:endpoint)
          stub_get(:application, list_applications_response)
          # PATCH
          application_patch_body = {'last_available_at' => subject.send(:check_time), 'last_checked_at' => subject.send(:check_time)}.to_json
          source_patch_body = {'availability_status' => described_class::STATUS_AVAILABLE, 'last_available_at' => subject.send(:check_time), 'last_checked_at' => subject.send(:check_time)}.to_json

          stub_patch(:source, source_patch_body)
          stub_patch(:application, application_patch_body)

          # Check
          expect(subject).not_to receive(:connection_check)
          subject.availability_check

          assert_patch(:source, source_patch_body)
          assert_patch(:application, application_patch_body)
        end
      end
    end

    context "when it is unavailable" do
      context 'kafka' do
        it "updates the availability status to unavailable" do
          stub_not_found(:endpoint)
          stub_get(:application, list_applications_unavailable_response)

          expect(subject).to receive(:connection_status).and_return([status_unavailable, error_message])

          expect(kafka_client).to receive(:publish_topic).with(
            kafka_message("Source", source_id, status_unavailable)
          )

          expect(kafka_client).to receive(:publish_topic).with(
            kafka_message("Application", application_id, status_unavailable)
          )

          subject.availability_check
        end
      end

      context 'sources_api' do
        before do
          subject.send(:updates_via_kafka=, false)
        end

        it "updates the availability status to unavailable" do
          # GET
          stub_not_found(:endpoint)
          stub_get(:application, list_applications_unavailable_response)
          # PATCH
          application_patch_body = {'last_checked_at' => subject.send(:check_time)}.to_json
          source_patch_body = {'availability_status' => described_class::STATUS_UNAVAILABLE, 'last_checked_at' => subject.send(:check_time)}.to_json

          stub_patch(:source, source_patch_body)
          stub_patch(:application, application_patch_body)

          # Check
          expect(subject).not_to receive(:connection_check)
          subject.availability_check

          assert_patch(:source, source_patch_body)
          assert_patch(:application, application_patch_body)
        end
      end
    end
  end

  def stub_get(object_type, response)
    case object_type
    when :endpoint
      stub_request(:get, "#{sources_api_url}/sources/#{source_id}/endpoints")
        .with(:headers => headers)
        .to_return(:status => 200, :body => response, :headers => {})
    when :authentication
      stub_request(:get, "#{sources_api_url}/endpoints/#{endpoint_id}/authentications")
        .with(:headers => headers)
        .to_return(:status => 200, :body => response, :headers => {})
    when :password
      stub_request(:get, "#{host_url}#{sources_internal_api_path}/authentications/#{authentication_id}?expose_encrypted_attribute%5B%5D=password")
        .with(:headers => headers)
        .to_return(:status => 200, :body => response, :headers => {})
    when :application
      stub_request(:get, "#{sources_api_url}/sources/#{source_id}/applications")
        .with(:headers => headers)
        .to_return(:status => 200, :body => response, :headers => {})
    end
  end

  def stub_not_found(object_type)
    case object_type
    when :endpoint
      stub_request(:get, "#{sources_api_url}/sources/#{source_id}/endpoints")
        .with(:headers => headers)
        .to_return(:status => 404, :body => {}.to_json, :headers => {})
    when :authentication
      stub_request(:get, "#{sources_api_url}/endpoints/#{endpoint_id}/authentications")
        .with(:headers => headers)
        .to_return(:status => 404, :body => {}.to_json, :headers => {})
    when :password
      stub_request(:get, "#{host_url}#{sources_internal_api_path}/authentications/#{authentication_id}?expose_encrypted_attribute%5B%5D=password")
        .with(:headers => headers)
        .to_return(:status => 404, :body => {}.to_json, :headers => {})
    when :application
      stub_request(:get, "#{sources_api_url}/sources/#{source_id}/applications")
        .with(:headers => headers)
        .to_return(:status => 404, :body => {}.to_json, :headers => {})
    end
  end

  def stub_patch(object_type, data)
    case object_type
    when :source
      stub_request(:patch, "#{sources_api_url}/sources/#{source_id}")
        .with(:body => data, :headers => headers)
        .to_return(:status => 200, :body => "", :headers => {})
    when :endpoint
      stub_request(:patch, "#{sources_api_url}/endpoints/#{endpoint_id}")
        .with(:body => data, :headers => headers)
        .to_return(:status => 200, :body => "", :headers => {})
    when :application
      stub_request(:patch, "#{sources_api_url}/applications/#{application_id}")
        .with(:body => data, :headers => headers)
        .to_return(:status => 200, :body => "", :headers => {})
    end
  end

  def assert_patch(object_type, data)
    case object_type
    when :source
      expect(WebMock).to have_requested(:patch, "#{sources_api_url}/sources/#{source_id}")
        .with(:body => data, :headers => headers).once
    when :endpoint
      expect(WebMock).to have_requested(:patch, "#{sources_api_url}/endpoints/#{endpoint_id}")
        .with(:body => data, :headers => headers).once
    when :application
      expect(WebMock).to have_requested(:patch, "#{sources_api_url}/applications/#{application_id}")
        .with(:body => data, :headers => headers).once
    end
  end
end
