# frozen_string_literal: true

require "digest"
require "securerandom"

module ::DiscourseSms
  # A phone verification performed before an account exists. The row is keyed
  # by phone number, not by user, because registration has no user yet. After a
  # successful provider verification it stores a digest of a one-time token
  # that the signup request must present again.
  class RegistrationChallenge < ::ActiveRecord::Base
    self.table_name = "discourse_sms_registration_challenges"

    TOKEN_BYTES = 32

    validates :phone_number, presence: true, uniqueness: true
    validates :sent_at, presence: true
    validates :expires_at, presence: true
    validate :phone_number_is_e164

    scope :expired, -> { where("expires_at <= ?", Time.zone.now) }

    def self.issue!(phone_number:, ttl:)
      now = Time.zone.now
      attributes = {
        phone_number: phone_number,
        sent_at: now,
        expires_at: now + ttl,
        attempts: 0,
        verified_at: nil,
        token_digest: nil,
        token_expires_at: nil,
        consumed_at: nil,
      }

      challenge = find_or_initialize_by(phone_number: phone_number)
      challenge.assign_attributes(attributes)
      challenge.save!
      challenge
    rescue ActiveRecord::RecordNotUnique
      challenge = find_by!(phone_number: phone_number)
      challenge.update!(attributes)
      challenge
    end

    def expired?
      expires_at <= Time.zone.now
    end

    def attempts_exhausted?
      attempts >= SiteSetting.sms_max_verification_attempts.to_i
    end

    def active?
      !expired? && !attempts_exhausted?
    end

    # Returns the raw token exactly once. Only its digest is persisted.
    def mark_verified!
      raw_token = SecureRandom.urlsafe_base64(TOKEN_BYTES)
      update!(
        verified_at: Time.zone.now,
        token_digest: self.class.digest(raw_token),
        token_expires_at:
          Time.zone.now + SiteSetting.sms_registration_token_ttl_minutes.to_i.minutes,
      )
      raw_token
    end

    def token_valid?(raw_token)
      return false if raw_token.blank? || token_digest.blank? || verified_at.blank?
      return false if consumed_at.present?
      return false if token_expires_at.nil? || token_expires_at <= Time.zone.now

      ActiveSupport::SecurityUtils.secure_compare(token_digest, self.class.digest(raw_token))
    end

    def consume!
      update!(consumed_at: Time.zone.now)
    end

    def self.digest(raw_token)
      Digest::SHA256.hexdigest(raw_token.to_s)
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
# Table name: discourse_sms_registration_challenges
#
#  id               :bigint           not null, primary key
#  attempts         :integer          default(0), not null
#  consumed_at      :datetime
#  expires_at       :datetime         not null
#  phone_number     :string(20)       not null
#  sent_at          :datetime         not null
#  token_digest     :string(64)
#  token_expires_at :datetime
#  verified_at      :datetime
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#
# Indexes
#
#  index_discourse_sms_registration_challenges_on_expires_at    (expires_at)
#  index_discourse_sms_registration_challenges_on_phone_number  (phone_number) UNIQUE
#  index_discourse_sms_registration_challenges_on_token_digest  (token_digest) UNIQUE
#
