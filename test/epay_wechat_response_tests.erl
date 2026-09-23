-module(epay_wechat_response_tests).
%%%===================================================================
%%% @doc EP-11 微信应答与回调验签合同 EUnit。
%%%
%%% 官方协议依据（微信支付官方文档《签名验证》+ 官方 SDK wechatpay-java）：
%%%   - 应答/回调验签串三行构造：Timestamp\nNonce\nBody\n（行尾均含 \n）
%%%   - 四个头：Wechatpay-Timestamp / Wechatpay-Nonce /
%%%     Wechatpay-Signature（base64 RSA-SHA256）/ Wechatpay-Serial
%%%   - 204 空 body：末行仅为一个 \n（Message = Ts\nNonce\n\n）
%%%   - 必须用原始报文主体验签；先验签后 JSON 解析
%%%   - SIGNTEST 前缀错误签名的探测流量：验签失败一律 fail-closed
%%%   - 时间戳双向 ±5min 窗口（应答与回调一致）
%%%   - 回调 serial 参与公钥选择约束（Cfg 可选键 platform_serial）
%%%
%%% 密钥策略：fixture-only——每个用例即时生成 2048 位 RSA 测试密钥对，
%%% 绝不内置真实密钥；仅 meck epay_http（绝不发网络）。验签/签名全部
%%% 走 epay_crypto 真实实现（notify 明文解密除外）。
%%% @end
%%%===================================================================
-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

%%%-------------------------------------------------------------------
%%% fixture-only 密钥与签名 helpers
%%%-------------------------------------------------------------------

%% fixture-only：即时生成 2048 位 RSA 密钥对，返回 {私钥PEM, 公钥PEM}。
gen_rsa() ->
    Priv = public_key:generate_key({rsa, 2048, 65537}),
    #'RSAPrivateKey'{modulus = N, publicExponent = E} = Priv,
    Pub = #'RSAPublicKey'{modulus = N, publicExponent = E},
    PrivPem = public_key:pem_encode([public_key:pem_entry_encode('RSAPrivateKey', Priv)]),
    PubPem = public_key:pem_encode([public_key:pem_entry_encode('RSAPublicKey', Pub)]),
    {PrivPem, PubPem}.

now_s() ->
    erlang:system_time(second).

%% 按官方三行构造对 body 签名，返回原始签名字节（SIGNTEST 拼接用）。
sign_body_bin(PrivPem, Ts, Nonce, Body) ->
    TsBin = integer_to_binary(Ts),
    Message = <<TsBin/binary, "\n", Nonce/binary, "\n", Body/binary, "\n">>,
    {ok, Sig} = epay_crypto:rsa_sign_sha256(Message, PrivPem),
    Sig.

%% 签名并 base64 编码（应答/回调 Wechatpay-Signature 头格式）。
sign_body(PrivPem, Ts, Nonce, Body) ->
    base64:encode(sign_body_bin(PrivPem, Ts, Nonce, Body)).

%%%-------------------------------------------------------------------
%%% mock 脚手架
%%%-------------------------------------------------------------------

%% Cfg：请求签名用真私钥，应答验签用真公钥（全链路真实，仅 mock HTTP）。
cfg(PrivPem, PubPem) ->
    #{
        mch_id => <<"M1">>,
        app_id => <<"A1">>,
        mch_serial_no => <<"S1">>,
        private_key => PrivPem,
        platform_public_key => PubPem
    }.

jsapi_order() ->
    #{out_trade_no => <<"X1">>, amount_fen => 100, openid => <<"o1">>}.

%% httpc 原始形态应答头（string 键值、大小写混合），证明归一化正确性。
resp_headers_str(Ts, Nonce, SigB64, Serial) ->
    [
        {"Content-Type", "application/json"},
        {"Request-ID", "mock-req-1"},
        {"Wechatpay-Serial", binary_to_list(Serial)},
        {"Wechatpay-Timestamp", integer_to_list(Ts)},
        {"Wechatpay-Nonce", binary_to_list(Nonce)},
        {"WECHATPAY-SIGNATURE", binary_to_list(SigB64)}
    ].

%% binary 键/值形态应答头，证明非 string 形态同样归一化。
resp_headers_bin(Ts, Nonce, SigB64) ->
    [
        {<<"Content-Type">>, <<"application/json">>},
        {<<"wechatpay-timestamp">>, integer_to_binary(Ts)},
        {<<"wechatpay-nonce">>, Nonce},
        {<<"wechatpay-signature">>, SigB64},
        {<<"wechatpay-serial">>, <<"PLATSERIAL1">>}
    ].

%% 大小写不敏感地删除一个头（篡改矩阵用）。
drop_header(Hdrs, KeyLower) ->
    [H || {K, _} = H <- Hdrs, string:lowercase(hdr_key_bin(K)) =/= KeyLower].

hdr_key_bin(K) when is_binary(K) -> K;
hdr_key_bin(K) when is_list(K) -> unicode:characters_to_binary(K).

with_http(Kind, Status, Headers, Body, Fun) ->
    meck:new(epay_http, [passthrough]),
    case Kind of
        post ->
            meck:expect(epay_http, post_json, fun(_U, _H, _B) -> {ok, Status, Headers, Body} end);
        get ->
            meck:expect(epay_http, get, fun(_U, _H) -> {ok, Status, Headers, Body} end)
    end,
    try
        Fun()
    after
        meck:unload(epay_http)
    end.

%%%-------------------------------------------------------------------
%%% 正向：真签名的 2xx 应答 → 验签通过后解析
%%%-------------------------------------------------------------------

%% jsapi_prepay 场景：真签名应答（httpc string 头、大小写混合）→ {ok, Map}
resp_verified_jsapi_test() ->
    {Priv, Pub} = gen_rsa(),
    Ts = now_s(),
    Nonce = <<"n-jsapi-1234567890">>,
    Body = <<"{\"prepay_id\":\"wx24202305070001abc\"}">>,
    Sig = sign_body(Priv, Ts, Nonce, Body),
    Hdrs = resp_headers_str(Ts, Nonce, Sig, <<"PLATSERIAL1">>),
    Cfg = cfg(Priv, Pub),
    with_http(post, 200, Hdrs, Body, fun() ->
        ?assertMatch(
            {ok, #{prepay_id := <<"wx24202305070001abc">>}},
            epay_wechat:jsapi_prepay(Cfg, jsapi_order())
        )
    end).

%% query 场景（get_signed）：binary 键头形态同样归一化验签 → {ok, Map}
resp_verified_query_test() ->
    {Priv, Pub} = gen_rsa(),
    Ts = now_s(),
    Nonce = <<"n-query-9876543210">>,
    Body = <<"{\"trade_state\":\"SUCCESS\",\"out_trade_no\":\"X1\"}">>,
    Sig = sign_body(Priv, Ts, Nonce, Body),
    Hdrs = resp_headers_bin(Ts, Nonce, Sig),
    Cfg = cfg(Priv, Pub),
    with_http(get, 200, Hdrs, Body, fun() ->
        ?assertMatch(
            {ok, #{trade_state := success, raw_state := <<"SUCCESS">>}},
            epay_wechat:query(Cfg, #{out_trade_no => <<"X1">>})
        )
    end).

%% 204 空 body（close 场景）：验签串末行仅为一个 \n（Ts\nNonce\n\n）
resp_verified_204_close_test() ->
    {Priv, Pub} = gen_rsa(),
    Ts = now_s(),
    Nonce = <<"n-close-204-empty">>,
    Sig = sign_body(Priv, Ts, Nonce, <<>>),
    Hdrs = resp_headers_str(Ts, Nonce, Sig, <<"PLATSERIAL1">>),
    Cfg = cfg(Priv, Pub),
    with_http(post, 204, Hdrs, <<>>, fun() ->
        ?assertMatch(
            {ok, #{type := wechat_close, out_trade_no := <<"X1">>}},
            epay_wechat:close(Cfg, #{out_trade_no => <<"X1">>})
        )
    end).

%% 未配置 platform_serial 时，不因 serial 头存在与否改变单公钥验签结果。
resp_no_serial_header_single_pubkey_test() ->
    {Priv, Pub} = gen_rsa(),
    Ts = now_s(),
    Nonce = <<"n-noserial-compat">>,
    Body = <<"{\"prepay_id\":\"p-noserial\"}">>,
    Sig = sign_body(Priv, Ts, Nonce, Body),
    Hdrs = drop_header(resp_headers_str(Ts, Nonce, Sig, <<"ignored">>), <<"wechatpay-serial">>),
    Cfg = cfg(Priv, Pub),
    with_http(post, 200, Hdrs, Body, fun() ->
        ?assertMatch(
            {ok, #{prepay_id := <<"p-noserial">>}},
            epay_wechat:jsapi_prepay(Cfg, jsapi_order())
        )
    end).

%%%-------------------------------------------------------------------
%%% 篡改矩阵：全拒且绝不返回解析后的 JSON（先验签后解析）
%%%-------------------------------------------------------------------

%% 公共：删掉一个 Wechatpay-* 头后跑 jsapi_prepay。Body 为合法 JSON——
%% 若实现先解析后验签则会误返回 {ok,_}；正确实现必须 fail-closed。
jsapi_without_header(Priv, Pub, DropKey) ->
    Ts = now_s(),
    Nonce = <<"n-drop-header">>,
    Body = <<"{\"prepay_id\":\"p-drop\"}">>,
    Sig = sign_body(Priv, Ts, Nonce, Body),
    Hdrs = drop_header(resp_headers_str(Ts, Nonce, Sig, <<"PLATSERIAL1">>), DropKey),
    Cfg = cfg(Priv, Pub),
    with_http(post, 200, Hdrs, Body, fun() ->
        epay_wechat:jsapi_prepay(Cfg, jsapi_order())
    end).

resp_missing_timestamp_rejected_test() ->
    {Priv, Pub} = gen_rsa(),
    ?assertMatch(
        {error, {missing_timestamp, _}},
        jsapi_without_header(Priv, Pub, <<"wechatpay-timestamp">>)
    ).

resp_missing_nonce_rejected_test() ->
    {Priv, Pub} = gen_rsa(),
    ?assertMatch(
        {error, {missing_nonce, _}},
        jsapi_without_header(Priv, Pub, <<"wechatpay-nonce">>)
    ).

resp_missing_signature_rejected_test() ->
    {Priv, Pub} = gen_rsa(),
    ?assertMatch(
        {error, {missing_signature, _}},
        jsapi_without_header(Priv, Pub, <<"wechatpay-signature">>)
    ).

%% 签名坏 base64 → {error, {bad_signature, _}}（不解析 body）
resp_bad_base64_rejected_test() ->
    {Priv, Pub} = gen_rsa(),
    Ts = now_s(),
    Nonce = <<"n-bad-base64">>,
    Body = <<"{\"prepay_id\":\"p-b64\"}">>,
    Hdrs = resp_headers_str(Ts, Nonce, <<"!!!not-base64!!!">>, <<"PLATSERIAL1">>),
    Cfg = cfg(Priv, Pub),
    with_http(post, 200, Hdrs, Body, fun() ->
        ?assertMatch(
            {error, {bad_signature, _}},
            epay_wechat:jsapi_prepay(Cfg, jsapi_order())
        )
    end).

%% 错公钥验签（签名真、公钥非对应）→ {error, {bad_signature, _}}
resp_wrong_pubkey_rejected_test() ->
    {Priv, _RealPub} = gen_rsa(),
    {_OtherPriv, OtherPub} = gen_rsa(),
    Ts = now_s(),
    Nonce = <<"n-wrong-pubkey">>,
    Body = <<"{\"prepay_id\":\"p-wrong\"}">>,
    Sig = sign_body(Priv, Ts, Nonce, Body),
    Hdrs = resp_headers_str(Ts, Nonce, Sig, <<"PLATSERIAL1">>),
    Cfg = cfg(Priv, OtherPub),
    with_http(post, 200, Hdrs, Body, fun() ->
        ?assertMatch(
            {error, {bad_signature, _}},
            epay_wechat:jsapi_prepay(Cfg, jsapi_order())
        )
    end).

%% 篡改 body 一字节（"p1"→"q1"，仍是合法 JSON）→ 验签失败拒收，
%% 且不得返回解析后的 {ok,_}（证明 JSON 解析发生在验签之后）。
resp_tampered_body_rejected_test() ->
    {Priv, Pub} = gen_rsa(),
    Ts = now_s(),
    Nonce = <<"n-tamper-body">>,
    SignedBody = <<"{\"prepay_id\":\"p1\"}">>,
    TamperedBody = <<"{\"prepay_id\":\"q1\"}">>,
    Sig = sign_body(Priv, Ts, Nonce, SignedBody),
    Hdrs = resp_headers_str(Ts, Nonce, Sig, <<"PLATSERIAL1">>),
    Cfg = cfg(Priv, Pub),
    with_http(post, 200, Hdrs, TamperedBody, fun() ->
        ?assertMatch(
            {error, {bad_signature, _}},
            epay_wechat:jsapi_prepay(Cfg, jsapi_order())
        )
    end).

%% 应答时间戳过期（-400s，超 ±300s 窗）→ 拒收（防重放）
resp_stale_timestamp_rejected_test() ->
    resp_out_of_window_rejected(now_s() - 400).

%% 应答时间戳来自未来（+400s，双向窗口）→ 拒收
resp_future_timestamp_rejected_test() ->
    resp_out_of_window_rejected(now_s() + 400).

resp_out_of_window_rejected(Ts) ->
    {Priv, Pub} = gen_rsa(),
    Nonce = <<"n-out-window">>,
    Body = <<"{\"prepay_id\":\"p-window\"}">>,
    Sig = sign_body(Priv, Ts, Nonce, Body),
    Hdrs = resp_headers_str(Ts, Nonce, Sig, <<"PLATSERIAL1">>),
    Cfg = cfg(Priv, Pub),
    with_http(post, 200, Hdrs, Body, fun() ->
        ?assertMatch(
            {error, {timestamp_expired, _}},
            epay_wechat:jsapi_prepay(Cfg, jsapi_order())
        )
    end).

%% 缺 platform_public_key（D-02：无「缺公钥继续解析」开关）→ fail-closed，
%% 绝不带空公钥验签、绝不继续解析 body。
resp_missing_pubkey_rejected_test() ->
    {Priv, _Pub} = gen_rsa(),
    Ts = now_s(),
    Nonce = <<"n-no-pubkey">>,
    Body = <<"{\"prepay_id\":\"p-nopub\"}">>,
    Sig = sign_body(Priv, Ts, Nonce, Body),
    Hdrs = resp_headers_str(Ts, Nonce, Sig, <<"PLATSERIAL1">>),
    Cfg = maps:remove(platform_public_key, cfg(Priv, <<"x">>)),
    with_http(post, 200, Hdrs, Body, fun() ->
        ?assertMatch(
            {error, {no_credential, _}},
            epay_wechat:jsapi_prepay(Cfg, jsapi_order())
        )
    end).

%% 微信验收期会发 SIGNTEST 前缀错误签名的探测流量：
%% 作为通用坏签名反例 → {error, {bad_signature, _}}（无需专属分支）。
resp_signtest_prefix_rejected_test() ->
    {Priv, Pub} = gen_rsa(),
    Ts = now_s(),
    Nonce = <<"n-signtest">>,
    Body = <<"{\"prepay_id\":\"p-signtest\"}">>,
    RealSig = sign_body_bin(Priv, Ts, Nonce, Body),
    SigntestB64 = base64:encode(<<"SIGNTEST", RealSig/binary>>),
    Hdrs = resp_headers_str(Ts, Nonce, SigntestB64, <<"PLATSERIAL1">>),
    Cfg = cfg(Priv, Pub),
    with_http(post, 200, Hdrs, Body, fun() ->
        ?assertMatch(
            {error, {bad_signature, _}},
            epay_wechat:jsapi_prepay(Cfg, jsapi_order())
        )
    end).

%% 配置 platform_serial 时应答 serial 不匹配 → fail-closed 拒收
resp_serial_mismatch_rejected_test() ->
    {Priv, Pub} = gen_rsa(),
    Ts = now_s(),
    Nonce = <<"n-resp-serial">>,
    Body = <<"{\"prepay_id\":\"p-serial\"}">>,
    Sig = sign_body(Priv, Ts, Nonce, Body),
    Hdrs = resp_headers_str(Ts, Nonce, Sig, <<"RESP-OTHER-SERIAL">>),
    Cfg0 = cfg(Priv, Pub),
    Cfg = Cfg0#{platform_serial => <<"RESP-EXPECT-SERIAL">>},
    with_http(post, 200, Hdrs, Body, fun() ->
        ?assertMatch(
            {error, {serial_mismatch, _}},
            epay_wechat:jsapi_prepay(Cfg, jsapi_order())
        )
    end).

%%%-------------------------------------------------------------------
%%% 回调 serial 约束（verify_notify/3）
%%%-------------------------------------------------------------------

notify_headers(Ts, Nonce, SigB64, Serial) ->
    #{
        <<"wechatpay-timestamp">> => integer_to_binary(Ts),
        <<"wechatpay-nonce">> => Nonce,
        <<"wechatpay-signature">> => SigB64,
        <<"wechatpay-serial">> => Serial
    }.

notify_raw_body() ->
    <<"{\"resource\":{\"ciphertext\":\"YWJj\",\"nonce\":\"n\",\"associated_data\":\"a\"}}">>.

%% 真签名验签通过后，resource 解密由 meck 返回明文（聚焦 serial 语义）。
with_aes_plain(Plain, Fun) ->
    meck:new(epay_crypto, [passthrough]),
    meck:expect(epay_crypto, aes_256_gcm_decrypt, fun(_C, _K, _N, _A) -> {ok, Plain} end),
    try
        Fun()
    after
        meck:unload(epay_crypto)
    end.

%% 配 platform_serial 且头匹配 → 验签+解密通过
notify_serial_match_ok_test() ->
    {Priv, Pub} = gen_rsa(),
    Ts = now_s(),
    Nonce = <<"n-notify-match">>,
    RawBody = notify_raw_body(),
    Sig = sign_body(Priv, Ts, Nonce, RawBody),
    Headers = notify_headers(Ts, Nonce, Sig, <<"PLATSERIAL1">>),
    Cfg = #{platform_public_key => Pub, api_v3_key => <<"k">>, platform_serial => <<"PLATSERIAL1">>},
    Plain = <<"{\"trade_state\":\"SUCCESS\",\"out_trade_no\":\"X1\"}">>,
    with_aes_plain(Plain, fun() ->
        ?assertMatch(
            {ok, #{trade_state := success}},
            epay_wechat:verify_notify(Cfg, Headers, RawBody)
        )
    end).

%% 配 platform_serial 但头不匹配 → {error, {serial_mismatch, 实际收到的 serial}}
notify_serial_mismatch_rejected_test() ->
    {Priv, Pub} = gen_rsa(),
    Ts = now_s(),
    Nonce = <<"n-notify-mismatch">>,
    RawBody = notify_raw_body(),
    Sig = sign_body(Priv, Ts, Nonce, RawBody),
    Headers = notify_headers(Ts, Nonce, Sig, <<"OTHER-SERIAL">>),
    Cfg = #{platform_public_key => Pub, api_v3_key => <<"k">>, platform_serial => <<"PLATSERIAL1">>},
    ?assertEqual(
        {error, {serial_mismatch, <<"OTHER-SERIAL">>}},
        epay_wechat:verify_notify(Cfg, Headers, RawBody)
    ).

%% 未配置 platform_serial：无 serial 头也通过（兼容现有单公钥配置）
notify_serial_unconfigured_compat_test() ->
    {Priv, Pub} = gen_rsa(),
    Ts = now_s(),
    Nonce = <<"n-notify-nocfg">>,
    RawBody = notify_raw_body(),
    Sig = sign_body(Priv, Ts, Nonce, RawBody),
    Headers = maps:remove(<<"wechatpay-serial">>, notify_headers(Ts, Nonce, Sig, <<"ignored">>)),
    Cfg = #{platform_public_key => Pub, api_v3_key => <<"k">>},
    Plain = <<"{\"trade_state\":\"REFUND\"}">>,
    with_aes_plain(Plain, fun() ->
        ?assertMatch(
            {ok, #{trade_state := refunded}},
            epay_wechat:verify_notify(Cfg, Headers, RawBody)
        )
    end).
