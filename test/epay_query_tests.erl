-module(epay_query_tests).
%%%===================================================================
%%% @doc query/2 主动查单 EUnit —— 三网关统一 trade_state 映射。
%%%
%%% 网关 HTTP 一律 meck mock，绝不发真实请求；微信/支付宝的请求签名
%%% mock epay_crypto:rsa_sign_sha256，使测试聚焦「请求构造 + 响应状态映射」。
%%% 每个用例自带 setup/teardown（try...after 保证 mock 必被卸载）。
%%% @end
%%%===================================================================
-include_lib("eunit/include/eunit.hrl").

-define(WX_CFG, #{mch_id => <<"M1">>, mch_serial_no => <<"S1">>, private_key => <<"K1">>}).
-define(ST_CFG, #{secret_key => <<"sk_test">>}).
-define(AL_CFG, #{app_id => <<"A1">>, private_key => <<"K1">>}).

%%%-------------------------------------------------------------------
%%% 公共 mock 脚手架
%%%-------------------------------------------------------------------
with_mocks(Fun) ->
    meck:new(epay_http, [passthrough]),
    meck:new(epay_crypto, [passthrough]),
    meck:expect(epay_crypto, rsa_sign_sha256, fun(_, _) -> {ok, <<"sig">>} end),
    try
        Fun()
    after
        meck:unload(epay_crypto),
        meck:unload(epay_http)
    end.

mock_get(RespBody) ->
    meck:expect(epay_http, get, fun(_Url, _Headers) -> {ok, 200, [], RespBody} end).

mock_post_form(RespBody) ->
    meck:expect(epay_http, post_form, fun(_Url, _Hdr, _Body) -> {ok, 200, [], RespBody} end).

wx_query(Body) ->
    mock_get(Body),
    epay_wechat:query(?WX_CFG, #{out_trade_no => <<"X1">>}).

st_query(Body) ->
    mock_get(Body),
    epay_stripe:query(?ST_CFG, #{payment_intent => <<"pi_1">>}).

al_query(Body) ->
    mock_post_form(Body),
    epay_alipay:query(?AL_CFG, #{out_trade_no => <<"X1">>}).

%%%-------------------------------------------------------------------
%%% 微信
%%%-------------------------------------------------------------------
wechat_success_test() ->
    with_mocks(fun() ->
        ?assertMatch(
            {ok, #{trade_state := success, raw_state := <<"SUCCESS">>}},
            wx_query(<<"{\"trade_state\":\"SUCCESS\",\"out_trade_no\":\"X1\"}">>)
        )
    end).

wechat_pending_test() ->
    with_mocks(fun() ->
        ?assertMatch({ok, #{trade_state := pending}}, wx_query(<<"{\"trade_state\":\"NOTPAY\"}">>))
    end).

wechat_closed_test() ->
    with_mocks(fun() ->
        ?assertMatch({ok, #{trade_state := closed}}, wx_query(<<"{\"trade_state\":\"CLOSED\"}">>))
    end).

wechat_unknown_state_test() ->
    with_mocks(fun() ->
        ?assertMatch({ok, #{trade_state := unknown}}, wx_query(<<"{\"trade_state\":\"WEIRD\"}">>))
    end).

wechat_http_error_test() ->
    with_mocks(fun() ->
        meck:expect(epay_http, get, fun(_, _) -> {error, timeout} end),
        %% T05：传输层错误统一为 {error, {http_error, Msg}}
        ?assertMatch(
            {error, {http_error, _}}, epay_wechat:query(?WX_CFG, #{out_trade_no => <<"X1">>})
        )
    end).

%%%-------------------------------------------------------------------
%%% Stripe
%%%-------------------------------------------------------------------
stripe_succeeded_test() ->
    with_mocks(fun() ->
        ?assertMatch(
            {ok, #{trade_state := success, raw_state := <<"succeeded">>}},
            st_query(<<"{\"status\":\"succeeded\",\"id\":\"pi_1\"}">>)
        )
    end).

stripe_processing_test() ->
    with_mocks(fun() ->
        ?assertMatch(
            {ok, #{trade_state := pending}}, st_query(<<"{\"status\":\"processing\",\"id\":\"pi_1\"}">>)
        )
    end).

stripe_canceled_test() ->
    with_mocks(fun() ->
        ?assertMatch(
            {ok, #{trade_state := closed}}, st_query(<<"{\"status\":\"canceled\",\"id\":\"pi_1\"}">>)
        )
    end).

%%%-------------------------------------------------------------------
%%% 支付宝
%%%-------------------------------------------------------------------
alipay_success_test() ->
    with_mocks(fun() ->
        ?assertMatch(
            {ok, #{trade_state := success, raw_state := <<"TRADE_SUCCESS">>}},
            al_query(
                <<"{\"alipay_trade_query_response\":{\"code\":\"10000\",\"trade_status\":\"TRADE_SUCCESS\"}}">>
            )
        )
    end).

alipay_wait_test() ->
    with_mocks(fun() ->
        ?assertMatch(
            {ok, #{trade_state := pending}},
            al_query(
                <<"{\"alipay_trade_query_response\":{\"code\":\"10000\",\"trade_status\":\"WAIT_BUYER_PAY\"}}">>
            )
        )
    end).

alipay_biz_error_test() ->
    with_mocks(fun() ->
        %% T05：网关业务错误统一为 {error, {gateway_error, Msg}}
        ?assertMatch(
            {error, {gateway_error, _}},
            al_query(
                <<"{\"alipay_trade_query_response\":{\"code\":\"40004\",\"sub_msg\":\"交易不存在\"}}"/utf8>>
            )
        )
    end).

%%%-------------------------------------------------------------------
%%% 门面分发
%%%-------------------------------------------------------------------
facade_dispatch_test() ->
    with_mocks(fun() ->
        mock_get(<<"{\"status\":\"succeeded\",\"id\":\"pi_1\"}">>),
        ?assertMatch(
            {ok, #{trade_state := success}},
            erlang_pay:query(stripe, ?ST_CFG, #{payment_intent => <<"pi_1">>})
        )
    end).

facade_unknown_gateway_test() ->
    ?assertMatch(
        {error, {unknown_gateway, _}},
        erlang_pay:query(foobar, #{}, #{})
    ).

%% T05：不支持的能力（Stripe 无 build_pay_sign/2）统一为 {error, {unsupported, _}}
facade_build_pay_sign_unsupported_test() ->
    ?assertMatch(
        {error, {unsupported, _}},
        erlang_pay:build_pay_sign(stripe, ?ST_CFG, #{})
    ).

%% T05：未知网关二次签名 → {error, {unknown_gateway, _}}
facade_build_pay_sign_unknown_test() ->
    ?assertMatch(
        {error, {unknown_gateway, _}},
        erlang_pay:build_pay_sign(foobar, #{}, #{})
    ).
