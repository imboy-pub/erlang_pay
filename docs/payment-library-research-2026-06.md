# 主流支付库架构研究 → erlang_pay 改进路线

> 生成日期：2026-06-14 ｜ 研究方法：联网抓取并逐字复核 PHP / Go / Python / Java 生态 6 个设计精良、社区活跃的支付库源码与文档，对照 erlang_pay v0.1.0 现状做差距分析。
> 标注约定：【事实】= 源码/文档原文可证；【推断】= 基于事实的工程推论。

---

## 0. 一句话结论

erlang_pay v0.1.0 的**地基设计已对标业界一流**（behaviour 契约 + 凭据无关 + OTP 原生密码学 + tagged map 统一差异 + 金额整数分），与 omnipay / wechatpay-go 的核心理念高度一致。当前最大缺口不在"设计"而在"完备性"：缺 **主动查单(query)**、**对账(download_bill)**、**证书自动轮换**、**多币种 exponent**；而 **幂等 / 状态机 / 单事务入账** 应在 imboy 后端接入层补齐（不属于库职责）。

---

## 1. 参考库精华速览

### 1.1 PHP — Omnipay（thephpleague）
- **窄统一接口 + 可选扩展**：`GatewayInterface` 只强制 5 个元方法；`purchase/refund/...` 用 PHPDoc `@method` 可选声明，`supportsXxx()` 运行期探测能力。
- **统一结果/通知抽象**：`AbstractResponse` 暴露 `isSuccessful/isRedirect/isPending`；`NotificationInterface` 三态 `COMPLETED/PENDING/FAILED`。
- **错误二分**：业务失败用返回值（`isSuccessful()=false`），系统错误抛异常；请求发送后冻结不可变。
- 来源：https://github.com/thephpleague/omnipay-common/blob/master/src/Common/GatewayInterface.php ｜ https://github.com/thephpleague/omnipay/blob/master/README.md

### 1.2 PHP — yansongda/pay v3 + artful
- **Rocket（上下文）+ Pipeline（洋葱中间件）+ Plugin（原子步骤）+ Shortcut（声明式插件清单）**。换支付方式 = 换插件清单，不改引擎。回调验签也建模为「只含 CallbackPlugin 的流水线」。
- **本质是纯函数折叠**（`array_reduce` + `$next` 闭包），与 Erlang 不可变哲学天然契合 → 最值得移植的模式。
- 来源：https://github.com/yansongda/artful/blob/main/src/Artful.php ｜ https://github.com/yansongda/pay/blob/master/src/Plugin/Alipay/V2/CallbackPlugin.php

### 1.3 Go — wechatpay-apiv3/wechatpay-go（工程化标杆）
- **四个正交小接口**组合进 Client：`Signer / Verifier / Credential / Cipher`，依赖倒置彻底。接口与实现分包。
- **证书自动轮换**：`CertificateDownloaderMgr` + `RepeatedTask` 每 24h 下载平台证书，按 mchID 多租户，`RWMutex` 并发安全，验签器通过「证书视图接口」永远拿最新证书。
- **回调先验签后解密**：AES-256-GCM（apiV3Key 32 字节直用）；敏感字段用 OAEP+SHA1（区别于签名 PKCS1v15+SHA256）。
- 来源：https://github.com/wechatpay-apiv3/wechatpay-go/blob/main/core/client.go ｜ .../core/downloader/downloader_mgr.go ｜ .../core/notify/notify.go

### 1.4 Go — go-pay/gopay（覆盖面最广）
- **BodyMap = `map[string]any`** 配三个渠道差异化签名串编码器（`EncodeWeChatSignParams` / `EncodeAliPaySignParams` / `EncodeURLParams`）：同一参数容器按渠道用不同方法序列化成待签名串。
- 证书刷新：goroutine + 12h + `retry.Retry(fn,3,1s)` + `recover()` 自愈。
- 来源：https://github.com/go-pay/gopay/blob/main/body_map.go ｜ .../wechat/v3/cert.go ｜ .../alipay/sign.go

### 1.5 Python — django-payments
- **provider_factory(variant)** 工厂注册；单一 `BasePayment` 抽象 + 多 provider backend。
- **状态相关动作约束**：未处理→`cancel`，预授权→`capture/release`，已确认→`refund`；支付状态与欺诈状态正交分离。
- **回调假定「至少一次」投递**：要求原子部分字段更新 / 锁行，避免读改写覆盖并发回调。金额统一 `Decimal`。
- 来源：https://django-payments.readthedocs.io/en/latest/api.html ｜ .../payment-model.html

### 1.6 Java — IJPay / dromara/payment-spring-boot
- **配置驱动多租户**：`tentantId` 为顶层 key；验签策略（平台证书 vs 支付公钥）可开关切换；provider 内 API 端点用枚举注册表。
- **官方标准流程**（源码注释）：生成商品订单 → 生成支付订单(待支付) → 支付 → 回调更新 → 结束；回调「务必幂等，微信可能多次调用」。
- 来源：https://github.com/dromara/payment-spring-boot ｜ https://github.com/Javen205/IJPay

---

## 2. 支付正确性的跨语言铁律（每条均有一手来源）

### 幂等性（Idempotency）
- 变更类接口必须支持幂等键；键的粒度 = 一次具体业务意图，不可跨用户复用，应在「即将下发支付」时生成（服务端生成为黄金标准）。
- **幂等 ≠ 缓存**：只存确定性结果（成功/已知失败），**不存未知结果（provider 超时）**；重试时对未知结果必须回查 provider。
- 原子「不存在则插入」（DB 唯一约束 / SETNX）防并发竞态；参数指纹校验，同键不同参返回 409；TTL ≥ 处理+重试+结算时间（默认 24h，跨 webhook 延长到 30 天）。
- 来源：https://docs.stripe.com/api/idempotent_requests ｜ https://sujeet.pro/articles/stripe-idempotency-reliability ｜ https://dev.to/benriemer/idempotency-keys-in-production-the-race-conditions-expiration-traps-and-edge-cases-most-4nf5

### 回调可靠性
- 假定「至少一次」投递 → 设计为可重复消费；**先验签确认来源，再消费**；消费幂等；状态走原子部分更新/锁行。
- 三阶段超时恢复：PSP 超时→返回 pending→同幂等键重试→**夜间用 PSP 结算文件对账兜底**收敛最终一致。
- 跨网络不存在 exactly-once 投递，只能靠「幂等 + 每个边界去重」实现 exactly-once 处理。
- 来源：https://www.calibreos.com/learn/hld-stripe-payment-processor ｜ django-payments payment-model.html

### 金额与货币（绝不用浮点）
- 绝不用 float/double 存钱；用整数最小货币单位（分，`BIGINT`）或定点 `DECIMAL(19,4)`，高吞吐首选整数。
- **金额必须与 ISO 4217 货币码同存**，小数位由货币码决定 exponent：USD/EUR=2，JPY/UGX=0，BHD/KWD=3，**不可假定恒为 100**。
- JSON 传输用 `{currency, exponent, value(整数)}`，只收整数；除法/汇率最后一步统一 round 一次。
- 来源：https://www.moderntreasury.com/journal/floats-dont-work-for-storing-cents ｜ https://github.com/paylike/api-docs/blob/master/money.md

### 双重记账 / 对账 / 安全
- 双重记账账本 append-only，退款是新增反向分录而非 UPDATE，一条 `SUM()` 检测损坏。
- 对账以 PSP 结算文件为准，比对在整数最小货币单位上做（避免浮点假性差异）。
- PCI 范围最小化：原始卡号只存隔离金库，业务层用 token；erlang_pay 定位「不经手 PAN 的网关聚合」可天然把 PCI 范围降到最低。
- 来源：CalibreOS（同上）｜ https://docs.njiapay.com/reconciliation/amounts

---

## 3. erlang_pay v0.1.0 现状评估（对照检查表）

| 最佳实践 | erlang_pay 现状 | 评定 |
|---|---|---|
| behaviour 统一契约（omnipay/wechatpay-go） | `epay_gateway`: create_payment/refund/verify_notify/build_pay_sign | ✅ 已实现 |
| OTP 原生密码学，零第三方 | `epay_crypto`: RSA2/HMAC/AES-256-GCM/常量时间/PEM 裸 base64 补头 | ✅ 优秀 |
| AES-GCM tag 正确切分 | 已切尾 16 字节 tag，auth_failed 处理 | ✅ 正确 |
| tagged map 统一渠道差异（yansongda/omnipay） | 返回 `#{type => alipay_app/wechat_jsapi/...}` | ✅ 已实现 |
| 凭据无关 / 配置驱动多租户 | 所有 API 以 `Cfg::map()` 传入，不读 application env | ✅ 优秀 |
| 金额整数最小货币单位 | 统一「分」`amount_fen` | ✅（但假定 exponent=2，见下） |
| 回调统一入口 + 先验签 | `verify_notify/3` 统一；TLS+主机名校验 | ✅ 已实现 |
| 显式网关注册表（非反射） | `gateway_module/1` 硬编码映射 | ✅（build_pay_sign 用 function_exported 反射，可改进） |
| **主动查单 query** | **缺失** | ❌ **P0 缺口** |
| **对账 download_bill** | **缺失** | ❌ P1 缺口 |
| **平台证书自动轮换** | Cfg 传静态 platform_public_key | ⚠️ P1（微信证书会轮换） |
| **多币种 exponent（ISO 4217）** | 硬编码「分」=2 位 | ⚠️ P1（JPY/BHD 会错） |
| 关单/撤单 close/cancel | 缺失 | ⚠️ P2 |
| 统一错误返回类型 | create/refund 返 `{error,binary()}`，verify 返 `{error,atom()}` 不一致 | ⚠️ P2 |
| 回调时间戳防重放窗口 | README 声称有，需核实 Stripe tolerance 实现 | ⚠️ 待核实 |
| 幂等键 / 订单状态机 / 单事务入账 | 不在库内（属业务接入层） | ➡️ imboy 后端职责 |

---

## 4. 改进路线（按优先级）

### P0 — 生产必需（否则订单状态永远 unknown / 丢钱）

1. **erlang_pay 库：新增 `query/2` 主动查单**
   - `epay_gateway` 加 callback `query(Cfg, #{out_trade_no | transaction_id}) -> {ok, #{trade_state, ...}} | {error, _}`。
   - 三家网关实现：支付宝 `alipay.trade.query`、微信 V3 `GET /v3/pay/transactions/out-trade-no/{no}`、Stripe `GET /v1/payment_intents/{id}`。
   - 理由：报告反复强调「超时不能当失败，必须回查 PSP」。没有 query，imboy 侧无法实现三阶段超时恢复与对账收敛。

2. **imboy 后端接入层（非库内）：幂等 + 状态机 + 单事务入账**
   - 幂等双层：`ets:insert_new` 抢占并发 + PG `idempotency_keys(key UNIQUE, fingerprint, response, status, expires_at)` 持久去重；只存确定性结果，超时记 `unknown` 触发回查。
   - 订单状态用 `gen_statem`：`pending→processing→confirmed|failed`，终态 `refunded|partially_refunded|cancelled`；非法跃迁由 gen_statem 拒绝；state_timeout 触发查单。
   - 回调入账：验签→去重→**同一 DB 事务内查重+入账**（with_tx），单进程（gen_statem）串行化天然防并发覆盖。对应项目记忆 `project_payment_subsystem_impl` 标注的「recharge 丢钱风险」。

### P1 — 重要（对账 / 多币种 / 证书）

3. **`download_bill/2`（optional callback）+ imboy 侧每日对账任务**
   - 微信 `downloadTradeBill`/`downloadFundFlowBill`、支付宝 `alipay.data.dataservice.bill.downloadurl.query`、Stripe Reporting/Balance Transactions。
   - imboy 用 gen_server + 定时器逐笔与本地账本比对（整数分比对），差异落「对账差异表」告警，不自动改账。

4. **多币种 exponent 支持**
   - 金额 API 从 `amount_fen` 升级为「金额整数 + currency 码」，按 ISO 4217 查表得 exponent（USD=2/JPY=0/BHD=3），**不再硬编码 100**。
   - Stripe 已是国际多币种，JPY 等零小数币种当前会算错。可加 `epay_money` 模块持 exponent 表 + 校验。

5. **可选 OTP 组件 `epay_cert_mgr`（gen_server + ETS + supervisor）**
   - 自动下载/缓存/轮换微信平台证书（对标 wechatpay-go `CertificateDownloaderMgr`）；`send_after(12h)` 定时刷新；崩溃由 supervisor 重启（替代 Go 的手写 recover 自愈）。
   - 保持库「纯函数核心」定位：cert_mgr 作为**可选**附加组件，验签函数仍接受外部传入公钥；调用方可选用 cert_mgr 或自管。

### P2 — 增强（一致性 / 完备性）

6. 统一错误返回为 `{error, {Code::atom(), Msg::binary()}}`（Code 供程序判断语义，Msg 供展示），消除 binary/atom 不一致。
7. `capabilities/0` 能力声明替代 `build_pay_sign` 的 `function_exported` 反射探测（对标 omnipay supportsXxx 但更显式、编译期可校验）。
8. 补 `close/2`（关单）、`cancel/2`（撤单）callback。
9. 核实并补全回调时间戳防重放：Stripe 默认 tolerance 300s 窗口校验。

---

## 5. 目标模块蓝图（库 + 接入层分工）

```
erlang_pay（独立库，纯函数 + 可选 OTP 组件）
  ├─ erlang_pay            门面 dispatch（现有，加 query/download_bill/close/cancel）
  ├─ epay_gateway          behaviour（现有，扩 callback + capabilities/0）
  ├─ epay_alipay/wechat/stripe  各网关实现（现有，补 query 等）
  ├─ epay_crypto           密码学原语（现有，质量已达标）
  ├─ epay_http / epay_util  HTTP/工具（现有）
  ├─ epay_money            ★新增：ISO 4217 exponent 表 + 金额校验
  └─ epay_cert_mgr         ★新增（可选）：gen_server+ETS 微信证书自动轮换

imboy 后端接入层（src/logic + src/ds + src/api，业务职责）
  ├─ 订单 gen_statem       状态机 + state_timeout 查单
  ├─ 幂等层                ETS 抢占 + PG idempotency_keys
  ├─ 回调 handler          验签→去重→同事务入账(with_tx)
  ├─ 对账 gen_server       每日拉 PSP 账单逐笔比对（整数分）
  └─ 双重记账账本表        append-only，退款记反向分录
```

**核心分工原则**：erlang_pay 保持「凭据无关、纯函数为主」的可复用库定位（幂等/状态机/账本是业务语义，不下沉到库）；imboy 后端负责把库拼装成可靠的生产支付系统。

---

## 6. 完整来源清单

见正文各节内联 URL。关键来源汇总：
- Omnipay: https://github.com/thephpleague/omnipay
- yansongda/pay + artful: https://github.com/yansongda/pay ｜ https://github.com/yansongda/artful
- wechatpay-go: https://github.com/wechatpay-apiv3/wechatpay-go
- gopay: https://github.com/go-pay/gopay
- django-payments: https://github.com/jazzband/django-payments
- dromara/payment-spring-boot: https://github.com/dromara/payment-spring-boot ｜ IJPay: https://github.com/Javen205/IJPay
- Stripe idempotency: https://docs.stripe.com/api/idempotent_requests ｜ https://sujeet.pro/articles/stripe-idempotency-reliability
- 支付系统设计: https://www.calibreos.com/learn/hld-stripe-payment-processor
- 金额货币: https://github.com/paylike/api-docs/blob/master/money.md ｜ https://www.moderntreasury.com/journal/floats-dont-work-for-storing-cents
