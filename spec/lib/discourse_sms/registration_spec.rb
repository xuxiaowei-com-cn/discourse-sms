# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseSms::Registration do
  let(:phone) { "+8613800138000" }

  before do
    SiteSetting.sms_enabled = true
    SiteSetting.sms_require_phone_on_signup = true
    SiteSetting.sms_registration_token_ttl_minutes = 30
    SiteSetting.sms_max_verification_attempts = 5
  end

  def verified_challenge
    challenge = DiscourseSms::RegistrationChallenge.issue!(phone_number: phone, ttl: 10.minutes)
    [challenge, challenge.mark_verified!]
  end

  it "returns nil when registration verification is disabled" do
    SiteSetting.sms_require_phone_on_signup = false

    expect(described_class.context_for({})).to be_nil
  end

  it "accepts a valid phone and token pair" do
    challenge, token = verified_challenge

    context = described_class.context_for({ sms_phone: phone, sms_registration_token: token })

    expect(context).to include(challenge_id: challenge.id, phone_number: phone)
  end

  it "falls back to the server session used by the email-code flow" do
    challenge, token = verified_challenge
    session = {
      described_class::SESSION_PHONE_KEY => phone,
      described_class::SESSION_TOKEN_KEY => token,
    }

    context = described_class.context_for({}, session: session)

    expect(context).to include(challenge_id: challenge.id, phone_number: phone)
  end

  it "rejects a token issued for another phone" do
    _challenge, token = verified_challenge

    expect(
      described_class.context_for({ sms_phone: "+8613900139000", sms_registration_token: token }),
    ).to eq(false)
  end

  it "rejects a phone that is already bound" do
    _challenge, token = verified_challenge
    DiscourseSms::PhoneBinding.create!(
      user: Fabricate(:user),
      phone_number: phone,
      verified_at: Time.zone.now,
    )

    expect(described_class.context_for({ sms_phone: phone, sms_registration_token: token })).to eq(
      false,
    )
  end
end
