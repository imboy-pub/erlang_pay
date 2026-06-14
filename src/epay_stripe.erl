-module(epay_stripe).
-behaviour(epay_gateway).
%%%===================================================================
%%% @doc Stripe 网关 / Stripe gateway（PaymentIntent）
%%%
%%% 移植自官方 stripe-go：
%%%   - PaymentIntent 创建（POST /v1/payment_intents, form-urlencoded, Bearer key）
%%%   - Refund 创建（POST /v1/refunds）
%%%   - Webhook 验签（Stripe-Signature: t=..,v1=..；HMAC-SHA256；常量时间比较 +
%%%     时间戳容忍窗口防重放）
%%%
%%% Cfg :: #{secret_key := binary(), webhook_secret => binary(),
%%%          currency => binary(), base_url => binary()}
%%% 金额以最小货币单位（cents）整数传入（与「分」同形）。
%%% @end
%%%===================================================================

%% epay_gateway behaviour
-export([
    create_payment/2, refund/2, verify_notify/2, query/2, download_bill/2,
    cancel/2, capabilities/0
]).
%% 低层 API（直接使用）
-export([create_payment_intent/2, verify_webhook/3]).

-define(BASE_URL, <<"https://api.stripe.com">>).
-define(WEBHOOK_TOLERANCE, 300).

%% @doc 能力声明。Stripe 无客户端二次签名（client_secret 直用）；PaymentIntent
%% 以 cancel 撤销（无独立关单语义，cancel 即终止）。
-spec capabilities() -> [atom()].
capabilities() ->
    [create_payment, refund, query, download_bill, verify_notify, cancel].

%% @doc 撤单（取消 PaymentIntent）。Req :: #{payment_intent := binary()}。
-spec cancel(map(), map()) -> {ok, map()} | epay_gateway:err().
cancel(Cfg, Req) ->
    PiId = maps:get(payment_intent, Req),
    Url = <<(base_url(Cfg))/binary, "/v1/payment_intents/", PiId/binary, "/cancel">>,
    Headers = [{<<"Authorization">>, bearer(Cfg)}],
    case epay_http:post_form(Url, Headers, <<>>) of
        {ok, Status, _H, Body} when Status >= 200, Status < 300 ->
            parse_cancel(Body);
        {ok, _S, _H, Body} ->
            {error, stripe_err_msg(Body)};
        {error, Reason} ->
            {error, http_err_bin(Reason)}
    end.

-spec parse_cancel(binary()) -> {ok, map()} | epay_gateway:err().
parse_cancel(Body) ->
    case epay_util:json_decode(Body) of
        {ok, #{<<"status">> := St} = Resp} ->
            {ok, #{type => stripe_cancel, raw_state => St, raw => Resp}};
        {ok, Resp} when is_map(Resp) ->
            {ok, #{type => stripe_cancel, raw => Resp}};
        _ ->
            {error, {invalid_response, <<"Stripe 取消响应解析失败"/utf8>>}}
    end.

%%%===================================================================
%%% epay_gateway behaviour
%%%===================================================================

%% @doc 下单（创建 PaymentIntent）。Order :: #{out_trade_no, amount_fen, currency => binary()}
-spec create_payment(map(), map()) -> {ok, map()} | epay_gateway:err().
create_payment(Cfg, Order) ->
    case create_payment_intent(Cfg, Order) of
        {ok, #{id := Id, client_secret := Secret}} ->
            {ok, #{type => stripe_payment_intent, payment_no => Id, client_secret => Secret}};
        {error, _} = Err ->
            Err
    end.

%% @doc Webhook 验签。Ctx :: #{headers := map(), body := binary()}。
%% 验签通过返回 {ok, EventMap}（已解析的 Stripe event JSON）。
-spec verify_notify(map(), map()) -> {ok, map()} | epay_gateway:err().
verify_notify(Cfg, Ctx) ->
    Headers = maps:get(headers, Ctx, #{}),
    Body = maps:get(body, Ctx, <<>>),
    SigHeader = stripe_sig_header(Headers),
    case verify_webhook(Cfg, SigHeader, Body) of
        ok ->
            case epay_util:json_decode(Body) of
                {ok, Event} when is_map(Event) -> {ok, Event};
                _ -> {error, {bad_event_json, <<"Stripe 事件 JSON 解析失败"/utf8>>}}
            end;
        {error, _} = Err ->
            Err
    end.

-spec stripe_sig_header(map()) -> binary().
stripe_sig_header(Headers) ->
    case maps:get(<<"stripe-signature">>, Headers, <<>>) of
        V when is_binary(V) -> V;
        V when is_list(V) -> iolist_to_binary(V);
        _ -> <<>>
    end.

%%%===================================================================
%%% 创建 PaymentIntent
%%%===================================================================

%% @doc 创建 PaymentIntent。Req :: #{amount_fen, out_trade_no, currency => binary()}
-spec create_payment_intent(map(), map()) ->
    {ok, #{id := binary(), client_secret := binary()}} | epay_gateway:err().
create_payment_intent(Cfg, Req) ->
    Currency = maps:get(currency, Req, maps:get(currency, Cfg, <<"usd">>)),
    OutTradeNo = maps:get(out_trade_no, Req),
    Form = epay_util:form_encode([
        {<<"amount">>, maps:get(amount_fen, Req)},
        {<<"currency">>, Currency},
        {<<"automatic_payment_methods[enabled]">>, <<"true">>},
        {<<"metadata[out_trade_no]">>, OutTradeNo}
    ]),
    Headers = [
        {<<"Authorization">>, bearer(Cfg)},
        %% 幂等键：同一充值订单重复下单不会创建多个 PaymentIntent
        {<<"Idempotency-Key">>, <<"pi_", OutTradeNo/binary>>}
    ],
    Url = <<(base_url(Cfg))/binary, "/v1/payment_intents">>,
    case epay_http:post_form(Url, Headers, Form) of
        {ok, Status, _H, Body} when Status >= 200, Status < 300 ->
            parse_payment_intent(Body);
        {ok, _Status, _H, Body} ->
            {error, stripe_err_msg(Body)};
        {error, Reason} ->
            {error, http_err_bin(Reason)}
    end.

-spec parse_payment_intent(binary()) -> {ok, map()} | epay_gateway:err().
parse_payment_intent(Body) ->
    case epay_util:json_decode(Body) of
        {ok, #{<<"id">> := Id, <<"client_secret">> := Secret}} ->
            {ok, #{id => Id, client_secret => Secret}};
        _ ->
            {error, {invalid_response, <<"Stripe 响应缺少 id/client_secret"/utf8>>}}
    end.

%%%===================================================================
%%% 退款
%%%===================================================================

%% @doc 退款。Req :: #{payment_intent := binary(), amount_fen => integer()}
-spec refund(map(), map()) -> {ok, map()} | epay_gateway:err().
refund(Cfg, Req) ->
    Pi = maps:get(payment_intent, Req),
    Base = [{<<"payment_intent">>, Pi}],
    Pairs =
        case maps:get(amount_fen, Req, undefined) of
            undefined -> Base;
            Amt -> Base ++ [{<<"amount">>, Amt}]
        end,
    Form = epay_util:form_encode(Pairs),
    Headers = [{<<"Authorization">>, bearer(Cfg)}],
    Url = <<(base_url(Cfg))/binary, "/v1/refunds">>,
    case epay_http:post_form(Url, Headers, Form) of
        {ok, Status, _H, Body} when Status >= 200, Status < 300 ->
            parse_refund(Body);
        {ok, _Status, _H, Body} ->
            {error, stripe_err_msg(Body)};
        {error, Reason} ->
            {error, http_err_bin(Reason)}
    end.

-spec parse_refund(binary()) -> {ok, map()} | epay_gateway:err().
parse_refund(Body) ->
    case epay_util:json_decode(Body) of
        {ok, #{<<"status">> := Status} = Resp} ->
            case lists:member(Status, [<<"succeeded">>, <<"pending">>]) of
                true -> {ok, Resp};
                false -> {error, {gateway_error, <<"Stripe 退款状态:"/utf8, Status/binary>>}}
            end;
        {ok, Resp} when is_map(Resp) ->
            {ok, Resp};
        _ ->
            {error, {invalid_response, <<"Stripe 退款响应解析失败"/utf8>>}}
    end.

%%%===================================================================
%%% Webhook 验签
%%%===================================================================

%% @doc 验证 Stripe-Signature 头。SigHeader 形如 "t=NNN,v1=hex[,v1=hex2]"。
-spec verify_webhook(map(), binary(), binary()) -> ok | epay_gateway:err().
verify_webhook(Cfg, SigHeader, RawBody) ->
    Secret = maps:get(webhook_secret, Cfg, <<>>),
    case Secret of
        <<>> ->
            {error, {no_credential, <<"缺少 Stripe webhook_secret"/utf8>>}};
        _ ->
            case parse_sig_header(SigHeader) of
                {ok, TsBin, V1List} ->
                    case check_timestamp(TsBin) of
                        ok -> verify_v1(Secret, TsBin, RawBody, V1List);
                        {error, _} = E -> E
                    end;
                error ->
                    {error, {malformed_signature, <<"Stripe-Signature 头格式非法"/utf8>>}}
            end
    end.

-spec verify_v1(binary(), binary(), binary(), [binary()]) -> ok | epay_gateway:err().
verify_v1(Secret, TsBin, RawBody, V1List) ->
    SignedPayload = <<TsBin/binary, ".", RawBody/binary>>,
    Expected = epay_crypto:hmac_sha256_hex(Secret, SignedPayload),
    %% 任一 v1 匹配即通过（Stripe 轮换期可能多个 v1），逐一常量时间比较
    case lists:any(fun(V1) -> epay_crypto:constant_time_equal(Expected, V1) end, V1List) of
        true -> ok;
        false -> {error, {bad_signature, <<"Stripe webhook 验签失败"/utf8>>}}
    end.

%% 解析 "t=NNN,v1=aaa,v1=bbb,v0=..." -> {ok, <<"NNN">>, [<<"aaa">>,<<"bbb">>]}
-spec parse_sig_header(binary()) -> {ok, binary(), [binary()]} | error.
parse_sig_header(Header) when is_binary(Header) ->
    Parts = binary:split(Header, <<",">>, [global]),
    {Ts, V1s} = lists:foldl(
        fun(Part, {TsAcc, V1Acc}) ->
            case binary:split(Part, <<"=">>) of
                [<<"t">>, T] -> {T, V1Acc};
                [<<"v1">>, V] -> {TsAcc, [V | V1Acc]};
                _ -> {TsAcc, V1Acc}
            end
        end,
        {<<>>, []},
        Parts
    ),
    case {Ts, V1s} of
        {<<>>, _} -> error;
        {_, []} -> error;
        _ -> {ok, Ts, V1s}
    end;
parse_sig_header(_) ->
    error.

-spec check_timestamp(binary()) -> ok | epay_gateway:err().
check_timestamp(TsBin) ->
    try
        Ts = binary_to_integer(TsBin),
        Now = erlang:system_time(second),
        case abs(Now - Ts) > ?WEBHOOK_TOLERANCE of
            true -> {error, {timestamp_expired, <<"Stripe webhook 时间戳超出容差窗口"/utf8>>}};
            false -> ok
        end
    catch
        _:_ -> {error, {invalid_timestamp, <<"Stripe webhook 时间戳非法"/utf8>>}}
    end.

%%%===================================================================
%%% Internal
%%%===================================================================

-spec bearer(map()) -> binary().
bearer(Cfg) ->
    <<"Bearer ", (maps:get(secret_key, Cfg))/binary>>.

-spec base_url(map()) -> binary().
base_url(Cfg) ->
    maps:get(base_url, Cfg, ?BASE_URL).

%% 网关业务错误（HTTP 非 2xx）：取 Stripe error.message，打 {gateway_error, Msg}。
-spec stripe_err_msg(binary()) -> {atom(), binary()}.
stripe_err_msg(Body) ->
    Msg =
        case epay_util:json_decode(Body) of
            {ok, #{<<"error">> := #{<<"message">> := M}}} -> M;
            _ -> <<"Stripe 接口错误"/utf8>>
        end,
    {gateway_error, Msg}.

%% 传输层错误（inets）：打 {http_error, Msg}。
-spec http_err_bin(term()) -> {atom(), binary()}.
http_err_bin(R) ->
    {http_error, iolist_to_binary(io_lib:format("~p", [R]))}.

%%%===================================================================
%%% 主动查单（GET /v1/payment_intents/{id}）
%%%===================================================================

%% @doc 查 PaymentIntent 状态。Q :: #{payment_intent := binary()}。
-spec query(map(), map()) -> {ok, map()} | epay_gateway:err().
query(Cfg, Q) ->
    PiId = maps:get(payment_intent, Q),
    Url = <<(base_url(Cfg))/binary, "/v1/payment_intents/", PiId/binary>>,
    Headers = [{<<"Authorization">>, bearer(Cfg)}],
    case epay_http:get(Url, Headers) of
        {ok, Status, _H, Body} when Status >= 200, Status < 300 ->
            parse_intent(Body);
        {ok, _S, _H, Body} ->
            {error, stripe_err_msg(Body)};
        {error, Reason} ->
            {error, http_err_bin(Reason)}
    end.

-spec parse_intent(binary()) -> {ok, map()} | epay_gateway:err().
parse_intent(Body) ->
    case epay_util:json_decode(Body) of
        {ok, #{<<"status">> := St} = Resp} ->
            {ok, #{trade_state => map_stripe_state(St), raw_state => St, raw => Resp}};
        {ok, Resp} when is_map(Resp) ->
            {ok, #{trade_state => unknown, raw => Resp}};
        _ ->
            {error, {invalid_response, <<"Stripe 查询响应解析失败"/utf8>>}}
    end.

-spec map_stripe_state(binary()) -> atom().
map_stripe_state(<<"succeeded">>) -> success;
map_stripe_state(<<"processing">>) -> pending;
map_stripe_state(<<"requires_payment_method">>) -> pending;
map_stripe_state(<<"requires_confirmation">>) -> pending;
map_stripe_state(<<"requires_action">>) -> pending;
map_stripe_state(<<"requires_capture">>) -> pending;
map_stripe_state(<<"canceled">>) -> closed;
map_stripe_state(_) -> unknown.

%%%===================================================================
%%% 对账（Reporting：POST /v1/reporting/report_runs）
%%%===================================================================

%% @doc 创建对账报告任务。Req :: #{report_type => binary(),
%%   interval_start => integer(), interval_end => integer()}。
-spec download_bill(map(), map()) -> {ok, map()} | epay_gateway:err().
download_bill(Cfg, Req) ->
    ReportType = maps:get(report_type, Req, <<"balance.summary.1">>),
    Form = epay_util:form_encode(bill_pairs(ReportType, Req)),
    Headers = [{<<"Authorization">>, bearer(Cfg)}],
    Url = <<(base_url(Cfg))/binary, "/v1/reporting/report_runs">>,
    case epay_http:post_form(Url, Headers, Form) of
        {ok, Status, _H, Body} when Status >= 200, Status < 300 ->
            parse_report_run(Body);
        {ok, _S, _H, Body} ->
            {error, stripe_err_msg(Body)};
        {error, Reason} ->
            {error, http_err_bin(Reason)}
    end.

-spec bill_pairs(binary(), map()) -> [{binary(), binary()}].
bill_pairs(ReportType, Req) ->
    Base = [{<<"report_type">>, ReportType}],
    P1 = maybe_param(<<"parameters[interval_start]">>, maps:get(interval_start, Req, undefined), Base),
    maybe_param(<<"parameters[interval_end]">>, maps:get(interval_end, Req, undefined), P1).

-spec maybe_param(binary(), integer() | undefined, [{binary(), binary()}]) -> [{binary(), binary()}].
maybe_param(_Key, undefined, Acc) -> Acc;
maybe_param(Key, Ts, Acc) when is_integer(Ts) -> Acc ++ [{Key, integer_to_binary(Ts)}].

-spec parse_report_run(binary()) -> {ok, map()} | epay_gateway:err().
parse_report_run(Body) ->
    case epay_util:json_decode(Body) of
        {ok, #{<<"id">> := Id} = Resp} ->
            {ok, #{type => stripe_report_run, report_run_id => Id,
                   status => maps:get(<<"status">>, Resp, <<>>), raw => Resp}};
        _ ->
            {error, {invalid_response, <<"Stripe 报告响应缺少 id"/utf8>>}}
    end.
