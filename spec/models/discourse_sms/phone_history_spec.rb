# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseSms::PhoneHistory do
  fab!(:user)

  it "records a valid phone event" do
    history =
      described_class.record!(user: user, phone_number: "+8613800138000", event_type: "bind")

    expect(history).to be_persisted
    expect(history.user_id).to eq(user.id)
    expect(history.phone_number).to eq("+8613800138000")
    expect(history.event_type).to eq("bind")
  end

  it "does not record an unknown event type" do
    expect(
      described_class.record!(user: user, phone_number: "+8613800138000", event_type: "unknown"),
    ).to be_nil

    expect(described_class.count).to eq(0)
  end

  it "does not record without a user" do
    expect(
      described_class.record!(user: nil, phone_number: "+8613800138000", event_type: "bind"),
    ).to be_nil
  end
end
