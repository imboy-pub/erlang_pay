# Changelog

All notable changes to `erlang_pay` are documented here.

## [0.1.0] - 2026-06-14

### Added

- 首个版本：纯 Erlang 统一第三方支付库，零业务耦合、凭据无关。
- `erlang_pay` 统一门面：`create_payment/3`、`refund/3`、`verify_notify/3`、`build_pay_sign/3`。
- `epay_gateway` behaviour：统一网关契约（create_payment/2、refund/2、verify_notify/2，可选 build_pay_sign/2）。
- **支付宝** `epay_alipay`：App 支付 orderStr RSA2 签名、退款（HTTP）、异步通知验签。
- **微信支付 v3** `epay_wechat`：JSAPI/Native 下单、客户端 paySign、退款、回调验签 + AES-256-GCM 解密。
- **Stripe** `epay_stripe`：PaymentIntent、退款、Webhook 验签（HMAC-SHA256 + 时间戳容忍窗口 + 多 v1 签名）。
- 共享层：`epay_crypto`（RSA SHA256withRSA、HMAC-SHA256、AES-256-GCM、常量时间比较、PEM 解析）、
  `epay_http`（强制 TLS 证书 + 主机名校验的出站 POST）、`epay_util`（URL/表单/JSON/金额换算）。

### 设计参考

移植自各语言社区标杆：官方 `wechatpay-go` / `stripe-go`、`smartwalle/alipay`、
`yansongda/pay`（架构）、`thephpleague/omnipay`（GatewayInterface）。

### 注意

- 仅依赖 OTP `crypto`/`public_key`/`inets`/`ssl` 与 `jsone`，无其他运行时依赖。
- 真实商户凭据须由调用方注入（库不读取 application env）；live 联调需真实商户号。
