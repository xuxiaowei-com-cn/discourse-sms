# frozen_string_literal: true

module ::DiscourseSms
  class VerificationChallenge < ::ActiveRecord::Base
    self.table_name = "discourse_sms_verification_challenges"

    belongs_to :user

    validates :user_id, presence: true, uniqueness: true
    validates :phone_number, presence: true
    validates :sent_at, presence: true
    validates :expires_at, presence: true

    scope :expired, -> { where("expires_at <= ?", Time.zone.now) }

    def self.issue!(user:, phone_number:, ttl:)
      now = Time.zone.now
      attributes = {
        phone_number: phone_number,
        sent_at: now,
        expires_at: now + ttl,
        attempts: 0,
      }

      challenge = find_or_initialize_by(user_id: user.id)
      challenge.assign_attributes(attributes)
      challenge.save!
      challenge
    rescue ActiveRecord::RecordNotUnique
      challenge = find_by!(user_id: user.id)
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
  end
end
