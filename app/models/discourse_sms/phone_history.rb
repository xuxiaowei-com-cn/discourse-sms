# frozen_string_literal: true

module ::DiscourseSms
  class PhoneHistory < ::ActiveRecord::Base
    self.table_name = "discourse_sms_phone_histories"

    EVENT_TYPES = %w[bind unbind verify].freeze

    belongs_to :user

    validates :user_id, presence: true
    validates :phone_number, presence: true
    validates :event_type, presence: true, inclusion: { in: EVENT_TYPES }
    validate :phone_number_is_e164

    scope :recent, -> { order(created_at: :desc, id: :desc) }

    def self.record!(user:, phone_number:, event_type:)
      return if user.nil? || phone_number.blank?

      create!(user_id: user.id, phone_number: phone_number, event_type: event_type.to_s)
    rescue StandardError => e
      Rails.logger.warn("[discourse-sms] failed to record phone history: #{e.class}: #{e.message}")
      nil
    end

    private

    def phone_number_is_e164
      return if phone_number.blank? || PhoneNumber.valid?(phone_number)

      errors.add(:phone_number, :invalid)
    end
  end
end

# == Schema Information
#
# Table name: discourse_sms_phone_histories
#
#  id           :bigint           not null, primary key
#  event_type   :string(20)       not null
#  phone_number :string(20)       not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  user_id      :integer          not null
#
# Indexes
#
#  index_discourse_sms_phone_histories_on_phone_number            (phone_number)
#  index_discourse_sms_phone_histories_on_user_id                 (user_id)
#  index_discourse_sms_phone_histories_on_user_id_and_created_at  (user_id,created_at)
#
