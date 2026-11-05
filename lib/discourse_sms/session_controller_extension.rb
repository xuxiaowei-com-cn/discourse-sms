# frozen_string_literal: true

module ::DiscourseSms
  module SessionControllerExtension
    def verify_login_code
      return super if !DiscourseSms::Registration.required?

      return super if params[:signup_token].blank? && !sms_code_login_creates_account?

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

      if context.present? && current_user
        DiscourseSms::Registration.complete!(current_user, context)
        DiscourseSms::Registration.clear_session!(server_session)
      end
    ensure
      DiscourseSms::Registration.clear_context!
    end

    private

    def sms_code_login_creates_account?
      return false if params[:email].blank?

      User.find_by_email(params[:email].to_s).nil?
    end
  end
end
