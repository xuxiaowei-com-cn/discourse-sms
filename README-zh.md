<p align="center"><a href="README.md">English</a> | <a href="README-zh.md">中文</a></p>

# discourse-sms

一个 Discourse 插件：通过**任意**外部短信服务商，将已验证的手机号绑定到会员账号。服务商接口
约定非常小：一个发送验证码 API，一个校验验证码 API。

> [!IMPORTANT]
> 默认情况下，发送短信验证码要求启用并配置官方
> [`discourse-captcha`](https://meta.discourse.org/t/discourse-captcha/291383) 插件（hCaptcha、
> reCAPTCHA v2 或 reCAPTCHA v3）。管理员可通过 `sms require captcha` 设置关闭该要求，但强烈建议
> 保持开启，以防止短信接口被滥用。

## 功能

- 在**偏好设置 → 安全性**中绑定、验证和更换手机号。
- 仅存储 E.164 格式手机号（例如 `+8613800138000`）。
- 一个账号只能绑定一个已验证手机号，一个手机号只能绑定一个账号。
- 验证成功后展示脱敏手机号。
- 可配置默认国家区号，会员输入不带 `+` 的号码时自动补全。
- 默认每次发送验证码都必须通过人机验证（Captcha），管理员可关闭该要求。
- 限流：重发冷却、每账号每小时发送上限、每手机号每小时发送上限。
- 验证挑战具有有效期和最大尝试次数。
- 支持 Bearer Token 或自定义请求头/前缀认证。
- 支持通过 HTTP 状态码或可配置 JSON 路径判断服务商返回是否成功。
- 认证 Token 仅在服务端使用，绝不下发到浏览器。
- 用户被删除或匿名化时清理手机号绑定数据。

## 环境要求

| 要求 | 说明 |
| --- | --- |
| Discourse | 3.2 或更高版本 |
| 人机验证 | 内置 `discourse-captcha` 插件已启用并配置服务商（`sms require captcha` 开启时需要，默认开启） |
| 短信服务 | 提供发送验证码和校验验证码两个 HTTP API |
| Ruby / Rails | 由 Discourse 提供 |

## 工作流程

1. 已登录会员打开**偏好设置 → 安全性**，点击**绑定手机号**。
2. 浏览器渲染站点配置的人机验证（若该要求已开启），将手机号和 Captcha Token 发送到
   `POST /sms/send_code`。
3. 需要时，服务端向人机验证服务商校验 Token；随后执行限流并调用外部**发送** API。
4. 为该账号保存一条验证挑战记录（Discourse 不保存短信验证码本身）。
5. 会员输入短信验证码，浏览器调用 `POST /sms/verify_code`。
6. 服务端调用外部**校验** API。校验成功后保存手机号绑定并删除挑战记录。

当前绑定状态可通过 `GET /sms/status`（需登录）获取，同时也会以
`sms_phone_verified` / `sms_phone_masked` 字段出现在 `current_user` 序列化结果中。

## 安装

将插件克隆到 Discourse 的插件目录，并按常规方式重建：

```sh
cd /var/www/discourse/plugins
git clone https://cnb.cool/xuxiaowei.com.cn/discourse-sms.git discourse-sms
cd /var/www/discourse
bin/rails db:migrate
```

重启应用；生产环境需要重新编译资源（`bin/rails assets:precompile`）。

然后在**管理 → 插件 → discourse-sms**中：

1. 启用 `sms enabled`。
2. 填写发送 API、校验 API 地址和认证 Token。
3. 确认**管理 → 设置 → 安全**（或 Captcha 插件设置）中已启用验证码，并配置好服务商和密钥；保持
   `sms require captcha` 开启。

### 生产环境 / Docker 资源构建

官方 `discourse/discourse` 镜像使用预编译的前端资源，并设置了 `SKIP_EMBER_CLI_COMPILE=1`。
包含前端代码的插件（包括本插件）不会出现在该预编译包中，因此必须先重新构建一次资源，
偏好设置中的手机号区块才会渲染：

```sh
docker exec -it <web 容器名> bash
cd /var/www/discourse
# 容器内需要 Node.js 22 和 pnpm
pnpm install --frozen-lockfile
git init
printf "node_modules/\npublic/\ntmp/\nlog/\n" > .git/info/exclude
git add frontend package.json pnpm-lock.yaml
LOAD_PLUGINS=1 DISCOURSE_DOWNLOAD_PRE_BUILT_ASSETS=0 SKIP_EMBER_CLI_COMPILE=0 \
  bundle exec rake assets:precompile
sv restart unicorn
```

构建完成后刷新浏览器。升级基础镜像或修改插件前端代码后需要重新执行。

## 配置项

所有设置位于**管理 → 设置 → 插件**。

| 设置 | 默认值 | 说明 |
| --- | --- | --- |
| `sms_enabled` | `false` | 是否启用插件。 |
| `sms_require_captcha` | `true` | 发送验证码前是否要求人机验证（Captcha）。强烈建议保持开启。 |
| `sms_send_api_url` | 空 | 发送验证码 API 的完整 URL。 |
| `sms_verify_api_url` | 空 | 校验验证码 API 的完整 URL。 |
| `sms_auth_token` | 空 | 每次请求短信服务商时携带的 Token，作为密钥保存。 |
| `sms_auth_header` | `Authorization` | 携带 Token 的请求头。 |
| `sms_auth_scheme` | `Bearer` | Token 前缀。留空表示直接发送原始 Token。 |
| `sms_request_format` | `json` | 请求体格式：`json` 或 `form`。 |
| `sms_request_timeout_seconds` | `10` | 单次请求超时时间。 |
| `sms_phone_param` | `phone` | 手机号字段名。 |
| `sms_code_param` | `code` | 验证码字段名。 |
| `sms_purpose` | `bind_phone` | `purpose` 字段的值。留空则不发送该字段。 |
| `sms_extra_params` | 空 | 合并到每次请求体中的 JSON 对象。 |
| `sms_default_country_code` | `86` | 会员未输入 `+` 时使用的国家区号。 |
| `sms_code_ttl_minutes` | `10` | 验证挑战有效期。 |
| `sms_resend_interval_seconds` | `60` | 同一账号两次发送之间的最小间隔。 |
| `sms_max_verification_attempts` | `5` | 单个挑战允许的最大失败次数。 |
| `sms_max_sends_per_hour` | `10` | 每账号、每手机号每小时发送上限。 |
| `sms_send_success_json_path` | 空 | 判断发送成功的 JSON 路径。 |
| `sms_send_success_value` | 空 | 该路径对应的期望值。 |
| `sms_verify_success_json_path` | 空 | 判断校验成功的 JSON 路径。 |
| `sms_verify_success_value` | 空 | 该路径对应的期望值。 |
| `sms_error_message_json_path` | `message` | 读取服务商错误信息的 JSON 路径。 |
| `sms_debug_logging` | `false` | 在日志中记录服务商请求状态码和耗时。 |

## 外部 API 约定

插件向配置的 URL 发送 POST 请求。默认请求体为 JSON；将 `sms_request_format` 设为 `form`
可使用 `application/x-www-form-urlencoded`。

### 发送验证码

```http
POST https://sms.example.com/send
Authorization: Bearer <token>
Content-Type: application/json

{
  "phone": "+8613800138000",
  "purpose": "bind_phone"
}
```

验证码由服务商生成并通过短信发送。由于 Discourse 不保存验证码，必须由同一服务商负责校验。

### 校验验证码

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

### 成功判断

- 未配置成功 JSON 路径时，任意 `2xx` 响应都视为成功。
- 配置了 `sms_send_success_json_path` / `sms_verify_success_json_path` 时，该路径的值必须等于
  对应的 `*_success_value`；如果值设置为空，则任意真值都视为成功。
- 路径以点分隔，支持数组下标，例如 `data.valid`、`items.0.status`。
- 校验接口返回 `400`、`422` 时视为**验证码错误**；返回 `429` 或 `5xx` 时视为服务商不可用；
  其他 `4xx` 视为配置问题。
- 可通过 `sms_error_message_json_path` 从响应中读取错误信息。

示例：

```json
{ "code": 0 }
```

配置 `sms_send_success_json_path = code`，`sms_send_success_value = 0`。

```json
{ "data": { "valid": true } }
```

配置 `sms_verify_success_json_path = data.valid`，`sms_verify_success_value = true`。

如果服务商使用不同的字段名，可修改 `sms_phone_param` 和 `sms_code_param`。额外字段可通过
`sms_extra_params` 添加，例如：

```json
{ "appId": "123", "signType": "HMAC-SHA256" }
```

## 验证码

`sms_require_captcha` 控制发送短信验证码前是否需要人机验证，默认开启。关闭后，发送接口会跳过
人机验证，浏览器也不再渲染验证码组件；限流仍然生效。

该要求开启时，Discourse 的人机验证功能由内置 `discourse-captcha` 插件提供。本插件复用以下设置：

- `discourse_captcha_enabled`
- `discourse_captcha_provider`（`hcaptcha`、`recaptcha_v2`、`recaptcha_v3`）
- 对应的 Site Key 和 Secret Key
- reCAPTCHA v3 的 `recaptcha_v3_score_threshold`

浏览器会为 hCaptcha/reCAPTCHA v2 渲染组件，或为 reCAPTCHA v3 以 `signup` action 执行验证，
并将 Token 作为 `captcha_token` 提交。该要求开启时，服务端在调用任何短信接口前向验证码服务商
校验该 Token；验证码未启用、未配置，或 Token 缺失/无效时，发送请求会被拒绝。

## 会员体验

- **偏好设置 → 安全性**中显示是否已绑定手机号。
- 验证成功后显示脱敏手机号。
- **更换手机号**使用相同的发送/校验流程；在新手机号验证成功前，旧绑定保持有效。
- 更换手机号需要接收新的短信验证码；`sms_require_captcha` 开启时还需要重新完成人机验证。

## 常见问题

- **提示“站点未启用或未正确配置人机验证”** — 安装/启用官方 `discourse-captcha` 插件，选择服务商并
  保存 Site Key 和 Secret Key。
- **提示“短信服务未配置”** — 填写两个 API 地址，并确认 Token 和字段名与服务商文档一致。
- **服务商拒绝所有请求** — 检查 `sms_auth_header` / `sms_auth_scheme`，并将
  `sms_error_message_json_path` 设置为服务商错误响应中的实际路径。
- **所有验证码都提示错误** — 很多服务商返回 HTTP 200，并在 JSON 中标记结果。请设置
  `sms_verify_success_json_path`（例如 `success` 或 `data.valid`）及对应的
  `sms_verify_success_value`。
- **会员无法再次获取验证码** — 检查 `sms_resend_interval_seconds` 和
  `sms_max_sends_per_hour`。
- **人机验证阻止发送** — 生产环境请保持 `sms require captcha` 开启。可以临时关闭用于排查，但
  此模式下只剩限流作为防滥用手段。

## 安全说明

- 外部 API Token 是 Discourse 密钥设置，不会下发到浏览器。
- 验证码不会保存到数据库。
- 一个手机号只能属于一个账号（数据库唯一索引）。
- 每个账号同时只有一个有效挑战；再次发送会替换旧挑战。
- 挑战会过期，并受 `sms_max_verification_attempts` 限制。
- 限流按账号、手机号和重发冷却生效。
- 用户被删除或匿名化时会删除手机号绑定。
- `sms_require_captcha` 开启时，人机验证未启用或未配置会拒绝发送。

## 开发

```sh
# 在包含本插件的 Discourse 代码库中运行 Ruby 测试
LOAD_PLUGINS=1 bin/rspec plugins/discourse-sms/spec

# Ruby 代码检查
bundle exec rubocop plugins/discourse-sms

# JS / CSS 检查
cd plugins/discourse-sms
pnpm install
pnpm lint
```

除 Discourse 本身外，插件没有运行时 gem 依赖。

## 许可证

[Apache License 2.0](LICENSE)
