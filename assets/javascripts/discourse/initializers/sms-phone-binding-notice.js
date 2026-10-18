import getURL from "discourse/lib/get-url";
import { withPluginApi } from "discourse/lib/plugin-api";
import { i18n } from "discourse-i18n";

let noticeAdded = false;

export default {
  name: "sms-phone-binding-notice",

  initialize() {
    withPluginApi((api) => {
      const maybeAddNotice = () => {
        if (noticeAdded) {
          return;
        }

        const currentUser = api.getCurrentUser();
        if (!currentUser?.sms_phone_binding_required) {
          return;
        }

        const url = getURL(
          `/u/${encodeURIComponent(currentUser.username)}/preferences/security`
        );

        api.addGlobalNotice(
          i18n("sms.binding_required.notice"),
          "sms-phone-binding-required",
          {
            html: `<a href="${url}">${i18n("sms.binding_required.link")}</a>`,
            level: "warning",
            dismissable: false,
          }
        );

        noticeAdded = true;
      };

      maybeAddNotice();
      api.onPageChange(maybeAddNotice);
    });
  },
};
