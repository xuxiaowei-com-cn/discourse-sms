import { withPluginApi } from "discourse/lib/plugin-api";

const SKIPPED_ROUTES = [
  "preferences.security",
  "login",
  "signup",
  "account-created",
  "activate-account",
  "password-reset",
  "confirm-email",
  "logout",
  "admin",
  "review",
  "wizard",
  "exception",
  "404",
];

function routeIsSkipped(routeName) {
  return SKIPPED_ROUTES.some(
    (name) => routeName === name || routeName.startsWith(`${name}.`)
  );
}

// When enforcement is on, keep unbound members on the page where they can
// actually bind a phone number instead of letting them browse and hit errors.
export default {
  name: "sms-phone-binding-redirect",

  initialize(container) {
    const siteSettings = container.lookup("service:site-settings");
    const router = container.lookup("service:router");

    if (
      !siteSettings.sms_enabled ||
      !siteSettings.sms_force_phone_binding_redirect
    ) {
      return;
    }

    withPluginApi((api) => {
      let redirecting = false;

      const enforce = () => {
        if (redirecting) {
          return;
        }

        const currentUser = api.getCurrentUser();
        if (!currentUser?.sms_phone_binding_required) {
          return;
        }

        const routeName = router.currentRouteName;
        if (!routeName || routeIsSkipped(routeName)) {
          return;
        }

        redirecting = true;
        Promise.resolve(
          router.transitionTo("preferences.security", currentUser.username)
        ).finally(() => {
          redirecting = false;
        });
      };

      enforce();
      api.onPageChange(enforce);
    });
  },
};
