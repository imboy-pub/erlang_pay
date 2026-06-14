-module(epay_notify_state_tests).
%%%===================================================================
%%% @doc verify_notify 回调归一 trade_state EUnit —— 三网关。
%%%
%%% 对标 omnipay NotificationInterface：回调验签通过后，除原始字段外统一
%%% 附带 trade_state（epay_state:state()），调用方无须再按网关挖 raw。
%%%
%%%   - stripe : 真实 HMAC（复用 webhook 路径），事件 type → trade_state
%%%   - alipay : meck rsa_verify → true，表单 trade_status → trade_state
%%%   - wechat : meck rsa_verify→true + aes 解密返回明文，resource trade_state
%%%
%%% 断言「加性」：trade_state 注入后原始 raw 字段仍在。
%%% @end
%%%===================================================================
-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%%% Stripe —— 真实 HMAC，事件 type → trade_state
%%%===================================================================
-define(ST_SECRET, <<"whsec_test_123">>).

st_cfg() -> #{webhook_secret => ?ST_SECRET}.

st_sig_header(Ts, Body) ->
    TsBin = integer_to_binary(Ts),
    Payload = <<TsBin/binary, ".", Body/binary>>,
    V1 = epay_crypto:hmac_sha256_hex(?ST_SECRET, Payload),
    <<"t=", TsBin/binary, ",v1=", V1/binary>>.

st_ctx(Body) ->
    Ts = erlang:system_time(second),
    #{headers => #{<<"stripe-signature">> => st_sig_header(Ts, Body)}, body => Body}.

stripe_succeeded_event_test() ->
    Body = <<"{\"id\":\"evt_1\",\"type\":\"payment_intent.succeeded\"}">>,
    {ok, Event} = epay_stripe:verify_notify(st_cfg(), st_ctx(Body)),
    ?assertEqual(success, maps:get(trade_state, Event)),
    %% 加性：原始字段仍在
    ?assertEqual(<<"evt_1">>, maps:get(<<"id">>, Event)).

stripe_processing_event_test() ->
    Body = <<"{\"id\":\"evt_2\",\"type\":\"payment_intent.processing\"}">>,
    {ok, Event} = epay_stripe:verify_notify(st_cfg(), st_ctx(Body)),
    ?assertEqual(pending, maps:get(trade_state, Event)).

stripe_failed_event_test() ->
    Body = <<"{\"id\":\"evt_3\",\"type\":\"payment_intent.payment_failed\"}">>,
    {ok, Event} = epay_stripe:verify_notify(st_cfg(), st_ctx(Body)),
    ?assertEqual(error, maps:get(trade_state, Event)).

stripe_refunded_event_test() ->
    Body = <<"{\"id\":\"evt_4\",\"type\":\"charge.refunded\"}">>,
    {ok, Event} = epay_stripe:verify_notify(st_cfg(), st_ctx(Body)),
    ?assertEqual(refunded, maps:get(trade_state, Event)).

stripe_unknown_event_test() ->
    Body = <<"{\"id\":\"evt_5\",\"type\":\"customer.created\"}">>,
    {ok, Event} = epay_stripe:verify_notify(st_cfg(), st_ctx(Body)),
    ?assertEqual(unknown, maps:get(trade_state, Event)).

%% 归一值必属 canonical 集合
stripe_state_is_canonical_test() ->
    Body = <<"{\"id\":\"evt_6\",\"type\":\"payment_intent.succeeded\"}">>,
    {ok, Event} = epay_stripe:verify_notify(st_cfg(), st_ctx(Body)),
    ?assert(epay_state:is_state(maps:get(trade_state, Event))).

%%%===================================================================
%%% Alipay —— meck rsa_verify→true，trade_status → trade_state
%%%===================================================================
al_cfg() -> #{public_key => <<"pk">>}.

%% sign 为合法 base64（<<"YWJj">> = "abc"），令 safe_b64_decode 通过后由 meck 接管验签
al_form(TradeStatus) ->
    #{<<"sign">> => <<"YWJj">>,
      <<"out_trade_no">> => <<"X1">>,
      <<"trade_status">> => TradeStatus}.

with_alipay_verify(Fun) ->
    meck:new(epay_crypto, [passthrough]),
    meck:expect(epay_crypto, rsa_verify_sha256, fun(_, _, _) -> true end),
    try Fun()
    after meck:unload(epay_crypto)
    end.

alipay_success_notify_test() ->
    with_alipay_verify(fun() ->
        {ok, Form} = epay_alipay:verify_notify(al_cfg(), #{form => al_form(<<"TRADE_SUCCESS">>)}),
        ?assertEqual(success, maps:get(trade_state, Form)),
        ?assertEqual(<<"X1">>, maps:get(<<"out_trade_no">>, Form))
    end).

alipay_pending_notify_test() ->
    with_alipay_verify(fun() ->
        {ok, Form} = epay_alipay:verify_notify(al_cfg(), #{form => al_form(<<"WAIT_BUYER_PAY">>)}),
        ?assertEqual(pending, maps:get(trade_state, Form))
    end).

alipay_closed_notify_test() ->
    with_alipay_verify(fun() ->
        {ok, Form} = epay_alipay:verify_notify(al_cfg(), #{form => al_form(<<"TRADE_CLOSED">>)}),
        ?assertEqual(closed, maps:get(trade_state, Form))
    end).

%%%===================================================================
%%% Wechat —— meck rsa_verify→true + aes 解密返回明文 resource
%%%===================================================================
wx_cfg() ->
    #{platform_public_key => <<"pk">>, api_v3_key => <<"k">>}.

%% RawBody 须含 resource{ciphertext,nonce,associated_data}；解密由 meck 返回明文 JSON
wx_raw_body() ->
    <<"{\"resource\":{\"ciphertext\":\"YWJj\",\"nonce\":\"n\",\"associated_data\":\"a\"}}">>.

wx_headers() ->
    #{<<"wechatpay-timestamp">> => integer_to_binary(erlang:system_time(second)),
      <<"wechatpay-nonce">> => <<"nonce1">>,
      <<"wechatpay-signature">> => <<"YWJj">>}.

with_wechat_verify(PlainJson, Fun) ->
    meck:new(epay_crypto, [passthrough]),
    meck:expect(epay_crypto, rsa_verify_sha256, fun(_, _, _) -> true end),
    meck:expect(epay_crypto, aes_256_gcm_decrypt, fun(_, _, _, _) -> {ok, PlainJson} end),
    try Fun()
    after meck:unload(epay_crypto)
    end.

wechat_success_notify_test() ->
    Plain = <<"{\"trade_state\":\"SUCCESS\",\"out_trade_no\":\"X1\"}">>,
    with_wechat_verify(Plain, fun() ->
        {ok, M} = epay_wechat:verify_notify(wx_cfg(), wx_headers(), wx_raw_body()),
        ?assertEqual(success, maps:get(trade_state, M)),
        ?assertEqual(<<"X1">>, maps:get(<<"out_trade_no">>, M))
    end).

wechat_refund_notify_test() ->
    Plain = <<"{\"trade_state\":\"REFUND\"}">>,
    with_wechat_verify(Plain, fun() ->
        {ok, M} = epay_wechat:verify_notify(wx_cfg(), wx_headers(), wx_raw_body()),
        ?assertEqual(refunded, maps:get(trade_state, M))
    end).

%% resource 无 trade_state 字段（如退款回调旧格式）→ unknown，不崩溃
wechat_missing_state_notify_test() ->
    Plain = <<"{\"out_trade_no\":\"X1\"}">>,
    with_wechat_verify(Plain, fun() ->
        {ok, M} = epay_wechat:verify_notify(wx_cfg(), wx_headers(), wx_raw_body()),
        ?assertEqual(unknown, maps:get(trade_state, M))
    end).
