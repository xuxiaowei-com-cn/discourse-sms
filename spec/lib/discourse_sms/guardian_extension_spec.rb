# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseSms::GuardianExtension do
  fab!(:user)
  fab!(:topic)
  fab!(:group)

  let(:guardian) { Guardian.new(user) }

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

  it "blocks post creation for unbound members" do
    expect(guardian.can_create_post?(topic)).to eq(false)
  end

  it "blocks private messages for unbound members" do
    expect(guardian.can_send_private_messages?).to eq(false)
  end

  it "allows verified members to post" do
    bind(user)

    expect(guardian.can_create_post?(topic)).to eq(true)
  end

  it "allows members of skip groups to post" do
    group.add(user)
    SiteSetting.sms_skip_phone_binding_groups = group.id.to_s

    expect(guardian.can_create_post?(topic)).to eq(true)
  end
end
