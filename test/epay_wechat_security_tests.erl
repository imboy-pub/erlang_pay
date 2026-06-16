-module(epay_wechat_security_tests).
%%%===================================================================
%%% @doc 微信网关安全加固 EUnit —— 覆盖 H1/H2 两个 HIGH 安全缺口。
%%%
%%%   - H1：refund/2 退款响应缺 status 字段时不得 fallthrough {ok, Resp}，
%%%         必须判定为错误（资金语义歧义防护）。
%%%   - H2：decrypt_resource 在 api_v3_key 缺失/为空时必须 fail-closed，
%%%         返回固定文案错误；解密失败时错误文案不得拼接内部 atom 名。
%%%
%%% HTTP 一律 meck mock，绝不发真实请求；请求签名 mock epay_crypto。
%%% 每用例 try...after 保证 mock 必被卸载。
%%% @end
%%%===================================================================
-include_lib("eunit/include/eunit.hrl").

-define(WX_CFG, #{
    mch_id => <<"M1">>,
    mch_serial_no => <<"S1">>,
    private_key => <<"K1">>,
    app_id => <<"A1">>
}).

%%%-------------------------------------------------------------------
%%% 公共 mock 脚手架
%%%-------------------------------------------------------------------
with_post_mock(RespBody, Fun) ->
    meck:new(epay_http, [passthrough]),
    meck:new(epay_crypto, [passthrough]),
    meck:expect(epay_crypto, rsa_sign_sha256, fun(_, _) -> {ok, <<"sig">>} end),
    meck:expect(epay_http, post_json, fun(_Url, _Hdr, _Body) -> {ok, 200, [], RespBody} end),
    try
        Fun()
    after
        meck:unload(epay_crypto),
        meck:unload(epay_http)
    end.

refund_req() ->
    #{
        out_trade_no => <<"X1">>,
        out_refund_no => <<"R1">>,
        refund_fen => 100,
        total_fen => 100
    }.

%%%===================================================================
%%% H1 —— 退款响应缺 status 不得当成功
%%%===================================================================

%% 缺 status 字段 → 必须是 {error, {invalid_refund_response, _}}，不再 fallthrough {ok, _}
h1_refund_missing_status_test() ->
    with_post_mock(<<"{\"refund_id\":\"50000\",\"out_refund_no\":\"R1\"}">>, fun() ->
        ?assertMatch(
            {error, {invalid_refund_response, _}},
            epay_wechat:refund(?WX_CFG, refund_req())
        )
    end).

%% status=SUCCESS 仍正常返回 {ok, _}（回归保护）
h1_refund_success_still_ok_test() ->
    with_post_mock(<<"{\"status\":\"SUCCESS\",\"refund_id\":\"50000\"}">>, fun() ->
        ?assertMatch({ok, #{<<"status">> := <<"SUCCESS">>}}, epay_wechat:refund(?WX_CFG, refund_req()))
    end).

%% status=PROCESSING 仍正常返回 {ok, _}（回归保护）
h1_refund_processing_still_ok_test() ->
    with_post_mock(<<"{\"status\":\"PROCESSING\"}">>, fun() ->
        ?assertMatch({ok, #{<<"status">> := <<"PROCESSING">>}}, epay_wechat:refund(?WX_CFG, refund_req()))
    end).

%% status=异常态仍判错（回归保护）
h1_refund_bad_status_still_error_test() ->
    with_post_mock(<<"{\"status\":\"ABNORMAL\"}">>, fun() ->
        ?assertMatch({error, {gateway_error, _}}, epay_wechat:refund(?WX_CFG, refund_req()))
    end).

%%%===================================================================
%%% H2 —— api_v3_key 缺失 fail-closed，错误不拼内部 atom
%%%===================================================================
wx_headers() ->
    #{
        <<"wechatpay-timestamp">> => integer_to_binary(erlang:system_time(second)),
        <<"wechatpay-nonce">> => <<"nonce1">>,
        <<"wechatpay-signature">> => <<"YWJj">>
    }.

wx_raw_body() ->
    <<"{\"resource\":{\"ciphertext\":\"YWJj\",\"nonce\":\"n\",\"associated_data\":\"a\"}}">>.

%% 验签通过（meck rsa_verify→true），但不 mock aes 解密，
%% 由 decrypt_resource 自身在 api_v3_key 缺失时前置 fail-closed。
with_verify_only(Fun) ->
    meck:new(epay_crypto, [passthrough]),
    meck:expect(epay_crypto, rsa_verify_sha256, fun(_, _, _) -> true end),
    try Fun()
    after meck:unload(epay_crypto)
    end.

%% api_v3_key 缺失（cfg 无该键）→ {error, {no_credential, 固定文案}}，不进解密
h2_missing_api_v3_key_test() ->
    Cfg = #{platform_public_key => <<"pk">>},
    with_verify_only(fun() ->
        Res = epay_wechat:verify_notify(Cfg, wx_headers(), wx_raw_body()),
        ?assertMatch({error, {no_credential, _}}, Res)
    end).

%% api_v3_key 为空二进制 → 同样 fail-closed
h2_empty_api_v3_key_test() ->
    Cfg = #{platform_public_key => <<"pk">>, api_v3_key => <<>>},
    with_verify_only(fun() ->
        Res = epay_wechat:verify_notify(Cfg, wx_headers(), wx_raw_body()),
        ?assertMatch({error, {no_credential, _}}, Res)
    end).

%% 解密失败错误文案不得含内部 atom 名（如 cipher_tag_mismatch / error 等）
h2_decrypt_failed_no_atom_leak_test() ->
    Cfg = #{platform_public_key => <<"pk">>, api_v3_key => <<"k">>},
    meck:new(epay_crypto, [passthrough]),
    meck:expect(epay_crypto, rsa_verify_sha256, fun(_, _, _) -> true end),
    meck:expect(epay_crypto, aes_256_gcm_decrypt, fun(_, _, _, _) ->
        {error, cipher_tag_mismatch}
    end),
    try
        Res = epay_wechat:verify_notify(Cfg, wx_headers(), wx_raw_body()),
        ?assertMatch({error, {decrypt_failed, _}}, Res),
        {error, {decrypt_failed, Msg}} = Res,
        %% 内部 atom 名不得穿透到对外文案
        ?assertEqual(nomatch, binary:match(Msg, <<"cipher_tag_mismatch">>))
    after
        meck:unload(epay_crypto)
    end.
