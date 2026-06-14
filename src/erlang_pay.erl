-module(erlang_pay).
%%%===================================================================
%%% @doc erlang_pay —— 纯 Erlang 第三方支付库（统一门面）
%%%
%%% 覆盖支付宝（App 支付）、微信支付 v3（JSAPI/Native）、Stripe（PaymentIntent）
%%% 的「下单 / 退款 / 回调验签」三条核心路径。设计原则：
%%%
%%%   1) 凭据无关：所有 API 以 Cfg :: map() 传入商户凭据，库自身不读取任何
%%%      application:get_env —— 便于被任意 Erlang 工程复用。
%%%   2) 统一门面：按 gateway 原子分发到 epay_alipay/epay_wechat/epay_stripe
%%%      （均实现 epay_gateway behaviour）。返回值打 tag，调用方统一处理差异。
%%%   3) 仅依赖 OTP crypto/public_key/inets/ssl + jsone。
%%%
%%% 架构参考：omnipay(GatewayInterface) / yansongda-pay / wechatpay-go /
%%%           stripe-go / smartwalle-alipay。
%%% @end
%%%===================================================================

-export([
    version/0,
    create_payment/3,
    refund/3,
    verify_notify/3,
    build_pay_sign/3,
    gateway_module/1,
    query/3,
    download_bill/3
]).

-type gateway() :: alipay | wechat | stripe.

-spec version() -> binary().
version() ->
    <<"0.1.0">>.

%% @doc 下单。返回打 tag 的 map（type 区分支付宝 orderStr / 微信 prepay_id /
%% Stripe client_secret）。Order 见各网关模块文档。
-spec create_payment(gateway(), map(), map()) -> {ok, map()} | {error, binary()}.
create_payment(Gateway, Cfg, Order) ->
    dispatch(Gateway, fun(Mod) -> Mod:create_payment(Cfg, Order) end).

%% @doc 退款。
-spec refund(gateway(), map(), map()) -> {ok, map()} | {error, binary()}.
refund(Gateway, Cfg, RefundReq) ->
    dispatch(Gateway, fun(Mod) -> Mod:refund(Cfg, RefundReq) end).

%% @doc 主动查单。返回打 tag 的 map，含统一 trade_state（success/pending/
%% closed/refunded/revoked/error/unknown）。
-spec query(gateway(), map(), map()) -> {ok, map()} | {error, binary()}.
query(Gateway, Cfg, Query) ->
    dispatch(Gateway, fun(Mod) -> Mod:query(Cfg, Query) end).

%% @doc 申请对账/结算文件。返回打 tag 的 map（微信/支付宝含 download_url，
%% Stripe 含 report_run_id）。调用方据此下载并逐笔比对。
-spec download_bill(gateway(), map(), map()) -> {ok, map()} | {error, binary()}.
download_bill(Gateway, Cfg, Req) ->
    dispatch(Gateway, fun(Mod) -> Mod:download_bill(Cfg, Req) end).

%% @doc 回调验签 + 解密，返回明文事件 map。
%% Ctx :: #{headers => map(), body => binary(), form => map()}
-spec verify_notify(gateway(), map(), map()) -> {ok, map()} | {error, atom()}.
verify_notify(Gateway, Cfg, Ctx) ->
    case gateway_module(Gateway) of
        {ok, Mod} -> Mod:verify_notify(Cfg, Ctx);
        {error, _} -> {error, unknown_gateway}
    end.

%% @doc 客户端二次签名（仅部分网关支持，如微信 JSAPI paySign）。
-spec build_pay_sign(gateway(), map(), map()) -> {ok, map()} | {error, binary()}.
build_pay_sign(Gateway, Cfg, Args) ->
    case gateway_module(Gateway) of
        {ok, Mod} ->
            case erlang:function_exported(Mod, build_pay_sign, 2) of
                true -> Mod:build_pay_sign(Cfg, Args);
                false -> {error, <<"该网关不支持客户端二次签名"/utf8>>}
            end;
        {error, _} ->
            {error, <<"未知支付网关"/utf8>>}
    end.

%% @doc gateway 原子 → 实现模块。
-spec gateway_module(gateway()) -> {ok, module()} | {error, unknown_gateway}.
gateway_module(alipay) -> {ok, epay_alipay};
gateway_module(wechat) -> {ok, epay_wechat};
gateway_module(stripe) -> {ok, epay_stripe};
gateway_module(_) -> {error, unknown_gateway}.

%%%===================================================================
%%% Internal
%%%===================================================================

-spec dispatch(gateway(), fun((module()) -> {ok, map()} | {error, binary()})) ->
    {ok, map()} | {error, binary()}.
dispatch(Gateway, Fun) ->
    case gateway_module(Gateway) of
        {ok, Mod} -> Fun(Mod);
        {error, _} -> {error, <<"未知支付网关"/utf8>>}
    end.
