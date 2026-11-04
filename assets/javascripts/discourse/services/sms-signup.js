import { tracked } from "@glimmer/tracking";
import Service from "@ember/service";

export default class SmsSignupService extends Service {
  @tracked phone = "";
  @tracked token = null;
  @tracked verified = false;

  setVerified(phone, token) {
    this.phone = phone;
    this.token = token;
    this.verified = Boolean(phone && token);
  }

  reset() {
    this.phone = "";
    this.token = null;
    this.verified = false;
  }
}
