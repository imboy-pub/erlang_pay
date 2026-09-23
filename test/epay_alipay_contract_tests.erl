-module(epay_alipay_contract_tests).
%%%===================================================================
%%% @doc EP-12 支付宝「原始响应验签 + 通知合同」EUnit（测试先行）。
%%%
%%% 合同依据（支付宝官方 Java SDK AbstractAlipayClient.checkResponseSign /
%%% JsonConverter.getSignSourceData / AlipaySignature.getSignCheckContentV1）：
%%%
%%%   1. 同步应答（query/close/cancel/download_bill/refund 全覆盖）：
%%%      在「原始响应字符串」上定位 <method>_response / error_response 节点的
%%%      原始 JSON 字节验签——绝不 json decode 后 re-encode 当验签串；
%%%      code=10000 无 sign → fail-closed（missing_signature）；
%%%      失败响应（code!=10000）带 sign 也必须验签，无 sign 维持 gateway_error；
%%%      验签失败先做一次 `\/`→`/` 替换重试（官方 JSON 转义兼容）。
%%%   2. 异步通知：验签串排除 sign/sign_type，**alipay_cert_sn 参与签名串**
%%%      （官方 V1/V2 均不排除；旧审计 SEC-7 的排除建议为误，本套件以反例证伪）；
%%%      通知 app_id 必须与配置一致（缺失/不一致拒绝）。
%%%
%%% fixture：真 RSA-2048 密钥对（crypto:generate_key，仅测试用，persistent_term
%%% 缓存避免重复生成）；签名走 public_key:sign 直调（不受测试对 epay_crypto 的
%%% meck 影响）；HTTP 层 meck mock，绝无真实请求。
%%%
%%% 本模块另导出 fixture 助手（fixture_pub_pem/0、signed_body/2 等），供既有
%%% 测试文件为 mock 响应补合法签名（EP-12 回归最小侵入改造，勿删）。
%%% @end
%%%===================================================================
-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

-define(APP_ID, <<"2021002100718301">>).
-define(QUERY_KEY, <<"alipay_trade_query_response">>).
-define(REFUND_KEY, <<"alipay_trade_refund_response">>).
-define(CLOSE_KEY, <<"alipay_trade_close_response">>).
-define(CANCEL_KEY, <<"alipay_trade_cancel_response">>).
-define(BILL_KEY, <<"alipay_data_dataservice_bill_downloadurl_query_response">>).

%% 供既有测试文件复用的 fixture 助手（回归改造用，非测试用例）
-export([fixture_pub_pem/0, fixture_priv_pem/0, signed_body/2]).

%%%-------------------------------------------------------------------
%%% fixture：真 RSA 密钥对 / 证书（persistent_term 缓存）
%%%-------------------------------------------------------------------

-spec keys() -> #{priv_rec := term(), priv_pem := binary(), pub_pem := binary()}.
keys() ->
    case persistent_term:get({?MODULE, keys}, undefined) of
        undefined ->
            Keys = gen_keys(),
            persistent_term:put({?MODULE, keys}, Keys),
            Keys;
        Keys ->
            Keys
    end.

%% 真 RSA-2048 密钥对（fixture-only）。crypto:generate_key 返回二进制整数分量，
%% 组 record 后转 PEM：pub_pem 供 Cfg.public_key；priv_rec 供直调
%% public_key:sign（绕开 epay_crypto，免疫其它测试的 meck）。
-spec gen_keys() -> #{priv_rec := term(), priv_pem := binary(), pub_pem := binary()}.
gen_keys() ->
    {[E, N], [_, _, D, P, Q, DP, DQ, QI]} = crypto:generate_key(rsa, {2048, 65537}),
    U = fun binary:decode_unsigned/1,
    PrivRec = #'RSAPrivateKey'{
        version = 0,
        modulus = U(N),
        publicExponent = U(E),
        privateExponent = U(D),
        prime1 = U(P),
        prime2 = U(Q),
        exponent1 = U(DP),
        exponent2 = U(DQ),
        coefficient = U(QI),
        otherPrimeInfos = asn1_NOVALUE
    },
    PubRec = #'RSAPublicKey'{modulus = U(N), publicExponent = U(E)},
    #{
        priv_rec => PrivRec,
        priv_pem => public_key:pem_encode([public_key:pem_entry_encode('RSAPrivateKey', PrivRec)]),
        pub_pem => public_key:pem_encode([public_key:pem_entry_encode('RSAPublicKey', PubRec)])
    }.

%% OTP 内置测试 CA 生成自签根证书（独立 RSA 密钥）：证书模式 Cfg 用。
-spec cert_fixture() -> #{cert_pem := binary(), priv_rec := term()}.
cert_fixture() ->
    case persistent_term:get({?MODULE, cert}, undefined) of
        undefined ->
            #{cert := Der, key := KeyRec} = public_key:pkix_test_root_cert(
                "erlang-pay-fixture", [{key, {rsa, 2048, 65537}}, {digest, sha256}]
            ),
            F = #{
                cert_pem => public_key:pem_encode([{'Certificate', Der, not_encrypted}]),
                priv_rec => KeyRec
            },
            persistent_term:put({?MODULE, cert}, F),
            F;
        F ->
            F
    end.

-spec fixture_pub_pem() -> binary().
fixture_pub_pem() -> maps:get(pub_pem, keys()).

-spec fixture_priv_pem() -> binary().
fixture_priv_pem() -> maps:get(priv_pem, keys()).

%% 用 fixture 私钥对 Source 原始字节做 RSA2(SHA256) 签名，返回 base64。
-spec sign_raw(binary()) -> binary().
sign_raw(Source) ->
    sign_with(maps:get(priv_rec, keys()), Source).

-spec sign_with(term(), binary()) -> binary().
sign_with(PrivRec, Source) ->
    base64:encode(public_key:sign(Source, sha256, PrivRec)).

%% 组装完整同步应答 body：顶层携带对 NodeRaw 原始字节（非 re-encode 形态）的签名。
-spec signed_body(binary(), binary()) -> binary().
signed_body(NodeKey, NodeRaw) ->
    signed_body_with(maps:get(priv_rec, keys()), NodeKey, NodeRaw).

-spec signed_body_with(term(), binary(), binary()) -> binary().
signed_body_with(PrivRec, NodeKey, NodeRaw) ->
    Sig = sign_with(PrivRec, NodeRaw),
    <<"{\"", NodeKey/binary, "\":", NodeRaw/binary,
        ",\"sign\":\"", Sig/binary, "\",\"sign_type\":\"RSA2\"}">>.

%%%-------------------------------------------------------------------
%%% 公共脚手架
%%%-------------------------------------------------------------------

%% 仅 mock HTTP 层；epay_crypto 不 mock——验签走真 RSA 全链路。
-spec with_http(binary(), fun(() -> term())) -> term().
with_http(Body, Fun) ->
    meck:new(epay_http, [passthrough]),
    meck:expect(epay_http, post_form, fun(_U, _H, _B) -> {ok, 200, [], Body} end),
    try
        Fun()
    after
        meck:unload(epay_http)
    end.

-spec cfg() -> map().
cfg() ->
    #{app_id => ?APP_ID, private_key => fixture_priv_pem(), public_key => fixture_pub_pem()}.

%%%-------------------------------------------------------------------
%%% 1. 同步应答：原始字节正向（嵌套对象/数组/中文/空格/转义引号/非字典序）
%%%-------------------------------------------------------------------

%% 手写节点字节（非 json_encode 生成）：嵌套对象 + 对象数组 + 中文字符串 +
%% 字符串内空格 + 字符串内转义引号与花括号；字段顺序刻意不同于字典序。
-spec raw_node() -> binary().
raw_node() ->
    <<"{\"trade_status\":\"TRADE_SUCCESS\",\"msg\":\"Success\",\"code\":\"10000\","
        "\"out_trade_no\":\"X1\",\"buyer_pay_amount\":\"1.00\",\"total_amount\":\"1.00\","
        "\"fund_bill_list\":[{\"amount\":\"1.00\",\"fund_channel\":\"ALIPAYACCOUNT\"},"
        "{\"amount\":\"0.00\",\"fund_channel\":\"PCREDIT\"}],"
        "\"buyer_user_info\":{\"nick_name\":\"Ali ", "张三"/utf8,
        "\",\"user_name\":\"", "张 三"/utf8, "\"},"
        "\"passback_params\":\"{\\\"seller_id\\\":\\\"208810111\\\"}\"}">>.

query_signed_raw_bytes_ok_test() ->
    with_http(signed_body(?QUERY_KEY, raw_node()), fun() ->
        {ok, M} = epay_alipay:query(cfg(), #{out_trade_no => <<"X1">>}),
        ?assertEqual(success, maps:get(trade_state, M)),
        ?assertEqual(<<"TRADE_SUCCESS">>, maps:get(raw_state, M)),
        %% 加性：节点原始字段完整保留
        ?assertEqual(<<"10000">>, maps:get(<<"code">>, maps:get(raw, M)))
    end).

%%%-------------------------------------------------------------------
%%% 2. re-encode 区分：只有「原始节点字节」的签名能过
%%%-------------------------------------------------------------------

%% 节点手写为逆字典序；erlang json re-encode（jsone 小 map 按字典序输出）
%% 字节形态必然不同 → 对 re-encode 字节的签名必须验签失败。
reencode_node() ->
    <<"{\"trade_status\":\"TRADE_SUCCESS\",\"msg\":\"Success\",\"code\":\"10000\"}">>.

reencoded_bytes(Node) ->
    {ok, Decoded} = epay_util:json_decode(Node),
    epay_util:json_encode(Decoded).

query_reencoded_sign_fails_test() ->
    Node = reencode_node(),
    ReEncoded = reencoded_bytes(Node),
    %% 前置自检：两种字节形态确实不同（否则本用例失去区分力）
    ?assertNotEqual(Node, ReEncoded),
    %% 对 re-encode 后的字节签名；body 携带的节点仍是手写原始字节 → 必须验签失败
    Body = <<"{\"", ?QUERY_KEY/binary, "\":", Node/binary,
        ",\"sign\":\"", (sign_raw(ReEncoded))/binary,
        "\",\"sign_type\":\"RSA2\"}">>,
    with_http(Body, fun() ->
        ?assertMatch(
            {error, {bad_signature, _}},
            epay_alipay:query(cfg(), #{out_trade_no => <<"X1">>})
        )
    end).

%%%-------------------------------------------------------------------
%%% 3. `\/` 兼容重试
%%%-------------------------------------------------------------------

%% 节点字符串值含 JSON 转义斜杠（字节 backslash+slash）；签名对替换为 `/` 后
%% 的字节 → 第一次验签失败，`\/`→`/` 重试通过（官方 JSON 转义兼容）。
escaped_node() ->
    <<"{\"code\":\"10000\",\"msg\":\"Success\",\"trade_status\":\"TRADE_SUCCESS\","
        "\"buyer_logon_id\":\"ali\\/user@test.com\"}">>.

query_escaped_slash_retry_ok_test() ->
    Node = escaped_node(),
    ?assertNotEqual(nomatch, binary:match(Node, <<"\\/">>)),
    Slashed = binary:replace(Node, <<"\\/">>, <<"/">>, [global]),
    Keys = keys(),
    Body = <<"{\"", ?QUERY_KEY/binary, "\":", Node/binary,
        ",\"sign\":\"", (sign_with(maps:get(priv_rec, Keys), Slashed))/binary,
        "\",\"sign_type\":\"RSA2\"}">>,
    with_http(Body, fun() ->
        ?assertMatch(
            {ok, #{trade_state := success}},
            epay_alipay:query(cfg(), #{out_trade_no => <<"X1">>})
        )
    end).

%%%-------------------------------------------------------------------
%%% 4. 拒绝路径：坏签名 / 成功无 sign / 篡改 body / 无凭据
%%%-------------------------------------------------------------------

query_bad_signature_test() ->
    Node = <<"{\"code\":\"10000\",\"msg\":\"Success\",\"trade_status\":\"TRADE_SUCCESS\"}">>,
    Body = <<"{\"", ?QUERY_KEY/binary, "\":", Node/binary,
        ",\"sign\":\"", (base64:encode(crypto:strong_rand_bytes(256)))/binary, "\"}">>,
    with_http(Body, fun() ->
        ?assertMatch(
            {error, {bad_signature, _}},
            epay_alipay:query(cfg(), #{out_trade_no => <<"X1">>})
        )
    end).

query_success_missing_sign_test() ->
    Node = raw_node(),
    Body = <<"{\"", ?QUERY_KEY/binary, "\":", Node/binary, "}">>,
    with_http(Body, fun() ->
        ?assertMatch(
            {error, {missing_signature, _}},
            epay_alipay:query(cfg(), #{out_trade_no => <<"X1">>})
        )
    end).

query_tampered_body_test() ->
    Node = raw_node(),
    Sig = sign_raw(Node),
    Body = <<"{\"", ?QUERY_KEY/binary, "\":", Node/binary,
        ",\"sign\":\"", Sig/binary, "\",\"sign_type\":\"RSA2\"}">>,
    %% 签名后篡改节点字节（金额 1.00 → 9.99），签名与字节不再对应
    Tampered = binary:replace(Body, <<"\"total_amount\":\"1.00\"">>, <<"\"total_amount\":\"9.99\"">>),
    ?assertNotEqual(Body, Tampered),
    with_http(Tampered, fun() ->
        ?assertMatch(
            {error, {bad_signature, _}},
            epay_alipay:query(cfg(), #{out_trade_no => <<"X1">>})
        )
    end).

query_no_credential_test() ->
    Cfg = #{app_id => ?APP_ID, private_key => fixture_priv_pem()},
    with_http(signed_body(?QUERY_KEY, raw_node()), fun() ->
        ?assertMatch(
            {error, {no_credential, _}},
            epay_alipay:query(Cfg, #{out_trade_no => <<"X1">>})
        )
    end).

%%%-------------------------------------------------------------------
%%% 5. 失败响应：无 sign 维持 gateway_error；带 sign 必须验签
%%%-------------------------------------------------------------------

query_biz_error_no_sign_test() ->
    Node = <<"{\"code\":\"40004\",\"msg\":\"Business Failed\","
        "\"sub_code\":\"ACQ.TRADE_NOT_EXIST\",\"sub_msg\":\"trade not exist\"}">>,
    with_http(<<"{\"", ?QUERY_KEY/binary, "\":", Node/binary, "}">>, fun() ->
        ?assertMatch(
            {error, {gateway_error, <<"trade not exist">>}},
            epay_alipay:query(cfg(), #{out_trade_no => <<"X1">>})
        )
    end).

query_biz_error_signed_ok_test() ->
    Node = <<"{\"code\":\"40004\",\"msg\":\"Business Failed\","
        "\"sub_code\":\"ACQ.TRADE_NOT_EXIST\",\"sub_msg\":\"trade not exist\"}">>,
    with_http(signed_body(?QUERY_KEY, Node), fun() ->
        %% 验签通过但业务失败：仍报 gateway_error
        ?assertMatch(
            {error, {gateway_error, <<"trade not exist">>}},
            epay_alipay:query(cfg(), #{out_trade_no => <<"X1">>})
        )
    end).

query_biz_error_signed_bad_test() ->
    Node = <<"{\"code\":\"40004\",\"msg\":\"Business Failed\","
        "\"sub_code\":\"ACQ.TRADE_NOT_EXIST\",\"sub_msg\":\"trade not exist\"}">>,
    Body = <<"{\"", ?QUERY_KEY/binary, "\":", Node/binary,
        ",\"sign\":\"", (base64:encode(crypto:strong_rand_bytes(256)))/binary, "\"}">>,
    with_http(Body, fun() ->
        ?assertMatch(
            {error, {bad_signature, _}},
            epay_alipay:query(cfg(), #{out_trade_no => <<"X1">>})
        )
    end).

%%%-------------------------------------------------------------------
%%% 6. error_response 节点回退（官方 checkResponseSign 同款顺序）
%%%-------------------------------------------------------------------

query_error_response_signed_test() ->
    Node = <<"{\"code\":\"40002\",\"msg\":\"InvalidArguments\"}">>,
    with_http(signed_body(<<"error_response">>, Node), fun() ->
        ?assertMatch(
            {error, {gateway_error, <<"InvalidArguments">>}},
            epay_alipay:query(cfg(), #{out_trade_no => <<"X1">>})
        )
    end).

query_error_response_no_sign_test() ->
    Node = <<"{\"code\":\"40002\",\"msg\":\"InvalidArguments\"}">>,
    with_http(<<"{\"error_response\":", Node/binary, "}">>, fun() ->
        ?assertMatch(
            {error, {gateway_error, <<"InvalidArguments">>}},
            epay_alipay:query(cfg(), #{out_trade_no => <<"X1">>})
        )
    end).

%%%-------------------------------------------------------------------
%%% 7. 证书模式（alipay_public_cert）：提取证书公钥验签 + key 选择边界
%%%-------------------------------------------------------------------

cert_mode_ok_test() ->
    Cert = cert_fixture(),
    Cfg = #{
        app_id => ?APP_ID,
        private_key => fixture_priv_pem(),
        alipay_public_cert => maps:get(cert_pem, Cert)
    },
    Node = <<"{\"code\":\"10000\",\"msg\":\"Success\",\"trade_status\":\"TRADE_SUCCESS\"}">>,
    Body = signed_body_with(maps:get(priv_rec, Cert), ?QUERY_KEY, Node),
    with_http(Body, fun() ->
        ?assertMatch(
            {ok, #{trade_state := success}},
            epay_alipay:query(Cfg, #{out_trade_no => <<"X1">>})
        )
    end).

%% key 选择边界：同时配置 alipay_public_cert（密钥 A）与 public_key（密钥 B），
%% 必须用证书公钥（A）——用 B 签名应拒绝。
cert_mode_precedence_test() ->
    Cert = cert_fixture(),
    Cfg = #{
        app_id => ?APP_ID,
        private_key => fixture_priv_pem(),
        alipay_public_cert => maps:get(cert_pem, Cert),
        public_key => fixture_pub_pem()
    },
    Node = <<"{\"code\":\"10000\",\"msg\":\"Success\",\"trade_status\":\"TRADE_SUCCESS\"}">>,
    BodyA = signed_body_with(maps:get(priv_rec, Cert), ?QUERY_KEY, Node),
    BodyB = signed_body(?QUERY_KEY, Node),
    with_http(BodyA, fun() ->
        ?assertMatch(
            {ok, #{trade_state := success}},
            epay_alipay:query(Cfg, #{out_trade_no => <<"X1">>})
        )
    end),
    with_http(BodyB, fun() ->
        ?assertMatch(
            {error, {bad_signature, _}},
            epay_alipay:query(Cfg, #{out_trade_no => <<"X1">>})
        )
    end).

%%%-------------------------------------------------------------------
%%% 8. refund / close / cancel / bill 应答路径全覆盖
%%%-------------------------------------------------------------------

refund_signed_ok_test() ->
    Node = <<"{\"code\":\"10000\",\"msg\":\"Success\",\"fund_change\":\"Y\","
        "\"refund_fee\":\"0.50\",\"out_trade_no\":\"X1\"}">>,
    with_http(signed_body(?REFUND_KEY, Node), fun() ->
        ?assertMatch(
            {ok, #{<<"code">> := <<"10000">>, <<"fund_change">> := <<"Y">>}},
            epay_alipay:refund(cfg(), #{
                out_trade_no => <<"X1">>, refund_amount_fen => 50
            })
        )
    end).

refund_missing_sign_test() ->
    with_http(<<"{\"", ?REFUND_KEY/binary, "\":{\"code\":\"10000\",\"msg\":\"Success\"}}">>, fun() ->
        ?assertMatch(
            {error, {missing_signature, _}},
            epay_alipay:refund(cfg(), #{
                out_trade_no => <<"X1">>, refund_amount_fen => 50
            })
        )
    end).

close_signed_ok_test() ->
    with_http(signed_body(?CLOSE_KEY, <<"{\"code\":\"10000\",\"msg\":\"Success\"}">>), fun() ->
        ?assertMatch(
            {ok, #{type := alipay_close}},
            epay_alipay:close(cfg(), #{out_trade_no => <<"X1">>})
        )
    end).

cancel_signed_ok_test() ->
    with_http(signed_body(?CANCEL_KEY, <<"{\"code\":\"10000\",\"action\":\"close\"}">>), fun() ->
        ?assertMatch(
            {ok, #{type := alipay_cancel, action := <<"close">>}},
            epay_alipay:cancel(cfg(), #{out_trade_no => <<"X1">>})
        )
    end).

bill_signed_ok_test() ->
    Node = <<"{\"code\":\"10000\",\"bill_download_url\":\"https://oss/bill.zip\"}">>,
    with_http(signed_body(?BILL_KEY, Node), fun() ->
        ?assertMatch(
            {ok, #{type := alipay_bill, download_url := <<"https://oss/bill.zip">>}},
            epay_alipay:download_bill(cfg(), #{bill_date => <<"2026-09-22">>})
        )
    end).

%%%-------------------------------------------------------------------
%%% 9. 异步通知合同：alipay_cert_sn 参与签名串 + app_id 绑定
%%%-------------------------------------------------------------------

notify_form() ->
    #{
        <<"app_id">> => ?APP_ID,
        <<"out_trade_no">> => <<"X1">>,
        <<"trade_no">> => <<"2026092222001400081">>,
        <<"trade_status">> => <<"TRADE_SUCCESS">>,
        <<"total_amount">> => <<"1.00">>,
        <<"seller_id">> => <<"208810111">>,
        <<"alipay_cert_sn">> => <<"45c8d0d09b4b7e6a1d8f0c2b9a3e5d7f">>
    }.

%% 测试侧独立实现官方 getSignCheckContentV1：排除 sign/sign_type，
%% key 字典序 k=v& 拼接（alipay_cert_sn 不排除——合同点）。
notify_content(Form) ->
    Keys = lists:sort([
        K || K <- maps:keys(Form), K =/= <<"sign">>, K =/= <<"sign_type">>
    ]),
    Parts = [<<K/binary, "=", (maps:get(K, Form))/binary>> || K <- Keys],
    join(Parts, <<"&">>).

join([], _Sep) -> <<>>;
join([H | T], Sep) ->
    lists:foldl(fun(X, Acc) -> <<Acc/binary, Sep/binary, X/binary>> end, H, T).

alipay_notify_signed_with_cert_sn_test() ->
    Form0 = notify_form(),
    Form = Form0#{<<"sign">> => sign_raw(notify_content(Form0)), <<"sign_type">> => <<"RSA2">>},
    {ok, M} = epay_alipay:verify_notify(cfg(), #{form => Form}),
    ?assertEqual(success, maps:get(trade_state, M)),
    %% 加性：原始字段仍在
    ?assertEqual(<<"X1">>, maps:get(<<"out_trade_no">>, M)),
    ?assertEqual(<<"2026092222001400081">>, maps:get(<<"trade_no">>, M)).

%% 反例证伪旧审计 SEC-7：若按「排除 alipay_cert_sn 的错误串」签名 → 必须验签失败
alipay_notify_excluding_cert_sn_fails_test() ->
    Form0 = notify_form(),
    WrongContent = notify_content(maps:remove(<<"alipay_cert_sn">>, Form0)),
    Form = Form0#{<<"sign">> => sign_raw(WrongContent), <<"sign_type">> => <<"RSA2">>},
    ?assertMatch(
        {error, {bad_signature, _}},
        epay_alipay:verify_notify(cfg(), #{form => Form})
    ).

%% 签名本身合法，仅 app_id 与配置不同 → 拒绝
alipay_notify_app_id_mismatch_test() ->
    Base = notify_form(),
    Form0 = Base#{<<"app_id">> => <<"2021999900000000">>},
    Form = Form0#{<<"sign">> => sign_raw(notify_content(Form0)), <<"sign_type">> => <<"RSA2">>},
    ?assertMatch(
        {error, {app_id_mismatch, _}},
        epay_alipay:verify_notify(cfg(), #{form => Form})
    ).

alipay_notify_missing_app_id_test() ->
    Form0 = maps:remove(<<"app_id">>, notify_form()),
    Sig = sign_raw(notify_content(Form0)),
    ?assertMatch(
        {error, {missing_app_id, _}},
        epay_alipay:verify_notify(cfg(), #{form => Form0#{<<"sign">> => Sig}})
    ),
    %% 空 app_id 同样视为缺失
    EmptyBase = notify_form(),
    Empty = EmptyBase#{<<"app_id">> => <<>>, <<"sign">> => Sig},
    ?assertMatch(
        {error, {missing_app_id, _}},
        epay_alipay:verify_notify(cfg(), #{form => Empty})
    ).
