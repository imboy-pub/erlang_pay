-module(epay_wechat).
-behaviour(epay_gateway).
%%%===================================================================
%%% @doc 微信支付 v3 网关 / WeChat Pay APIv3 gateway
%%%
%%% 移植自官方 wechatpay-apiv3/wechatpay-go：
%%%   - utils.SignSHA256WithRSA   -> APIv3 请求签名（商户私钥）
%%%   - utils.DecryptAES256GCM    -> 回调 resource 解密（APIv3 Key 直用）
%%%   - core/notify               -> 回调验签 + 解密
%%% 覆盖：
%%%   - jsapi_prepay/2 / native_prepay/2 : 下单获取 prepay_id / code_url
%%%   - build_jsapi_pay_sign/2           : 客户端调起二次签名 paySign
%%%   - refund/2                         : v3 退款
%%%   - verify_notify/3                  : 回调验签（平台公钥）+ AES-GCM 解密
%%%
%%% Cfg :: #{mch_id := binary(), app_id := binary(), api_v3_key := binary(),
%%%          mch_serial_no := binary(), private_key := binary(),
%%%          platform_public_key => binary(), notify_url => binary(),
%%%          base_url => binary()}
%%% 金额统一以「分」(integer) 传入（微信原生单位即分）。
%%% @end
%%%===================================================================

%% epay_gateway behaviour
-export([create_payment/2, refund/2, verify_notify/2, build_pay_sign/2]).
%% 低层 API（直接使用）
-export([jsapi_prepay/2, native_prepay/2, build_jsapi_pay_sign/2, verify_notify/3]).

-define(BASE_URL, <<"https://api.mch.weixin.qq.com">>).

%%%===================================================================
%%% epay_gateway behaviour
%%%===================================================================

%% @doc 下单。Order :: #{out_trade_no, amount_fen, description => binary(),
%%   pay_type => jsapi | native, openid => binary()(jsapi 必填)}
-spec create_payment(map(), map()) -> {ok, map()} | {error, binary()}.
create_payment(Cfg, Order) ->
    case maps:get(pay_type, Order, jsapi) of
        native ->
            case native_prepay(Cfg, Order) of
                {ok, #{code_url := CodeUrl}} ->
                    {ok, #{type => wechat_native, code_url => CodeUrl}};
                {error, _} = Err ->
                    Err
            end;
        _ ->
            case jsapi_prepay(Cfg, Order) of
                {ok, #{prepay_id := PrepayId}} ->
                    {ok, #{type => wechat_jsapi, prepay_id => PrepayId}};
                {error, _} = Err ->
                    Err
            end
    end.

%% @doc 回调验签 + AES-GCM 解密。Ctx :: #{headers := map(), body := binary()}。
-spec verify_notify(map(), map()) -> {ok, map()} | {error, atom()}.
verify_notify(Cfg, Ctx) ->
    Headers = maps:get(headers, Ctx, #{}),
    Body = maps:get(body, Ctx, <<>>),
    verify_notify(Cfg, Headers, Body).

%% @doc 客户端 JSAPI 二次签名。Args :: #{prepay_id := binary()}。
-spec build_pay_sign(map(), map()) -> {ok, map()} | {error, binary()}.
build_pay_sign(Cfg, Args) ->
    build_jsapi_pay_sign(Cfg, maps:get(prepay_id, Args)).
-define(PATH_JSAPI, <<"/v3/pay/transactions/jsapi">>).
-define(PATH_NATIVE, <<"/v3/pay/transactions/native">>).
-define(PATH_REFUND, <<"/v3/refund/domestic/refunds">>).
%% 回调时间戳容忍窗口（秒）—— 防重放
-define(NOTIFY_TOLERANCE, 300).

%%%===================================================================
%%% 下单
%%%===================================================================

%% @doc JSAPI 下单。Order :: #{out_trade_no, amount_fen, description, openid}
-spec jsapi_prepay(map(), map()) -> {ok, #{prepay_id := binary()}} | {error, binary()}.
jsapi_prepay(Cfg, Order) ->
    Body = jsapi_body(Cfg, Order),
    case post_signed(Cfg, ?PATH_JSAPI, Body) of
        {ok, #{<<"prepay_id">> := PrepayId}} -> {ok, #{prepay_id => PrepayId}};
        {ok, _} -> {error, <<"微信下单响应缺少 prepay_id"/utf8>>};
        {error, _} = Err -> Err
    end.

%% @doc Native 下单（扫码）。Order :: #{out_trade_no, amount_fen, description}
-spec native_prepay(map(), map()) -> {ok, #{code_url := binary()}} | {error, binary()}.
native_prepay(Cfg, Order) ->
    Body = native_body(Cfg, Order),
    case post_signed(Cfg, ?PATH_NATIVE, Body) of
        {ok, #{<<"code_url">> := CodeUrl}} -> {ok, #{code_url => CodeUrl}};
        {ok, _} -> {error, <<"微信下单响应缺少 code_url"/utf8>>};
        {error, _} = Err -> Err
    end.

-spec jsapi_body(map(), map()) -> binary().
jsapi_body(Cfg, Order) ->
    OpenId = maps:get(openid, Order, <<>>),
    Base = base_order_map(Cfg, Order),
    epay_util:json_encode(Base#{<<"payer">> => #{<<"openid">> => OpenId}}).

-spec native_body(map(), map()) -> binary().
native_body(Cfg, Order) ->
    epay_util:json_encode(base_order_map(Cfg, Order)).

-spec base_order_map(map(), map()) -> map().
base_order_map(Cfg, Order) ->
    #{
        <<"appid">> => maps:get(app_id, Cfg),
        <<"mchid">> => maps:get(mch_id, Cfg),
        <<"description">> => maps:get(description, Order, <<"充值"/utf8>>),
        <<"out_trade_no">> => maps:get(out_trade_no, Order),
        <<"notify_url">> => maps:get(notify_url, Cfg, <<>>),
        <<"amount">> => #{
            <<"total">> => maps:get(amount_fen, Order),
            <<"currency">> => <<"CNY">>
        }
    }.

%% @doc 客户端 JSAPI 调起二次签名。返回 #{appId,timeStamp,nonceStr,package,signType,paySign}
-spec build_jsapi_pay_sign(map(), binary()) -> {ok, map()} | {error, binary()}.
build_jsapi_pay_sign(Cfg, PrepayId) ->
    AppId = maps:get(app_id, Cfg),
    PriKey = maps:get(private_key, Cfg),
    TimeStamp = integer_to_binary(erlang:system_time(second)),
    NonceStr = epay_crypto:nonce(16),
    Package = <<"prepay_id=", PrepayId/binary>>,
    Message = <<AppId/binary, "\n", TimeStamp/binary, "\n", NonceStr/binary, "\n", Package/binary,
        "\n">>,
    case epay_crypto:rsa_sign_sha256(Message, PriKey) of
        {ok, Sig} ->
            {ok, #{
                <<"appId">> => AppId,
                <<"timeStamp">> => TimeStamp,
                <<"nonceStr">> => NonceStr,
                <<"package">> => Package,
                <<"signType">> => <<"RSA">>,
                <<"paySign">> => base64:encode(Sig)
            }};
        {error, _} ->
            {error, <<"微信 paySign 签名失败"/utf8>>}
    end.

%%%===================================================================
%%% 退款
%%%===================================================================

%% @doc 退款。Req :: #{out_trade_no | transaction_id, out_refund_no,
%%   refund_fen, total_fen, reason => binary()}
-spec refund(map(), map()) -> {ok, map()} | {error, binary()}.
refund(Cfg, Req) ->
    Body = refund_body(Cfg, Req),
    case post_signed(Cfg, ?PATH_REFUND, Body) of
        {ok, #{<<"status">> := Status} = Resp} ->
            case lists:member(Status, [<<"SUCCESS">>, <<"PROCESSING">>]) of
                true -> {ok, Resp};
                false -> {error, <<"微信退款状态:"/utf8, Status/binary>>}
            end;
        {ok, Resp} ->
            {ok, Resp};
        {error, _} = Err ->
            Err
    end.

-spec refund_body(map(), map()) -> binary().
refund_body(_Cfg, Req) ->
    Amount = #{
        <<"refund">> => maps:get(refund_fen, Req),
        <<"total">> => maps:get(total_fen, Req),
        <<"currency">> => <<"CNY">>
    },
    M0 = #{<<"out_refund_no">> => maps:get(out_refund_no, Req), <<"amount">> => Amount},
    M1 =
        case maps:get(transaction_id, Req, <<>>) of
            <<>> -> M0#{<<"out_trade_no">> => maps:get(out_trade_no, Req)};
            Tid -> M0#{<<"transaction_id">> => Tid}
        end,
    M2 =
        case maps:get(reason, Req, <<>>) of
            <<>> -> M1;
            Reason -> M1#{<<"reason">> => Reason}
        end,
    epay_util:json_encode(M2).

%%%===================================================================
%%% 回调验签 + 解密
%%%===================================================================

%% @doc 验证回调签名（平台公钥）并解密 resource，返回明文 JSON map。
%% Headers 为小写键 map（cowboy 已小写化）。
-spec verify_notify(map(), map(), binary()) -> {ok, map()} | {error, atom()}.
verify_notify(Cfg, Headers, RawBody) ->
    Ts = header(Headers, <<"wechatpay-timestamp">>),
    Nonce = header(Headers, <<"wechatpay-nonce">>),
    Sig = header(Headers, <<"wechatpay-signature">>),
    PubKey = maps:get(platform_public_key, Cfg, <<>>),
    case validate_notify_headers(Ts, Nonce, Sig, PubKey) of
        ok ->
            case check_timestamp(Ts) of
                ok ->
                    Message = <<Ts/binary, "\n", Nonce/binary, "\n", RawBody/binary, "\n">>,
                    case safe_b64_decode(Sig) of
                        {ok, SigBin} ->
                            case epay_crypto:rsa_verify_sha256(Message, SigBin, PubKey) of
                                true -> decrypt_resource(Cfg, RawBody);
                                false -> {error, bad_signature}
                            end;
                        error ->
                            {error, bad_signature}
                    end;
                {error, _} = E ->
                    E
            end;
        {error, _} = Err ->
            Err
    end.

-spec validate_notify_headers(binary(), binary(), binary(), binary()) -> ok | {error, atom()}.
validate_notify_headers(<<>>, _, _, _) -> {error, missing_timestamp};
validate_notify_headers(_, <<>>, _, _) -> {error, missing_nonce};
validate_notify_headers(_, _, <<>>, _) -> {error, missing_signature};
validate_notify_headers(_, _, _, <<>>) -> {error, no_credential};
validate_notify_headers(_, _, _, _) -> ok.

-spec check_timestamp(binary()) -> ok | {error, atom()}.
check_timestamp(TsBin) ->
    try
        Ts = binary_to_integer(TsBin),
        Now = erlang:system_time(second),
        case abs(Now - Ts) > ?NOTIFY_TOLERANCE of
            true -> {error, timestamp_expired};
            false -> ok
        end
    catch
        _:_ -> {error, invalid_timestamp}
    end.

-spec decrypt_resource(map(), binary()) -> {ok, map()} | {error, atom()}.
decrypt_resource(Cfg, RawBody) ->
    ApiV3Key = maps:get(api_v3_key, Cfg, <<>>),
    case epay_util:json_decode(RawBody) of
        {ok, #{<<"resource">> := Res}} when is_map(Res) ->
            Cipher = maps:get(<<"ciphertext">>, Res, <<>>),
            Nonce = maps:get(<<"nonce">>, Res, <<>>),
            Aad = maps:get(<<"associated_data">>, Res, <<>>),
            case epay_crypto:aes_256_gcm_decrypt(Cipher, ApiV3Key, Nonce, Aad) of
                {ok, Plain} ->
                    case epay_util:json_decode(Plain) of
                        {ok, M} when is_map(M) -> {ok, M};
                        _ -> {error, bad_plaintext}
                    end;
                {error, _} = E ->
                    E
            end;
        _ ->
            {error, no_resource}
    end.

%%%===================================================================
%%% Internal —— APIv3 签名 + 出站
%%%===================================================================

%% 签名 + POST，返回解析后的 JSON map（2xx）或 {error, binary()}
-spec post_signed(map(), binary(), binary()) -> {ok, map()} | {error, binary()}.
post_signed(Cfg, Path, Body) ->
    case sign_request(Cfg, <<"POST">>, Path, Body) of
        {ok, Auth} ->
            Url = <<(maps:get(base_url, Cfg, ?BASE_URL))/binary, Path/binary>>,
            Headers = [
                {<<"Authorization">>, Auth},
                {<<"Accept">>, <<"application/json">>},
                {<<"User-Agent">>, <<"erlang_pay/0.1.0">>}
            ],
            case epay_http:post_json(Url, Headers, Body) of
                {ok, Status, _H, RespBody} when Status >= 200, Status < 300 ->
                    decode_ok(RespBody);
                {ok, _Status, _H, RespBody} ->
                    {error, wechat_err_msg(RespBody)};
                {error, Reason} ->
                    {error, http_err_bin(Reason)}
            end;
        {error, _} ->
            {error, <<"微信请求签名失败"/utf8>>}
    end.

-spec decode_ok(binary()) -> {ok, map()} | {error, binary()}.
decode_ok(<<>>) ->
    {ok, #{}};
decode_ok(RespBody) ->
    case epay_util:json_decode(RespBody) of
        {ok, M} when is_map(M) -> {ok, M};
        _ -> {error, <<"微信响应解析失败"/utf8>>}
    end.

%% APIv3 请求签名：Method\nPath\nTimestamp\nNonce\nBody\n，商户私钥 SHA256withRSA
-spec sign_request(map(), binary(), binary(), binary()) -> {ok, binary()} | {error, atom()}.
sign_request(Cfg, Method, Path, Body) ->
    MchId = maps:get(mch_id, Cfg),
    Serial = maps:get(mch_serial_no, Cfg),
    PriKey = maps:get(private_key, Cfg),
    Timestamp = integer_to_binary(erlang:system_time(second)),
    Nonce = epay_crypto:nonce(16),
    Message = <<Method/binary, "\n", Path/binary, "\n", Timestamp/binary, "\n", Nonce/binary, "\n",
        Body/binary, "\n">>,
    case epay_crypto:rsa_sign_sha256(Message, PriKey) of
        {ok, Sig} ->
            {ok, auth_header(MchId, Serial, Nonce, Timestamp, base64:encode(Sig))};
        {error, _} = Err ->
            Err
    end.

-spec auth_header(binary(), binary(), binary(), binary(), binary()) -> binary().
auth_header(MchId, Serial, Nonce, Timestamp, SignB64) ->
    <<"WECHATPAY2-SHA256-RSA2048 ",
        "mchid=\"", MchId/binary, "\",",
        "nonce_str=\"", Nonce/binary, "\",",
        "signature=\"", SignB64/binary, "\",",
        "timestamp=\"", Timestamp/binary, "\",",
        "serial_no=\"", Serial/binary, "\"">>.

-spec wechat_err_msg(binary()) -> binary().
wechat_err_msg(RespBody) ->
    case epay_util:json_decode(RespBody) of
        {ok, #{<<"message">> := Msg}} -> Msg;
        {ok, #{<<"code">> := Code}} -> Code;
        _ -> <<"微信接口错误"/utf8>>
    end.

-spec header(map(), binary()) -> binary().
header(Headers, Key) ->
    case maps:get(Key, Headers, <<>>) of
        V when is_binary(V) -> V;
        V when is_list(V) -> iolist_to_binary(V);
        _ -> <<>>
    end.

-spec safe_b64_decode(binary()) -> {ok, binary()} | error.
safe_b64_decode(B) ->
    try {ok, base64:decode(B)} catch _:_ -> error end.

-spec http_err_bin(term()) -> binary().
http_err_bin(R) ->
    iolist_to_binary(io_lib:format("~p", [R])).
