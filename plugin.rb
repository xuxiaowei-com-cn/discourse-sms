# frozen_string_literal: true

# name: discourse-sms
# about: Verify and manage a user's phone number through an external SMS provider.
# version: 0.1.0
# authors: 徐晓伟
# url: https://cnb.cool/xuxiaowei.com.cn/discourse-sms
# required_version: 3.2.0

enabled_site_setting :sms_enabled

# Never write SMS codes or captcha tokens to request logs.
Rails.application.config.filter_parameters += %i[sms_phone sms_code captcha_token]

register_asset "stylesheets/common/sms-phone.scss"

module ::DiscourseSms
  PLUGIN_NAME = "discourse-sms"
end

require_relative "lib/discourse_sms/engine"

after_initialize do
  require_relative "app/models/discourse_sms/phone_binding"
  require_relative "app/models/discourse_sms/phone_history"
  require_relative "app/models/discourse_sms/verification_challenge"
  require_relative "lib/discourse_sms/phone_verification"
  require_relative "lib/discourse_sms/guardian_extension"

  reloadable_patch { Guardian.prepend(DiscourseSms::GuardianExtension) }

  add_to_serializer(
    :current_user,
    :sms_phone_verified,
    include_condition: -> { SiteSetting.sms_enabled },
  ) { DiscourseSms::PhoneBinding.exists?(user_id: object.id) }

  add_to_serializer(
    :current_user,
    :sms_phone_masked,
    include_condition: -> { SiteSetting.sms_enabled },
  ) { DiscourseSms::PhoneBinding.find_by(user_id: object.id)&.masked_phone }

  add_to_serializer(
    :current_user,
    :sms_phone_binding_required,
    include_condition: -> { SiteSetting.sms_enabled },
  ) { DiscourseSms::PhoneVerification.required_for?(object) }

  add_to_serializer(
    :admin_detailed_user,
    :sms_phone_verified,
    include_condition: -> { SiteSetting.sms_enabled },
  ) { DiscourseSms::PhoneBinding.exists?(user_id: object.id) }

  # Do not keep phone numbers around after an account is removed or anonymized.
  on(:user_destroyed) do |user|
    DiscourseSms::PhoneBinding.where(user_id: user.id).delete_all
    DiscourseSms::PhoneHistory.where(user_id: user.id).delete_all
    DiscourseSms::VerificationChallenge.where(user_id: user.id).delete_all
  end

  on(:user_anonymized) do |user:, **|
    DiscourseSms::PhoneBinding.where(user_id: user.id).delete_all
    DiscourseSms::PhoneHistory.where(user_id: user.id).delete_all
    DiscourseSms::VerificationChallenge.where(user_id: user.id).delete_all
  end
end
