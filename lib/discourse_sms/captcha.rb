# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "openssl"

module ::DiscourseSms
  # Verifies a captcha token with the provider configured in the official
  # discourse-captcha plugin. Sending an SMS is refused unless captcha support
  # is both enabled and fully configured.
  class Captcha
    class Error < StandardError; end
    class NotConfigured < Error; end
    class VerificationFailed < Error; end
    class Unavailable < Error; end

    HCAPTCHA = "hcaptcha"
    RECAPTCHA_V2 = "recaptcha_v2"
    RECAPTCHA_V3 = "recaptcha_v3"
    RECAPTCHA_ACTION = "signup"
    HCAPTCHA_VERIFY_URL = "https://hcaptcha.com/siteverify"
    RECAPTCHA_VERIFY_URL = "https://www.google.com/recaptcha/api/siteverify"
    TIMEOUT_SECONDS = 5

    class << self
      def enabled?
        SiteSetting.respond_to?(:discourse_captcha_enabled) &&
          SiteSetting.discourse_captcha_enabled &&
          provider.in?([HCAPTCHA, RECAPTCHA_V2, RECAPTCHA_V3])
      end

      def provider
        return nil unless SiteSetting.respond_to?(:discourse_captcha_provider)

        SiteSetting.discourse_captcha_provider.to_s
      end

      def verify!(token, remote_ip: nil)
        raise NotConfigured if !enabled?
        raise VerificationFailed if token.blank?

        secret, url, site_key = configuration
        raise NotConfigured if secret.blank? || site_key.blank?

        response = post_verification(url, secret, token, remote_ip)
        raise Unavailable if !response.is_a?(Net::HTTPSuccess)

        json = parse_json(response.body)
        raise Unavailable if json.nil?
        raise VerificationFailed if json["success"] != true

        verify_recaptcha_v3!(json) if provider == RECAPTCHA_V3

        true
      end

      private

      def configuration
        case provider
        when HCAPTCHA
          [
            SiteSetting.hcaptcha_secret_key,
            HCAPTCHA_VERIFY_URL,
            SiteSetting.hcaptcha_site_key,
          ]
        when RECAPTCHA_V2
          [
            SiteSetting.recaptcha_v2_secret_key,
            RECAPTCHA_VERIFY_URL,
            SiteSetting.recaptcha_v2_site_key,
          ]
        when RECAPTCHA_V3
          [
            SiteSetting.recaptcha_v3_secret_key,
            RECAPTCHA_VERIFY_URL,
            SiteSetting.recaptcha_v3_site_key,
          ]
        else
          raise NotConfigured
        end
      end

      def verify_recaptcha_v3!(json)
        raise VerificationFailed if json["action"] != RECAPTCHA_ACTION

        threshold =
          if SiteSetting.respond_to?(:recaptcha_v3_score_threshold)
            SiteSetting.recaptcha_v3_score_threshold.to_f
          else
            0.5
          end

        score = json["score"]
        raise VerificationFailed if !score.is_a?(Numeric) || score < threshold
      end

      def post_verification(url, secret, token, remote_ip)
        uri = URI.parse(url)
        params = { "secret" => secret.to_s, "response" => token.to_s }
        params["remoteip"] = remote_ip.to_s if remote_ip.present?

        Net::HTTP.start(
          uri.hostname,
          uri.port,
          use_ssl: uri.scheme == "https",
          open_timeout: TIMEOUT_SECONDS,
          read_timeout: TIMEOUT_SECONDS,
          write_timeout: TIMEOUT_SECONDS,
        ) do |http|
          request = Net::HTTP::Post.new(uri.request_uri)
          request.set_form_data(params)
          http.request(request)
        end
      rescue Timeout::Error,
             SocketError,
             SystemCallError,
             OpenSSL::SSL::SSLError,
             Net::ProtocolError,
             Net::HTTPBadResponse,
             IOError
        raise Unavailable
      end

      def parse_json(body)
        JSON.parse(body.to_s)
      rescue JSON::ParserError
        nil
      end
    end
  end
end
