-module(epay_http_tests).
%%%===================================================================
%%% @doc EP-21 HTTPS-only 出站边界 EUnit —— validate_url 网络前拦截。
%%%
%%% meck httpc:request（4 参形态，与 epay_http 实际调用一致），
%%% 绝不发真实网络请求；"零调用"断言经 meck:history(httpc) 验证
%%% 校验失败时在 httpc 之前即返回错误。
%%%
%%% 注意：foreach instantiator 须返回 test set，故用例内一律使用
%%% lazy 断言宏（?_assertMatch / ?_assertEqual）并返回列表。
%%% @end
%%%===================================================================
-include_lib("eunit/include/eunit.hrl").

%% httpc 成功应答 fixture：{ok, {StatusLine, RespHeaders, Body}}
-define(OK_RESP, {ok, {{"HTTP/1.1", 200, "OK"}, [], <<"body">>}}).

httpc_test_() ->
    {foreach, fun start_httpc/0, fun stop_httpc/1, [
        fun post_json_insecure_http_rejected/1,
        fun post_json_https_ok/1,
        fun post_form_insecure_http_rejected/1,
        fun post_form_https_ok/1,
        fun get_insecure_uppercase_http_rejected/1,
        fun get_https_ok/1,
        fun get_httpc_error_passthrough/1,
        fun ftp_scheme_rejected/1,
        fun bare_host_without_scheme_rejected/1,
        fun empty_url_rejected/1,
        fun userinfo_url_rejected/1
    ]}.

start_httpc() ->
    {module, httpc} = code:ensure_loaded(httpc),
    meck:new(httpc),
    %% 默认应答：合法 https 请求成功（个别用例覆盖为 error）
    meck:expect(httpc, request, fun(_Method, _Req, _HttpOpts, _Opts) -> ?OK_RESP end),
    ok.

stop_httpc(_) ->
    meck:unload(httpc).

%%%-------------------------------------------------------------------
%%% post_json 入口：1 反 1 正
%%%-------------------------------------------------------------------

%% 明文 http 小写：拒绝 + httpc 零调用（SEC-8：Bearer/签名绝不明文外发）
post_json_insecure_http_rejected(_) ->
    [
        ?_assertMatch(
            {error, {insecure_url, _}},
            epay_http:post_json(
                <<"http://api.stripe.com/v1/charges">>,
                [{"Authorization", "Bearer sk_test_x"}],
                <<"{\"a\":1}">>
            )
        ),
        ?_assertEqual([], meck:history(httpc))
    ].

post_json_https_ok(_) ->
    [
        ?_assertEqual(
            {ok, 200, [], <<"body">>},
            epay_http:post_json(
                <<"https://api.stripe.com/v1/charges">>,
                [{"Authorization", "Bearer sk_test_x"}],
                <<"{\"a\":1}">>
            )
        ),
        ?_assertEqual(1, meck:num_calls(httpc, request, 4))
    ].

%%%-------------------------------------------------------------------
%%% post_form 入口：1 反 1 正
%%%-------------------------------------------------------------------

post_form_insecure_http_rejected(_) ->
    [
        ?_assertMatch(
            {error, {insecure_url, _}},
            epay_http:post_form(
                <<"http://api.mch.weixin.qq.com/v3/refund/domestic/refunds">>,
                [],
                <<"amount=1">>
            )
        ),
        ?_assertEqual([], meck:history(httpc))
    ].

post_form_https_ok(_) ->
    [
        ?_assertEqual(
            {ok, 200, [], <<"body">>},
            epay_http:post_form(
                <<"https://api.stripe.com/v1/refunds">>,
                [],
                <<"amount=100">>
            )
        ),
        ?_assertEqual(1, meck:num_calls(httpc, request, 4))
    ].

%%%-------------------------------------------------------------------
%%% get 入口：1 反（大写 HTTP）1 正 + error 透传
%%%-------------------------------------------------------------------

%% 大写 HTTP:// 同样拒绝（scheme 大小写不敏感校验）
get_insecure_uppercase_http_rejected(_) ->
    [
        ?_assertMatch(
            {error, {insecure_url, _}},
            epay_http:get(<<"HTTP://api.stripe.com/v1/charges/ch_1">>, [])
        ),
        ?_assertEqual([], meck:history(httpc))
    ].

get_https_ok(_) ->
    [
        ?_assertEqual(
            {ok, 200, [], <<"body">>},
            epay_http:get("https://api.stripe.com/v1/charges", [{"Authorization", "Bearer k"}])
        ),
        ?_assertEqual(1, meck:num_calls(httpc, request, 4))
    ].

%% 合法 https 且 httpc 返回 {error, Reason} → 原样透传（校验不吞网络错误）
get_httpc_error_passthrough(_) ->
    meck:expect(httpc, request, fun(_M, _R, _H, _O) -> {error, timeout} end),
    [
        ?_assertEqual(
            {error, timeout},
            epay_http:get(<<"https://api.stripe.com/v1/charges">>, [])
        )
    ].

%%%-------------------------------------------------------------------
%%% 通用边界：异常 scheme / 无 scheme / 空 URL / userinfo
%%%-------------------------------------------------------------------

ftp_scheme_rejected(_) ->
    [
        ?_assertMatch(
            {error, {insecure_url, _}},
            epay_http:post_form(<<"ftp://ex.com/pay">>, [], <<"a=1">>)
        ),
        ?_assertEqual([], meck:history(httpc))
    ].

%% 裸字符串（无 scheme，string() 输入）——解析仅得 path，必须拒绝
bare_host_without_scheme_rejected(_) ->
    [
        ?_assertMatch(
            {error, {insecure_url, _}},
            epay_http:get("api.stripe.com/v1", [])
        ),
        ?_assertEqual([], meck:history(httpc))
    ].

empty_url_rejected(_) ->
    [
        ?_assertMatch(
            {error, {insecure_url, _}},
            epay_http:post_json(<<>>, [], <<"{}">>)
        ),
        ?_assertEqual([], meck:history(httpc))
    ].

%% userinfo（user:pass@host）：即使 https 也拒绝，防凭据随 URL 泄露
userinfo_url_rejected(_) ->
    [
        ?_assertMatch(
            {error, {insecure_url, _}},
            epay_http:get(<<"https://user:pass@api.stripe.com/v1/charges">>, [])
        ),
        ?_assertEqual([], meck:history(httpc))
    ].
