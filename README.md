# erlang_pay

纯 Erlang 第三方支付网关库：支付宝（App 支付）、微信支付 v3（JSAPI/Native）、Stripe（PaymentIntent）。
A pure-Erlang payment gateway library for Alipay (App pay), WeChat Pay v3 (JSAPI/Native) and Stripe (PaymentIntent).

## 特性 / Features

- **统一门面**：三家网关一套 API，差异用「打 tag 的返回 map」隔离。
  One facade, one API for all three gateways; differences isolated in tagged result maps.
- **全生命周期**：下单 / 退款 / 回调验签 / 查单 / 对账 / 关单 / 撤单。
  Full lifecycle: create, refund, webhook verify, query, bill download, close, cancel.
- **处处先验签后解析**：微信应答与回调、支付宝应答与通知、Stripe webhook，验签失败绝不碰报文。
  Verify-then-parse everywhere; a failed signature check never falls through to parsing.
- **Stripe 退款幂等**：退款必须带稳定退款号，无幂等键不发送请求。
  Idempotent Stripe refunds: a stable refund id is required; no request without one.
- **凭据无关**：凭据全部由 `Cfg` map 传入，库不读任何 application env。
  Credentials come in as a `Cfg` map; the library reads no application env.
- **仅依赖 OTP + jsone**；出站强制 HTTPS + TLS 证书/主机名校验。
  Only OTP + jsone; outbound is https-only with TLS certificate and hostname checks.
- **金额一律最小货币单位整数**（分 / cents），无浮点误差。
  All amounts are integers in the smallest currency unit — no floating point.

## 安装 / Install

```erlang
%% rebar.config
{deps, [{erlang_pay, {git, "https://github.com/imboy-pub/erlang_pay.git", {tag, "0.3.0"}}}]}.
%% Gitee 镜像 / Gitee mirror:
%% {deps, [{erlang_pay, {git, "https://gitee.com/imboy-pub/erlang_pay.git", {tag, "0.3.0"}}}]}.
```

## 快速上手 / Quick Start

金额单位为「分 / cents」整数。/ Amounts are integers in the smallest currency unit.

### 支付宝 App 支付 / Alipay App pay

```erlang
Cfg = #{app_id => AppId, private_key => MchPriPem, public_key => AlipayPubPem,
        notify_url => <<"https://example.com/pay/callback/alipay">>},
{ok, #{order_str := OrderStr}} =
    erlang_pay:create_payment(alipay, Cfg, #{out_trade_no => <<"R123">>, amount_fen => 1000}).
%% OrderStr 交给客户端 AlipaySDK 唤起 / hand OrderStr to the client SDK.
```

### 微信 Native（扫码）/ WeChat Native

```erlang
Cfg = #{app_id => AppId, mch_id => MchId, api_v3_key => V3Key,
        mch_serial_no => Serial, private_key => MchPriPem,
        platform_public_key => PlatformPubPem,
        notify_url => <<"https://example.com/pay/callback/wechat">>},
{ok, #{code_url := CodeUrl}} =
    erlang_pay:create_payment(wechat, Cfg, #{out_trade_no => <<"R123">>,
                                             amount_fen => 1000, pay_type => native}).
```

### Stripe

```erlang
Cfg = #{secret_key => <<"sk_...">>, webhook_secret => <<"whsec_...">>},
{ok, #{payment_no := Pi, client_secret := Cs}} =
    erlang_pay:create_payment(stripe, Cfg, #{out_trade_no => <<"R123">>,
                                             amount_fen => 1000, currency => <<"usd">>}).
```

### 退款（Stripe 幂等）/ Refund (Stripe idempotency)

```erlang
%% 必带稳定退款号 out_refund_no（或显式 idempotency_key）→ Idempotency-Key = "rf_" + 退款号；
%% 缺号返回 bad_request，绝不发送请求。禁止用 payment_intent 派生（同一 PI 可多次部分退款）。
%% A stable out_refund_no (or explicit idempotency_key) is required; without one
%% the call is rejected and nothing is sent. Never derive from payment_intent.
{ok, _} = erlang_pay:refund(stripe, Cfg, #{payment_intent => Pi, out_refund_no => <<"RF123">>}).
```

### 回调验签 / Webhook verification

```erlang
%% 微信/Stripe：Ctx = #{headers => Headers, body => RawBody}（原始字节验签）
%% 支付宝：Ctx = #{form => FormMap}（已 url-decode 的通知表单）
{ok, Event} = erlang_pay:verify_notify(wechat, Cfg, #{headers => H, body => RawBody}).
```

## 安全要点 / Security Notes

- **先验签后解析**：验签失败即拒，绝不解析报文。
  Verify before parse; on failure the payload is never parsed.
- **验签只证明来源可信**：订单匹配、幂等、入账判定（`ORDER_MATCHED / IDEMPOTENT / POSTABLE`）是调用方责任。
  A verified event only proves authenticity; order matching, idempotency and posting remain the caller's job.
- **微信平台公钥**由调用方注入（`platform_public_key`）；证书自动轮换不内置。
  The WeChat platform public key is injected by the caller; automatic certificate rotation is not built in.
- **出站仅 HTTPS**；URL 校验失败（`insecure_url`）不起任何网络调用。
  Outbound is https-only; an invalid URL fails before any network call.
- **凭据缺失即拒**（`no_credential`），不会崩溃；密钥/签名/报文绝不写日志。
  Missing credentials fail closed with `no_credential`; secrets never reach the logs.

## 错误码 / Error Codes

所有失败统一 `{error, {Code, Msg}}`。
All failures return `{error, {Code, Msg}}`.

| Code | 含义 / Meaning |
|------|------|
| `bad_request` | 调用方输入不合法 / invalid caller input |
| `no_credential` | 缺商户凭据 / missing merchant credential |
| `unknown_gateway` / `unsupported` | 未知网关 / 网关不支持该能力 / unknown gateway or capability |
| `bad_signature` / `missing_signature` / `serial_mismatch` | 验签失败 / 缺签名 / 序列号不匹配 / signature failures |
| `timestamp_expired` / `invalid_timestamp` | 时间戳超窗或非法（防重放）/ timestamp out of window |
| `app_id_mismatch` / `missing_app_id` | 支付宝通知 app_id 不符 / Alipay notify app_id mismatch |
| `refund_failed` / `invalid_refund_response` | 退款终态失败 / 响应缺 status（结果不明按失败处理）/ refund failed or ambiguous |
| `gateway_error` / `invalid_response` | 网关业务错误 / 响应解析失败 / gateway error or unparseable response |
| `http_error` | 传输错误；**超时=结果未知，先查后重** / transport error; on timeout the result is unknown — query before retry |
| `insecure_url` | 出站 URL 非 https 等 / outbound URL rejected |

## 测试 / Testing

```bash
rebar3 eunit       # 213 tests / 213 个用例
rebar3 dialyzer    # zero warnings / 零警告
bash scripts/gate.sh   # 清洁编译+单测+类型+打包全门 / full clean gate
```

测试用即时生成的 RSA 密钥对做真签名/真验签，mock 只打在 HTTP 边界。
Tests generate real RSA key pairs and real signatures; mocking happens only at the HTTP boundary.

## 状态 / Status

**0.3.0**（2026-09-23）：本地测试全绿；尚未对真实沙箱环境联调。
**0.3.0** (2026-09-23): all local tests green; verification against live sandbox providers is still pending.

## 协议参考 / Protocol References

- 微信支付《签名验证》/ WeChat Pay signature verification:
  <https://pay.weixin.qq.com/docs/merchant/development/interface-rules/signature-verification.html>
- 官方 SDK 对照 / official SDKs used as reference:
  [wechatpay-java@1dab7be](https://github.com/wechatpay-apiv3/wechatpay-java) ·
  [alipay-sdk-java-all@5aafe29](https://github.com/alipay/alipay-sdk-java-all)
- Stripe: [idempotent requests](https://docs.stripe.com/api/idempotent_requests) · [webhooks](https://docs.stripe.com/webhooks)

## License

Apache-2.0
