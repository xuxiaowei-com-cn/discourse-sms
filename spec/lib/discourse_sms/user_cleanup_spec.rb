# frozen_string_literal: true

require "rails_helper"

RSpec.describe "discourse-sms user cleanup" do
  fab!(:user)

  before do
    SiteSetting.sms_enabled = true
    SiteSetting.sms_delete_phone_data_on_user_delete = false
  end

  def create_phone_data(phone_number)
    DiscourseSms::PhoneBinding.create!(
      user: user,
      phone_number: phone_number,
      verified_at: Time.zone.now,
    )
    DiscourseSms::PhoneHistory.record!(user: user, phone_number: phone_number, event_type: "bind")
    DiscourseSms::VerificationChallenge.issue!(
      user: user,
      phone_number: phone_number,
      ttl: 10.minutes,
    )
    DiscourseSms::RegistrationChallenge.issue!(phone_number: phone_number, ttl: 10.minutes)
  end

  it "keeps all phone data by default" do
    create_phone_data("+8613800138000")

    DiscourseEvent.trigger(:user_destroyed, user)

    expect(DiscourseSms::PhoneBinding.exists?(user_id: user.id)).to eq(true)
    expect(DiscourseSms::PhoneHistory.exists?(user_id: user.id)).to eq(true)
    expect(DiscourseSms::VerificationChallenge.exists?(user_id: user.id)).to eq(true)
    expect(DiscourseSms::RegistrationChallenge.exists?(phone_number: "+8613800138000")).to eq(true)
  end

  it "keeps all phone data on anonymization by default" do
    create_phone_data("+8613800138001")

    DiscourseEvent.trigger(:user_anonymized, user: user)

    expect(DiscourseSms::PhoneBinding.exists?(user_id: user.id)).to eq(true)
    expect(DiscourseSms::PhoneHistory.exists?(user_id: user.id)).to eq(true)
    expect(DiscourseSms::VerificationChallenge.exists?(user_id: user.id)).to eq(true)
    expect(DiscourseSms::RegistrationChallenge.exists?(phone_number: "+8613800138001")).to eq(true)
  end

  it "deletes all phone data when the setting is enabled" do
    SiteSetting.sms_delete_phone_data_on_user_delete = true
    create_phone_data("+8613800138002")

    DiscourseEvent.trigger(:user_destroyed, user)

    expect(DiscourseSms::PhoneBinding.exists?(user_id: user.id)).to eq(false)
    expect(DiscourseSms::PhoneHistory.exists?(user_id: user.id)).to eq(false)
    expect(DiscourseSms::VerificationChallenge.exists?(user_id: user.id)).to eq(false)
    expect(DiscourseSms::RegistrationChallenge.exists?(phone_number: "+8613800138002")).to eq(false)
  end
end
