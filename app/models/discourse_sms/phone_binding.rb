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

# == Schema Information
#
# Table name: discourse_sms_phone_bindings
#
#  id           :bigint           not null, primary key
#  phone_number :string(20)       not null
#  verified_at  :datetime         not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  user_id      :integer          not null
#
# Indexes
#
#  index_discourse_sms_phone_bindings_on_phone_number  (phone_number) UNIQUE
#  index_discourse_sms_phone_bindings_on_user_id       (user_id) UNIQUE
#
