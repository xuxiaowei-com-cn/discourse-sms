# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "openssl"

module ::DiscourseSms
  # Small HTTP client for the external SMS service. The contract is deliberately
  # provider agnostic: a JSON (or form encoded) POST with a phone number and,
  # when verifying, a code. Success can be detected from the HTTP status alone
  # or from a configurable JSON path in the response.
  class ApiClient
    class Error < StandardError; end
    class ConfigurationError < Error; end
    class UnavailableError < Error; end
    class RejectedError < Error; end

    def send_code(phone:, user: nil)
      ensure_configured!

      response =
        post(
          url_for(SiteSetting.sms_send_api_url),
          payload(phone: phone),
          label: "send_code",
          user_id: user&.id,
        )

      if response.is_a?(Net::HTTPSuccess)
        expected = SiteSetting.sms_send_success_value
        path = SiteSetting.sms_send_success_json_path
        return true if success_response?(response, path, expected)

        raise RejectedError.new(error_message(response))
      end

      if response.is_a?(Net::HTTPClientError)
        raise UnavailableError.new("HTTP #{response.code}") if response.code.to_i == 429
        if [401, 403, 404].include?(response.code.to_i)
          raise ConfigurationError.new(error_message(response) || "HTTP #{response.code}")
        end

        raise RejectedError.new(error_message(response))
      end

      raise UnavailableError.new("HTTP #{response.code}")
    end

    def verify_code(phone:, code:)
      ensure_configured!

      response =
        post(
          url_for(SiteSetting.sms_verify_api_url),
          payload(phone: phone, code: code),
          label: "verify_code",
        )

      if response.is_a?(Net::HTTPSuccess)
        return success_response?(response, SiteSetting.sms_verify_success_json_path, SiteSetting.sms_verify_success_value)
      end

      # Most providers answer 400/422 for an invalid or expired code.
      return false if [400, 422].include?(response.code.to_i)
      raise UnavailableError.new("HTTP #{response.code}") if response.code.to_i == 429

      if response.is_a?(Net::HTTPClientError)
        raise ConfigurationError.new(error_message(response) || "HTTP #{response.code}")
      end

      raise UnavailableError.new("HTTP #{response.code}")
    end

    private

    def ensure_configured!
      if SiteSetting.sms_send_api_url.blank? || SiteSetting.sms_verify_api_url.blank?
        raise ConfigurationError.new("SMS API URLs are not configured")
      end
    end

    def post(uri, data, label:, user_id: nil)
      request = Net::HTTP::Post.new(uri.request_uri)
      request["Accept"] = "application/json"
      apply_auth(request)
      apply_body(request, data)

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      response =
        Net::HTTP.start(
          uri.hostname,
          uri.port,
          use_ssl: uri.scheme == "https",
          open_timeout: timeout,
          read_timeout: timeout,
          write_timeout: timeout,
        ) { |http| http.request(request) }

      if SiteSetting.sms_debug_logging
        elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
        Rails.logger.info(
          "[discourse-sms] #{label} status=#{response.code} duration=#{elapsed}ms user_id=#{user_id}",
        )
      end

      response
    rescue Timeout::Error,
           SocketError,
           SystemCallError,
           OpenSSL::SSL::SSLError,
           Net::ProtocolError,
           Net::HTTPBadResponse,
           IOError => e
      raise UnavailableError.new(e.class.name)
    end

    def apply_auth(request)
      token = SiteSetting.sms_auth_token.to_s
      return if token.blank?

      header = SiteSetting.sms_auth_header.to_s.strip.presence || "Authorization"
      scheme = SiteSetting.sms_auth_scheme.to_s.strip
      request[header] = scheme.present? ? "#{scheme} #{token}" : token
    end

    def apply_body(request, data)
      if SiteSetting.sms_request_format == "form"
        request["Content-Type"] = "application/x-www-form-urlencoded"
        request.body = URI.encode_www_form(data)
      else
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(data)
      end
    end

    def payload(phone:, code: nil)
      phone_param = SiteSetting.sms_phone_param.to_s.strip
      code_param = SiteSetting.sms_code_param.to_s.strip

      raise ConfigurationError.new("Phone parameter name is blank") if phone_param.blank?
      raise ConfigurationError.new("Code parameter name is blank") if code && code_param.blank?

      data = extra_params
      data[phone_param] = phone
      data[code_param] = code if code
      data["purpose"] = SiteSetting.sms_purpose.to_s.strip if SiteSetting.sms_purpose.present?
      data
    end

    def extra_params
      raw = SiteSetting.sms_extra_params.to_s.strip
      return {} if raw.blank?

      parsed = JSON.parse(raw)
      raise ConfigurationError.new("Extra params must be a JSON object") if !parsed.is_a?(Hash)

      parsed.transform_keys(&:to_s)
    rescue JSON::ParserError
      raise ConfigurationError.new("Extra params must be valid JSON")
    end

    def url_for(value)
      uri = URI.parse(value.to_s)
      unless uri.is_a?(URI::HTTP) && uri.hostname.present?
        raise ConfigurationError.new("SMS API URL must be an absolute HTTP(S) URL")
      end

      uri
    rescue URI::InvalidURIError
      raise ConfigurationError.new("SMS API URL is invalid")
    end

    def timeout
      [[SiteSetting.sms_request_timeout_seconds.to_i, 1].max, 60].min
    end

    def success_response?(response, path, expected)
      return true if path.blank?

      value = json_value(response, path)
      return true if expected.blank? && value.present?
      return false if expected.blank?

      normalize(value) == normalize(expected)
    end

    def json_value(response, path)
      json = parse_json(response.body)
      return nil if json.nil?

      path.to_s.split(".").reduce(json) do |memo, key|
        break nil if memo.nil?

        if memo.is_a?(Array)
          index = Integer(key, exception: false)
          break nil if index.nil?

          memo[index]
        elsif memo.is_a?(Hash)
          memo[key]
        else
          break nil
        end
      end
    end

    def error_message(response)
      path = SiteSetting.sms_error_message_json_path.to_s.strip
      return nil if path.blank?

      value = json_value(response, path)
      value.to_s.strip.presence&.truncate(200)
    end

    def parse_json(body)
      JSON.parse(body.to_s)
    rescue JSON::ParserError
      nil
    end

    def normalize(value)
      case value
      when true
        "true"
      when false
        "false"
      when nil
        ""
      else
        value.to_s
      end
    end
  end
end
