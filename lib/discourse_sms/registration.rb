# frozen_string_literal: true

module ::DiscourseSms
  # Connects the pre-signup SMS challenge to the user that is finally created.
  # The controller validates the one-time token before creating the account and
  # leaves a short lived context on the current thread. The :user_created event
  # then creates the binding for the new user.
  module Registration
    THREAD_KEY = :discourse_sms_registration_context
    SESSION_PHONE_KEY = "sms_registration_phone"
    SESSION_TOKEN_KEY = "sms_registration_token"

    module_function

    def required?
      SiteSetting.sms_enabled && SiteSetting.sms_require_phone_on_signup
    end

    # Returns nil when registration verification is disabled, false when the
    # request is missing a valid token, and a context hash when it is valid.
    def context_for(params, session: nil)
      return nil if !required?

      phone =
        PhoneNumber.normalize(
          params[:sms_phone],
          default_country_code: SiteSetting.sms_default_country_code,
        )
      token = params[:sms_registration_token].to_s

      if phone.blank? && token.blank? && session
        phone = session[SESSION_PHONE_KEY]
        token = session[SESSION_TOKEN_KEY].to_s
      end

      return false if phone.blank? || token.blank?
      return false if PhoneBinding.exists?(phone_number: phone)

      challenge = RegistrationChallenge.find_by(phone_number: phone)
      return false if challenge.nil? || !challenge.token_valid?(token)

      { challenge_id: challenge.id, phone_number: phone, token: token }
    end

    def store_session!(session, phone:, token:)
      return if session.nil?

      session[SESSION_PHONE_KEY] = phone
      session[SESSION_TOKEN_KEY] = token
    end

    def clear_session!(session)
      return if session.nil?

      session.delete(SESSION_PHONE_KEY)
      session.delete(SESSION_TOKEN_KEY)
    end

    def set_context!(context)
      Thread.current[THREAD_KEY] = context
    end

    def clear_context!
      Thread.current[THREAD_KEY] = nil
    end

    def complete!(user, context = Thread.current[THREAD_KEY])
      clear_context!
      return if context.blank? || user.nil?

      challenge = RegistrationChallenge.find_by(id: context[:challenge_id])
      return if challenge.nil? || !challenge.token_valid?(context[:token])
      return if PhoneBinding.exists?(user_id: user.id)

      binding = PhoneBinding.find_or_initialize_by(user_id: user.id)
      binding.phone_number = challenge.phone_number
      binding.verified_at = Time.zone.now

      PhoneBinding.transaction do
        binding.save!
        challenge.consume!
      end

      PhoneHistory.record!(user: user, phone_number: binding.phone_number, event_type: "bind")
      PhoneHistory.record!(user: user, phone_number: binding.phone_number, event_type: "verify")
    rescue StandardError => e
      Rails.logger.error(
        "[discourse-sms] failed to bind phone for new user #{user&.id}: #{e.class}: #{e.message}",
      )
    end
  end
end
