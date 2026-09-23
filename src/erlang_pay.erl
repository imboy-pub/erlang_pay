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
%%%   4) 最小输入合同（EP-20/D-05）：分发前在门面做 action 级最小校验 ——
%%%      Cfg/Req 必须为 map，Req 按 ?INPUT_SPECS 校验 gateway×action 必填
%%%      字段（坏输入 {error, {bad_request, 中文 Msg}} 前置拒绝，不再透传
%%%      到 provider 内因 maps:get badkey 崩溃）；Cfg 按 ?CFG_SPECS 校验
%%%      出站必需商户凭据（缺失/空值 {error, {no_credential, _}}，与
%%%      provider 内部缺平台公钥/webhook_secret 的 fail-closed 语义一致）。
%%%      合法请求零变化。表中无条目的组合（如 stripe 的 close）不做校验，
%%%      交由能力门控（unsupported）或 provider 自身合同兜底。
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
    download_bill/3,
    capabilities/1,
    supports/2,
    close/3,
    cancel/3
]).

-type gateway() :: alipay | wechat | stripe.
-type err() :: epay_gateway:err().

%%%-------------------------------------------------------------------
%%% 最小输入规格表（EP-20：公开 API 最小输入合同）
%%%-------------------------------------------------------------------

%% 单条字段规格：
%%   {字段名, b}      —— 必填，非空 binary
%%   {字段名, i}      —— 必填，正整数（金额单位：分，> 0）
%%   {any_of_b, [...]} —— 候选字段中至少一个为非空 binary
-type field_spec() :: {atom(), b | i} | {any_of_b, [atom()]}.

%% 规格 key 为 {Action, Gateway}。金额一律以「分/最小货币单位」integer 传入，
%% 与 epay_gateway behaviour 约定一致。stripe 的 refund 与 W1 已落地的
%% 幂等合同对齐：payment_intent 必填 + 幂等键候选（显式 idempotency_key
%% 或 out_refund_no 至少其一）。
-define(INPUT_SPECS,
    #{
        {create_payment, alipay} => [{out_trade_no, b}, {amount_fen, i}],
        {create_payment, wechat} => [{out_trade_no, b}, {amount_fen, i}],
        {create_payment, stripe} => [{out_trade_no, b}, {amount_fen, i}],
        {refund, alipay} => [{out_trade_no, b}, {refund_amount_fen, i}],
        {refund, wechat} => [{out_refund_no, b}, {refund_fen, i}, {total_fen, i}],
        {refund, stripe} => [{payment_intent, b},
                             {any_of_b, [out_refund_no, idempotency_key]}],
        {query, alipay} => [{out_trade_no, b}],
        {query, wechat} => [{out_trade_no, b}],
        {query, stripe} => [{payment_intent, b}],
        {download_bill, alipay} => [{bill_date, b}],
        {download_bill, wechat} => [{bill_date, b}],
        {download_bill, stripe} => [],
        {close, alipay} => [{out_trade_no, b}],
        {close, wechat} => [{out_trade_no, b}],
        {cancel, alipay} => [{out_trade_no, b}],
        {cancel, stripe} => [{payment_intent, b}],
        {build_pay_sign, wechat} => [{prepay_id, b}],
        %% verify_notify：门面只拦非 map；Ctx 内部结构由 provider 验签
        %% 自然 fail-closed，不做字段级校验。
        {verify_notify, alipay} => [],
        {verify_notify, wechat} => [],
        {verify_notify, stripe} => []
    }
).

%% Cfg 必需凭据规格表：key 为 {Action, Gateway}，值为该出站路径实际从 Cfg
%% 提取的凭据键（须非空 binary）。依据各 provider 源码的凭据提取点：
%%   alipay  —— 全部出站请求签名需 app_id + private_key（query/close/cancel/
%%             download_bill/refund/app_pay 统一形态）
%%   wechat  —— APIv3 请求签名（sign_request）需 mch_id + mch_serial_no +
%%             private_key；下单另带 appid；build_pay_sign 只需 app_id +
%%             private_key
%%   stripe  —— 出站均经 bearer/1 取 secret_key
%% verify_notify 不列入（各网关内部已对平台公钥/APIv3 key/webhook_secret/
%% public_key 缺失 fail-closed），保持调用方「最小 Cfg 回调」形态可用。
-define(CFG_SPECS,
    #{
        {create_payment, alipay} => [app_id, private_key],
        {refund, alipay} => [app_id, private_key],
        {query, alipay} => [app_id, private_key],
        {download_bill, alipay} => [app_id, private_key],
        {close, alipay} => [app_id, private_key],
        {cancel, alipay} => [app_id, private_key],
        {create_payment, wechat} => [app_id, mch_id, mch_serial_no, private_key],
        {refund, wechat} => [mch_id, mch_serial_no, private_key],
        {query, wechat} => [mch_id, mch_serial_no, private_key],
        {download_bill, wechat} => [mch_id, mch_serial_no, private_key],
        {close, wechat} => [mch_id, mch_serial_no, private_key],
        {build_pay_sign, wechat} => [app_id, private_key],
        {create_payment, stripe} => [secret_key],
        {refund, stripe} => [secret_key],
        {query, stripe} => [secret_key],
        {download_bill, stripe} => [secret_key],
        {cancel, stripe} => [secret_key]
    }
).

%%%===================================================================
%%% 公开 API
%%%===================================================================

-spec version() -> binary().
version() ->
    <<"0.1.0">>.

%% @doc 下单。返回打 tag 的 map（type 区分支付宝 orderStr / 微信 prepay_id /
%% Stripe client_secret）。Order 见各网关模块文档。
-spec create_payment(gateway(), map(), map()) -> {ok, map()} | err().
create_payment(Gateway, Cfg, Order) ->
    with_valid_input(Gateway, create_payment, Cfg, Order,
        fun(Mod) -> Mod:create_payment(Cfg, Order) end).

%% @doc 退款。
-spec refund(gateway(), map(), map()) -> {ok, map()} | err().
refund(Gateway, Cfg, RefundReq) ->
    with_valid_input(Gateway, refund, Cfg, RefundReq,
        fun(Mod) -> Mod:refund(Cfg, RefundReq) end).

%% @doc 主动查单。返回打 tag 的 map，含统一 trade_state（success/pending/
%% closed/refunded/revoked/error/unknown）。
-spec query(gateway(), map(), map()) -> {ok, map()} | err().
query(Gateway, Cfg, Query) ->
    with_valid_input(Gateway, query, Cfg, Query,
        fun(Mod) -> Mod:query(Cfg, Query) end).

%% @doc 申请对账/结算文件。返回打 tag 的 map（微信/支付宝含 download_url，
%% Stripe 含 report_run_id）。调用方据此下载并逐笔比对。
-spec download_bill(gateway(), map(), map()) -> {ok, map()} | err().
download_bill(Gateway, Cfg, Req) ->
    with_valid_input(Gateway, download_bill, Cfg, Req,
        fun(Mod) -> Mod:download_bill(Cfg, Req) end).

%% @doc 回调验签 + 解密，返回明文事件 map。
%% Ctx :: #{headers => map(), body => binary(), form => map()}
-spec verify_notify(gateway(), map(), map()) -> {ok, map()} | err().
verify_notify(Gateway, Cfg, Ctx) ->
    with_valid_input(Gateway, verify_notify, Cfg, Ctx,
        fun(Mod) -> Mod:verify_notify(Cfg, Ctx) end).

%% @doc 客户端二次签名（仅部分网关支持，如微信 JSAPI paySign）。
%% 据网关 capabilities/0 显式声明判断，替代 function_exported 反射探测。
-spec build_pay_sign(gateway(), map(), map()) -> {ok, map()} | err().
build_pay_sign(Gateway, Cfg, Args) ->
    with_valid_input(Gateway, build_pay_sign, Cfg, Args, fun(Mod) ->
        case lists:member(build_pay_sign, Mod:capabilities()) of
            true -> Mod:build_pay_sign(Cfg, Args);
            false -> {error, {unsupported, <<"该网关不支持客户端二次签名"/utf8>>}}
        end
    end).

%% @doc 查询网关能力清单（atom 列表，见 epay_gateway capabilities/0 callback）。
-spec capabilities(gateway()) -> {ok, [atom()]} | err().
capabilities(Gateway) ->
    case gateway_module(Gateway) of
        {ok, Mod} -> {ok, Mod:capabilities()};
        {error, _} -> {error, {unknown_gateway, <<"未知支付网关"/utf8>>}}
    end.

%% @doc 判断网关是否支持某能力。未知网关返回 false。
-spec supports(gateway(), atom()) -> boolean().
supports(Gateway, Capability) ->
    case gateway_module(Gateway) of
        {ok, Mod} -> lists:member(Capability, Mod:capabilities());
        {error, _} -> false
    end.

%% @doc 关单（未支付订单主动关闭）。仅 capabilities 含 close 的网关支持。
-spec close(gateway(), map(), map()) -> {ok, map()} | err().
close(Gateway, Cfg, Req) ->
    with_valid_input(Gateway, close, Cfg, Req, fun(Mod) ->
        require_cap(Mod, close, fun() -> Mod:close(Cfg, Req) end)
    end).

%% @doc 撤单（已下单未支付/超时撤销）。仅 capabilities 含 cancel 的网关支持。
-spec cancel(gateway(), map(), map()) -> {ok, map()} | err().
cancel(Gateway, Cfg, Req) ->
    with_valid_input(Gateway, cancel, Cfg, Req, fun(Mod) ->
        require_cap(Mod, cancel, fun() -> Mod:cancel(Cfg, Req) end)
    end).

%% @doc gateway 原子 → 实现模块。
-spec gateway_module(gateway()) -> {ok, module()} | {error, unknown_gateway}.
gateway_module(alipay) -> {ok, epay_alipay};
gateway_module(wechat) -> {ok, epay_wechat};
gateway_module(stripe) -> {ok, epay_stripe};
gateway_module(_) -> {error, unknown_gateway}.

%%%===================================================================
%%% Internal —— 最小输入校验与分发
%%%===================================================================

%% 网关解析 → 最小输入校验 → Continue(Mod)。未知网关语义保持 unknown_gateway
%% 优先于 bad_request（回归约束：合法输入下 unknown_gateway/unsupported 不变）。
-spec with_valid_input(gateway(), atom(), map(), map(),
    fun((module()) -> {ok, map()} | err())) -> {ok, map()} | err().
with_valid_input(Gateway, Action, Cfg, Req, Continue) ->
    case gateway_module(Gateway) of
        {ok, Mod} ->
            case check_input(Action, Gateway, Cfg, Req) of
                ok -> Continue(Mod);
                {error, _} = Err -> Err
            end;
        {error, _} ->
            {error, {unknown_gateway, <<"未知支付网关"/utf8>>}}
    end.

%% 能力门控：网关须在 capabilities/0 中声明 Cap，否则返回 unsupported。
-spec require_cap(module(), atom(), fun(() -> {ok, map()} | err())) ->
    {ok, map()} | err().
require_cap(Mod, Cap, Fun) ->
    case lists:member(Cap, Mod:capabilities()) of
        true -> Fun();
        false -> {error, {unsupported, <<"该网关不支持该操作"/utf8>>}}
    end.

%% 通用校验：Cfg/Req 必须为 map，再按规格表做字段级校验，最后校验 Cfg
%% 出站必需凭据（Req 合同优先于凭据合同，与既有测试意图一致）。
-spec check_input(atom(), gateway(), map(), map()) -> ok | err().
check_input(Action, Gateway, Cfg, Req) ->
    case is_map(Cfg) of
        false ->
            bad_request(Gateway, Action, <<"商户配置 Cfg"/utf8>>, <<"map"/utf8>>);
        true ->
            case is_map(Req) of
                false ->
                    bad_request(Gateway, Action, <<"请求参数"/utf8>>, <<"map"/utf8>>);
                true ->
                    case validate_fields(Action, Gateway, Req) of
                        ok -> validate_credentials(Action, Gateway, Cfg);
                        {error, _} = Err -> Err
                    end
            end
    end.

%% Cfg 出站必需凭据校验：无规格条目（回调路径/能力门控域）直接放行。
-spec validate_credentials(atom(), gateway(), map()) -> ok | err().
validate_credentials(Action, Gateway, Cfg) ->
    case maps:get({Action, Gateway}, ?CFG_SPECS, undefined) of
        undefined -> ok;
        Keys -> check_credentials(Action, Gateway, Keys, Cfg)
    end.

%% 逐键校验非空 binary，首缺即返 no_credential（Msg 指明 gateway+action+键名）。
-spec check_credentials(atom(), gateway(), [atom()], map()) -> ok | err().
check_credentials(_Action, _Gateway, [], _Cfg) ->
    ok;
check_credentials(Action, Gateway, [Key | Rest], Cfg) ->
    case is_nonempty_binary(maps:get(Key, Cfg, undefined)) of
        true ->
            check_credentials(Action, Gateway, Rest, Cfg);
        false ->
            Msg = <<(atom_to_binary(Gateway, utf8))/binary, " ",
                    (atom_to_binary(Action, utf8))/binary,
                    " 缺少商户凭据 "/utf8, (atom_to_binary(Key, utf8))/binary>>,
            {error, {no_credential, Msg}}
    end.

%% 字段级校验：无规格条目（该网关无此动作/参数可选）则直接放行。
-spec validate_fields(atom(), gateway(), map()) -> ok | err().
validate_fields(Action, Gateway, Req) ->
    case maps:get({Action, Gateway}, ?INPUT_SPECS, undefined) of
        undefined -> ok;
        Specs -> check_specs(Action, Gateway, Req, Specs)
    end.

%% 逐条校验规格，首错即返（Msg 指明 gateway+action+字段+期望形态）。
-spec check_specs(atom(), gateway(), map(), [field_spec()]) -> ok | err().
check_specs(_Action, _Gateway, _Req, []) ->
    ok;
check_specs(Action, Gateway, Req, [{Field, b} | Rest]) ->
    case Req of
        #{Field := V} when is_binary(V), V =/= <<>> ->
            check_specs(Action, Gateway, Req, Rest);
        _ ->
            bad_request(Gateway, Action, field_label(Field), <<"非空 binary"/utf8>>)
    end;
check_specs(Action, Gateway, Req, [{Field, i} | Rest]) ->
    case Req of
        #{Field := V} when is_integer(V), V > 0 ->
            check_specs(Action, Gateway, Req, Rest);
        _ ->
            bad_request(Gateway, Action, field_label(Field),
                        <<"正整数（金额单位：分）"/utf8>>)
    end;
check_specs(Action, Gateway, Req, [{any_of_b, Fields} | Rest]) ->
    case any_of_valid(Req, Fields) of
        ok -> check_specs(Action, Gateway, Req, Rest);
        {error, Field} ->
            bad_request(Gateway, Action, field_label(Field), <<"非空 binary"/utf8>>)
    end.

%% 候选字段至少一个非空 binary 即通过；全部缺失时报第一个候选字段，
%% 存在但类型不符且无合规兄弟字段时报该字段。
-spec any_of_valid(map(), [atom()]) -> ok | {error, atom()}.
any_of_valid(Req, Fields) ->
    case [F || F <- Fields, is_nonempty_binary(maps:get(F, Req, undefined))] of
        [_ | _] ->
            ok;
        [] ->
            case [F || F <- Fields, maps:is_key(F, Req)] of
                [] -> {error, hd(Fields)};
                [Bad | _] -> {error, Bad}
            end
    end.

-spec is_nonempty_binary(term()) -> boolean().
is_nonempty_binary(V) -> is_binary(V) andalso V =/= <<>>.

%% 字段名转 binary，用于错误 Msg 拼接。
-spec field_label(atom()) -> binary().
field_label(Field) ->
    atom_to_binary(Field, utf8).

%% 构造 {error, {bad_request, Msg}}，Msg 说明 gateway+action+字段/参数+期望形态。
-spec bad_request(gateway(), atom(), binary(), binary()) -> err().
bad_request(Gateway, Action, What, Expect) ->
    Msg = <<(atom_to_binary(Gateway, utf8))/binary, " ",
            (atom_to_binary(Action, utf8))/binary, " 请求的 "/utf8,
            What/binary, " 必须为 "/utf8, Expect/binary>>,
    {error, {bad_request, Msg}}.
