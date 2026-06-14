# erlang_pay

纯 Erlang 第三方支付库 —— 支付宝（App 支付）、微信支付 v3（JSAPI/Native）、Stripe（PaymentIntent）。

> Pure-Erlang payment gateway library, modeled after the official `wechatpay-go` /
> `stripe-go` and community `smartwalle/alipay`, `yansongda/pay`, `omnipay`.

## 特性

- **零业务耦合、凭据无关**：所有 API 以 `Cfg :: map()` 传入商户凭据，库自身不读取任何
  application env，可被任意 Erlang 工程复用。
- **统一门面 + behaviour**：`erlang_pay` 按网关分发；三家网关实现同一 `epay_gateway` 契约，
  差异通过「打 tag 的返回 map」隔离，能力差异通过 `capabilities/0` 显式声明。
- **完整支付生命周期**：下单 / 退款 / 回调验签 / 主动查单 / 对账下载 / 关单 / 撤单。
- **统一错误返回**：所有 API 失败统一为 `{error, {Code::atom(), Msg::binary()}}`，`Code` 供程序
  判断语义、`Msg` 供展示。
- **多币种金额**：`epay_money` 持 ISO 4217 exponent 表（USD/EUR=2，JPY/KRW=0，BHD/KWD=3），
  整数运算杜绝浮点误差，不假定「分」恒为 2 位。
- **仅依赖 OTP**：`crypto`/`public_key`/`inets`/`ssl` + `jsone`，无其他运行时依赖。
- **安全默认**：出站 HTTP 强制 TLS 证书 + 主机名校验；Webhook 验签常量时间比较 + 时间戳防重放
  （容差可配）；密钥/签名绝不落日志。
- **可选 OTP 组件**：`epay_cert_mgr`（gen_server + ETS）自动下载/缓存/轮换微信平台证书，多租户；
  库纯函数核心不依赖它也能验签。

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

### 主动查单（统一 trade_state）

```erlang
%% 返回统一 trade_state：success | pending | closed | refunded | revoked | error | unknown
{ok, #{trade_state := success}} = erlang_pay:query(wechat, WxCfg, #{out_trade_no => <<"R123">>}),
{ok, #{trade_state := pending}} = erlang_pay:query(alipay, Cfg, #{out_trade_no => <<"R123">>}),
{ok, #{trade_state := success}} = erlang_pay:query(stripe, StCfg, #{payment_intent => Pi}).
```

### 对账文件下载

```erlang
%% 微信/支付宝返回 download_url，Stripe 返回 report_run_id
{ok, #{download_url := Url}}    = erlang_pay:download_bill(wechat, WxCfg, #{bill_date => <<"2026-06-13">>}),
{ok, #{download_url := Url2}}   = erlang_pay:download_bill(alipay, Cfg, #{bill_date => <<"2026-06-13">>}),
{ok, #{report_run_id := RunId}} = erlang_pay:download_bill(stripe, StCfg,
                                      #{interval_start => 1700000000, interval_end => 1700086400}).
```

### 关单 / 撤单（按网关能力）

```erlang
%% 能力差异：微信支持 close；支付宝支持 close + cancel；Stripe 支持 cancel
true  = erlang_pay:supports(wechat, close),
{ok, _} = erlang_pay:close(wechat, WxCfg, #{out_trade_no => <<"R123">>}),
{ok, _} = erlang_pay:close(alipay, Cfg, #{out_trade_no => <<"R123">>}),
{ok, _} = erlang_pay:cancel(alipay, Cfg, #{out_trade_no => <<"R123">>}),
{ok, _} = erlang_pay:cancel(stripe, StCfg, #{payment_intent => Pi}),

%% 不支持的能力返回 {error, {unsupported, _}}
{error, {unsupported, _}} = erlang_pay:close(stripe, StCfg, #{payment_intent => Pi}),

%% 查询网关能力清单
{ok, Caps} = erlang_pay:capabilities(wechat).
```

### 多币种金额换算

```erlang
%% 主单位字符串 ↔ 最小单位整数，随币种 exponent 而变（不假定 ×100）
{ok, 1234} = epay_money:to_minor(<<"12.34">>, <<"USD">>),   %% 2 位
{ok, 100}  = epay_money:to_minor(<<"100">>,   <<"JPY">>),   %% 0 位
{ok, 1234} = epay_money:to_minor(<<"1.234">>, <<"BHD">>),   %% 3 位
{ok, <<"12.34">>} = epay_money:to_major(1234, <<"USD">>).
```

### 可选：微信平台证书自动轮换

```erlang
%% gen_server + ETS，自动下载/缓存/定时轮换，多租户 {mch_id, serial}。
%% 不使用本组件也可验签——验签函数始终接受外部传入的平台公钥。
{ok, Mgr} = epay_cert_mgr:start_link(#{refresh_interval => 43200000}),
ok = epay_cert_mgr:add_merchant(Mgr, WxCfg),
{ok, CertPem} = epay_cert_mgr:get_cert(Mgr, MchId, Serial).
```

## 错误返回约定

所有门面与网关 API 失败统一返回 `{error, {Code::atom(), Msg::binary()}}`：

| Code | 含义 |
|------|------|
| `unknown_gateway` | 未知支付网关 |
| `unsupported` | 网关不支持该能力 |
| `gateway_error` | 网关返回业务错误（含其 message） |
| `http_error` | 传输层错误（超时/连接失败） |
| `invalid_response` | 响应解析失败 / 缺字段 |
| `sign_failed` | 本地签名失败 |
| `no_credential` | 缺凭据（密钥 / 公钥 / webhook secret） |
| `bad_signature` | 验签失败 |
| `timestamp_expired` | 回调时间戳超出容差窗口（防重放） |
| `decrypt_failed` | 回调密文解密失败 |

## 模块

| 模块 | 职责 |
|------|------|
| `erlang_pay` | 统一门面，按网关分发 + 能力门控 |
| `epay_gateway` | 网关 behaviour 契约（含 capabilities/close/cancel） |
| `epay_alipay` / `epay_wechat` / `epay_stripe` | 各网关实现 |
| `epay_money` | 多币种 ISO 4217 exponent 金额换算 |
| `epay_cert_mgr` | 可选：微信平台证书自动轮换（gen_server + ETS） |
| `epay_crypto` | RSA2 / HMAC / AES-256-GCM / 常量时间比较 / PEM |
| `epay_http` | TLS 校验出站 POST / GET |
| `epay_util` | URL / 表单 / JSON / 金额换算 |

## 安全须知

- 商户私钥 / APIv3 Key / webhook secret 请经环境变量或密钥管理注入，切勿硬编码或入库。
- 生产环境务必提供真实平台公钥（微信）/ 支付宝公钥用于回调验签；验签失败必须拒绝入账。
- 回调金额应与本地订单金额比对（由调用方业务层负责）。

## License

Apache-2.0 © imboy-pub
