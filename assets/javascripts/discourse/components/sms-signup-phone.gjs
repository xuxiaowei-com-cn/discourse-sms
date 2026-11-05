import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { modifier } from "ember-modifier";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import loadScript from "discourse/lib/load-script";
import { i18n } from "discourse-i18n";

const CAPTCHA_CALLBACK = "discourseSmsSignupCaptchaLoaded";
const CAPTCHA_LOAD_TIMEOUT = 15000;
const HCAPTCHA_PROVIDER = "hcaptcha";
const RECAPTCHA_V2_PROVIDER = "recaptcha_v2";
const RECAPTCHA_V3_PROVIDER = "recaptcha_v3";

export default class SmsSignupPhone extends Component {
  @service siteSettings;
  @service smsSignup;

  @tracked phone = "";
  @tracked code = "";
  @tracked codeSent = false;
  @tracked sending = false;
  @tracked verifying = false;
  @tracked error = null;
  @tracked success = null;
  @tracked resendRemaining = 0;
  @tracked captchaToken = null;
  @tracked captchaLoadFailed = false;

  gateContinue = modifier((element, [verified]) => {
    const form = element.closest("form");
    let button = null;
    let frame = null;
    let onSubmit = null;

    const bind = () => {
      button =
        form?.querySelector(".code-login-form__continue") ||
        document.querySelector(".signup-page-cta__signup");

      if (!button) {
        if (form || document.querySelector(".signup-page-cta")) {
          frame = requestAnimationFrame(bind);
        }
        return;
      }

      onSubmit = (event) => {
        if (!verified) {
          event.preventDefault();
          event.stopPropagation();
        }
      };

      button.disabled = !verified;
      button.title = verified ? "" : i18n("sms.signup.verify_before_continue");
      form?.addEventListener("submit", onSubmit, true);
    };

    bind();

    return () => {
      cancelAnimationFrame(frame);
      if (onSubmit) {
        form?.removeEventListener("submit", onSubmit, true);
      }
      if (button) {
        button.disabled = false;
        button.title = "";
      }
    };
  });
  renderCaptcha = modifier((element) => {
    if (!this.showCaptchaWidget || !this.captchaConfigured) {
      return;
    }

    let cancelled = false;
    this.#renderCaptchaWidget(element).catch(() => {
      if (!cancelled) {
        this.captchaLoadFailed = true;
      }
    });

    return () => {
      cancelled = true;
      this.#teardownCaptchaWidget();
    };
  });
  #captchaWidgetId = null;
  #captchaScriptPromise = null;
  #cooldownTimer = null;

  willDestroy() {
    clearInterval(this.#cooldownTimer);
    this.#teardownCaptchaWidget();
    super.willDestroy(...arguments);
  }

  get enabled() {
    return Boolean(
      this.siteSettings.sms_enabled &&
      this.siteSettings.sms_require_phone_on_signup
    );
  }

  get verified() {
    return this.smsSignup.verified;
  }

  get captchaProvider() {
    if (!this.siteSettings.discourse_captcha_enabled) {
      return null;
    }

    const provider = this.siteSettings.discourse_captcha_provider;
    return [
      HCAPTCHA_PROVIDER,
      RECAPTCHA_V2_PROVIDER,
      RECAPTCHA_V3_PROVIDER,
    ].includes(provider)
      ? provider
      : null;
  }

  get captchaSiteKey() {
    switch (this.captchaProvider) {
      case HCAPTCHA_PROVIDER:
        return this.siteSettings.hcaptcha_site_key;
      case RECAPTCHA_V2_PROVIDER:
        return this.siteSettings.recaptcha_v2_site_key;
      case RECAPTCHA_V3_PROVIDER:
        return this.siteSettings.recaptcha_v3_site_key;
      default:
        return null;
    }
  }

  get captchaRequired() {
    return Boolean(this.siteSettings.sms_require_captcha);
  }

  get captchaConfigured() {
    return (
      !this.captchaRequired ||
      Boolean(this.captchaProvider && this.captchaSiteKey)
    );
  }

  get showCaptchaWidget() {
    return (
      this.captchaRequired &&
      (this.captchaProvider === HCAPTCHA_PROVIDER ||
        this.captchaProvider === RECAPTCHA_V2_PROVIDER)
    );
  }

  get captchaApiName() {
    return this.captchaProvider === HCAPTCHA_PROVIDER
      ? "hcaptcha"
      : "grecaptcha";
  }

  get sendDisabled() {
    return (
      this.sending ||
      this.resendRemaining > 0 ||
      !this.phone.trim() ||
      !this.captchaConfigured
    );
  }

  get verifyDisabled() {
    return this.verifying || !this.code.trim();
  }

  @action
  onPhoneInput(event) {
    this.phone = event.target.value;
    this.error = null;
    this.success = null;
    this.smsSignup.reset();
  }

  @action
  onCodeInput(event) {
    this.code = event.target.value;
    this.error = null;
  }

  @action
  changePhone() {
    this.smsSignup.reset();
    this.phone = "";
    this.code = "";
    this.codeSent = false;
    this.error = null;
    this.success = null;
    this.#resetCaptchaWidget();
  }

  @action
  async sendCode(event) {
    event?.preventDefault?.();

    if (this.sending || this.resendRemaining > 0) {
      return;
    }

    if (this.captchaRequired && !this.captchaConfigured) {
      this.error = i18n("sms.captcha.unavailable");
      return;
    }

    if (!this.phone.trim()) {
      this.error = i18n("sms.errors.phone_invalid");
      return;
    }

    this.sending = true;
    this.error = null;
    this.success = null;

    try {
      let token = null;

      if (this.captchaRequired) {
        token = await this.#obtainCaptchaToken();
        if (!token) {
          this.error = this.captchaLoadFailed
            ? i18n("sms.captcha.load_failed")
            : i18n("sms.captcha.required");
          return;
        }

        this.captchaLoadFailed = false;
      }

      const data = { sms_phone: this.phone.trim() };
      if (token) {
        data.captcha_token = token;
      }

      const result = await ajax("/sms/registration/send_code.json", {
        type: "POST",
        data,
      });

      this.codeSent = true;
      this.success = i18n("sms.success.code_sent");
      this.#startCooldown(result.resend_after);
      this.#resetCaptchaWidget();
    } catch (error) {
      this.error = this.#errorMessage(error);
      this.#resetCaptchaWidget();
    } finally {
      this.sending = false;
    }
  }

  @action
  async verifyCode(event) {
    event?.preventDefault?.();

    if (this.verifying || this.sending) {
      return;
    }

    if (!this.code.trim()) {
      this.error = i18n("sms.errors.code_required");
      return;
    }

    this.verifying = true;
    this.error = null;
    this.success = null;

    try {
      const result = await ajax("/sms/registration/verify_code.json", {
        type: "POST",
        data: {
          sms_phone: this.phone.trim(),
          sms_code: this.code.trim(),
        },
      });

      this.smsSignup.setVerified(
        result.phone_number,
        result.registration_token
      );
      this.codeSent = false;
      this.code = "";
      this.success = i18n("sms.signup.verified");
      this.#resetCaptchaWidget();
    } catch (error) {
      this.error = extractError(error, i18n("sms.errors.generic"));
    } finally {
      this.verifying = false;
    }
  }

  #errorMessage(error) {
    if (this.captchaLoadFailed) {
      return i18n("sms.captcha.load_failed");
    }

    return extractError(error, i18n("sms.errors.generic"));
  }

  async #obtainCaptchaToken() {
    if (this.captchaProvider === RECAPTCHA_V3_PROVIDER) {
      try {
        const api = await this.#ensureCaptchaApi();
        await new Promise((resolve) => api.ready(resolve));
        return await api.execute(this.captchaSiteKey, { action: "signup" });
      } catch {
        this.captchaLoadFailed = true;
        return null;
      }
    }

    return this.captchaToken;
  }

  async #ensureCaptchaApi() {
    const api = window[this.captchaApiName];
    if (api) {
      return api;
    }

    if (!this.#captchaScriptPromise) {
      this.#captchaScriptPromise = this.#loadCaptchaScript().catch((error) => {
        this.#captchaScriptPromise = null;
        throw error;
      });
    }

    return this.#captchaScriptPromise;
  }

  #loadCaptchaScript() {
    const apiName = this.captchaApiName;

    return new Promise((resolve, reject) => {
      const previousCallback = window[CAPTCHA_CALLBACK];
      let settled = false;
      let poll;
      let timeout;

      const cleanup = () => {
        clearInterval(poll);
        clearTimeout(timeout);

        if (previousCallback) {
          window[CAPTCHA_CALLBACK] = previousCallback;
        } else {
          delete window[CAPTCHA_CALLBACK];
        }
      };

      const succeed = () => {
        if (settled || !window[apiName]) {
          return;
        }

        settled = true;
        cleanup();
        resolve(window[apiName]);
      };

      const fail = (error) => {
        if (settled) {
          return;
        }

        settled = true;
        cleanup();
        reject(error);
      };

      window[CAPTCHA_CALLBACK] = succeed;
      poll = setInterval(() => {
        if (window[apiName]) {
          succeed();
        }
      }, 100);
      timeout = setTimeout(
        () => fail(new Error("Captcha load timed out")),
        CAPTCHA_LOAD_TIMEOUT
      );

      loadScript(this.#captchaScriptUrl()).catch(fail);
    });
  }

  #captchaScriptUrl() {
    const callback = encodeURIComponent(CAPTCHA_CALLBACK);

    switch (this.captchaProvider) {
      case HCAPTCHA_PROVIDER:
        return `https://js.hcaptcha.com/1/api.js?onload=${callback}&render=explicit`;
      case RECAPTCHA_V2_PROVIDER:
        return `https://www.google.com/recaptcha/api.js?onload=${callback}&render=explicit`;
      case RECAPTCHA_V3_PROVIDER:
        return `https://www.google.com/recaptcha/api.js?onload=${callback}&render=${encodeURIComponent(
          this.captchaSiteKey
        )}`;
      default:
        return null;
    }
  }

  async #renderCaptchaWidget(element) {
    const api = await this.#ensureCaptchaApi();
    if (!element?.isConnected) {
      return;
    }

    this.captchaToken = null;
    this.#captchaWidgetId = api.render(element, {
      sitekey: this.captchaSiteKey,
      callback: (token) => {
        this.captchaToken = token;
        this.error = null;
      },
      "expired-callback": () => {
        this.captchaToken = null;
      },
      "error-callback": () => {
        this.captchaToken = null;
        this.captchaLoadFailed = true;
      },
    });
  }

  #resetCaptchaWidget() {
    const api = window[this.captchaApiName];
    if (api?.reset && this.#captchaWidgetId !== null) {
      try {
        api.reset(this.#captchaWidgetId);
      } catch {
        // The widget may already have been removed with the form.
      }
    }

    this.captchaToken = null;
  }

  #teardownCaptchaWidget() {
    this.#resetCaptchaWidget();
    this.#captchaWidgetId = null;
  }

  #startCooldown(seconds) {
    const duration = Number.parseInt(seconds, 10) || 0;

    clearInterval(this.#cooldownTimer);
    this.resendRemaining = Math.max(duration, 0);

    if (this.resendRemaining === 0) {
      return;
    }

    this.#cooldownTimer = setInterval(() => {
      this.resendRemaining = Math.max(this.resendRemaining - 1, 0);

      if (this.resendRemaining === 0) {
        clearInterval(this.#cooldownTimer);
      }
    }, 1000);
  }

  <template>
    {{#if this.enabled}}
      <div
        class="create-account__sms-phone"
        data-setting-name="signup-sms-phone"
      >
        <label class="control-label" for="sms-signup-phone">
          {{i18n "sms.signup.title"}}
        </label>
        <div class="instructions">{{i18n "sms.signup.description"}}</div>

        {{#if this.verified}}
          <div class="sms-phone-status">
            <span class="sms-phone-number">{{this.smsSignup.phone}}</span>
            <span class="sms-phone-badge">{{i18n "sms.status.verified"}}</span>
          </div>
          <div class="instructions">{{i18n "sms.signup.verified"}}</div>
          <button
            type="button"
            class="btn btn-flat"
            {{on "click" this.changePhone}}
          >
            {{i18n "sms.change"}}
          </button>
        {{else}}
          <input
            id="sms-signup-phone"
            class="input-large sms-phone-input"
            type="tel"
            autocomplete="tel"
            disabled={{this.codeSent}}
            placeholder={{i18n "sms.phone_placeholder"}}
            value={{this.phone}}
            {{on "input" this.onPhoneInput}}
          />
          <div class="instructions">{{i18n "sms.phone_hint"}}</div>

          {{#if this.captchaRequired}}
            {{#if this.captchaConfigured}}
              {{#if this.showCaptchaWidget}}
                <div class="sms-captcha">
                  <div class="sms-captcha-widget" {{this.renderCaptcha}}></div>
                  <div class="instructions">{{i18n "sms.captcha.hint"}}</div>
                </div>
              {{/if}}
              {{#if this.captchaLoadFailed}}
                <div class="alert alert-error">
                  {{i18n "sms.captcha.load_failed"}}
                </div>
              {{/if}}
            {{else}}
              <div class="alert alert-error">
                {{i18n "sms.captcha.unavailable"}}
              </div>
            {{/if}}
          {{/if}}

          <div class="sms-phone-actions">
            <button
              type="button"
              class="btn btn-primary"
              disabled={{this.sendDisabled}}
              {{on "click" this.sendCode}}
            >
              {{#if this.sending}}
                {{i18n "sms.sending"}}
              {{else if this.resendRemaining}}
                {{i18n "sms.resend_in" seconds=this.resendRemaining}}
              {{else}}
                {{i18n "sms.send_code"}}
              {{/if}}
            </button>
          </div>

          {{#if this.codeSent}}
            <div class="sms-code-form">
              <label class="control-label" for="sms-signup-code">
                {{i18n "sms.code_label"}}
              </label>
              <input
                id="sms-signup-code"
                class="input-medium"
                type="text"
                autocomplete="one-time-code"
                placeholder={{i18n "sms.code_placeholder"}}
                value={{this.code}}
                {{on "input" this.onCodeInput}}
              />

              <button
                type="button"
                class="btn btn-primary"
                disabled={{this.verifyDisabled}}
                {{on "click" this.verifyCode}}
              >
                {{#if this.verifying}}
                  {{i18n "sms.verifying"}}
                {{else}}
                  {{i18n "sms.verify"}}
                {{/if}}
              </button>
            </div>
          {{/if}}
        {{/if}}

        <span
          class="sms-signup-continue-gate"
          style="display: none"
          {{this.gateContinue this.smsSignup.verified}}
        ></span>

        {{#if this.error}}
          <div class="alert alert-error">{{this.error}}</div>
        {{/if}}
        {{#if this.success}}
          <div class="alert alert-success">{{this.success}}</div>
        {{/if}}
      </div>
    {{/if}}
  </template>
}
