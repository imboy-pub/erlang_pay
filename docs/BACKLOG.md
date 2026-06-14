# erlang_pay 落地 BACKLOG（loop 驱动）

> 目标定位：**现代、简洁、高效、通用、纯 Erlang** 的第三方支付模块。
> 仅依赖 OTP（crypto/public_key/inets/ssl）+ jsone，零其他运行时依赖。
>
> 本文件是 `/epay-loop` 的任务源。loop 每轮取**第一个 `[TODO]`** 任务，TDD 实现，
> 跑 `scripts/gate.sh` 绿后标 `[DONE]`，再停下等复核。状态：`[TODO]` / `[DOING]` / `[DONE]`。
>
> 设计依据见 `docs/payment-library-research-2026-06.md`（6 库研究 + 缺口分析）。

---

## P0 — 地基与生产必需

### T01 [DONE] 测试基建 + 密码学/工具层 EUnit
- 目标：建 `test/` 目录，为 `epay_crypto`、`epay_util` 写 EUnit（纯函数，最易测、价值最高）。这是 gate 单测门有意义的前提。
- 验收：`bash scripts/gate.sh` 绿；`epay_crypto` 覆盖 RSA 签名/验签往返、AES-256-GCM 解密（含 tag 篡改→auth_failed）、常量时间比较、PEM 裸 base64 补头；`epay_util` 覆盖金额换算与表单/URL 编码。
- 参照：报告 §3（epay_crypto 质量已达标，补测试固化行为）。

### T02 [TODO] query/2 主动查单（最大功能缺口）
- 目标：`epay_gateway` 加 `query/2` callback；三网关实现主动查单，统一返回 `#{trade_state := atom(), ...}`。
- 验收：gate 绿；三网关各有 meck 模拟 HTTP 的 EUnit（绝不发真实请求）；`erlang_pay:query/3` 门面分发。
- 参照：微信 `GET /v3/pay/transactions/out-trade-no/{no}`（权威 wechatpay-go）；支付宝 `alipay.trade.query`（smartwalle/alipay）；Stripe `GET /v1/payment_intents/{id}`。报告 §4 P0-1：超时必回查，否则订单永远 unknown。

---

## P1 — 通用性与可靠性

### T03 [TODO] epay_money 多币种 exponent
- 目标：新增 `epay_money` 模块，持 ISO 4217 exponent 表（USD/EUR=2，JPY/KRW=0，BHD/KWD=3…），金额校验与「主单位↔最小单位」换算。修复当前硬编码「分」=2 位导致 Stripe 接 JPY/BHD 算错。
- 验收：gate 绿；EUnit 覆盖 2/0/3 位小数三类币种往返；非法币种/溢出返回明确错误。
- 参照：报告 §2「金额货币铁律」——不可假定恒为 100；金额必与货币码同存。

### T04 [TODO] download_bill/2 对账接口
- 目标：`epay_gateway` 加 `download_bill/2`（optional callback）；三网关实现拉取对账/结算文件。
- 验收：gate 绿；meck EUnit；返回统一结构供调用方逐笔比对（整数分）。
- 参照：微信 `downloadTradeBill`/`downloadFundFlowBill`；支付宝 `alipay.data.dataservice.bill.downloadurl.query`；Stripe Reporting。

### T09 [TODO] epay_cert_mgr 可选证书自动轮换（gen_server）
- 目标：可选 OTP 组件 `epay_cert_mgr`（gen_server + ETS），自动下载/缓存/轮换微信平台证书；`send_after` 定时刷新；崩溃由 supervisor 重启。**保持库纯函数核心**：验签函数仍接受外部传入公钥，cert_mgr 仅为可选附加。
- 验收：gate 绿；EUnit 用 meck 模拟下载，验证缓存命中/过期刷新/按 {mch_id,serial} 多租户。
- 参照：wechatpay-go `CertificateDownloaderMgr`（OTP supervisor 优于 Go 手写 recover）。

---

## P2 — 一致性与通用库交付打磨

### T05 [TODO] 统一错误返回 {error, {Code::atom(), Msg::binary()}}
- 目标：消除 `create/refund` 返 `{error,binary()}` 与 `verify_notify` 返 `{error,atom()}` 的不一致。统一为 `{error, {Code, Msg}}`：Code 供程序判断语义，Msg 供展示。
- 验收：gate 绿；门面与三网关全部对齐；更新 README 与 spec；EUnit 覆盖错误分支。

### T06 [TODO] capabilities/0 能力声明替代反射
- 目标：每网关导出 `capabilities() -> [create_payment|refund|query|...]`；门面据此判断能力，替代 `build_pay_sign` 的 `function_exported` 反射探测（更显式、可在启动期校验）。
- 验收：gate 绿；EUnit 验证不支持能力返回明确错误。

### T07 [TODO] close/2 + cancel/2 关单撤单
- 目标：`epay_gateway` 加 `close/2`（关单）、`cancel/2`（撤单）optional callback；按各网关支持度实现。
- 验收：gate 绿；meck EUnit。

### T08 [TODO] Stripe webhook 时间戳 tolerance 防重放
- 目标：核实并补全 Stripe webhook 验签的时间戳容差窗口（默认 300s），超窗拒绝，防重放。
- 验收：gate 绿；EUnit 覆盖过期时间戳→拒绝、窗口内→通过。
- 参照：报告 §4 P2。

### T10 [TODO] ex_doc 文档 + hex 发布就绪
- 目标：补全各模块 `@doc`/`-spec`；`rebar3 ex_doc` 生成无警告；校对 README/CHANGELOG；确认 hex 元数据（licenses/links/description）就绪。
- 验收：`rebar3 ex_doc` 成功；gate 绿；README 与实际 API 一致（含本轮新增 query/money/对账）。

---

## 进度日志
> loop 每完成一个任务在此追加一行（也镜像到 `.claude/state/epay_loop.log`）。

- 2026-06-14 T01 DONE — 建 test/ 基建；epay_crypto/epay_util 共 18 个 EUnit 全绿（RSA往返/HMAC标准向量/AES-GCM往返+篡改/裸base64补头/金额换算）
