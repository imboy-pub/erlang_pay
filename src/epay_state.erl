-module(epay_state).
-moduledoc """
统一交易状态词汇表与三态分类（单一真相源）。

对标 omnipay `NotificationInterface` 的三态读取（`isSuccessful`/`isPending`）：
各网关把渠道私有状态（微信 `SUCCESS`、支付宝 `TRADE_SUCCESS`、Stripe
`payment_intent.succeeded`…）经各自 `map_*_state/1` 归一到本模块定义的
**canonical 状态集**，调用方据此统一判断，无须再认识各网关词汇。

canonical 状态：

| 状态 | 含义 | is_paid | is_pending | is_final |
|------|------|---------|------------|----------|
| `success`  | 支付成功 | ✓ | | ✓ |
| `pending`  | 待支付/处理中（须继续轮询） | | ✓ | |
| `closed`   | 关单/取消（未支付即终结） | | | ✓ |
| `refunded` | 已退款 | | | ✓ |
| `revoked`  | 已撤销 | | | ✓ |
| `error`    | 支付失败 | | | ✓ |
| `unknown`  | 未知（须回查 PSP） | | | |

`is_final/1` 标识状态已收敛——供订单状态机/查单轮询判断「是否还需再查」：
`pending`/`unknown` 非终态须再查，其余为终态。

本模块为纯函数，零依赖。
""".

-export([states/0, is_state/1, is_paid/1, is_pending/1, is_final/1]).

-type state() :: success | pending | closed | refunded | revoked | error | unknown.
-export_type([state/0]).

-doc "canonical 状态全集（单一真相源）。".
-spec states() -> [state()].
states() ->
    [success, pending, closed, refunded, revoked, error, unknown].

-doc "判断 Term 是否为合法 canonical 状态。".
-spec is_state(term()) -> boolean().
is_state(Term) ->
    lists:member(Term, states()).

-doc "支付成功（omnipay isSuccessful）——仅 success 为真。".
-spec is_paid(state()) -> boolean().
is_paid(success) -> true;
is_paid(_) -> false.

-doc "待支付/处理中（omnipay isPending）——仅 pending 为真，须继续轮询。".
-spec is_pending(state()) -> boolean().
is_pending(pending) -> true;
is_pending(_) -> false.

-doc """
状态是否已收敛（终态）。

`success`/`closed`/`refunded`/`revoked`/`error` 为终态；`pending`/`unknown`
非终态，订单状态机/查单轮询应据此决定是否继续回查 PSP。
""".
-spec is_final(state()) -> boolean().
is_final(success) -> true;
is_final(closed) -> true;
is_final(refunded) -> true;
is_final(revoked) -> true;
is_final(error) -> true;
is_final(pending) -> false;
is_final(unknown) -> false;
is_final(_) -> false.
