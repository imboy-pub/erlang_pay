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

### T02 [DONE] query/2 主动查单（最大功能缺口）
- 目标：`epay_gateway` 加 `query/2` callback；三网关实现主动查单，统一返回 `#{trade_state := atom(), ...}`。
- 验收：gate 绿；三网关各有 meck 模拟 HTTP 的 EUnit（绝不发真实请求）；`erlang_pay:query/3` 门面分发。
- 参照：微信 `GET /v3/pay/transactions/out-trade-no/{no}`（权威 wechatpay-go）；支付宝 `alipay.trade.query`（smartwalle/alipay）；Stripe `GET /v1/payment_intents/{id}`。报告 §4 P0-1：超时必回查，否则订单永远 unknown。

---

## P1 — 通用性与可靠性

### T03 [DONE] epay_money 多币种 exponent
- 目标：新增 `epay_money` 模块，持 ISO 4217 exponent 表（USD/EUR=2，JPY/KRW=0，BHD/KWD=3…），金额校验与「主单位↔最小单位」换算。修复当前硬编码「分」=2 位导致 Stripe 接 JPY/BHD 算错。
- 验收：gate 绿；EUnit 覆盖 2/0/3 位小数三类币种往返；非法币种/溢出返回明确错误。
- 参照：报告 §2「金额货币铁律」——不可假定恒为 100；金额必与货币码同存。

### T04 [DONE] download_bill/2 对账接口
- 目标：`epay_gateway` 加 `download_bill/2`（optional callback）；三网关实现拉取对账/结算文件。
- 验收：gate 绿；meck EUnit；返回统一结构供调用方逐笔比对（整数分）。
- 参照：微信 `downloadTradeBill`/`downloadFundFlowBill`；支付宝 `alipay.data.dataservice.bill.downloadurl.query`；Stripe Reporting。

### T09 [TODO] epay_cert_mgr 可选证书自动轮换（gen_server）
- 目标：可选 OTP 组件 `epay_cert_mgr`（gen_server + ETS），自动下载/缓存/轮换微信平台证书；`send_after` 定时刷新；崩溃由 supervisor 重启。**保持库纯函数核心**：验签函数仍接受外部传入公钥，cert_mgr 仅为可选附加。
- 验收：gate 绿；EUnit 用 meck 模拟下载，验证缓存命中/过期刷新/按 {mch_id,serial} 多租户。
- 参照：wechatpay-go `CertificateDownloaderMgr`（OTP supervisor 优于 Go 手写 recover）。

---

## P2 — 一致性与通用库交付打磨

### T05 [DONE] 统一错误返回 {error, {Code::atom(), Msg::binary()}}
- 目标：消除 `create/refund` 返 `{error,binary()}` 与 `verify_notify` 返 `{error,atom()}` 的不一致。统一为 `{error, {Code, Msg}}`：Code 供程序判断语义，Msg 供展示。
- 验收：gate 绿；门面与三网关全部对齐；更新 README 与 spec；EUnit 覆盖错误分支。

### T06 [DONE] capabilities/0 能力声明替代反射
- 目标：每网关导出 `capabilities() -> [create_payment|refund|query|...]`；门面据此判断能力，替代 `build_pay_sign` 的 `function_exported` 反射探测（更显式、可在启动期校验）。
- 验收：gate 绿；EUnit 验证不支持能力返回明确错误。

### T07 [DONE] close/2 + cancel/2 关单撤单
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
- 2026-06-14 T02 DONE — query/2 主动查单：epay_gateway 加 query callback；三网关实现（微信 GET out-trade-no、支付宝 alipay.trade.query、Stripe GET payment_intents）；epay_http 加 get/2,3；门面 query/3 分发；trade_state 统一 atom。epay_query_tests 13 个 meck EUnit。
- 2026-06-14 T03 DONE — epay_money 多币种 exponent：ISO 4217 表（14 币种 2/0/3 位）；to_minor/to_major 整数运算杜绝浮点误差；非法币种/小数超位/负数校验。epay_money_tests 16 个 EUnit。
- 2026-06-14 T04 DONE — download_bill/2 对账：epay_gateway 加 download_bill callback；三网关实现（微信 tradebill、支付宝 bill.downloadurl.query、Stripe report_runs）；门面 download_bill/3。支付宝 query/download_bill 抽出 build_params/do_open_request 共用。epay_bill_tests 8 个 meck EUnit。gate 绿（54 EUnit）。
- 2026-06-14 T05 DONE — 统一错误返回 {error, {Code::atom(), Msg::binary()}}：behaviour 定义 err/0 类型并导出；门面 erlang_pay 与三网关全部错误返回点对齐（gateway_error/http_error/invalid_response/sign_failed/no_credential/bad_signature/timestamp_expired/decrypt_failed/unsupported/unknown_gateway…）；底层原语 epay_crypto/epay_util/epay_money 保留各自被测错误词汇（不在本范围）；epay_query_tests 加 2 个能力/未知网关 build_pay_sign 错误用例 + 收紧 http_error/gateway_error 断言。gate 绿（56 EUnit）。
- 2026-06-14 T06 DONE — capabilities/0 能力声明：behaviour 加 capabilities/0 callback；三网关各显式列能力（微信含 build_pay_sign，支付宝/Stripe 不含）；门面 build_pay_sign 用 lists:member(Mod:capabilities()) 替代 function_exported 反射；门面新增 capabilities/1 + supports/2。epay_capabilities_tests 7 个纯函数 EUnit。gate 绿（63 EUnit）。
- 2026-06-14 T07 DONE — close/2 关单 + cancel/2 撤单：behaviour 加 close/cancel optional callback；按支持度实现（微信 close、支付宝 close+cancel 共用 trade_action、Stripe cancel）；各网关 capabilities 同步登记；门面 close/3 + cancel/3 经 cap_dispatch 能力门控（不支持→unsupported）。epay_close_cancel_tests 9 个 meck EUnit。gate 绿（72 EUnit）。
- ⚠️ 2026-06-14 恢复说明 — T02/T03/T04 此前多轮"提交"实为 sandbox 幻影未落真实 git（真实 git 此前仅 T01 89af42b）；本次经 Edit/Write 在真实 FS 重建全部并一次性提交。教训：源码改动必须用 Edit/Write 工具，禁用 Bash 脚本改源码（落 sandbox 不持久）；gate/commit 须 sandbox 禁用。
