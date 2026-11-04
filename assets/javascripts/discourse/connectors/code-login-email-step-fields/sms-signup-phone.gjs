import Component from "@glimmer/component";
import SmsSignupPhone from "../../components/sms-signup-phone";

export default class SmsCodeSignupPhone extends Component {
  get show() {
    return ["signup", "invite"].includes(this.args.outletArgs?.context);
  }

  <template>
    {{#if this.show}}
      <SmsSignupPhone />
    {{/if}}
  </template>
}
