# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseSms::ApiClient do
  fab!(:user)

  let(:send_url) { "https://sms.example.com/send" }
  let(:verify_url) { "https://sms.example.com/verify" }
  let(:phone) { "+8613800138000" }

  before do
    SiteSetting.sms_send_api_url = send_url
    SiteSetting.sms_verify_api_url = verify_url
    SiteSetting.sms_auth_token = "token"
    SiteSetting.sms_auth_header = "Authorization"
    SiteSetting.sms_auth_scheme = "Bearer"
    SiteSetting.sms_request_format = "json"
    SiteSetting.sms_request_timeout_seconds = 5
    SiteSetting.sms_phone_param = "phone"
    SiteSetting.sms_code_param = "code"
    SiteSetting.sms_user_id_param = "user_id"
    SiteSetting.sms_email_param = "email"
    SiteSetting.sms_purpose = "bind_phone"
    SiteSetting.sms_extra_params = ""
    SiteSetting.sms_send_success_json_path = ""
    SiteSetting.sms_send_success_value = ""
    SiteSetting.sms_verify_success_json_path = ""
    SiteSetting.sms_verify_success_value = ""
    SiteSetting.sms_error_message_json_path = "message"
  end

  describe "#send_code" do
    it "posts a JSON payload with the configured bearer token" do
      stub_request(:post, send_url).to_return(status: 200, body: '{"ok":true}')

      expect(described_class.new.send_code(phone: phone)).to eq(true)

      expect(
        a_request(:post, send_url).with do |request|
          JSON.parse(request.body) == { "phone" => phone, "purpose" => "bind_phone" } &&
            request.headers["Authorization"] == "Bearer token" &&
            request.headers["Content-Type"] == "application/json"
        end,
      ).to have_been_made.once
    end

    it "includes the member ID and email in the send payload" do
      stub_request(:post, send_url).to_return(status: 200, body: "")

      described_class.new.send_code(phone: phone, user: user)

      expect(
        a_request(:post, send_url).with do |request|
          body = JSON.parse(request.body)
          body["user_id"] == user.id && body["email"] == user.email
        end,
      ).to have_been_made.once
    end

    it "supports custom member field names" do
      SiteSetting.sms_user_id_param = "uid"
      SiteSetting.sms_email_param = "mail"
      stub_request(:post, send_url).to_return(status: 200, body: "")

      described_class.new.send_code(phone: phone, user: user)

      expect(
        a_request(:post, send_url).with do |request|
          body = JSON.parse(request.body)
          body["uid"] == user.id && body["mail"] == user.email && !body.key?("user_id") &&
            !body.key?("email")
        end,
      ).to have_been_made.once
    end

    it "can send form encoded requests" do
      SiteSetting.sms_request_format = "form"
      stub_request(:post, send_url).to_return(status: 200, body: "")

      described_class.new.send_code(phone: phone)

      expect(
        a_request(:post, send_url).with do |request|
          request.headers["Content-Type"] == "application/x-www-form-urlencoded" &&
            Rack::Utils.parse_nested_query(request.body) ==
              { "phone" => phone, "purpose" => "bind_phone" }
        end,
      ).to have_been_made.once
    end

    it "merges extra params into the payload" do
      SiteSetting.sms_extra_params = '{"appId":"abc"}'
      stub_request(:post, send_url).to_return(status: 200, body: "")

      described_class.new.send_code(phone: phone)

      expect(
        a_request(:post, send_url).with { |request| JSON.parse(request.body)["appId"] == "abc" },
      ).to have_been_made.once
    end

    it "supports custom success paths" do
      SiteSetting.sms_send_success_json_path = "code"
      SiteSetting.sms_send_success_value = "0"
      stub_request(:post, send_url).to_return(status: 200, body: '{"code":0}')

      expect(described_class.new.send_code(phone: phone)).to eq(true)
    end

    it "raises when the success path does not match" do
      SiteSetting.sms_send_success_json_path = "code"
      SiteSetting.sms_send_success_value = "0"
      stub_request(:post, send_url).to_return(status: 200, body: '{"code":1}')

      expect { described_class.new.send_code(phone: phone) }.to raise_error(
        DiscourseSms::ApiClient::RejectedError,
      )
    end

    it "raises a rejected error with the provider message" do
      SiteSetting.sms_error_message_json_path = "error.message"
      stub_request(:post, send_url).to_return(
        status: 400,
        body: '{"error":{"message":"bad phone"}}',
      )

      expect { described_class.new.send_code(phone: phone) }.to raise_error(
        DiscourseSms::ApiClient::RejectedError,
        "bad phone",
      )
    end

    it "raises an unavailable error for server errors" do
      stub_request(:post, send_url).to_return(status: 500, body: "")

      expect { described_class.new.send_code(phone: phone) }.to raise_error(
        DiscourseSms::ApiClient::UnavailableError,
      )
    end

    it "requires both API URLs to be configured" do
      SiteSetting.sms_verify_api_url = ""

      expect { described_class.new.send_code(phone: phone) }.to raise_error(
        DiscourseSms::ApiClient::ConfigurationError,
      )
    end

    it "does not send an authorization header when the token is blank" do
      SiteSetting.sms_auth_token = ""
      stub_request(:post, send_url).to_return(status: 200, body: "")

      described_class.new.send_code(phone: phone)

      expect(
        a_request(:post, send_url).with { |request| request.headers["Authorization"].nil? },
      ).to have_been_made.once
    end
  end

  describe "#verify_code" do
    it "returns true for a successful response" do
      stub_request(:post, verify_url).to_return(status: 200, body: '{"success":true}')

      expect(described_class.new.verify_code(phone: phone, code: "123456")).to eq(true)
    end

    it "supports custom verification success paths" do
      SiteSetting.sms_verify_success_json_path = "data.valid"
      SiteSetting.sms_verify_success_value = "true"
      stub_request(:post, verify_url).to_return(status: 200, body: '{"data":{"valid":true}}')

      expect(described_class.new.verify_code(phone: phone, code: "123456")).to eq(true)
    end

    it "returns false when the success path is false" do
      SiteSetting.sms_verify_success_json_path = "data.valid"
      SiteSetting.sms_verify_success_value = "true"
      stub_request(:post, verify_url).to_return(status: 200, body: '{"data":{"valid":false}}')

      expect(described_class.new.verify_code(phone: phone, code: "123456")).to eq(false)
    end

    it "returns false for an invalid code response" do
      stub_request(:post, verify_url).to_return(status: 400, body: '{"message":"invalid"}')

      expect(described_class.new.verify_code(phone: phone, code: "000000")).to eq(false)
    end

    it "raises an unavailable error for rate limiting" do
      stub_request(:post, verify_url).to_return(status: 429, body: "")

      expect { described_class.new.verify_code(phone: phone, code: "123456") }.to raise_error(
        DiscourseSms::ApiClient::UnavailableError,
      )
    end

    it "raises an unavailable error for server errors" do
      stub_request(:post, verify_url).to_return(status: 503, body: "")

      expect { described_class.new.verify_code(phone: phone, code: "123456") }.to raise_error(
        DiscourseSms::ApiClient::UnavailableError,
      )
    end

    it "raises a configuration error for rejected credentials" do
      stub_request(:post, verify_url).to_return(status: 401, body: '{"message":"unauthorized"}')

      expect { described_class.new.verify_code(phone: phone, code: "123456") }.to raise_error(
        DiscourseSms::ApiClient::ConfigurationError,
        "unauthorized",
      )
    end
  end
end
