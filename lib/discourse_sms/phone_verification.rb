# frozen_string_literal: true

module ::DiscourseSms
  # Decides whether an account is required to bind a phone number. Staff and
  # explicitly configured groups/usernames can be exempted, as can automated
  # accounts that cannot complete an SMS challenge.
  module PhoneVerification
    module_function

    def required_for?(user)
      return false if user.nil?
      return false if !SiteSetting.sms_enabled || !SiteSetting.sms_require_phone_binding
      return false if exempt?(user)

      !PhoneBinding.verified?(user)
    end

    def exempt?(user)
      return true if user.is_system_user? || user.bot? || user.staged?
      return true if skip_group?(user)
      return true if skip_username?(user)

      false
    end

    def skip_group?(user)
      group_ids = SiteSetting.sms_skip_phone_binding_groups_map
      group_ids.present? && user.in_any_groups?(group_ids)
    end

    def skip_username?(user)
      usernames =
        SiteSetting
          .sms_skip_phone_binding_usernames
          .to_s
          .split(/[|,]/)
          .filter_map { |name| name.strip.downcase.presence }

      usernames.include?(user.username_lower)
    end
  end
end
