# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseSms::SmsController do
  fab!(:user)
  fab!(:other_user, :user)
  fab!(:admin)

  let(:send_url) { "https://sms.example.com/send" }
  let(:verify_url) { "https://sms.example.com/verify" }
  let(:phone) { "+8613800138000" }

  before do
    SiteSetting.sms_enabled = true
    SiteSetting.sms_require_captcha = true
    SiteSetting.sms_send_api_url = send_url
    SiteSetting.sms_verify_api_url = verify_url
    SiteSetting.sms_auth_token = "token"
    SiteSetting.sms_default_country_code = "86"
    SiteSetting.sms_code_ttl_minutes = 10
    SiteSetting.sms_resend_interval_seconds = 60
    SiteSetting.sms_max_sends_per_hour = 10
    SiteSetting.sms_max_verification_attempts = 5
    SiteSetting.sms_verify_success_json_path = ""
    SiteSetting.sms_verify_success_value = ""

    allow(DiscourseSms::Captcha).to receive(:verify!).and_return(true)
    sign_in(user)
  end

  describe "#status" do
    it "reports an unbound account" do
      get "/sms/status.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body).to include(
        "bound" => false,
        "masked_phone" => nil,
        "verified_at" => nil,
      )
    end

    it "reports a bound account with a masked phone number" do
      DiscourseSms::PhoneBinding.create!(
        user: user,
        phone_number: phone,
        verified_at: Time.zone.now,
      )

      get "/sms/status.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body["bound"]).to eq(true)
      expect(response.parsed_body["masked_phone"]).to eq("+8613****8000")
      expect(response.parsed_body["verified_at"]).to be_present
      expect(response.parsed_body).not_to have_key("phone_number")
    end
  end

  describe "#user_status" do
    before do
      DiscourseSms::PhoneBinding.create!(
        user: other_user,
        phone_number: "+8618300000001",
        verified_at: Time.zone.now,
      )
    end

    it "allows an admin to view another member's masked phone number" do
      sign_in(admin)

      get "/sms/users/#{other_user.username}/status.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body["username"]).to eq(other_user.username)
      expect(response.parsed_body["masked_phone"]).to eq("+8618****0001")
      expect(response.parsed_body).not_to have_key("phone_number")
    end

    it "rejects a non-admin member" do
      sign_in(user)

      get "/sms/users/#{other_user.username}/status.json"

      expect(response.status).to eq(403)
    end

    it "returns not found for an unknown username" do
      sign_in(admin)

      get "/sms/users/not-a-real-user/status.json"

      expect(response.status).to eq(404)
    end
  end

  describe "current user serializer" do
    it "exposes the verified state to the current user" do
      DiscourseSms::PhoneBinding.create!(
        user: user,
        phone_number: phone,
        verified_at: Time.zone.now,
      )

      get "/session/current.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body.dig("current_user", "sms_phone_verified")).to eq(true)
      expect(response.parsed_body.dig("current_user", "sms_phone_masked")).to eq("+8613****8000")
    end

    it "reports an unverified state" do
      get "/session/current.json"

      expect(response.status).to eq(200)
      expect(response.parsed_body.dig("current_user", "sms_phone_verified")).to eq(false)
      expect(response.parsed_body.dig("current_user", "sms_phone_masked")).to be_nil
    end
  end

  describe "#send_code" do
    before { stub_request(:post, send_url).to_return(status: 200, body: '{"ok":true}') }

    it "sends a code through the provider and stores a challenge" do
      post "/sms/send_code.json",
           params: {
             sms_phone: "13800138000",
             captcha_token: "captcha-token",
           },
           headers: {
             "ACCEPT" => "application/json",
           }

      expect(response.status).to eq(200)
      expect(response.parsed_body["success"]).to eq(true)
      expect(response.parsed_body["masked_phone"]).to eq("+8613****8000")
      expect(response.parsed_body["resend_after"]).to eq(60)

      challenge = DiscourseSms::VerificationChallenge.find_by(user_id: user.id)
      expect(challenge.phone_number).to eq(phone)
      expect(challenge.expires_at).to be > Time.zone.now
    end

    it "can send a code without a captcha when the requirement is disabled" do
      SiteSetting.sms_require_captcha = false

      post "/sms/send_code.json",
           params: {
             sms_phone: "13800138000",
           },
           headers: {
             "ACCEPT" => "application/json",
           }

      expect(response.status).to eq(200)
      expect(response.parsed_body["success"]).to eq(true)
      expect(DiscourseSms::Captcha).not_to have_received(:verify!)
      expect(a_request(:post, send_url)).to have_been_made.once
    end

    it "requires a captcha token" do
      allow(DiscourseSms::Captcha).to receive(:verify!).and_raise(
        DiscourseSms::Captcha::VerificationFailed,
      )

      post "/sms/send_code.json",
           params: {
             sms_phone: "13800138000",
             captcha_token: "",
           },
           headers: {
             "ACCEPT" => "application/json",
           }

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"].first).to eq(
        I18n.t("sms.errors.captcha_failed"),
      )
      expect(DiscourseSms::VerificationChallenge.count).to eq(0)
      expect(a_request(:post, send_url)).not_to have_been_made
    end

    it "refuses to send when captcha is not configured" do
      allow(DiscourseSms::Captcha).to receive(:verify!).and_raise(
        DiscourseSms::Captcha::NotConfigured,
      )

      post "/sms/send_code.json",
           params: {
             sms_phone: "13800138000",
             captcha_token: "captcha-token",
           },
           headers: {
             "ACCEPT" => "application/json",
           }

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"].first).to eq(
        I18n.t("sms.errors.captcha_not_configured"),
      )
      expect(a_request(:post, send_url)).not_to have_been_made
    end

    it "rejects an invalid phone number before calling the provider" do
      post "/sms/send_code.json",
           params: {
             sms_phone: "not-a-phone",
             captcha_token: "captcha-token",
           },
           headers: {
             "ACCEPT" => "application/json",
           }

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"].first).to eq(I18n.t("sms.errors.phone_invalid"))
      expect(a_request(:post, send_url)).not_to have_been_made
    end

    it "rejects a phone number bound to another account" do
      DiscourseSms::PhoneBinding.create!(
        user: other_user,
        phone_number: phone,
        verified_at: Time.zone.now,
      )

      post "/sms/send_code.json",
           params: {
             sms_phone: "13800138000",
             captcha_token: "captcha-token",
           },
           headers: {
             "ACCEPT" => "application/json",
           }

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"].first).to eq(I18n.t("sms.errors.phone_taken"))
      expect(a_request(:post, send_url)).not_to have_been_made
    end

    it "cleans up the challenge when the provider rejects the request" do
      stub_request(:post, send_url).to_return(status: 400, body: '{"message":"bad request"}')

      post "/sms/send_code.json",
           params: {
             sms_phone: "13800138000",
             captcha_token: "captcha-token",
           },
           headers: {
             "ACCEPT" => "application/json",
           }

      expect(response.status).to eq(422)
      expect(DiscourseSms::VerificationChallenge.count).to eq(0)
    end

    it "reports provider outages with a 503" do
      stub_request(:post, send_url).to_return(status: 503, body: "")

      post "/sms/send_code.json",
           params: {
             sms_phone: "13800138000",
             captcha_token: "captcha-token",
           },
           headers: {
             "ACCEPT" => "application/json",
           }

      expect(response.status).to eq(503)
      expect(response.parsed_body["errors"].first).to eq(
        I18n.t("sms.errors.provider_unavailable"),
      )
    end
  end

  describe "#verify_code" do
    before do
      DiscourseSms::VerificationChallenge.issue!(
        user: user,
        phone_number: phone,
        ttl: 10.minutes,
      )
      stub_request(:post, verify_url).to_return(status: 200, body: '{"success":true}')
    end

    it "binds the verified phone number" do
      post "/sms/verify_code.json",
           params: {
             sms_code: "123456",
           },
           headers: {
             "ACCEPT" => "application/json",
           }

      expect(response.status).to eq(200)
      expect(response.parsed_body["bound"]).to eq(true)
      expect(response.parsed_body["masked_phone"]).to eq("+8613****8000")

      binding = DiscourseSms::PhoneBinding.find_by(user_id: user.id)
      expect(binding.phone_number).to eq(phone)
      expect(DiscourseSms::VerificationChallenge.count).to eq(0)
    end

    it "replaces an existing binding when the member changes phone number" do
      DiscourseSms::PhoneBinding.create!(
        user: user,
        phone_number: "+8613900139000",
        verified_at: 1.week.ago,
      )

      post "/sms/verify_code.json",
           params: {
             sms_code: "123456",
           },
           headers: {
             "ACCEPT" => "application/json",
           }

      expect(response.status).to eq(200)
      expect(DiscourseSms::PhoneBinding.find_by(user_id: user.id).phone_number).to eq(phone)
    end

    it "increments attempts when the code is invalid" do
      SiteSetting.sms_verify_success_json_path = "valid"
      SiteSetting.sms_verify_success_value = "true"
      stub_request(:post, verify_url).to_return(status: 200, body: '{"valid":false}')

      post "/sms/verify_code.json",
           params: {
             sms_code: "000000",
           },
           headers: {
             "ACCEPT" => "application/json",
           }

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"].first).to eq(I18n.t("sms.errors.code_invalid"))
      expect(DiscourseSms::VerificationChallenge.find_by(user_id: user.id).attempts).to eq(1)
      expect(DiscourseSms::PhoneBinding.count).to eq(0)
    end

    it "rejects a malformed code without calling the provider" do
      post "/sms/verify_code.json",
           params: {
             sms_code: "abc",
           },
           headers: {
             "ACCEPT" => "application/json",
           }

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"].first).to eq(
        I18n.t("sms.errors.code_invalid_format"),
      )
      expect(a_request(:post, verify_url)).not_to have_been_made
    end

    it "rejects an expired code" do
      DiscourseSms::VerificationChallenge.find_by(user_id: user.id).update!(
        expires_at: 1.minute.ago,
      )

      post "/sms/verify_code.json",
           params: {
             sms_code: "123456",
           },
           headers: {
             "ACCEPT" => "application/json",
           }

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"].first).to eq(I18n.t("sms.errors.code_expired"))
    end

    it "rejects verification without a prior code request" do
      DiscourseSms::VerificationChallenge.delete_all

      post "/sms/verify_code.json",
           params: {
             sms_code: "123456",
           },
           headers: {
             "ACCEPT" => "application/json",
           }

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"].first).to eq(
        I18n.t("sms.errors.code_not_requested"),
      )
    end

    it "locks the challenge after too many attempts" do
      DiscourseSms::VerificationChallenge.find_by(user_id: user.id).update!(attempts: 5)

      post "/sms/verify_code.json",
           params: {
             sms_code: "123456",
           },
           headers: {
             "ACCEPT" => "application/json",
           }

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"].first).to eq(
        I18n.t("sms.errors.too_many_attempts"),
      )
      expect(a_request(:post, verify_url)).not_to have_been_made
    end

    it "rejects a phone number taken by another account" do
      DiscourseSms::PhoneBinding.create!(
        user: other_user,
        phone_number: phone,
        verified_at: Time.zone.now,
      )

      post "/sms/verify_code.json",
           params: {
             sms_code: "123456",
           },
           headers: {
             "ACCEPT" => "application/json",
           }

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"].first).to eq(I18n.t("sms.errors.phone_taken"))
      expect(DiscourseSms::PhoneBinding.find_by(user_id: user.id)).to be_nil
    end

    it "reports provider outages with a 503" do
      stub_request(:post, verify_url).to_return(status: 503, body: "")

      post "/sms/verify_code.json",
           params: {
             sms_code: "123456",
           },
           headers: {
             "ACCEPT" => "application/json",
           }

      expect(response.status).to eq(503)
      expect(response.parsed_body["errors"].first).to eq(
        I18n.t("sms.errors.provider_unavailable"),
      )
    end
  end
end
