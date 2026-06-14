# erlang_pay

纯 Erlang 第三方支付库 —— 支付宝（App 支付）、微信支付 v3（JSAPI/Native）、Stripe（PaymentIntent）。

> Pure-Erlang payment gateway library, modeled after the official `wechatpay-go` /
> `stripe-go` and community `smartwalle/alipay`, `yansongda/pay`, `omnipay`.

## 特性

- **零业务耦合、凭据无关**：所有 API 以 `Cfg :: map()` 传入商户凭据，库自身不读取任何
  application env，可被任意 Erlang 工程复用。
- **统一门面 + behaviour**：`erlang_pay` 按网关分发；三家网关实现同一 `epay_gateway` 契约，
  差异通过「打 tag 的返回 map」隔离。
- **仅依赖 OTP**：`crypto`/`public_key`/`inets`/`ssl` + `jsone`，无其他运行时依赖。
- **安全默认**：出站 HTTP 强制 TLS 证书 + 主机名校验；Webhook 验签常量时间比较 + 时间戳防重放；
  密钥/签名绝不落日志。

## 安装（rebar3）

```erlang
%% rebar.config
{deps, [{erlang_pay, {git, "https://github.com/imboy-pub/erlang_pay.git", {tag, "0.1.0"}}}]}.
```

## 快速上手

金额一律以「分/最小货币单位」整数传入。

### 下单

```erlang
%% 支付宝 App 支付 —— 返回 orderStr 供客户端 SDK 唤起
Cfg = #{app_id => AppId, private_key => PriKeyPem, public_key => AlipayPubPem,
        notify_url => <<"https://example.com/v1/payment/callback/alipay">>},
{ok, #{type := alipay_app, order_str := OrderStr}} =
    erlang_pay:create_payment(alipay, Cfg, #{out_trade_no => <<"R123">>, amount_fen => 1000}).

%% 微信 JSAPI —— 返回 prepay_id，再二次签名给客户端
WxCfg = #{mch_id => Mch, app_id => App, api_v3_key => V3Key, mch_serial_no => Serial,
          private_key => MchPriKeyPem, platform_public_key => PlatPubPem,
          notify_url => <<"https://example.com/v1/payment/callback/wechat">>},
{ok, #{type := wechat_jsapi, prepay_id := PrepayId}} =
    erlang_pay:create_payment(wechat, WxCfg, #{out_trade_no => <<"R123">>, amount_fen => 1000,
                                               pay_type => jsapi, openid => OpenId}),
{ok, PaySign} = erlang_pay:build_pay_sign(wechat, WxCfg, #{prepay_id => PrepayId}).

%% Stripe —— 返回 client_secret 给前端
StCfg = #{secret_key => <<"sk_live_...">>, webhook_secret => <<"whsec_...">>},
{ok, #{type := stripe_payment_intent, payment_no := Pi, client_secret := Secret}} =
    erlang_pay:create_payment(stripe, StCfg, #{out_trade_no => <<"R123">>, amount_fen => 1000}).
```

### 回调验签（统一返回明文事件）

```erlang
%% 微信 / Stripe：headers + 原始 body
Ctx = #{headers => Headers, body => RawBody},
{ok, Event} = erlang_pay:verify_notify(wechat, WxCfg, Ctx),   %% 已 AES-GCM 解密
{ok, Event} = erlang_pay:verify_notify(stripe, StCfg, Ctx),

%% 支付宝：已 url-decode 的表单 map
{ok, Form} = erlang_pay:verify_notify(alipay, Cfg, #{form => FormMap}).
```

### 退款

```erlang
{ok, _} = erlang_pay:refund(alipay, Cfg, #{out_trade_no => <<"R123">>, refund_amount_fen => 1000,
                                           out_request_no => <<"RF123">>}),
{ok, _} = erlang_pay:refund(wechat, WxCfg, #{out_trade_no => <<"R123">>, out_refund_no => <<"RF123">>,
                                             refund_fen => 1000, total_fen => 1000}),
{ok, _} = erlang_pay:refund(stripe, StCfg, #{payment_intent => Pi}).
```

## 模块

| 模块 | 职责 |
|------|------|
| `erlang_pay` | 统一门面，按网关分发 |
| `epay_gateway` | 网关 behaviour 契约 |
| `epay_alipay` / `epay_wechat` / `epay_stripe` | 各网关实现 |
| `epay_crypto` | RSA2 / HMAC / AES-256-GCM / 常量时间比较 / PEM |
| `epay_http` | TLS 校验出站 POST |
| `epay_util` | URL / 表单 / JSON / 金额换算 |

## 安全须知

- 商户私钥 / APIv3 Key / webhook secret 请经环境变量或密钥管理注入，切勿硬编码或入库。
- 生产环境务必提供真实平台公钥（微信）/ 支付宝公钥用于回调验签；验签失败必须拒绝入账。
- 回调金额应与本地订单金额比对（由调用方业务层负责）。

## License

Apache-2.0 © imboy-pub
