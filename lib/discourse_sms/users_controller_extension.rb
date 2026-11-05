# frozen_string_literal: true

module ::DiscourseSms
  module UsersControllerExtension
    def create
      context = DiscourseSms::Registration.context_for(params, session: server_session)

      if context.is_a?(Hash)
        context =
          context.merge(
            ip_address: request.remote_ip,
            user_agent: request.user_agent.to_s.truncate(500),
          )
      end

      if context == false
        return(
          render json: { success: false, message: I18n.t("sms.errors.registration_phone_required") }
        )
      end

      DiscourseSms::Registration.set_context!(context)
      super

      if context.present? && sms_registration_response_success?
        user_id = session[SessionController::ACTIVATE_USER_KEY]
        user = User.find_by(id: user_id) if user_id.present?
        if user
          DiscourseSms::Registration.complete!(user, context)
          DiscourseSms::Registration.clear_session!(server_session)
        end
      end
    ensure
      DiscourseSms::Registration.clear_context!
    end

    private

    def sms_registration_response_success?
      JSON.parse(response.body.to_s)["success"] == true
    rescue JSON::ParserError, TypeError
      false
    end
  end
end
