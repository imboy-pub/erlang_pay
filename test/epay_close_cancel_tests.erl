-module(epay_close_cancel_tests).
%%%===================================================================
%%% @doc close/2 关单 + cancel/2 撤单 EUnit —— 按各网关支持度实现。
%%%   微信：close（无 cancel）；支付宝：close + cancel；Stripe：cancel（无 close）。
%%% 网关 HTTP 一律 meck mock，绝不发真实请求。门面据 capabilities 门控。
%%% @end
%%%===================================================================
-include_lib("eunit/include/eunit.hrl").

-define(WX_CFG, #{
    mch_id => <<"M1">>,
    mch_serial_no => <<"S1">>,
    private_key => <<"K1">>,
    platform_public_key => <<"PK1">>  %% EP-11：应答验签所需（meck 验签通过）
}).
-define(ST_CFG, #{secret_key => <<"sk_test">>}).
%% EP-12：同步应答需验签，公钥取合同测试 fixture（signed_body 用配套私钥签名）
-define(AL_CFG, #{app_id => <<"A1">>, private_key => <<"K1">>,
    public_key => epay_alipay_contract_tests:fixture_pub_pem()}).

with_mocks(Fun) ->
    meck:new(epay_http, [passthrough]),
    meck:new(epay_crypto, [passthrough]),
    meck:expect(epay_crypto, rsa_sign_sha256, fun(_, _) -> {ok, <<"sig">>} end),
    %% EP-11：2xx 应答先验签后解析——mock 验签通过（聚焦关单流程不变）
    meck:expect(epay_crypto, rsa_verify_sha256, fun(_, _, _) -> true end),
    try
        Fun()
    after
        meck:unload(epay_crypto),
        meck:unload(epay_http)
    end.

mock_post_json(Status, Body) ->
    meck:expect(epay_http, post_json, fun(_U, _H, _B) -> {ok, Status, wx_resp_hdrs(), Body} end).

%% EP-11：mock 应答补合法验签头（时间戳取当前时间，落在 ±300s 窗口内）
wx_resp_hdrs() ->
    [
        {"Wechatpay-Timestamp", integer_to_list(erlang:system_time(second))},
        {"Wechatpay-Nonce", "mock-nonce"},
        {"Wechatpay-Signature", "c2ln"},
        {"Wechatpay-Serial", "mock-serial"}
    ].

mock_post_form(Body) ->
    meck:expect(epay_http, post_form, fun(_U, _H, _B) -> {ok, 200, [], Body} end).

%%%-------------------------------------------------------------------
%%% 微信关单（成功 204 无 body）
%%%-------------------------------------------------------------------
wechat_close_ok_test() ->
    with_mocks(fun() ->
        mock_post_json(204, <<>>),
        ?assertMatch(
            {ok, #{type := wechat_close, out_trade_no := <<"X1">>}},
            epay_wechat:close(?WX_CFG, #{out_trade_no => <<"X1">>})
        )
    end).

wechat_close_error_test() ->
    with_mocks(fun() ->
        mock_post_json(400, <<"{\"code\":\"ORDER_CLOSED\",\"message\":\"已关闭\"}"/utf8>>),
        ?assertMatch(
            {error, {gateway_error, _}},
            epay_wechat:close(?WX_CFG, #{out_trade_no => <<"X1">>})
        )
    end).

%%%-------------------------------------------------------------------
%%% 支付宝关单 + 撤单
%%%-------------------------------------------------------------------
alipay_close_ok_test() ->
    with_mocks(fun() ->
        mock_post_form(
            epay_alipay_contract_tests:signed_body(
                <<"alipay_trade_close_response">>, <<"{\"code\":\"10000\"}">>
            )
        ),
        ?assertMatch(
            {ok, #{type := alipay_close}},
            epay_alipay:close(?AL_CFG, #{out_trade_no => <<"X1">>})
        )
    end).

alipay_cancel_ok_test() ->
    with_mocks(fun() ->
        mock_post_form(
            epay_alipay_contract_tests:signed_body(
                <<"alipay_trade_cancel_response">>,
                <<"{\"code\":\"10000\",\"action\":\"close\"}">>
            )
        ),
        ?assertMatch(
            {ok, #{type := alipay_cancel, action := <<"close">>}},
            epay_alipay:cancel(?AL_CFG, #{out_trade_no => <<"X1">>})
        )
    end).

%%%-------------------------------------------------------------------
%%% Stripe 撤单
%%%-------------------------------------------------------------------
stripe_cancel_ok_test() ->
    with_mocks(fun() ->
        mock_post_form(<<"{\"id\":\"pi_1\",\"status\":\"canceled\"}">>),
        ?assertMatch(
            {ok, #{type := stripe_cancel, raw_state := <<"canceled">>}},
            epay_stripe:cancel(?ST_CFG, #{payment_intent => <<"pi_1">>})
        )
    end).

%%%-------------------------------------------------------------------
%%% 门面能力门控
%%%-------------------------------------------------------------------
facade_close_ok_test() ->
    with_mocks(fun() ->
        mock_post_form(
            epay_alipay_contract_tests:signed_body(
                <<"alipay_trade_close_response">>, <<"{\"code\":\"10000\"}">>
            )
        ),
        ?assertMatch(
            {ok, #{type := alipay_close}},
            erlang_pay:close(alipay, ?AL_CFG, #{out_trade_no => <<"X1">>})
        )
    end).

%% Stripe 不支持 close → {error, {unsupported, _}}
facade_close_unsupported_test() ->
    ?assertMatch(
        {error, {unsupported, _}},
        erlang_pay:close(stripe, ?ST_CFG, #{payment_intent => <<"pi_1">>})
    ).

%% 微信不支持 cancel → {error, {unsupported, _}}
facade_cancel_unsupported_test() ->
    ?assertMatch(
        {error, {unsupported, _}},
        erlang_pay:cancel(wechat, ?WX_CFG, #{out_trade_no => <<"X1">>})
    ).

facade_close_unknown_gateway_test() ->
    ?assertMatch(
        {error, {unknown_gateway, _}},
        erlang_pay:close(foobar, #{}, #{})
    ).
