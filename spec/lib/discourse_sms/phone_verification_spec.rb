# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseSms::PhoneVerification do
  fab!(:user)
  fab!(:group)

  before do
    SiteSetting.sms_enabled = true
    SiteSetting.sms_require_phone_binding = true
    SiteSetting.sms_skip_phone_binding_groups = ""
    SiteSetting.sms_skip_phone_binding_usernames = ""
  end

  def bind(user)
    DiscourseSms::PhoneBinding.create!(
      user: user,
      phone_number: "+8613800138000",
      verified_at: Time.zone.now,
    )
  end

  it "does not require binding when the requirement is disabled" do
    SiteSetting.sms_require_phone_binding = false

    expect(described_class.required_for?(user)).to eq(false)
  end

  it "requires binding for an unbound member" do
    expect(described_class.required_for?(user)).to eq(true)
  end

  it "does not require binding for a verified member" do
    bind(user)

    expect(described_class.required_for?(user)).to eq(false)
  end

  it "does not require binding for members of skip groups" do
    group.add(user)
    SiteSetting.sms_skip_phone_binding_groups = group.id.to_s

    expect(described_class.required_for?(user)).to eq(false)
  end

  it "does not require binding for usernames in the skip list" do
    SiteSetting.sms_skip_phone_binding_usernames = "someone, #{user.username}"

    expect(described_class.required_for?(user)).to eq(false)
  end

  it "does not require binding for the system user" do
    expect(described_class.required_for?(Discourse.system_user)).to eq(false)
  end

  it "does not require binding for a nil user" do
    expect(described_class.required_for?(nil)).to eq(false)
  end
end
