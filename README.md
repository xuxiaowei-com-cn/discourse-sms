<p align="center"><a href="README.md">English</a> | <a href="README-zh.md">中文</a></p>

# discourse-sms

A Discourse plugin that links a verified phone number to a member account through **any**
external SMS provider. The provider contract is intentionally small: one API to send a code and
one API to verify it.

> [!IMPORTANT]
> By default, sending an SMS code requires the official
> [`discourse-captcha`](https://meta.discourse.org/t/discourse-captcha/291383) plugin to be enabled
> and configured with hCaptcha, reCAPTCHA v2, or reCAPTCHA v3. The requirement can be turned off
> with the `sms require captcha` setting, but keeping it enabled is strongly recommended to prevent
> SMS abuse.

## Features

- Bind, verify, and change a phone number from **Preferences → Security**.
- Store only E.164 phone numbers (for example `+8613800138000`).
- One verified phone number per account and one account per phone number.
- Show a masked phone number after verification.
- Configurable country code for members who type a number without `+`.
- Captcha is required by default whenever a verification code is sent, and can be turned off by an administrator.
- Optionally require phone binding before creating topics, replies, or private messages, with group and username exemptions.
- Rate limits: resend cooldown, sends per account per hour, and sends per phone number per hour.
- Verification challenges with a TTL and a limited number of attempts.
- Provider authentication with a bearer token (or a custom header/scheme).
- Provider success detection through HTTP status or a configurable JSON path.
- Server-side verification only: the provider token is never exposed to the browser.
- Binding data is removed when a user is destroyed or anonymized.

## Requirements

| Requirement | Details |
| --- | --- |
| Discourse | 3.2 or newer |
| Captcha | The bundled `discourse-captcha` plugin, enabled with a configured provider (required while `sms require captcha` is on, which is the default) |
| SMS service | Two HTTP APIs: send a code and verify a code |
| Ruby / Rails | Provided by Discourse |

## How it works

1. A signed-in member opens **Preferences → Security** and chooses **Link phone number**.
2. The browser renders the configured captcha (unless the requirement is disabled) and sends the
   phone number plus the captcha token to `POST /sms/send_code`.
3. When required, the server verifies the captcha with the provider. It then applies rate limits and
   calls the external **send** API.
4. A verification challenge is stored for that account (the SMS code itself is never stored by
   Discourse).
5. The member enters the code from the SMS. The browser calls `POST /sms/verify_code`.
6. The server calls the external **verify** API. On success, the phone number is saved as the
   member's verified binding and the challenge is deleted.

The current binding is available at `GET /sms/status` (authenticated) and is also exposed as
`sms_phone_verified` / `sms_phone_masked` on the `current_user` serializer.

## Installation

Clone the plugin into your Discourse plugins directory and rebuild as usual:

```sh
cd /var/www/discourse/plugins
git clone https://cnb.cool/xuxiaowei.com.cn/discourse-sms.git discourse-sms
cd /var/www/discourse
bin/rails db:migrate
```

Restart the application and rebuild assets for production (`bin/rails assets:precompile`).

Then, in **Admin → Plugins → discourse-sms**:

1. Enable `sms enabled`.
2. Fill in the send and verify API URLs and the authentication token.
3. Make sure **Captcha** is enabled under **Admin → Settings → Security** (or the Captcha plugin
   settings) and that a provider and its keys are configured. Keep `sms require captcha` enabled.

### Production / Docker asset build

The official `discourse/discourse` image serves precompiled frontend assets and sets
`SKIP_EMBER_CLI_COMPILE=1`. Plugins with frontend code (including this one) are not present in
that prebuilt bundle, so the preferences section will not render until assets are rebuilt once:

```sh
docker exec -it <web-container> bash
cd /var/www/discourse
# Node.js 22 and pnpm must be available in the container
pnpm install --frozen-lockfile
git init
printf "node_modules/\npublic/\ntmp/\nlog/\n" > .git/info/exclude
git add frontend package.json pnpm-lock.yaml
LOAD_PLUGINS=1 DISCOURSE_DOWNLOAD_PRE_BUILT_ASSETS=0 SKIP_EMBER_CLI_COMPILE=0 \
  bundle exec rake assets:precompile
sv restart unicorn
```

Refresh the browser afterwards. Re-run the build after upgrading the base image or changing the
plugin's frontend code.

## Configuration

All settings are under **Admin → Settings → Plugins**.

| Setting | Default | Description |
| --- | --- | --- |
| `sms_enabled` | `false` | Turns the plugin on. |
| `sms_require_captcha` | `true` | Requires a Captcha challenge before sending a code. Strongly recommended. |
| `sms_require_phone_binding` | `false` | Requires a verified phone number before creating topics, replies, or private messages. |
| `sms_skip_phone_binding_groups` | `1\|2` | Groups that can skip the binding requirement. Defaults to admins and moderators. |
| `sms_skip_phone_binding_usernames` | empty | Individual usernames that can skip the binding requirement (comma or `\|` separated). |
| `sms_send_api_url` | empty | Absolute URL of the send-code API. |
| `sms_verify_api_url` | empty | Absolute URL of the verify-code API. |
| `sms_auth_token` | empty | Token sent with every provider request. Stored as a secret. |
| `sms_auth_header` | `Authorization` | Header used for the token. |
| `sms_auth_scheme` | `Bearer` | Prefix for the token. Leave blank to send the raw token. |
| `sms_request_format` | `json` | `json` or `form` request body encoding. |
| `sms_request_timeout_seconds` | `10` | Per-request timeout. |
| `sms_phone_param` | `phone` | Name of the phone field. |
| `sms_code_param` | `code` | Name of the code field. |
| `sms_purpose` | `bind_phone` | Value of the `purpose` field. Leave blank to omit it. |
| `sms_extra_params` | empty | JSON object merged into every request body. |
| `sms_default_country_code` | `86` | Country code added when a member omits `+`. |
| `sms_code_ttl_minutes` | `10` | Challenge lifetime. |
| `sms_resend_interval_seconds` | `60` | Minimum delay between codes for one account. |
| `sms_max_verification_attempts` | `5` | Failed attempts allowed for one challenge. |
| `sms_max_sends_per_hour` | `10` | Hourly sends per account and per phone number. |
| `sms_send_success_json_path` | empty | JSON path that marks a send as successful. |
| `sms_send_success_value` | empty | Expected value at that path. |
| `sms_verify_success_json_path` | empty | JSON path that marks a verification as successful. |
| `sms_verify_success_value` | empty | Expected value at that path. |
| `sms_error_message_json_path` | `message` | JSON path used to read a provider error message. |
| `sms_debug_logging` | `false` | Log provider status codes and durations. |

## External API contract

The plugin posts to the configured URLs. By default the body is JSON; set
`sms_request_format` to `form` for `application/x-www-form-urlencoded`.

### Send a code

```http
POST https://sms.example.com/send
Authorization: Bearer <token>
Content-Type: application/json

{
  "phone": "+8613800138000",
  "purpose": "bind_phone"
}
```

The provider generates the code and delivers it by SMS. Because Discourse does not store the code,
the same provider must be able to verify it.

### Verify a code

```http
POST https://sms.example.com/verify
Authorization: Bearer <token>
Content-Type: application/json

{
  "phone": "+8613800138000",
  "code": "123456",
  "purpose": "bind_phone"
}
```

### Success detection

- With no success JSON path, any `2xx` response means success.
- If `sms_send_success_json_path` / `sms_verify_success_json_path` is set, the value at that path
  must equal the matching `*_success_value`. If the value setting is blank, any truthy value is
  accepted.
- Paths are dot-separated and may include array indexes, for example `data.valid` or
  `items.0.status`.
- For verification, `400` and `422` are treated as **invalid code**. `429` and `5xx` responses are
  treated as a provider outage. Other `4xx` responses are treated as a configuration problem.
- Error messages can be read from the response with `sms_error_message_json_path`.

Examples:

```json
{ "code": 0 }
```

Use `sms_send_success_json_path = code` and `sms_send_success_value = 0`.

```json
{ "data": { "valid": true } }
```

Use `sms_verify_success_json_path = data.valid` and `sms_verify_success_value = true`.

If your provider expects different field names, change `sms_phone_param` and `sms_code_param`.
Additional fields can be added with `sms_extra_params`, for example:

```json
{ "appId": "123", "signType": "HMAC-SHA256" }
```

## Captcha

`sms_require_captcha` controls whether a captcha is needed before an SMS code is sent. It defaults
to `true`. When it is off, the send endpoint skips captcha verification and the browser does not
render a captcha widget; rate limits still apply.

When the requirement is on, Discourse's captcha support lives in the bundled `discourse-captcha`
plugin. The plugin uses the same settings:

- `discourse_captcha_enabled`
- `discourse_captcha_provider` (`hcaptcha`, `recaptcha_v2`, `recaptcha_v3`)
- the matching site key and secret key
- `recaptcha_v3_score_threshold` for reCAPTCHA v3

The browser renders the widget for hCaptcha/reCAPTCHA v2, or executes reCAPTCHA v3 with the
`signup` action, and sends the resulting token as `captcha_token`. The server verifies the token
with the provider before any SMS request is made. If the requirement is enabled but captcha is
disabled, not configured, or the token is missing/invalid, the send request is rejected.

## Forced phone binding

Set `sms_require_phone_binding` to require a verified phone number before a member can:

- create a topic
- reply to a topic
- send a private message

Reading and other account features remain available. Verified members are never blocked.

Members in `sms_skip_phone_binding_groups` (admins and moderators by default) or listed in
`sms_skip_phone_binding_usernames` are exempt. System accounts, bots, and staged users are always
exempt so automated mail and system messages keep working. Clear the group list if you want to
enforce binding for staff too.

When an unbound member is affected, a site-wide notice links them to **Preferences → Security** to
bind a phone number.

## Member experience

- **Preferences → Security** shows whether a phone number is linked. The management section is
  only shown on the member's own preferences page; staff viewing another member's security page do
  not see their own number there.
- The masked number is displayed after verification.
- Administrators can open another member's **Preferences → Security** page and see that member's full
  bound phone number in a read-only view.
- **Change phone number** starts the same send/verify flow; the old binding stays active until the
  new number is verified.
- Changing the phone number requires a new SMS code; when `sms_require_captcha` is on, a new captcha is required too.

## Troubleshooting

- **"Captcha is not enabled..."** — install/enable the official `discourse-captcha` plugin, select a
  provider, and save both the site key and secret key.
- **"The SMS provider is not configured"** — fill in both API URLs and verify that the token and
  field names match the provider documentation.
- **The provider rejects every request** — check `sms_auth_header` / `sms_auth_scheme`, and set
  `sms_error_message_json_path` to the path used by the provider's error payload.
- **Every code is reported as invalid** — many providers return HTTP 200 with a JSON flag. Set
  `sms_verify_success_json_path` (for example `success` or `data.valid`) and the expected
  `sms_verify_success_value`.
- **Members cannot request a second code** — check `sms_resend_interval_seconds` and
  `sms_max_sends_per_hour`.
- **Captcha blocks sending** — keep `sms require captcha` enabled in production. It can be disabled
  temporarily for diagnostics, but rate limits remain the only abuse protection in that mode.
- **Members cannot post after enabling enforcement** — add them to `sms skip phone binding groups`
  or `sms skip phone binding usernames`, or make sure they have verified a phone number.

## Security notes

- The external API token is a Discourse secret setting and is never sent to the browser.
- Verification codes are never stored in the database.
- A phone number can belong to only one account (database unique indexes).
- Only one active challenge exists per account; a new send replaces the previous challenge.
- Challenges expire and are limited by `sms_max_verification_attempts`.
- Rate limits apply per account, per phone number, and as a resend cooldown.
- Phone bindings are deleted when a user is destroyed or anonymized.
- When `sms_require_captcha` is on, the send endpoint refuses to run unless captcha is enabled and configured.
- When `sms_require_phone_binding` is on, unbound non-exempt accounts cannot create topics, replies, or private messages.
- Full phone numbers are only returned by the admin-only status endpoint; the self endpoint returns a masked number.

## Development

```sh
# Ruby specs (from a Discourse checkout with this plugin under plugins/)
LOAD_PLUGINS=1 bin/rspec plugins/discourse-sms/spec

# Ruby lint
bundle exec rubocop plugins/discourse-sms

# JS / CSS lint
cd plugins/discourse-sms
pnpm install
pnpm lint
```

The plugin has no runtime gem dependencies beyond Discourse itself.

## License

[Apache License 2.0](LICENSE)
