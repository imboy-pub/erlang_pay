-module(epay_capabilities_tests).
%%%===================================================================
%%% @doc capabilities/0 能力声明 EUnit —— 三网关显式能力清单 + 门面据此分发。
%%% 纯函数（不发 HTTP），验证能力注册表替代 function_exported 反射。
%%% @end
%%%===================================================================
-include_lib("eunit/include/eunit.hrl").

%%%-------------------------------------------------------------------
%%% 各网关能力清单
%%%-------------------------------------------------------------------
wechat_caps_test() ->
    Caps = epay_wechat:capabilities(),
    ?assert(lists:member(create_payment, Caps)),
    ?assert(lists:member(build_pay_sign, Caps)),
    ?assert(lists:member(query, Caps)).

stripe_caps_no_pay_sign_test() ->
    Caps = epay_stripe:capabilities(),
    ?assert(lists:member(create_payment, Caps)),
    ?assertNot(lists:member(build_pay_sign, Caps)).

alipay_caps_no_pay_sign_test() ->
    Caps = epay_alipay:capabilities(),
    ?assert(lists:member(refund, Caps)),
    ?assertNot(lists:member(build_pay_sign, Caps)).

%%%-------------------------------------------------------------------
%%% 门面 capabilities/1 与 supports/2
%%%-------------------------------------------------------------------
facade_capabilities_test() ->
    ?assertMatch({ok, [_ | _]}, erlang_pay:capabilities(wechat)),
    ?assertMatch({ok, [_ | _]}, erlang_pay:capabilities(stripe)).

facade_capabilities_unknown_test() ->
    ?assertMatch({error, {unknown_gateway, _}}, erlang_pay:capabilities(foobar)).

facade_supports_test() ->
    ?assert(erlang_pay:supports(wechat, build_pay_sign)),
    ?assertNot(erlang_pay:supports(stripe, build_pay_sign)),
    ?assert(erlang_pay:supports(alipay, refund)).

facade_supports_unknown_gateway_test() ->
    ?assertNot(erlang_pay:supports(foobar, create_payment)).
