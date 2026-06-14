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
-export([create_payment/2, refund/2, verify_notify/2]).
%% 低层 API（直接使用）
-export([create_payment_intent/2, verify_webhook/3]).

-define(BASE_URL, <<"https://api.stripe.com">>).
-define(WEBHOOK_TOLERANCE, 300).

%%%===================================================================
%%% epay_gateway behaviour
%%%===================================================================

%% @doc 下单（创建 PaymentIntent）。Order :: #{out_trade_no, amount_fen, currency => binary()}
-spec create_payment(map(), map()) -> {ok, map()} | {error, binary()}.
create_payment(Cfg, Order) ->
    case create_payment_intent(Cfg, Order) of
        {ok, #{id := Id, client_secret := Secret}} ->
            {ok, #{type => stripe_payment_intent, payment_no => Id, client_secret => Secret}};
        {error, _} = Err ->
            Err
    end.

%% @doc Webhook 验签。Ctx :: #{headers := map(), body := binary()}。
%% 验签通过返回 {ok, EventMap}（已解析的 Stripe event JSON）。
-spec verify_notify(map(), map()) -> {ok, map()} | {error, atom()}.
verify_notify(Cfg, Ctx) ->
    Headers = maps:get(headers, Ctx, #{}),
    Body = maps:get(body, Ctx, <<>>),
    SigHeader = stripe_sig_header(Headers),
    case verify_webhook(Cfg, SigHeader, Body) of
        ok ->
            case epay_util:json_decode(Body) of
                {ok, Event} when is_map(Event) -> {ok, Event};
                _ -> {error, bad_event_json}
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
    {ok, #{id := binary(), client_secret := binary()}} | {error, binary()}.
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

-spec parse_payment_intent(binary()) -> {ok, map()} | {error, binary()}.
parse_payment_intent(Body) ->
    case epay_util:json_decode(Body) of
        {ok, #{<<"id">> := Id, <<"client_secret">> := Secret}} ->
            {ok, #{id => Id, client_secret => Secret}};
        _ ->
            {error, <<"Stripe 响应缺少 id/client_secret"/utf8>>}
    end.

%%%===================================================================
%%% 退款
%%%===================================================================

%% @doc 退款。Req :: #{payment_intent := binary(), amount_fen => integer()}
-spec refund(map(), map()) -> {ok, map()} | {error, binary()}.
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

-spec parse_refund(binary()) -> {ok, map()} | {error, binary()}.
parse_refund(Body) ->
    case epay_util:json_decode(Body) of
        {ok, #{<<"status">> := Status} = Resp} ->
            case lists:member(Status, [<<"succeeded">>, <<"pending">>]) of
                true -> {ok, Resp};
                false -> {error, <<"Stripe 退款状态:"/utf8, Status/binary>>}
            end;
        {ok, Resp} when is_map(Resp) ->
            {ok, Resp};
        _ ->
            {error, <<"Stripe 退款响应解析失败"/utf8>>}
    end.

%%%===================================================================
%%% Webhook 验签
%%%===================================================================

%% @doc 验证 Stripe-Signature 头。SigHeader 形如 "t=NNN,v1=hex[,v1=hex2]"。
-spec verify_webhook(map(), binary(), binary()) -> ok | {error, atom()}.
verify_webhook(Cfg, SigHeader, RawBody) ->
    Secret = maps:get(webhook_secret, Cfg, <<>>),
    case Secret of
        <<>> ->
            {error, no_credential};
        _ ->
            case parse_sig_header(SigHeader) of
                {ok, TsBin, V1List} ->
                    case check_timestamp(TsBin) of
                        ok -> verify_v1(Secret, TsBin, RawBody, V1List);
                        {error, _} = E -> E
                    end;
                error ->
                    {error, malformed_signature}
            end
    end.

-spec verify_v1(binary(), binary(), binary(), [binary()]) -> ok | {error, atom()}.
verify_v1(Secret, TsBin, RawBody, V1List) ->
    SignedPayload = <<TsBin/binary, ".", RawBody/binary>>,
    Expected = epay_crypto:hmac_sha256_hex(Secret, SignedPayload),
    %% 任一 v1 匹配即通过（Stripe 轮换期可能多个 v1），逐一常量时间比较
    case lists:any(fun(V1) -> epay_crypto:constant_time_equal(Expected, V1) end, V1List) of
        true -> ok;
        false -> {error, bad_signature}
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

-spec check_timestamp(binary()) -> ok | {error, atom()}.
check_timestamp(TsBin) ->
    try
        Ts = binary_to_integer(TsBin),
        Now = erlang:system_time(second),
        case abs(Now - Ts) > ?WEBHOOK_TOLERANCE of
            true -> {error, timestamp_expired};
            false -> ok
        end
    catch
        _:_ -> {error, invalid_timestamp}
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

-spec stripe_err_msg(binary()) -> binary().
stripe_err_msg(Body) ->
    case epay_util:json_decode(Body) of
        {ok, #{<<"error">> := #{<<"message">> := Msg}}} -> Msg;
        _ -> <<"Stripe 接口错误"/utf8>>
    end.

-spec http_err_bin(term()) -> binary().
http_err_bin(R) ->
    iolist_to_binary(io_lib:format("~p", [R])).
