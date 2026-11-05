# frozen_string_literal: true

class AddIpAndUserAgentToDiscourseSmsTables < ActiveRecord::Migration[7.0]
  TABLES = %i[
    discourse_sms_phone_bindings
    discourse_sms_phone_histories
    discourse_sms_registration_challenges
    discourse_sms_verification_challenges
  ].freeze

  def change
    TABLES.each do |table|
      add_column table, :ip_address, :string, limit: 45
      add_column table, :user_agent, :string, limit: 500
    end
  end
end
