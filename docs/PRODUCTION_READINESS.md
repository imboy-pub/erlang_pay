# erlang_pay 生产就绪评估 / Production Readiness

> 生成日期：2026-06-14 ｜ 评估基准：HEAD（trade_state 三态统一打磨后，106 EUnit 绿 / dialyzer 零 warning）
> 结论先行：**库层已达生产质量门槛，可作依赖「拿来即用」；但「上线收款」还需补 imboy 接入层 + 真机联调。**

---

## 1. 支持的平台与能力

| 能力 | 支付宝 Alipay | 微信支付 v3 | Stripe |
|---|:---:|:---:|:---:|
| 下单 create_payment | App 支付 | JSAPI / Native | PaymentIntent |
| 退款 refund | ✅ | ✅ | ✅ |
| 主动查单 query | ✅ | ✅ | ✅ |
| 对账 download_bill | ✅ | ✅ | Reporting |
| 回调验签 verify_notify | RSA2 | RSA2 + AES-GCM 解密 | HMAC + 防重放 |
| 客户端二次签名 build_pay_sign | — | JSAPI paySign | — |
| 关单 close | ✅ | ✅ | — |
| 撤单 cancel | ✅ | — | ✅ |
| 证书自动轮换 | — | `epay_cert_mgr`（可选 gen_server） | — |
| 回调统一 trade_state | ✅ | ✅ | ✅ |

`trade_state` 经 `epay_state` 归一为 canonical 集合：`success / pending / closed / refunded / revoked / error / unknown`；配 `epay_state:is_paid/1`、`is_pending/1`、`is_final/1` 判断。

---

## 2. 库层质量门槛（已达成，有证据）

| 生产关键项 | 现状 | 证据 |
|---|:---:|---|
| TLS 证书 + 主机名双校验 | ✅ | `epay_http:tls_opts/0` `verify_peer` + `cacerts_get()` + `pkix_verify_hostname_match_fun(https)` |
| 不泄露密钥/单据 | ✅ | 全程不打印请求/响应报文 |
| 密码学正确 | ✅ | RSA2/HMAC/AES-256-GCM、tag 正确切分、常量时间比较（逐字审计 + EUnit 篡改用例） |
| 先验签后解密 | ✅ | 微信 `rsa_verify_sha256=true` 后才 `decrypt_resource` |
| 回调防重放双向容差 | ✅ | `abs(Now-Ts) > Tolerance`，过期+未来均拒 |
| 缺凭据/缺签名头 fail-closed | ✅ | 验签头四路 `<<>>` 全拦截，默认拒绝 |
| 真实端点 + sandbox 可覆盖 | ✅ | openapi.alipay.com / api.mch.weixin.qq.com / api.stripe.com，`base_url` 覆盖 |
| 质量门 | ✅ | 106 EUnit / 编译零 warning / dialyzer 零 warning / hex 发布就绪 |
| 凭据无关、零额外依赖 | ✅ | 所有 API 传 `Cfg::map()`，仅依赖 OTP + jsone |

---

## 3. 安全复审发现（2026-06-14，security-reviewer）

**总体：回调安全关键路径通过，无 CRITICAL。** 本轮 `trade_state` 注入确认纯加性、均在验签通过分支内、不绕过验签。

| 级别 | 编号 | 位置 | 问题 | 修复建议 |
|---|---|---|---|---|
| HIGH | H1 | `epay_wechat.erl:180` + `epay_stripe.erl:177` | 退款响应缺 status 字段时无条件 `{ok, Resp}` fallthrough，资金语义歧义 | 改为 `{error, {invalid_response, _}}` 强制调用方处理 |
| HIGH | H2 | `epay_wechat.erl:272,285` | `api_v3_key` 缺失无前置 fail-closed；错误路径 `atom_to_binary(Reason)` 内部错误名穿透对外返回值 | 前置检查 `<<>>` → `no_credential`；错误文案固定不拼 Reason |
| MED | M1 | `epay_http.erl:88` | TLS 未显式锁最低版本/密码套件，依赖运行时默认 | 加 `{versions, ['tlsv1.2','tlsv1.3']}` |
| MED | M2 | `epay_alipay.erl:283` | `now_beijing()` 手算时区偏移，实现语义脆弱 | 用系统时区正确处理 + 时钟偏移监控 |
| MED | M3 | `epay_stripe.erl:213` | 多 v1 签名（密钥轮换期）`lists:any` 短路使常量时间属性退化 | 改全量 `bor` 累计，消除短路 |
| LOW | L1 | 三网关 | `base_url`/`gateway_url` 来自 Cfg，无 `https://` 协议白名单 | 出站前断言 https，否则 `insecure_url` |
| LOW | L2 | `epay_alipay.erl:247` | `verify_content` 空值过滤与支付宝 SDK 版本差异，可能误拒含空值合法通知 | 加含空值通知样本回归测试 |

> 注：H1/H2 属退款与配置健壮性，非本轮 `trade_state` 改动引入；回调入账主路径安全。建议上线前按优先级 H1→H2→M3→M1→L1 修复。

---

## 4. 上线收款的剩余缺口（按依赖顺序）

```
库层（erlang_pay）          —— 已就绪，可被依赖
  └─ ✅ 拿来即用：rebar 依赖 → 传 Cfg map 调 API
  └─ ⚠️ 上线前建议修 H1/H2（退款健壮性 + 配置 fail-closed）

接入层（imboy 后端，未完成）—— 上生产的真正工作量
  ① 幂等层：ETS 抢占 + PG idempotency_keys（只存确定性结果，超时回查）
  ② 订单 gen_statem：pending→processing→confirmed|failed，state_timeout 触发查单
  ③ 回调入账：验签→去重→同一 with_tx 事务内入账（防并发覆盖）
  ④ 对账 gen_server：每日拉 PSP 账单逐笔比对（整数分）

联调验证（未做）           —— 代码再绿也替代不了
  ⑤ 沙箱真实凭据跑通三家：下单/支付/回调/退款/查单全链路
  ⑥ 灰度小额真实交易 + 对账核验
```

**核心分工原则**：erlang_pay 保持「凭据无关、纯函数为主」的可复用库定位（幂等/状态机/账本是业务语义，不下沉到库）；imboy 后端负责把库拼装成可靠的生产支付系统。

---

## 5. 一句话结论

- **作为库**：API 齐全、质量达标、安全实践到位，`import` 即用。
- **作为可上线收款的系统**：还需 imboy 侧接入层（①~④）+ 真实凭据联调（⑤⑥），并建议先修 H1/H2。
