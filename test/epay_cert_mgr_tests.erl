-module(epay_cert_mgr_tests).
%%%===================================================================
%%% @doc epay_cert_mgr 证书自动轮换 EUnit。
%%%
%%% meck 模拟下载（epay_http:get）与密码学（签名/AES 解密），绝不发真实请求。
%%% 覆盖：缓存命中（不重复下载）、强制刷新（重新下载）、多租户 {mch_id, serial}
%%% 隔离、未知序列号 not_found。大刷新间隔避免定时器在测试期触发。
%%% @end
%%%===================================================================
-include_lib("eunit/include/eunit.hrl").

-define(BIG_INTERVAL, 3600000).

mch(MchId) ->
    #{
        mch_id => MchId,
        mch_serial_no => <<"MCHSERIAL">>,
        private_key => <<"PRIKEY">>,
        api_v3_key => <<"0123456789abcdef0123456789abcdef">>
    }.

%% 一条平台证书的 /v3/certificates 响应（serial_no 明文 + 加密证书体）。
certs_body(Serial) ->
    <<"{\"data\":[{\"serial_no\":\"", Serial/binary,
        "\",\"encrypt_certificate\":{\"algorithm\":\"AEAD_AES_256_GCM\","
        "\"nonce\":\"abc\",\"associated_data\":\"certificate\",\"ciphertext\":\"Y2lwaGVy\"}}]}">>.

setup() ->
    meck:new(epay_http, [passthrough]),
    meck:new(epay_crypto, [passthrough]),
    meck:expect(epay_crypto, rsa_sign_sha256, fun(_, _) -> {ok, <<"sig">>} end),
    meck:expect(epay_crypto, aes_256_gcm_decrypt, fun(_, _, _, _) ->
        {ok, <<"-----BEGIN CERTIFICATE-----\nPLATFORMCERT\n-----END CERTIFICATE-----">>}
    end),
    meck:expect(epay_http, get, fun(_Url, _Headers) -> {ok, 200, [], certs_body(<<"SERIAL_A">>)} end),
    ok.

cleanup(_) ->
    meck:unload(epay_crypto),
    meck:unload(epay_http).

with_mgr(Fun) ->
    {ok, Mgr} = epay_cert_mgr:start_link(#{refresh_interval => ?BIG_INTERVAL}),
    try
        Fun(Mgr)
    after
        epay_cert_mgr:stop(Mgr)
    end.

cert_mgr_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"下载后命中缓存", fun cache_hit/0},
        {"强制刷新重新下载", fun force_refresh/0},
        {"多租户 {mch_id, serial} 隔离", fun multi_tenant/0},
        {"未知序列号 not_found", fun not_found/0},
        {"下载失败回报错误但仍登记商户", fun download_error/0}
    ]}.

%%%-------------------------------------------------------------------
cache_hit() ->
    with_mgr(fun(Mgr) ->
        ok = epay_cert_mgr:add_merchant(Mgr, mch(<<"M1">>)),
        Calls1 = meck:num_calls(epay_http, get, '_'),
        ?assertMatch({ok, <<"-----BEGIN CERTIFICATE", _/binary>>},
            epay_cert_mgr:get_cert(Mgr, <<"M1">>, <<"SERIAL_A">>)),
        %% 再次 get_cert 走 ETS，不触发新下载
        _ = epay_cert_mgr:get_cert(Mgr, <<"M1">>, <<"SERIAL_A">>),
        Calls2 = meck:num_calls(epay_http, get, '_'),
        ?assertEqual(Calls1, Calls2)
    end).

force_refresh() ->
    with_mgr(fun(Mgr) ->
        ok = epay_cert_mgr:add_merchant(Mgr, mch(<<"M1">>)),
        Before = meck:num_calls(epay_http, get, '_'),
        ok = epay_cert_mgr:refresh(Mgr),
        After = meck:num_calls(epay_http, get, '_'),
        ?assert(After > Before)
    end).

multi_tenant() ->
    with_mgr(fun(Mgr) ->
        ok = epay_cert_mgr:add_merchant(Mgr, mch(<<"M1">>)),
        ok = epay_cert_mgr:add_merchant(Mgr, mch(<<"M2">>)),
        ?assertMatch({ok, _}, epay_cert_mgr:get_cert(Mgr, <<"M1">>, <<"SERIAL_A">>)),
        ?assertMatch({ok, _}, epay_cert_mgr:get_cert(Mgr, <<"M2">>, <<"SERIAL_A">>)),
        ?assertEqual([<<"SERIAL_A">>], epay_cert_mgr:list_serials(Mgr, <<"M1">>)),
        ?assertEqual([<<"SERIAL_A">>], epay_cert_mgr:list_serials(Mgr, <<"M2">>))
    end).

not_found() ->
    with_mgr(fun(Mgr) ->
        ok = epay_cert_mgr:add_merchant(Mgr, mch(<<"M1">>)),
        ?assertEqual({error, not_found}, epay_cert_mgr:get_cert(Mgr, <<"M1">>, <<"NOPE">>)),
        ?assertEqual({error, not_found}, epay_cert_mgr:get_cert(Mgr, <<"OTHER">>, <<"SERIAL_A">>))
    end).

download_error() ->
    with_mgr(fun(Mgr) ->
        meck:expect(epay_http, get, fun(_, _) -> {error, timeout} end),
        ?assertMatch({error, {http_error, _}}, epay_cert_mgr:add_merchant(Mgr, mch(<<"M9">>))),
        %% 恢复正常后定时/手动刷新可补回
        meck:expect(epay_http, get, fun(_, _) -> {ok, 200, [], certs_body(<<"SERIAL_A">>)} end),
        ok = epay_cert_mgr:refresh(Mgr),
        ?assertMatch({ok, _}, epay_cert_mgr:get_cert(Mgr, <<"M9">>, <<"SERIAL_A">>))
    end).
