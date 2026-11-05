# frozen_string_literal: true

require "rails_helper"

RSpec.describe "discourse-sms registration verification" do
  let(:phone) { "+8613800138000" }
  let(:send_url) { "https://sms.example.com/send" }
  let(:verify_url) { "https://sms.example.com/verify" }

  before do
    SiteSetting.sms_enabled = true
    SiteSetting.sms_require_phone_on_signup = true
    SiteSetting.sms_require_captcha = true
    SiteSetting.sms_send_api_url = send_url
    SiteSetting.sms_verify_api_url = verify_url
    SiteSetting.sms_default_country_code = "86"
    SiteSetting.sms_code_ttl_minutes = 10
    SiteSetting.sms_registration_token_ttl_minutes = 30
    SiteSetting.sms_resend_interval_seconds = 0
    SiteSetting.sms_max_sends_per_hour = 0
    SiteSetting.sms_max_verification_attempts = 5
    SiteSetting.sms_verify_success_json_path = ""
    SiteSetting.sms_verify_success_value = ""

    allow(DiscourseSms::Captcha).to receive(:verify!).and_return(true)
    stub_request(:post, send_url).to_return(status: 200, body: '{"ok":true}')
    stub_request(:post, verify_url).to_return(status: 200, body: '{"success":true}')
  end

  def request_code
    post "/sms/registration/send_code.json",
         params: {
           sms_phone: "13800138000",
           captcha_token: "captcha-token",
         },
         headers: {
           "ACCEPT" => "application/json",
         }
  end

  def verify_code
    post "/sms/registration/verify_code.json",
         params: {
           sms_phone: "13800138000",
           sms_code: "123456",
         },
         headers: {
           "ACCEPT" => "application/json",
         }
  end

  describe "the registration challenge endpoints" do
    it "sends a code without an authenticated user" do
      request_code

      expect(response.status).to eq(200)
      expect(response.parsed_body["success"]).to eq(true)
      expect(DiscourseSms::RegistrationChallenge.find_by(phone_number: phone)).to be_present
      expect(a_request(:post, send_url)).to have_been_made.once
    end

    it "records the request IP and user agent on the challenge" do
      post "/sms/registration/send_code.json",
           params: {
             sms_phone: "13800138000",
             captcha_token: "captcha-token",
           },
           headers: {
             "ACCEPT" => "application/json",
             "HTTP_USER_AGENT" => "SMS Registration Test",
           }

      challenge = DiscourseSms::RegistrationChallenge.find_by(phone_number: phone)
      expect(challenge.ip_address).to be_present
      expect(challenge.user_agent).to eq("SMS Registration Test")
    end

    it "does not reveal a bound phone when sending a code" do
      DiscourseSms::PhoneBinding.create!(
        user: Fabricate(:user),
        phone_number: phone,
        verified_at: Time.zone.now,
      )

      request_code

      expect(response.status).to eq(200)
      expect(response.parsed_body["success"]).to eq(true)
      expect(a_request(:post, send_url)).to have_been_made.once
    end

    it "rejects a bound phone only after the code is verified" do
      DiscourseSms::PhoneBinding.create!(
        user: Fabricate(:user),
        phone_number: phone,
        verified_at: Time.zone.now,
      )

      request_code
      verify_code

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"].first).to eq(I18n.t("sms.errors.phone_taken"))
      expect(response.parsed_body).not_to have_key("registration_token")
      expect(DiscourseSms::RegistrationChallenge.find_by(phone_number: phone)).to be_nil
    end

    it "verifies the code and returns a one-time token" do
      request_code
      verify_code

      expect(response.status).to eq(200)
      expect(response.parsed_body["registration_token"]).to be_present
      expect(response.parsed_body["phone_number"]).to eq(phone)
      expect(response.parsed_body["masked_phone"]).to eq("+8613****8000")
    end

    it "rejects a code for a different phone number" do
      request_code

      post "/sms/registration/verify_code.json",
           params: {
             sms_phone: "13900139000",
             sms_code: "123456",
           },
           headers: {
             "ACCEPT" => "application/json",
           }

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"].first).to eq(I18n.t("sms.errors.code_not_requested"))
    end

    it "refuses to run when registration verification is disabled" do
      SiteSetting.sms_require_phone_on_signup = false

      request_code

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"].first).to eq(I18n.t("sms.errors.registration_disabled"))
      expect(a_request(:post, send_url)).not_to have_been_made
    end
  end

  describe "creating an account" do
    before do
      UsersController.any_instance.stubs(:honeypot_value).returns(nil)
      UsersController.any_instance.stubs(:challenge_value).returns(nil)
      SiteSetting.allow_new_registrations = true
    end

    let(:user_params) do
      {
        name: "New Member",
        username: "new_member",
        email: "new_member@example.com",
        password: "strongpassword",
      }
    end

    def create_account(extra = {})
      post "/u.json", params: user_params.merge(extra)
    end

    it "refuses registration without a verified phone number" do
      expect { create_account }.not_to change { User.count }

      expect(response.status).to eq(200)
      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to eq(
        I18n.t("sms.errors.registration_phone_required"),
      )
    end

    it "creates the account and the binding with a valid token" do
      request_code
      verify_code
      token = response.parsed_body["registration_token"]

      expect { create_account(sms_phone: phone, sms_registration_token: token) }.to change {
        User.count
      }.by(1)

      expect(response.status).to eq(200)
      expect(response.parsed_body["success"]).to eq(true)

      user = User.find_by(username: "new_member")
      binding = DiscourseSms::PhoneBinding.find_by(user_id: user.id)
      expect(binding.phone_number).to eq(phone)
      expect(
        DiscourseSms::PhoneHistory.where(user_id: user.id).order(:id).pluck(:event_type),
      ).to eq(%w[bind verify])
      expect(
        DiscourseSms::RegistrationChallenge.find_by(phone_number: phone).consumed_at,
      ).to be_present
    end

    it "rejects a token that was already used" do
      request_code
      verify_code
      token = response.parsed_body["registration_token"]

      create_account(sms_phone: phone, sms_registration_token: token)
      expect(response.parsed_body["success"]).to eq(true)

      post "/u.json",
           params:
             user_params.merge(
               username: "another_member",
               email: "another_member@example.com",
               sms_phone: phone,
               sms_registration_token: token,
             )

      expect(response.parsed_body["success"]).to eq(false)
      expect(User.find_by(username: "another_member")).to be_nil
    end

    it "rejects a token issued for another phone number" do
      request_code
      verify_code
      token = response.parsed_body["registration_token"]

      create_account(sms_phone: "+8613900139000", sms_registration_token: token)

      expect(response.parsed_body["success"]).to eq(false)
      expect(User.find_by(username: "new_member")).to be_nil
    end
  end
end
