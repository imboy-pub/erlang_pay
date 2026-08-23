# erlang_pay — AI 上下文 / AI Context

> 纯 Erlang 第三方支付库：支付宝（App）、微信 v3（JSAPI/Native）、Stripe（PaymentIntent）。
> 独立 git 仓。完整 API/示例见 [README.md](./README.md)，路线图见 [docs/BACKLOG.md](./docs/BACKLOG.md)、[docs/PRODUCTION_READINESS.md](./docs/PRODUCTION_READINESS.md)。

## 设计铁律（改代码前必读）
- **凭据无关 / 零业务耦合**：所有 API 以 `Cfg :: map()` 传凭据，库**绝不读 application env**，可被任意工程复用。
- **仅依赖 OTP**：`crypto`/`public_key`/`inets`/`ssl` + `jsone`，不得引入其他运行时依赖。
- **统一错误**：失败一律 `{error, {Code::atom(), Msg::binary()}}`（Code 见 README 表）。
- **金额用最小货币单位整数**：`epay_money` 持 ISO 4217 exponent 表（USD/EUR=2，JPY/KRW=0，BHD/KWD=3），**不假定 ×100**，禁浮点。
- **能力差异显式声明**：经 `epay_gateway:capabilities/0` + `supports/2`，不支持返回 `{error, {unsupported, _}}`，勿用反射。
- **安全默认**：出站强制 TLS 证书+主机名校验；webhook 常量时间比较 + 时间戳防重放；密钥/签名绝不落日志。

## 命令
```bash
rebar3 compile  # 编译（Makefile 不入库——.gitignore /Makefile 有意为之）
rebar3 eunit    # 单元测试（test/）
rebar3 dialyzer
```

## 模块（`src/`）
| 模块 | 职责 |
|------|------|
| `erlang_pay` | 统一门面，按网关分发 + 能力门控 |
| `epay_gateway` | 网关 behaviour 契约 |
| `epay_alipay` / `epay_wechat` / `epay_stripe` | 各网关实现 |
| `epay_money` | 多币种 exponent 金额换算 |
| `epay_state` | 统一 trade_state 映射 |
| `epay_cert_mgr` | 可选：微信平台证书自动轮换（gen_server + ETS，多租户） |
| `epay_crypto` | RSA2 / HMAC / AES-256-GCM / 常量时间比较 / PEM |
| `epay_http` / `epay_util` | TLS 出站 / URL·表单·JSON |

## OTP28 已知坑
模块级 `@doc` 浮动到首函数会报 "multiple @doc"，`@doc` 含 `<<">>` 触发 XML 崩溃 → 一律用 `-moduledoc`/`-doc` 属性。

License：Apache-2.0 © imboy-pub。
