# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseSms::Captcha, skip: !SiteSetting.respond_to?(:discourse_captcha_enabled) do
  before do
    SiteSetting.discourse_captcha_enabled = true
    SiteSetting.discourse_captcha_provider = "hcaptcha"
    SiteSetting.hcaptcha_site_key = "site-key"
    SiteSetting.hcaptcha_secret_key = "secret-key"
  end

  describe ".enabled?" do
    it "is true when the captcha plugin is enabled and configured" do
      expect(described_class.enabled?).to eq(true)
    end

    it "is false when the captcha plugin is disabled" do
      SiteSetting.discourse_captcha_enabled = false

      expect(described_class.enabled?).to eq(false)
    end

    it "is false when no provider is selected" do
      SiteSetting.discourse_captcha_provider = "none"

      expect(described_class.enabled?).to eq(false)
    end
  end

  describe ".verify!" do
    it "verifies an hCaptcha token" do
      stub_request(:post, "https://hcaptcha.com/siteverify").with(
        body: hash_including("secret" => "secret-key", "response" => "token"),
      ).to_return(status: 200, body: '{"success":true}')

      expect(described_class.verify!("token", remote_ip: "1.2.3.4")).to eq(true)
    end

    it "raises when the provider rejects the token" do
      stub_request(:post, "https://hcaptcha.com/siteverify").to_return(
        status: 200,
        body: '{"success":false}',
      )

      expect { described_class.verify!("token") }.to raise_error(
        DiscourseSms::Captcha::VerificationFailed,
      )
    end

    it "raises when captcha is not configured" do
      SiteSetting.hcaptcha_secret_key = ""

      expect { described_class.verify!("token") }.to raise_error(
        DiscourseSms::Captcha::NotConfigured,
      )
    end

    it "raises when captcha is disabled" do
      SiteSetting.discourse_captcha_enabled = false

      expect { described_class.verify!("token") }.to raise_error(
        DiscourseSms::Captcha::NotConfigured,
      )
    end

    it "raises when the token is blank" do
      expect { described_class.verify!("") }.to raise_error(
        DiscourseSms::Captcha::VerificationFailed,
      )
    end

    it "raises when the provider is unavailable" do
      stub_request(:post, "https://hcaptcha.com/siteverify").to_return(status: 500, body: "")

      expect { described_class.verify!("token") }.to raise_error(DiscourseSms::Captcha::Unavailable)
    end

    context "with reCAPTCHA v3" do
      before do
        SiteSetting.discourse_captcha_provider = "recaptcha_v3"
        SiteSetting.recaptcha_v3_site_key = "v3-site-key"
        SiteSetting.recaptcha_v3_secret_key = "v3-secret-key"
        SiteSetting.recaptcha_v3_score_threshold = 0.5
      end

      it "accepts a matching action with a sufficient score" do
        stub_request(:post, "https://www.google.com/recaptcha/api/siteverify").to_return(
          status: 200,
          body: '{"success":true,"action":"signup","score":0.9}',
        )

        expect(described_class.verify!("token")).to eq(true)
      end

      it "rejects a mismatched action" do
        stub_request(:post, "https://www.google.com/recaptcha/api/siteverify").to_return(
          status: 200,
          body: '{"success":true,"action":"login","score":0.9}',
        )

        expect { described_class.verify!("token") }.to raise_error(
          DiscourseSms::Captcha::VerificationFailed,
        )
      end

      it "rejects a low score" do
        stub_request(:post, "https://www.google.com/recaptcha/api/siteverify").to_return(
          status: 200,
          body: '{"success":true,"action":"signup","score":0.2}',
        )

        expect { described_class.verify!("token") }.to raise_error(
          DiscourseSms::Captcha::VerificationFailed,
        )
      end
    end
  end
end
