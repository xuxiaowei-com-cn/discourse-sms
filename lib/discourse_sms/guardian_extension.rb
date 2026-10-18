# frozen_string_literal: true

module ::DiscourseSms
  module GuardianExtension
    def can_create_post?(topic)
      return false if DiscourseSms::PhoneVerification.required_for?(user)

      super
    end

    def can_create_topic?(parent)
      return false if DiscourseSms::PhoneVerification.required_for?(user)

      super
    end

    def can_send_private_messages?(notify_moderators: false)
      return false if DiscourseSms::PhoneVerification.required_for?(user)

      super
    end

    def can_send_private_message?(target, **kwargs)
      return false if DiscourseSms::PhoneVerification.required_for?(user)

      super
    end
  end
end
