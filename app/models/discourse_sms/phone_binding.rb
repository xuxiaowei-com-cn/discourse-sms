# frozen_string_literal: true

module ::DiscourseSms
  class PhoneBinding < ::ActiveRecord::Base
    self.table_name = "discourse_sms_phone_bindings"

    belongs_to :user

    validates :user_id, presence: true, uniqueness: true
    validates :phone_number, presence: true, uniqueness: true
    validates :verified_at, presence: true
    validate :phone_number_is_e164

    def self.for_user(user)
      return nil if user.nil?

      find_by(user_id: user.id)
    end

    def self.verified?(user)
      return false if user.nil?

      exists?(user_id: user.id)
    end

    def masked_phone
      PhoneNumber.mask(phone_number)
    end

    private

    def phone_number_is_e164
      return if phone_number.blank? || PhoneNumber.valid?(phone_number)

      errors.add(:phone_number, :invalid)
    end
  end
end
