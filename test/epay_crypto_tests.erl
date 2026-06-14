-module(epay_crypto_tests).
%%%===================================================================
%%% @doc epay_crypto EUnit —— 固化支付密码学原语行为。
%%% 全部纯函数/本地运算，不发网络、不读真实密钥（测试密钥即时生成）。
%%% @end
%%%===================================================================
-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

%%%-------------------------------------------------------------------
%%% helpers
%%%-------------------------------------------------------------------

%% 即时生成 2048 位测试 RSA 密钥对，返回 {PrivPem(PKCS#1), PubPem(PKCS#1), PubRecord}。
gen_rsa() ->
    Priv = public_key:generate_key({rsa, 2048, 65537}),
    #'RSAPrivateKey'{modulus = N, publicExponent = E} = Priv,
    Pub = #'RSAPublicKey'{modulus = N, publicExponent = E},
    PrivPem = public_key:pem_encode([public_key:pem_entry_encode('RSAPrivateKey', Priv)]),
    PubPem = public_key:pem_encode([public_key:pem_entry_encode('RSAPublicKey', Pub)]),
    {PrivPem, PubPem, Pub}.

%% 去掉 PEM 头尾与换行，得到裸 base64（模拟支付宝公钥下发格式）。
strip_pem(Pem) ->
    Lines = binary:split(Pem, <<"\n">>, [global]),
    Body = [L || L <- Lines, L =/= <<>>, binary:match(L, <<"-----">>) =:= nomatch],
    iolist_to_binary(Body).

%%%-------------------------------------------------------------------
%%% RSA SHA256withRSA
%%%-------------------------------------------------------------------

rsa_sign_verify_roundtrip_test() ->
    {Priv, Pub, _} = gen_rsa(),
    Msg = <<"hello payment">>,
    {ok, Sig} = epay_crypto:rsa_sign_sha256(Msg, Priv),
    ?assert(epay_crypto:rsa_verify_sha256(Msg, Sig, Pub)),
    ?assertNot(epay_crypto:rsa_verify_sha256(<<"tampered">>, Sig, Pub)).

%% 支付宝场景：公钥以裸 base64（X.509 SPKI，无 PEM 头）下发，需自动补头。
rsa_verify_bare_base64_pubkey_test() ->
    {Priv, _, PubRec} = gen_rsa(),
    Msg = <<"alipay style">>,
    {ok, Sig} = epay_crypto:rsa_sign_sha256(Msg, Priv),
    SpkiPem = public_key:pem_encode([
        public_key:pem_entry_encode('SubjectPublicKeyInfo', PubRec)
    ]),
    RawB64 = strip_pem(SpkiPem),
    ?assert(epay_crypto:rsa_verify_sha256(Msg, Sig, RawB64)).

rsa_sign_bad_key_test() ->
    ?assertMatch({error, _}, epay_crypto:rsa_sign_sha256(<<"m">>, <<"not a key">>)).

rsa_verify_bad_key_returns_false_test() ->
    ?assertNot(epay_crypto:rsa_verify_sha256(<<"m">>, <<"sig">>, <<"not a key">>)).

%%%-------------------------------------------------------------------
%%% HMAC-SHA256（Stripe webhook）
%%%-------------------------------------------------------------------

%% 标准测试向量（Wikipedia HMAC-SHA256）。
hmac_sha256_known_vector_test() ->
    Key = <<"key">>,
    Data = <<"The quick brown fox jumps over the lazy dog">>,
    Expect = <<"f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8">>,
    ?assertEqual(Expect, epay_crypto:hmac_sha256_hex(Key, Data)),
    ?assertEqual(32, byte_size(epay_crypto:hmac_sha256(Key, Data))).

%%%-------------------------------------------------------------------
%%% AES-256-GCM（微信 v3 回调 resource 解密）
%%%-------------------------------------------------------------------

aes_gcm_roundtrip_test() ->
    Key = crypto:strong_rand_bytes(32),
    Nonce = crypto:strong_rand_bytes(12),
    Aad = <<"associated_data">>,
    Plain = <<"secret resource json">>,
    {Cipher, Tag} = crypto:crypto_one_time_aead(aes_256_gcm, Key, Nonce, Plain, Aad, true),
    CipherB64 = base64:encode(<<Cipher/binary, Tag/binary>>),
    ?assertEqual({ok, Plain}, epay_crypto:aes_256_gcm_decrypt(CipherB64, Key, Nonce, Aad)).

aes_gcm_tampered_tag_test() ->
    Key = crypto:strong_rand_bytes(32),
    Nonce = crypto:strong_rand_bytes(12),
    Aad = <<"aad">>,
    Plain = <<"data">>,
    {Cipher, Tag} = crypto:crypto_one_time_aead(aes_256_gcm, Key, Nonce, Plain, Aad, true),
    <<T0, TRest/binary>> = Tag,
    BadTag = <<(T0 bxor 16#FF), TRest/binary>>,
    CipherB64 = base64:encode(<<Cipher/binary, BadTag/binary>>),
    ?assertEqual({error, auth_failed}, epay_crypto:aes_256_gcm_decrypt(CipherB64, Key, Nonce, Aad)).

aes_gcm_bad_key_len_test() ->
    CipherB64 = base64:encode(<<0:256>>),
    ?assertEqual(
        {error, bad_args},
        epay_crypto:aes_256_gcm_decrypt(CipherB64, <<"shortkey">>, <<"nonce">>, <<"aad">>)
    ).

%%%-------------------------------------------------------------------
%%% 常量时间比较 / 小写 hex / nonce
%%%-------------------------------------------------------------------

constant_time_equal_test() ->
    ?assert(epay_crypto:constant_time_equal(<<"abc">>, <<"abc">>)),
    ?assertNot(epay_crypto:constant_time_equal(<<"abc">>, <<"abd">>)),
    ?assertNot(epay_crypto:constant_time_equal(<<"abc">>, <<"abcd">>)),
    ?assert(epay_crypto:constant_time_equal(<<>>, <<>>)).

lower_hex_test() ->
    ?assertEqual(<<"ff0010">>, epay_crypto:lower_hex(<<255, 0, 16>>)),
    ?assertEqual(<<>>, epay_crypto:lower_hex(<<>>)).

nonce_test() ->
    N = epay_crypto:nonce(16),
    ?assertEqual(32, byte_size(N)),
    ?assertNotEqual(epay_crypto:nonce(16), epay_crypto:nonce(16)).
