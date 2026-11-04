import { withPluginApi } from "discourse/lib/plugin-api";
import { i18n } from "discourse-i18n";

// Adds the verified phone number and one-time token to the signup payload.
// The server rejects registration when the token is missing or invalid.
export default {
  name: "sms-signup",
  before: "inject-discourse-objects",

  initialize(container) {
    const siteSettings = container.lookup("service:site-settings");
    if (
      !siteSettings.sms_enabled ||
      !siteSettings.sms_require_phone_on_signup
    ) {
      return;
    }

    withPluginApi((api) => {
      if (typeof api.registerBehaviorTransformer !== "function") {
        // eslint-disable-next-line no-console
        console.warn(
          "[discourse-sms] this Discourse version does not support create-account behavior transformers"
        );
        return;
      }

      api.registerBehaviorTransformer(
        "create-account",
        async ({ next, context }) => {
          const smsSignup = container.lookup("service:sms-signup");

          if (!smsSignup.verified || !smsSignup.token || !smsSignup.phone) {
            return {
              success: false,
              message: i18n("sms.signup.verification_required"),
            };
          }

          if (context.data) {
            context.data.sms_phone = smsSignup.phone;
            context.data.sms_registration_token = smsSignup.token;
          }

          // The email-code signup flow does not pass request data to this
          // transformer. The server validates the token from the session
          // instead, because /sms/registration/verify_code stored it there.
          return next();
        }
      );
    });
  },
};
