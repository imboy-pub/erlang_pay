-module(epay_bill_tests).
%%%===================================================================
%%% @doc download_bill/2 对账接口 EUnit —— 三网关获取对账文件下载入口。
%%% 网关 HTTP 一律 meck mock，绝不发真实请求。
%%% @end
%%%===================================================================
-include_lib("eunit/include/eunit.hrl").

-define(WX_CFG, #{mch_id => <<"M1">>, mch_serial_no => <<"S1">>, private_key => <<"K1">>}).
-define(ST_CFG, #{secret_key => <<"sk_test">>}).
-define(AL_CFG, #{app_id => <<"A1">>, private_key => <<"K1">>}).

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

mock_get(Body) ->
    meck:expect(epay_http, get, fun(_U, _H) -> {ok, 200, [], Body} end).

mock_post_form(Body) ->
    meck:expect(epay_http, post_form, fun(_U, _H, _B) -> {ok, 200, [], Body} end).

%%%-------------------------------------------------------------------
%%% 微信
%%%-------------------------------------------------------------------
wechat_bill_ok_test() ->
    with_mocks(fun() ->
        mock_get(<<"{\"download_url\":\"https://wx/bill.gz\",\"hash_value\":\"abc\"}">>),
        ?assertMatch(
            {ok, #{type := wechat_bill, download_url := <<"https://wx/bill.gz">>}},
            epay_wechat:download_bill(?WX_CFG, #{bill_date => <<"2024-01-01">>})
        )
    end).

wechat_bill_missing_url_test() ->
    with_mocks(fun() ->
        mock_get(<<"{\"code\":\"NO_BILL\"}">>),
        ?assertMatch(
            {error, _}, epay_wechat:download_bill(?WX_CFG, #{bill_date => <<"2024-01-01">>})
        )
    end).

%%%-------------------------------------------------------------------
%%% 支付宝
%%%-------------------------------------------------------------------
alipay_bill_ok_test() ->
    with_mocks(fun() ->
        mock_post_form(
            <<"{\"alipay_data_dataservice_bill_downloadurl_query_response\":{\"code\":\"10000\",\"bill_download_url\":\"https://oss/bill.zip\"}}">>
        ),
        ?assertMatch(
            {ok, #{type := alipay_bill, download_url := <<"https://oss/bill.zip">>}},
            epay_alipay:download_bill(?AL_CFG, #{bill_date => <<"2024-01-01">>})
        )
    end).

alipay_bill_biz_error_test() ->
    with_mocks(fun() ->
        mock_post_form(
            <<"{\"alipay_data_dataservice_bill_downloadurl_query_response\":{\"code\":\"40004\",\"sub_msg\":\"账单不存在\"}}"/utf8>>
        ),
        ?assertMatch(
            {error, _}, epay_alipay:download_bill(?AL_CFG, #{bill_date => <<"2024-01-01">>})
        )
    end).

%%%-------------------------------------------------------------------
%%% Stripe
%%%-------------------------------------------------------------------
stripe_bill_ok_test() ->
    with_mocks(fun() ->
        mock_post_form(<<"{\"id\":\"frr_123\",\"status\":\"pending\"}">>),
        ?assertMatch(
            {ok, #{type := stripe_report_run, report_run_id := <<"frr_123">>, status := <<"pending">>}},
            epay_stripe:download_bill(?ST_CFG, #{
                interval_start => 1700000000, interval_end => 1700086400
            })
        )
    end).

stripe_bill_missing_id_test() ->
    with_mocks(fun() ->
        mock_post_form(<<"{\"error\":{\"message\":\"bad\"}}">>),
        ?assertMatch({error, _}, epay_stripe:download_bill(?ST_CFG, #{}))
    end).

%%%-------------------------------------------------------------------
%%% 门面分发
%%%-------------------------------------------------------------------
facade_bill_dispatch_test() ->
    with_mocks(fun() ->
        mock_post_form(<<"{\"id\":\"frr_9\",\"status\":\"succeeded\"}">>),
        ?assertMatch(
            {ok, #{type := stripe_report_run}},
            erlang_pay:download_bill(stripe, ?ST_CFG, #{})
        )
    end).

facade_bill_unknown_gateway_test() ->
    ?assertEqual(
        {error, <<"未知支付网关"/utf8>>},
        erlang_pay:download_bill(foobar, #{}, #{})
    ).
