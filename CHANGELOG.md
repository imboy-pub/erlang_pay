# Changelog

All notable changes to `erlang_pay` are documented here.
`erlang_pay` 的所有重要变更记录于此。

## [0.3.0] - 2026-09-23

安全加固与发布工程 / Security hardening and release engineering.
官方协议依据见 README「协议参考」/ See README "Protocol References".

### Added / 新增

- 微信 APIv3 应答验签：2xx 应答先验签（`Wechatpay-*` 四头 + 平台公钥）后解析，时间戳 ±300s 防重放。
  WeChat APIv3 response verification: 2xx responses are signature-verified before parsing, ±300s replay window.
- 支付宝同步应答验签：对业务节点**原始 JSON 字节**验签（括号配对提取，`\/` 兼容重试一次）。
  Alipay response verification on the raw JSON bytes of the business node, with one `\/`-escape retry.
- 支付宝通知核对 `app_id`；验签排除清单仅 `sign`/`sign_type`（对齐官方 SDK）。
  Alipay notify checks `app_id`; exclusion list stays `sign`/`sign_type` (matches the official SDK).
- Stripe 退款幂等与状态合同：必带稳定退款号（`rf_` 前缀幂等键），五状态显式分支，缺 status 按失败处理。
  Stripe refund idempotency and status contract: stable refund id required, explicit five-state mapping.
- 门面输入校验 `?INPUT_SPECS` 与凭据前置校验 `?CFG_SPECS`：坏输入/缺凭据返回 `bad_request` / `no_credential`，不崩溃。
  Facade-level input and credential validation — invalid input or missing credentials return tagged errors instead of crashing.
- HTTPS-only 出站边界（`insecure_url` 前置拒绝）。
  Https-only outbound boundary, rejected before any network call.
- CI（GitHub Actions OTP 28/29 matrix）与 gate 自检脚本。
  CI matrix (OTP 28/29) and a gate self-test script.

### Fixed / 修复

- `gate.sh` 假绿路径（dialyzer 退出码、增量编译缓存）；bash 3.2 兼容。
  `gate.sh` false-green paths (dialyzer exit code, incremental build cache); bash 3.2 compatible.
- LICENSE 替换为完整 Apache-2.0 官方正文。
  LICENSE replaced with the full Apache-2.0 text.

### Removed / 移除

- `epay_cert_mgr`：证书生命周期（首次信任/轮换/serial 消费）未闭环，不宜宣称生产可用；
  验签路径改为调用方注入公钥。
  `epay_cert_mgr` removed: certificate lifecycle was not closed-loop; callers inject the public key instead.

### Security / 安全

- 明确阶段语义：`verify_notify` 仅证明 `AUTHENTICATED`；`ORDER_MATCHED / IDEMPOTENT / POSTABLE` 归调用方。
  Staged semantics: `verify_notify` only proves authenticity; matching/idempotency/posting stay with the caller.
- 测试 113 → 213（真 RSA fixture 签验，mock 只打 HTTP 边界）；dialyzer 零警告。
  Tests grew 113 → 213 with real RSA fixtures; zero dialyzer warnings.

## [0.1.0] - 2026-06-14

### Added

- 首个版本：纯 Erlang 统一第三方支付库，零业务耦合、凭据无关。
- `erlang_pay` 统一门面：`create_payment/3`、`refund/3`、`verify_notify/3`、`build_pay_sign/3`、
  `query/3`、`download_bill/3`、`close/3`、`cancel/3`、`capabilities/1`、`supports/2`。
- `epay_gateway` behaviour：统一网关契约（可选 `build_pay_sign/2`、`close/2`、`cancel/2`）。
- **统一错误返回**：所有 API 失败统一为 `{error, {Code::atom(), Msg::binary()}}`。
- **能力声明**：每网关 `capabilities/0` 显式列出支持的动作，门面据此门控。
- 支付宝 `epay_alipay`：App 支付 orderStr、退款、异步通知验签、查单、对账下载、关单、撤单。
- 微信 `epay_wechat`：JSAPI/Native 下单、paySign、退款、回调验签 + AES-256-GCM 解密、查单、对账、关单。
- Stripe `epay_stripe`：PaymentIntent、退款、Webhook 验签（HMAC + 容差窗口 + 多 v1）、查单、对账、撤单。
- 多币种金额 `epay_money`：ISO 4217 exponent 表，整数换算无浮点误差。
- 共享层：`epay_crypto`（RSA/HMAC/AES-GCM/常量时间比较）、`epay_http`（强制 TLS）、`epay_util`。

### 注意

- 仅依赖 OTP `crypto`/`public_key`/`inets`/`ssl` 与 `jsone`。
- 真实商户凭据由调用方注入（库不读取 application env）。
