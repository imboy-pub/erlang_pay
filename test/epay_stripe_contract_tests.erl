-module(epay_stripe_contract_tests).
%%%===================================================================
%%% @doc Stripe refund 幂等与状态合同 EUnit（EP-10，测试先行）。
%%%
%%% 幂等键合同（对照 create_payment_intent 的 <<"pi_", No/binary>> 惯例）：
%%%   - refund/2 必须携带 Idempotency-Key 头：显式 idempotency_key 优先，
%%%     否则由 out_refund_no 派生稳定键 <<"rf_", No/binary>>；
%%%   - 两者皆缺 → {error, {bad_request, _}} 且绝不发送 HTTP POST；
%%%   - 禁止用 payment_intent 当键（同一 PI 允许多次部分退款）：
%%%     同退款号两次调用生成相同键，不同退款号生成不同键。
%%%
%%% 状态合同（官方 Refund.status 枚举 pending/requires_action/succeeded/
%%% failed/canceled）：
%%%   - succeeded | pending → {ok, Resp}；
%%%   - requires_action | failed | canceled | 未知值 →
%%%     {error, {refund_failed, Msg}}，Msg 含状态原文；
%%%   - 2xx 响应缺 status → {error, {invalid_refund_response, _}}，
%%%     不得 fallthrough {ok, _}；非 JSON 维持 invalid_response。
%%%
%%% HTTP 一律 meck mock，绝不发真实请求；密钥仅用 fixture 占位。
%%% 每用例 try...after 保证 mock 必被卸载。
%%% @end
%%%===================================================================
-include_lib("eunit/include/eunit.hrl").

-define(STRIPE_CFG, #{secret_key => <<"sk_test_FIXTURE">>}).

%%%-------------------------------------------------------------------
%%% 公共 mock 脚手架
%%%-------------------------------------------------------------------

%% mock epay_http:post_form 统一返回 2xx + RespBody；调用参数经
%% meck:history 捕获，供断言请求头 / 零调用。
with_post_mock(RespBody, Fun) ->
    meck:new(epay_http, [passthrough]),
    meck:expect(epay_http, post_form,
                fun(_Url, _Headers, _Body) -> {ok, 200, [], RespBody} end),
    try
        Fun()
    after
        meck:unload(epay_http)
    end.

%% 从 meck 历史提取每次 post_form 调用捕获的 Headers（每次调用一项）。
%% meck history 条目格式：{CallerPid, {Mod, Func, Args}, Result}
captured_post_headers() ->
    [Headers
     || {_Pid, {epay_http, post_form, [_Url, Headers, _Body]}, _Result}
            <- meck:history(epay_http)].

-spec idem_key([{binary(), binary()}]) -> binary() | undefined.
idem_key(Headers) ->
    proplists:get_value(<<"Idempotency-Key">>, Headers).

%% 标准合法退款请求（out_refund_no 派生幂等键路径），可用 Overrides 覆盖字段
refund_req(Overrides) when is_map(Overrides) ->
    maps:merge(#{payment_intent => <<"pi_FIXTURE">>, out_refund_no => <<"R1">>},
               Overrides).

%%%===================================================================
%%% 幂等键合同
%%%===================================================================

%% 缺 idempotency_key 与 out_refund_no → bad_request，且绝不发送 HTTP POST
idem_missing_both_rejects_without_http_test() ->
    with_post_mock(<<"{\"status\":\"succeeded\"}">>, fun() ->
        Req = #{payment_intent => <<"pi_FIXTURE">>},
        ?assertMatch({error, {bad_request, _}},
                     epay_stripe:refund(?STRIPE_CFG, Req)),
        %% 零调用断言：历史里不得出现任何 epay_http 调用
        ?assertEqual([], meck:history(epay_http))
    end).

%% out_refund_no → 派生 rf_ 前缀幂等键，请求头必须携带且值正确
idem_out_refund_no_derives_rf_key_test() ->
    with_post_mock(<<"{\"status\":\"succeeded\"}">>, fun() ->
        ?assertMatch({ok, _},
                     epay_stripe:refund(?STRIPE_CFG,
                                        refund_req(#{out_refund_no => <<"R01">>}))),
        [Headers] = captured_post_headers(),
        ?assertEqual(<<"rf_R01">>, idem_key(Headers))
    end).

%% 显式 idempotency_key 优先于 out_refund_no 派生
idem_explicit_key_takes_precedence_test() ->
    with_post_mock(<<"{\"status\":\"succeeded\"}">>, fun() ->
        Req = refund_req(#{
            out_refund_no => <<"R02">>,
            idempotency_key => <<"merchant-custom-key">>
        }),
        ?assertMatch({ok, _}, epay_stripe:refund(?STRIPE_CFG, Req)),
        [Headers] = captured_post_headers(),
        ?assertEqual(<<"merchant-custom-key">>, idem_key(Headers))
    end).

%% 同一退款号两次调用 → 相同幂等键；不同退款号 → 不同键
%% （禁止用 payment_intent 派生：同一 PI 允许多次部分退款）
idem_same_no_same_key_diff_no_diff_key_test() ->
    with_post_mock(<<"{\"status\":\"succeeded\"}">>, fun() ->
        Base = #{payment_intent => <<"pi_FIXTURE">>},
        ?assertMatch({ok, _},
                     epay_stripe:refund(?STRIPE_CFG, Base#{out_refund_no => <<"RA">>})),
        ?assertMatch({ok, _},
                     epay_stripe:refund(?STRIPE_CFG, Base#{out_refund_no => <<"RA">>})),
        ?assertMatch({ok, _},
                     epay_stripe:refund(?STRIPE_CFG, Base#{out_refund_no => <<"RB">>})),
        [H1, H2, H3] = captured_post_headers(),
        ?assertEqual(<<"rf_RA">>, idem_key(H1)),
        ?assertEqual(idem_key(H1), idem_key(H2)),
        ?assertNotEqual(idem_key(H1), idem_key(H3))
    end).

%%%===================================================================
%%% 状态合同（官方枚举 pending/requires_action/succeeded/failed/canceled）
%%%===================================================================

%% status=succeeded → {ok, Resp}
status_succeeded_ok_test() ->
    with_post_mock(<<"{\"id\":\"re_FIXTURE\",\"status\":\"succeeded\"}">>, fun() ->
        ?assertMatch({ok, #{<<"status">> := <<"succeeded">>}},
                     epay_stripe:refund(?STRIPE_CFG, refund_req(#{})))
    end).

%% status=pending → {ok, Resp}
status_pending_ok_test() ->
    with_post_mock(<<"{\"id\":\"re_FIXTURE\",\"status\":\"pending\"}">>, fun() ->
        ?assertMatch({ok, #{<<"status">> := <<"pending">>}},
                     epay_stripe:refund(?STRIPE_CFG, refund_req(#{})))
    end).

%% requires_action/failed/canceled/未知状态 → {refund_failed, Msg 含状态原文}
status_non_success_is_refund_failed_test() ->
    Statuses = [<<"failed">>, <<"canceled">>, <<"requires_action">>, <<"unknown_val">>],
    lists:foreach(fun(St) ->
        Body = <<"{\"id\":\"re_FIXTURE\",\"status\":\"", St/binary, "\"}">>,
        with_post_mock(Body, fun() ->
            Res = epay_stripe:refund(?STRIPE_CFG, refund_req(#{})),
            ?assertMatch({error, {refund_failed, _}}, Res),
            {error, {refund_failed, Msg}} = Res,
            %% 错误文案必须包含网关返回的状态原文，便于对账排障
            ?assertNotEqual(nomatch, binary:match(Msg, St))
        end)
    end, Statuses).

%% 2xx 响应缺 status → {invalid_refund_response, _}（修复 fallthrough {ok,_} 缺陷）
missing_status_is_invalid_refund_response_test() ->
    with_post_mock(<<"{\"id\":\"re_FIXTURE\",\"amount\":100}">>, fun() ->
        ?assertMatch({error, {invalid_refund_response, _}},
                     epay_stripe:refund(?STRIPE_CFG, refund_req(#{})))
    end).

%% 非 JSON 响应 → 维持 {invalid_response, _}
non_json_is_invalid_response_test() ->
    with_post_mock(<<"not-json">>, fun() ->
        ?assertMatch({error, {invalid_response, _}},
                     epay_stripe:refund(?STRIPE_CFG, refund_req(#{})))
    end).
