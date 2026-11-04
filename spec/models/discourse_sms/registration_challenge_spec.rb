# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseSms::RegistrationChallenge do
  let(:phone) { "+8613800138000" }

  before do
    SiteSetting.sms_enabled = true
    SiteSetting.sms_require_phone_on_signup = true
    SiteSetting.sms_registration_token_ttl_minutes = 30
    SiteSetting.sms_max_verification_attempts = 5
  end

  def issue
    described_class.issue!(phone_number: phone, ttl: 10.minutes)
  end

  it "issues a challenge keyed by phone number" do
    challenge = issue

    expect(challenge.phone_number).to eq(phone)
    expect(challenge.expires_at).to be > Time.zone.now
    expect(challenge.attempts).to eq(0)
  end

  it "returns a token only after verification and stores only its digest" do
    challenge = issue
    raw_token = challenge.mark_verified!

    expect(raw_token).to be_present
    expect(challenge.reload.token_digest).to eq(described_class.digest(raw_token))
    expect(challenge.token_digest).not_to eq(raw_token)
    expect(challenge.token_valid?(raw_token)).to eq(true)
  end

  it "rejects a wrong token" do
    challenge = issue
    challenge.mark_verified!

    expect(challenge.token_valid?("not-the-token")).to eq(false)
  end

  it "rejects an expired token" do
    challenge = issue
    raw_token = challenge.mark_verified!
    challenge.update!(token_expires_at: 1.minute.ago)

    expect(challenge.token_valid?(raw_token)).to eq(false)
  end

  it "rejects a consumed token" do
    challenge = issue
    raw_token = challenge.mark_verified!
    challenge.consume!

    expect(challenge.token_valid?(raw_token)).to eq(false)
  end

  it "invalidates the previous token when a new code is requested" do
    challenge = issue
    raw_token = challenge.mark_verified!

    challenge = issue

    expect(challenge.reload.token_digest).to be_nil
    expect(challenge.token_valid?(raw_token)).to eq(false)
  end
end
