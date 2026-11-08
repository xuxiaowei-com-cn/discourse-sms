import { withPluginApi } from "discourse/lib/plugin-api";
import { emailValid } from "discourse/lib/utilities";
import { i18n } from "discourse-i18n";

// Invite links with a locked email skip the normal email step, which also
// skips the phone verification outlet. When phone verification is required,
// render the normal email step so the phone section is available before the
// email code is requested.
export default {
  name: "sms-invite-phone",

  initialize(container) {
    const siteSettings = container.lookup("service:site-settings");

    if (
      !siteSettings.sms_enabled ||
      !siteSettings.sms_require_phone_on_signup
    ) {
      return;
    }

    withPluginApi((api) => {
      api.modifyClass("component:code-login-form", {
        pluginId: "discourse-sms",

        get isInviteEmailLocked() {
          return Boolean(
            this.args.context === "invite" &&
            this.args.emailLocked &&
            !this.siteSettings.sms_require_phone_on_signup
          );
        },

        validateEmail(name, value, { addError }) {
          // Invite links may expose only a masked email to the browser. The
          // server resolves the real address from the invite token.
          if (
            value?.includes("*") ||
            (this.args?.context === "invite" &&
              this.siteSettings?.sms_require_phone_on_signup)
          ) {
            return;
          }

          if (value && !emailValid(value)) {
            addError("email", {
              title: i18n("code_login.email_label"),
              message: i18n("user.email.invalid"),
            });
          }
        },
      });
    });
  },
};
