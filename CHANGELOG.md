# Changelog

All notable changes to `erlang_pay` are documented here.

## [0.1.0] - 2026-06-14

### Added

- 首个版本：纯 Erlang 统一第三方支付库，零业务耦合、凭据无关。
- `erlang_pay` 统一门面：`create_payment/3`、`refund/3`、`verify_notify/3`、`build_pay_sign/3`、
  `query/3`、`download_bill/3`、`close/3`、`cancel/3`、`capabilities/1`、`supports/2`。
- `epay_gateway` behaviour：统一网关契约（create_payment/2、refund/2、verify_notify/2、query/2、
  download_bill/2、capabilities/0，可选 build_pay_sign/2、close/2、cancel/2）。
- **统一错误返回**：所有 API 失败统一为 `{error, {Code::atom(), Msg::binary()}}`。
- **能力声明**：每网关 `capabilities/0` 显式列出支持的动作，门面据此门控（替代 function_exported 反射）。
- **支付宝** `epay_alipay`：App 支付 orderStr RSA2 签名、退款（HTTP）、异步通知验签、查单、对账下载、关单、撤单。
- **微信支付 v3** `epay_wechat`：JSAPI/Native 下单、客户端 paySign、退款、回调验签 + AES-256-GCM 解密、查单、对账下载、关单。
- **Stripe** `epay_stripe`：PaymentIntent、退款、Webhook 验签（HMAC-SHA256 + 时间戳容差窗口可配 + 多 v1 签名）、查单、对账（Reporting）、撤单。
- **多币种金额** `epay_money`：ISO 4217 exponent 表（2/0/3 位），主单位↔最小单位整数换算，杜绝浮点误差。
- **可选 OTP 组件** `epay_cert_mgr`：gen_server + ETS，自动下载/缓存/定时轮换微信平台证书，多租户 `{mch_id, serial}`；
  库纯函数核心不依赖它也能验签。
- 共享层：`epay_crypto`（RSA SHA256withRSA、HMAC-SHA256、AES-256-GCM、常量时间比较、PEM 解析）、
  `epay_http`（强制 TLS 证书 + 主机名校验的出站 POST/GET）、`epay_util`（URL/表单/JSON/金额换算）。

### 设计参考

移植自各语言社区标杆：官方 `wechatpay-go` / `stripe-go`、`smartwalle/alipay`、
`yansongda/pay`（架构）、`thephpleague/omnipay`（GatewayInterface）。

### 注意

- 仅依赖 OTP `crypto`/`public_key`/`inets`/`ssl` 与 `jsone`，无其他运行时依赖。
- 真实商户凭据须由调用方注入（库不读取 application env）；live 联调需真实商户号。
