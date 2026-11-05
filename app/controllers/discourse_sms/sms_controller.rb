# frozen_string_literal: true

require "digest"

module ::DiscourseSms
  class SmsController < ::ApplicationController
    requires_plugin PLUGIN_NAME

    before_action :ensure_logged_in
    before_action :ensure_admin, only: :user_status
    skip_before_action :ensure_logged_in, only: %i[registration_send_code registration_verify_code]

    def status
      render json: binding_json(PhoneBinding.for_user(current_user))
    end

    def user_status
      user = User.find_by(username_lower: params[:username].to_s.downcase)
      raise Discourse::NotFound if user.nil?

      binding = PhoneBinding.for_user(user)
      render json: binding_json(binding).merge(username: user.username)
    end

    # Registration happens before a user exists, so this challenge is keyed by
    # phone number and a one-time token is returned after verification.
    def registration_send_code
      return render_error(:registration_disabled) if !Registration.required?

      phone = registration_phone
      return render_error(:phone_invalid) if phone.nil?
      return if !verify_captcha_or_render_error!

      enforce_registration_send_rate_limits!(phone)

      Registration.clear_session!(server_session)

      ttl = SiteSetting.sms_code_ttl_minutes.to_i.minutes
      challenge =
        RegistrationChallenge.issue!(
          phone_number: phone,
          ttl: ttl,
          ip_address: request_ip_address,
          user_agent: request_user_agent,
        )

      begin
        ApiClient.new.send_code(phone: phone)
      rescue ApiClient::RejectedError => e
        challenge.destroy!
        return render_error(:provider_rejected, message: e.message)
      rescue ApiClient::UnavailableError
        challenge.destroy!
        return render_error(:provider_unavailable, status: 503)
      rescue ApiClient::ConfigurationError
        challenge.destroy!
        return render_error(:provider_not_configured)
      end

      render json: {
               success: true,
               masked_phone: PhoneNumber.mask(phone),
               expires_in: ttl.to_i,
               resend_after: SiteSetting.sms_resend_interval_seconds.to_i,
             }
    end

    def registration_verify_code
      return render_error(:registration_disabled) if !Registration.required?

      phone = registration_phone
      return render_error(:phone_invalid) if phone.nil?

      code = params[:sms_code].to_s.strip
      return render_error(:code_invalid_format) if !code.match?(/\A[A-Za-z0-9]{4,20}\z/)

      challenge = RegistrationChallenge.find_by(phone_number: phone)
      return render_error(:code_not_requested) if challenge.nil?
      return render_error(:code_expired) if challenge.expired?
      return render_error(:too_many_attempts) if challenge.attempts_exhausted?

      enforce_registration_verify_rate_limits!(phone)

      challenge.with_lock do
        return render_error(:code_expired) if challenge.expired?
        return render_error(:too_many_attempts) if challenge.attempts_exhausted?

        which = verify_with_provider(challenge.phone_number, code)
        return which if performed?

        if which == true
          # Do not reveal whether a phone is already bound until the caller has
          # proven control of it with a valid SMS code.
          if PhoneBinding.exists?(phone_number: challenge.phone_number)
            challenge.destroy!
            return render_error(:phone_taken)
          end

          raw_token = challenge.mark_verified!
          Registration.store_session!(
            server_session,
            phone: challenge.phone_number,
            token: raw_token,
          )
          render json: {
                   success: true,
                   registration_token: raw_token,
                   phone_number: challenge.phone_number,
                   masked_phone: PhoneNumber.mask(challenge.phone_number),
                   expires_in: (challenge.token_expires_at - Time.zone.now).to_i,
                 }
        else
          challenge.increment!(:attempts)
          render_error(:code_invalid)
        end
      end
    end

    def send_code
      verifying_current = params[:purpose].to_s == "verify_current_phone"

      if verifying_current
        binding = PhoneBinding.for_user(current_user)
        return render_error(:current_phone_not_bound) if binding.nil?
        return render_error(:phone_change_disabled) if !SiteSetting.sms_allow_phone_change

        phone =
          PhoneNumber.normalize(
            params[:sms_phone],
            default_country_code: SiteSetting.sms_default_country_code,
          )
        return render_error(:phone_invalid) if phone.nil?
        return render_error(:current_phone_does_not_match) if phone != binding.phone_number
      else
        phone =
          PhoneNumber.normalize(
            params[:sms_phone],
            default_country_code: SiteSetting.sms_default_country_code,
          )
        return render_error(:phone_invalid) if phone.nil?

        if PhoneBinding.verified?(current_user)
          return render_error(:phone_change_disabled) if !SiteSetting.sms_allow_phone_change
          return render_error(:current_phone_verification_required) if !phone_change_authorized?
        end
      end

      return if !verify_captcha_or_render_error!

      enforce_send_rate_limits!(phone)

      ttl = SiteSetting.sms_code_ttl_minutes.to_i.minutes
      challenge =
        VerificationChallenge.issue!(
          user: current_user,
          phone_number: phone,
          ttl: ttl,
          ip_address: request_ip_address,
          user_agent: request_user_agent,
        )

      begin
        ApiClient.new.send_code(phone: phone, user: current_user)
      rescue ApiClient::RejectedError => e
        challenge.destroy!
        return render_error(:provider_rejected, message: e.message)
      rescue ApiClient::UnavailableError
        challenge.destroy!
        return render_error(:provider_unavailable, status: 503)
      rescue ApiClient::ConfigurationError
        challenge.destroy!
        return render_error(:provider_not_configured)
      end

      render json: {
               success: true,
               current_phone: verifying_current,
               masked_phone: PhoneNumber.mask(phone),
               expires_in: ttl.to_i,
               resend_after: SiteSetting.sms_resend_interval_seconds.to_i,
             }
    end

    def verify_code
      verifying_current = params[:purpose].to_s == "verify_current_phone"
      code = params[:sms_code].to_s.strip
      return render_error(:code_invalid_format) if !code.match?(/\A[A-Za-z0-9]{4,20}\z/)

      challenge = VerificationChallenge.find_by(user_id: current_user.id)
      return render_error(:code_not_requested) if challenge.nil?
      return render_error(:code_expired) if challenge.expired?
      return render_error(:too_many_attempts) if challenge.attempts_exhausted?

      if verifying_current
        binding = PhoneBinding.for_user(current_user)
        return render_error(:current_phone_not_bound) if binding.nil?
        return render_error(:phone_change_disabled) if !SiteSetting.sms_allow_phone_change
        if challenge.phone_number != binding.phone_number
          return render_error(:current_phone_mismatch)
        end
      elsif PhoneBinding.verified?(current_user)
        return render_error(:phone_change_disabled) if !SiteSetting.sms_allow_phone_change
        return render_error(:current_phone_verification_required) if !phone_change_authorized?
      end

      RateLimiter.new(current_user, "sms-verify-hour", 60, 1.hour).performed!

      challenge.with_lock do
        return render_error(:code_expired) if challenge.expired?
        return render_error(:too_many_attempts) if challenge.attempts_exhausted?

        which = verify_with_provider(challenge.phone_number, code)
        return which if performed?

        if which == true
          if verifying_current
            PhoneHistory.record!(
              user: current_user,
              phone_number: binding.phone_number,
              event_type: "verify",
              ip_address: request_ip_address,
              user_agent: request_user_agent,
            )
            authorize_phone_change!
            challenge.destroy!
            render json: {
                     success: true,
                     current_phone_verified: true,
                     masked_phone: binding.masked_phone,
                   }
          else
            bind_phone!(challenge)
          end
        else
          challenge.increment!(:attempts)
          render_error(:code_invalid)
        end
      end
    end

    private

    def request_ip_address
      request.remote_ip
    end

    def request_user_agent
      request.user_agent.to_s.truncate(500)
    end

    def registration_phone
      PhoneNumber.normalize(
        params[:sms_phone],
        default_country_code: SiteSetting.sms_default_country_code,
      )
    end

    def verify_captcha_or_render_error!
      return true if !SiteSetting.sms_require_captcha

      Captcha.verify!(params[:captcha_token], remote_ip: request.remote_ip)
      true
    rescue Captcha::NotConfigured
      render_error(:captcha_not_configured)
      false
    rescue Captcha::VerificationFailed
      render_error(:captcha_failed)
      false
    rescue Captcha::Unavailable
      render_error(:captcha_unavailable)
      false
    end

    def enforce_registration_send_rate_limits!(phone)
      phone_key = Digest::SHA256.hexdigest(phone)
      ip_key = Digest::SHA256.hexdigest(request.remote_ip.to_s)
      interval = SiteSetting.sms_resend_interval_seconds.to_i

      if interval.positive?
        RateLimiter.new(nil, "sms-register-send-cooldown-#{phone_key}", 1, interval).performed!
      end

      max = SiteSetting.sms_max_sends_per_hour.to_i
      if max.positive?
        RateLimiter.new(nil, "sms-register-send-ip-#{ip_key}", max, 1.hour).performed!
        RateLimiter.new(nil, "sms-register-send-phone-#{phone_key}", max, 1.hour).performed!
      end
    end

    def enforce_registration_verify_rate_limits!(phone)
      phone_key = Digest::SHA256.hexdigest(phone)
      ip_key = Digest::SHA256.hexdigest(request.remote_ip.to_s)
      RateLimiter.new(nil, "sms-register-verify-ip-#{ip_key}", 60, 1.hour).performed!
      RateLimiter.new(nil, "sms-register-verify-phone-#{phone_key}", 60, 1.hour).performed!
    end

    def verify_with_provider(phone, code)
      ApiClient.new.verify_code(phone: phone, code: code)
    rescue ApiClient::ConfigurationError
      render_error(:provider_not_configured)
    rescue ApiClient::UnavailableError
      render_error(:provider_unavailable, status: 503)
    rescue ApiClient::RejectedError => e
      render_error(:provider_rejected, message: e.message)
    end

    def bind_phone!(challenge)
      binding = PhoneBinding.find_or_initialize_by(user_id: current_user.id)
      previous_phone = binding.persisted? ? binding.phone_number_was : nil
      binding.phone_number = challenge.phone_number
      binding.verified_at = Time.zone.now
      binding.ip_address = request_ip_address
      binding.user_agent = request_user_agent

      PhoneBinding.transaction do
        binding.save!
        challenge.destroy!
      end

      if previous_phone.present? && previous_phone != binding.phone_number
        PhoneHistory.record!(
          user: current_user,
          phone_number: previous_phone,
          event_type: "unbind",
          ip_address: request_ip_address,
          user_agent: request_user_agent,
        )
      end

      if previous_phone != binding.phone_number
        PhoneHistory.record!(
          user: current_user,
          phone_number: binding.phone_number,
          event_type: "bind",
          ip_address: request_ip_address,
          user_agent: request_user_agent,
        )
      end

      PhoneHistory.record!(
        user: current_user,
        phone_number: binding.phone_number,
        event_type: "verify",
        ip_address: request_ip_address,
        user_agent: request_user_agent,
      )

      clear_phone_change_authorization!

      render json: binding_json(binding)
    rescue ActiveRecord::RecordNotUnique
      challenge.destroy!
      render_error(:phone_taken)
    rescue ActiveRecord::RecordInvalid => e
      challenge.destroy!
      if e.record.errors.of_kind?(:phone_number, :taken) ||
           e.record.errors.of_kind?(:user_id, :taken)
        render_error(:phone_taken)
      else
        raise
      end
    end

    def binding_json(binding)
      {
        bound: binding.present?,
        masked_phone: binding&.masked_phone,
        verified_at: binding&.verified_at&.iso8601,
      }
    end

    def enforce_send_rate_limits!(phone)
      phone_key = Digest::SHA256.hexdigest(phone)
      interval = SiteSetting.sms_resend_interval_seconds.to_i
      if interval.positive?
        RateLimiter.new(current_user, "sms-send-cooldown-#{phone_key}", 1, interval).performed!
      end

      max = SiteSetting.sms_max_sends_per_hour.to_i
      if max.positive?
        RateLimiter.new(current_user, "sms-send-hour", max, 1.hour).performed!
        RateLimiter.new(nil, "sms-send-phone-#{phone_key}", max, 1.hour).performed!
      end
    end

    PHONE_CHANGE_SESSION_KEY = "sms_phone_change_authorized_at"

    def phone_change_authorized?
      authorized_at = server_session[PHONE_CHANGE_SESSION_KEY].to_i
      return false if authorized_at <= 0

      Time.zone.now.to_i - authorized_at <= SiteSetting.sms_code_ttl_minutes.to_i.minutes.to_i
    end

    def authorize_phone_change!
      server_session[PHONE_CHANGE_SESSION_KEY] = Time.zone.now.to_i
    end

    def clear_phone_change_authorization!
      server_session.delete(PHONE_CHANGE_SESSION_KEY)
    end

    def render_error(key, message: nil, status: 422)
      text =
        if key == :provider_rejected
          if message.present?
            I18n.t("sms.errors.provider_rejected", message: message)
          else
            I18n.t("sms.errors.provider_rejected_generic")
          end
        else
          I18n.t("sms.errors.#{key}")
        end

      render_json_error(text, status: status)
    end
  end
end
