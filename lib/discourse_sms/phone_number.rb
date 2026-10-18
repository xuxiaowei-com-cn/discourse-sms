# frozen_string_literal: true

module ::DiscourseSms
  # Normalizes user supplied phone numbers to E.164. The plugin only stores
  # E.164 numbers so that changing the default country code later cannot
  # silently reinterpret a number that was already verified.
  module PhoneNumber
    DEFAULT_COUNTRY_CODE = "86"
    E164_REGEX = /\A[1-9]\d{7,14}\z/

    module_function

    def normalize(raw, default_country_code: DEFAULT_COUNTRY_CODE)
      value = raw.to_s.strip
      return nil if value.blank?

      value = value.gsub(/[\s\-().\/]/, "")

      if value.start_with?("00")
        digits = value.delete_prefix("00")
        return nil unless digits.match?(/\A\d+\z/)
      elsif value.start_with?("+")
        digits = value.delete_prefix("+")
        return nil unless digits.match?(/\A\d+\z/)
      else
        digits = value
        return nil unless digits.match?(/\A\d+\z/)

        country_code = default_country_code.to_s.gsub(/\D/, "").sub(/\A0+/, "")
        return nil if country_code.blank?

        digits = country_code + digits unless digits.start_with?(country_code)
      end

      return nil unless digits.match?(E164_REGEX)

      "+#{digits}"
    end

    def valid?(phone)
      phone.to_s.delete_prefix("+").match?(E164_REGEX) && phone.to_s.start_with?("+")
    end

    def mask(phone)
      return nil if phone.blank?

      digits = phone.to_s.delete_prefix("+")
      return phone if digits.length < 8

      "+#{digits[0, 4]}****#{digits[-4, 4]}"
    end
  end
end
