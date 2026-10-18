# frozen_string_literal: true

require "digest"

module ::DiscourseSms
  class SmsController < ::ApplicationController
    requires_plugin PLUGIN_NAME

    before_action :ensure_logged_in
    before_action :ensure_admin, only: :user_status

    def status
      render json: binding_json(PhoneBinding.for_user(current_user))
    end

    def user_status
      user = User.find_by(username_lower: params[:username].to_s.downcase)
      raise Discourse::NotFound if user.nil?

      binding = PhoneBinding.for_user(user)
      render json: binding_json(binding).merge(
               username: user.username,
               phone_number: binding&.phone_number,
             )
    end

    def send_code
      phone =
        PhoneNumber.normalize(
          params[:sms_phone],
          default_country_code: SiteSetting.sms_default_country_code,
        )
      return render_error(:phone_invalid) if phone.nil?

      if SiteSetting.sms_require_captcha
        begin
          Captcha.verify!(params[:captcha_token], remote_ip: request.remote_ip)
        rescue Captcha::NotConfigured
          return render_error(:captcha_not_configured)
        rescue Captcha::VerificationFailed
          return render_error(:captcha_failed)
        rescue Captcha::Unavailable
          return render_error(:captcha_unavailable)
        end
      end

      existing = PhoneBinding.find_by(phone_number: phone)
      return render_error(:phone_taken) if existing && existing.user_id != current_user.id

      enforce_send_rate_limits!(phone)

      ttl = SiteSetting.sms_code_ttl_minutes.to_i.minutes
      challenge = VerificationChallenge.issue!(user: current_user, phone_number: phone, ttl: ttl)

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
               masked_phone: PhoneNumber.mask(phone),
               expires_in: ttl.to_i,
               resend_after: SiteSetting.sms_resend_interval_seconds.to_i,
             }
    end

    def verify_code
      code = params[:sms_code].to_s.strip
      return render_error(:code_invalid_format) if !code.match?(/\A[A-Za-z0-9]{4,20}\z/)

      challenge = VerificationChallenge.find_by(user_id: current_user.id)
      return render_error(:code_not_requested) if challenge.nil?
      return render_error(:code_expired) if challenge.expired?
      return render_error(:too_many_attempts) if challenge.attempts_exhausted?

      RateLimiter.new(current_user, "sms-verify-hour", 60, 1.hour).performed!

      challenge.with_lock do
        return render_error(:code_expired) if challenge.expired?
        return render_error(:too_many_attempts) if challenge.attempts_exhausted?

        which = verify_with_provider(challenge.phone_number, code)
        return which if performed?

        if which == true
          bind_phone!(challenge)
        else
          challenge.increment!(:attempts)
          render_error(:code_invalid)
        end
      end
    end

    private

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
      binding.phone_number = challenge.phone_number
      binding.verified_at = Time.zone.now

      PhoneBinding.transaction do
        binding.save!
        challenge.destroy!
      end

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
      interval = SiteSetting.sms_resend_interval_seconds.to_i
      if interval.positive?
        RateLimiter.new(current_user, "sms-send-cooldown", 1, interval).performed!
      end

      max = SiteSetting.sms_max_sends_per_hour.to_i
      if max.positive?
        RateLimiter.new(current_user, "sms-send-hour", max, 1.hour).performed!
        phone_key = Digest::SHA256.hexdigest(phone)
        RateLimiter.new(nil, "sms-send-phone-#{phone_key}", max, 1.hour).performed!
      end
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
