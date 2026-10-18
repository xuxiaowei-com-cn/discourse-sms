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

const CAPTCHA_CALLBACK = "discourseSmsCaptchaLoaded";
const CAPTCHA_LOAD_TIMEOUT = 15000;
const HCAPTCHA_PROVIDER = "hcaptcha";
const RECAPTCHA_V2_PROVIDER = "recaptcha_v2";
const RECAPTCHA_V3_PROVIDER = "recaptcha_v3";

export default class SmsPhoneForm extends Component {
  @service siteSettings;
  @service currentUser;

  @tracked loading = true;
  @tracked binding = { bound: false };
  @tracked editing = false;
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

  constructor() {
    super(...arguments);
    this.loadStatus();
  }

  willDestroy() {
    clearInterval(this.#cooldownTimer);
    this.#teardownCaptchaWidget();
    super.willDestroy(...arguments);
  }

  get enabled() {
    return Boolean(this.siteSettings.sms_enabled);
  }

  get canManage() {
    return Boolean(
      this.currentUser?.id && this.args.model?.id === this.currentUser.id
    );
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

  get captchaConfigured() {
    return Boolean(this.captchaProvider && this.captchaSiteKey);
  }

  get showCaptchaWidget() {
    return (
      this.captchaProvider === HCAPTCHA_PROVIDER ||
      this.captchaProvider === RECAPTCHA_V2_PROVIDER
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
  async loadStatus() {
    if (!this.enabled) {
      this.loading = false;
      return;
    }

    try {
      this.binding = await ajax("/sms/status.json");
    } catch (error) {
      this.error = extractError(error, i18n("sms.errors.generic"));
    } finally {
      this.loading = false;
    }
  }

  @action
  startEditing() {
    this.editing = true;
    this.phone = "";
    this.code = "";
    this.codeSent = false;
    this.error = null;
    this.success = null;
    this.captchaToken = null;
    this.captchaLoadFailed = false;

    if (this.captchaProvider === RECAPTCHA_V3_PROVIDER) {
      this.#ensureCaptchaApi().catch(() => {
        this.captchaLoadFailed = true;
      });
    }
  }

  @action
  cancelEditing() {
    this.editing = false;
    this.phone = "";
    this.code = "";
    this.codeSent = false;
    this.error = null;
    this.success = null;
    this.#resetCaptchaWidget();
  }

  @action
  onPhoneInput(event) {
    this.phone = event.target.value;
    this.error = null;
  }

  @action
  onCodeInput(event) {
    this.code = event.target.value;
    this.error = null;
  }

  @action
  async sendCode(event) {
    event?.preventDefault?.();

    if (this.sending || this.verifying || this.resendRemaining > 0) {
      return;
    }

    if (!this.captchaConfigured) {
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
      const token = await this.#obtainCaptchaToken();
      if (!token) {
        this.error = this.captchaLoadFailed
          ? i18n("sms.captcha.load_failed")
          : i18n("sms.captcha.required");
        return;
      }

      this.captchaLoadFailed = false;

      const result = await ajax("/sms/send_code.json", {
        type: "POST",
        data: {
          sms_phone: this.phone.trim(),
          captcha_token: token,
        },
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
      this.binding = await ajax("/sms/verify_code.json", {
        type: "POST",
        data: { sms_code: this.code.trim() },
      });

      this.editing = false;
      this.codeSent = false;
      this.code = "";
      this.phone = "";
      this.success = i18n("sms.success.verified");
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
      {{#if this.canManage}}
        <div
          class="control-group pref-sms-phone"
          data-setting-name="user-sms-phone"
        >
          <label class="control-label">{{i18n "sms.title"}}</label>
          <div class="instructions">{{i18n "sms.description"}}</div>

          <div class="controls">
            {{#if this.loading}}
              <div class="sms-phone-loading">{{i18n "loading"}}</div>
            {{else}}
              {{#if this.binding.bound}}
                <div class="sms-phone-status">
                  <span
                    class="sms-phone-number"
                  >{{this.binding.masked_phone}}</span>
                  <span class="sms-phone-badge">{{i18n
                      "sms.status.verified"
                    }}</span>
                </div>
              {{else}}
                <div class="sms-phone-status sms-phone-status--empty">
                  {{i18n "sms.not_bound"}}
                </div>
              {{/if}}

              {{#unless this.editing}}
                <button
                  type="button"
                  class="btn btn-default"
                  {{on "click" this.startEditing}}
                >
                  {{#if this.binding.bound}}
                    {{i18n "sms.change"}}
                  {{else}}
                    {{i18n "sms.bind"}}
                  {{/if}}
                </button>
              {{/unless}}

              {{#if this.error}}
                <div class="alert alert-error">{{this.error}}</div>
              {{/if}}
              {{#if this.success}}
                <div class="alert alert-success">{{this.success}}</div>
              {{/if}}

              {{#if this.editing}}
                <div class="sms-phone-form">
                  <label class="control-label" for="sms-phone-number">
                    {{i18n "sms.phone_label"}}
                  </label>
                  <input
                    id="sms-phone-number"
                    class="input-large"
                    type="tel"
                    autocomplete="tel"
                    disabled={{this.codeSent}}
                    placeholder={{i18n "sms.phone_placeholder"}}
                    value={{this.phone}}
                    {{on "input" this.onPhoneInput}}
                  />
                  <div class="instructions">{{i18n "sms.phone_hint"}}</div>

                  {{#if this.captchaConfigured}}
                    {{#if this.showCaptchaWidget}}
                      <div class="sms-captcha">
                        <div
                          class="sms-captcha-widget"
                          {{this.renderCaptcha}}
                        ></div>
                        <div class="instructions">{{i18n
                            "sms.captcha.hint"
                          }}</div>
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

                    <button
                      type="button"
                      class="btn btn-flat"
                      {{on "click" this.cancelEditing}}
                    >
                      {{i18n "sms.cancel"}}
                    </button>
                  </div>

                  {{#if this.codeSent}}
                    <div class="sms-code-form">
                      <label class="control-label" for="sms-verification-code">
                        {{i18n "sms.code_label"}}
                      </label>
                      <input
                        id="sms-verification-code"
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
                </div>
              {{/if}}
            {{/if}}
          </div>
        </div>
      {{/if}}
    {{/if}}
  </template>
}
