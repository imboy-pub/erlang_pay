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
%%%   - EP-11 应答验签                    : 2xx 应答先验签后解析
%%%
%%% EP-11 应答与回调验签合同（官方《签名验证》+ 官方 SDK wechatpay-java）：
%%%   - 验签串三行构造：Timestamp\nNonce\nBody\n（行尾均含 \n；204 空 body
%%%     时 Message = Ts\nNonce\n\n）；用原始报文主体验签，先验签后 JSON 解析。
%%%   - 四个头：Wechatpay-Timestamp / Wechatpay-Nonce /
%%%     Wechatpay-Signature（base64 RSA-SHA256）/ Wechatpay-Serial。
%%%   - 应答与回调时间戳均做双向 ±5min 窗口校验（防重放）。
%%%   - 验签失败（含 SIGNTEST 前缀探测流量）一律 fail-closed，绝不解析 body。
%%%
%%% Cfg :: #{mch_id := binary(), app_id := binary(), api_v3_key := binary(),
%%%          mch_serial_no := binary(), private_key := binary(),
%%%          platform_public_key => binary(), notify_url => binary(),
%%%          base_url => binary(),
%%%          platform_serial => binary()}  %% 可选：配置后应答/回调头
%%%                                       %% wechatpay-serial 必须精确匹配
%%% 金额统一以「分」(integer) 传入（微信原生单位即分）。
%%% @end
%%%===================================================================

%% epay_gateway behaviour
-export([
    create_payment/2, refund/2, verify_notify/2, build_pay_sign/2, query/2, download_bill/2,
    close/2, capabilities/0
]).
%% 低层 API（直接使用）
-export([jsapi_prepay/2, native_prepay/2, build_jsapi_pay_sign/2, verify_notify/3]).

-define(BASE_URL, <<"https://api.mch.weixin.qq.com">>).

%% @doc 能力声明。微信支持 JSAPI 客户端二次签名（paySign）与关单（无独立撤单）。
-spec capabilities() -> [atom()].
capabilities() ->
    [create_payment, refund, query, download_bill, verify_notify, build_pay_sign, close].

%% @doc 关单。Req :: #{out_trade_no := binary()}。微信关单成功返回 204 无 body。
-spec close(map(), map()) -> {ok, map()} | epay_gateway:err().
close(Cfg, Req) ->
    OutTradeNo = maps:get(out_trade_no, Req),
    MchId = maps:get(mch_id, Cfg),
    Path = <<"/v3/pay/transactions/out-trade-no/", OutTradeNo/binary, "/close">>,
    Body = epay_util:json_encode(#{<<"mchid">> => MchId}),
    case post_signed(Cfg, Path, Body) of
        {ok, _} -> {ok, #{type => wechat_close, out_trade_no => OutTradeNo}};
        {error, _} = Err -> Err
    end.

%%%===================================================================
%%% epay_gateway behaviour
%%%===================================================================

%% @doc 下单。Order :: #{out_trade_no, amount_fen, description => binary(),
%%   pay_type => jsapi | native, openid => binary()(jsapi 必填)}
-spec create_payment(map(), map()) -> {ok, map()} | epay_gateway:err().
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
-spec verify_notify(map(), map()) -> {ok, map()} | epay_gateway:err().
verify_notify(Cfg, Ctx) ->
    Headers = maps:get(headers, Ctx, #{}),
    Body = maps:get(body, Ctx, <<>>),
    verify_notify(Cfg, Headers, Body).

%% @doc 客户端 JSAPI 二次签名。Args :: #{prepay_id := binary()}。
-spec build_pay_sign(map(), map()) -> {ok, map()} | epay_gateway:err().
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
-spec jsapi_prepay(map(), map()) -> {ok, #{prepay_id := binary()}} | epay_gateway:err().
jsapi_prepay(Cfg, Order) ->
    Body = jsapi_body(Cfg, Order),
    case post_signed(Cfg, ?PATH_JSAPI, Body) of
        {ok, #{<<"prepay_id">> := PrepayId}} -> {ok, #{prepay_id => PrepayId}};
        {ok, _} -> {error, {invalid_response, <<"微信下单响应缺少 prepay_id"/utf8>>}};
        {error, _} = Err -> Err
    end.

%% @doc Native 下单（扫码）。Order :: #{out_trade_no, amount_fen, description}
-spec native_prepay(map(), map()) -> {ok, #{code_url := binary()}} | epay_gateway:err().
native_prepay(Cfg, Order) ->
    Body = native_body(Cfg, Order),
    case post_signed(Cfg, ?PATH_NATIVE, Body) of
        {ok, #{<<"code_url">> := CodeUrl}} -> {ok, #{code_url => CodeUrl}};
        {ok, _} -> {error, {invalid_response, <<"微信下单响应缺少 code_url"/utf8>>}};
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
-spec build_jsapi_pay_sign(map(), binary()) -> {ok, map()} | epay_gateway:err().
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
            {error, {sign_failed, <<"微信 paySign 签名失败"/utf8>>}}
    end.

%%%===================================================================
%%% 退款
%%%===================================================================

%% @doc 退款。Req :: #{out_trade_no | transaction_id, out_refund_no,
%%   refund_fen, total_fen, reason => binary()}
-spec refund(map(), map()) -> {ok, map()} | epay_gateway:err().
refund(Cfg, Req) ->
    Body = refund_body(Cfg, Req),
    case post_signed(Cfg, ?PATH_REFUND, Body) of
        {ok, #{<<"status">> := Status} = Resp} ->
            case lists:member(Status, [<<"SUCCESS">>, <<"PROCESSING">>]) of
                true -> {ok, Resp};
                false -> {error, {gateway_error, <<"微信退款状态:"/utf8, Status/binary>>}}
            end;
        {ok, _Resp} ->
            %% H1：响应缺 status 字段时不得 fallthrough {ok,_}，
            %% 退款结果语义不明须强制调用方按错误处理（资金安全）。
            {error, {invalid_refund_response, <<"微信退款响应缺少 status 字段"/utf8>>}};
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
%% EP-11：Cfg 配置可选键 platform_serial => binary() 时（公钥模式
%% PUB_KEY_ID_ 或证书序列号绑定），头 wechatpay-serial 必须精确匹配，
%% 否则 fail-closed；未配置时不约束（兼容现有单公钥配置）。
-spec verify_notify(map(), map(), binary()) -> {ok, map()} | epay_gateway:err().
verify_notify(Cfg, Headers, RawBody) ->
    Ts = header(Headers, <<"wechatpay-timestamp">>),
    Nonce = header(Headers, <<"wechatpay-nonce">>),
    Sig = header(Headers, <<"wechatpay-signature">>),
    Serial = header(Headers, <<"wechatpay-serial">>),
    PubKey = maps:get(platform_public_key, Cfg, <<>>),
    case validate_sig_headers(Ts, Nonce, Sig, PubKey) of
        ok ->
            case check_serial(Cfg, Serial) of
                ok ->
                    case verify_signature_core(<<"微信回调"/utf8>>, Ts, Nonce, Sig, PubKey, RawBody) of
                        ok -> add_notify_state(decrypt_resource(Cfg, RawBody));
                        {error, _} = Err -> Err
                    end;
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

%% EP-11：serial 约束（应答/回调共用）。Cfg 配置 platform_serial 时头
%% wechatpay-serial 必须与之相等，否则 fail-closed（用于公钥模式
%% PUB_KEY_ID_ 或证书序列号绑定）；未配置时不约束。
-spec check_serial(map(), binary()) -> ok | epay_gateway:err().
check_serial(Cfg, Serial) ->
    case maps:get(platform_serial, Cfg, <<>>) of
        <<>> -> ok;
        Expect when Expect =:= Serial -> ok;
        _ -> {error, {serial_mismatch, Serial}}
    end.

%% 验签核心（应答/回调共用）：时间窗 + base64 + RSA-SHA256。
%% Message 严格三行构造：Ts\nNonce\nBody\n（空 body 时末行仅 \n）。
%% Scene 为场景文案前缀（<<"微信应答">>/<<"微信回调">>）。
-spec verify_signature_core(binary(), binary(), binary(), binary(), binary(), binary()) ->
    ok | epay_gateway:err().
verify_signature_core(Scene, Ts, Nonce, Sig, PubKey, Body) ->
    case check_timestamp(Ts) of
        ok ->
            Message = <<Ts/binary, "\n", Nonce/binary, "\n", Body/binary, "\n">>,
            case safe_b64_decode(Sig) of
                {ok, SigBin} ->
                    case epay_crypto:rsa_verify_sha256(Message, SigBin, PubKey) of
                        true -> ok;
                        false -> {error, {bad_signature, <<Scene/binary, "验签失败"/utf8>>}}
                    end;
                error ->
                    {error, {bad_signature, <<Scene/binary, "签名 base64 解析失败"/utf8>>}}
            end;
        {error, _} = E ->
            E
    end.

-spec validate_sig_headers(binary(), binary(), binary(), binary()) ->
    ok | epay_gateway:err().
validate_sig_headers(<<>>, _, _, _) ->
    {error, {missing_timestamp, <<"缺少微信应答/回调时间戳头"/utf8>>}};
validate_sig_headers(_, <<>>, _, _) ->
    {error, {missing_nonce, <<"缺少微信应答/回调 nonce 头"/utf8>>}};
validate_sig_headers(_, _, <<>>, _) ->
    {error, {missing_signature, <<"缺少微信应答/回调签名头"/utf8>>}};
validate_sig_headers(_, _, _, <<>>) ->
    {error, {no_credential, <<"缺少平台公钥"/utf8>>}};
validate_sig_headers(_, _, _, _) -> ok.

-spec check_timestamp(binary()) -> ok | epay_gateway:err().
check_timestamp(TsBin) ->
    try
        Ts = binary_to_integer(TsBin),
        Now = erlang:system_time(second),
        case abs(Now - Ts) > ?NOTIFY_TOLERANCE of
            true ->
                {error, {timestamp_expired, <<"微信应答/回调时间戳超出容差窗口"/utf8>>}};
            false ->
                ok
        end
    catch
        _:_ -> {error, {invalid_timestamp, <<"微信应答/回调时间戳非法"/utf8>>}}
    end.

%% 加性注入归一 trade_state（epay_state:state()）到解密后的回调明文。
%% 无 trade_state 字段（如部分退款回调）→ unknown，不崩溃；保留全部原始字段。
-spec add_notify_state({ok, map()} | epay_gateway:err()) ->
    {ok, map()} | epay_gateway:err().
add_notify_state({ok, M}) when is_map(M) ->
    St = map_wechat_state(maps:get(<<"trade_state">>, M, <<>>)),
    {ok, M#{trade_state => St}};
add_notify_state(Other) ->
    Other.

-spec decrypt_resource(map(), binary()) -> {ok, map()} | epay_gateway:err().
decrypt_resource(Cfg, RawBody) ->
    %% H2：api_v3_key 缺失/为空必须前置 fail-closed，绝不带空密钥进解密。
    case maps:get(api_v3_key, Cfg, <<>>) of
        <<>> ->
            {error, {no_credential, <<"缺少微信 api_v3_key"/utf8>>}};
        ApiV3Key ->
            decrypt_resource(Cfg, RawBody, ApiV3Key)
    end.

-spec decrypt_resource(map(), binary(), binary()) -> {ok, map()} | epay_gateway:err().
decrypt_resource(_Cfg, RawBody, ApiV3Key) ->
    case epay_util:json_decode(RawBody) of
        {ok, #{<<"resource">> := Res}} when is_map(Res) ->
            Cipher = maps:get(<<"ciphertext">>, Res, <<>>),
            Nonce = maps:get(<<"nonce">>, Res, <<>>),
            Aad = maps:get(<<"associated_data">>, Res, <<>>),
            case epay_crypto:aes_256_gcm_decrypt(Cipher, ApiV3Key, Nonce, Aad) of
                {ok, Plain} ->
                    case epay_util:json_decode(Plain) of
                        {ok, M} when is_map(M) -> {ok, M};
                        _ -> {error, {bad_plaintext, <<"微信回调明文非 JSON 对象"/utf8>>}}
                    end;
                {error, _Reason} ->
                    %% H2：错误文案固定，不拼接内部 atom 名（防内部错误名穿透对外）。
                    {error, {decrypt_failed, <<"微信回调 resource 解密失败"/utf8>>}}
            end;
        _ ->
            {error, {no_resource, <<"微信回调缺少 resource"/utf8>>}}
    end.

%%%===================================================================
%%% Internal —— APIv3 签名 + 出站
%%%===================================================================

%% 签名 + POST，返回解析后的 JSON map（2xx）或 {error, {Code, Msg}}。
%% EP-11：2xx 应答先验签（Wechatpay-* 头 + 平台公钥）后解析。
-spec post_signed(map(), binary(), binary()) -> {ok, map()} | epay_gateway:err().
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
                {ok, Status, RespHeaders, RespBody} when Status >= 200, Status < 300 ->
                    case verify_response(Cfg, RespHeaders, RespBody) of
                        ok -> decode_ok(RespBody);
                        {error, _} = Err -> Err
                    end;
                {ok, _Status, _H, RespBody} ->
                    {error, wechat_err_msg(RespBody)};
                {error, Reason} ->
                    {error, http_err_bin(Reason)}
            end;
        {error, _} ->
            {error, {sign_failed, <<"微信请求签名失败"/utf8>>}}
    end.

%% EP-11：2xx 应答验签（先验签后解析，绝不在验签失败时继续解析 body）。
%% RespHeaders 为 httpc 原始 list（键值类型/大小写不定），先归一化再提取。
%% D-02：platform_public_key 缺失/为空即 fail-closed，无「继续解析」开关。
-spec verify_response(map(), list(), binary()) -> ok | epay_gateway:err().
verify_response(Cfg, RespHeaders, RespBody) ->
    Norm = norm_resp_headers(RespHeaders),
    Ts = maps:get(<<"wechatpay-timestamp">>, Norm, <<>>),
    Nonce = maps:get(<<"wechatpay-nonce">>, Norm, <<>>),
    Sig = maps:get(<<"wechatpay-signature">>, Norm, <<>>),
    Serial = maps:get(<<"wechatpay-serial">>, Norm, <<>>),
    PubKey = maps:get(platform_public_key, Cfg, <<>>),
    case validate_sig_headers(Ts, Nonce, Sig, PubKey) of
        ok ->
            case check_serial(Cfg, Serial) of
                ok ->
                    verify_signature_core(<<"微信应答"/utf8>>, Ts, Nonce, Sig, PubKey, RespBody);
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

%% httpc 原始响应头归一化：[{StrK, StrV} ...]（键值类型/大小写不定）→
%% 小写 binary 键 map，供 Wechatpay-* 头提取。
-spec norm_resp_headers(list()) -> #{binary() := binary()}.
norm_resp_headers(Hdrs) when is_list(Hdrs) ->
    maps:from_list([{lower_bin(K), to_bin(V)} || {K, V} <- Hdrs]).

-spec lower_bin(binary() | string() | atom()) -> binary().
lower_bin(K) when is_binary(K) -> string:lowercase(K);
lower_bin(K) when is_list(K) -> string:lowercase(unicode:characters_to_binary(K));
lower_bin(K) when is_atom(K) -> string:lowercase(atom_to_binary(K)).

-spec to_bin(binary() | string() | atom()) -> binary().
to_bin(V) when is_binary(V) -> V;
to_bin(V) when is_list(V) -> unicode:characters_to_binary(V);
to_bin(V) when is_atom(V) -> atom_to_binary(V).

-spec decode_ok(binary()) -> {ok, map()} | epay_gateway:err().
decode_ok(<<>>) ->
    {ok, #{}};
decode_ok(RespBody) ->
    case epay_util:json_decode(RespBody) of
        {ok, M} when is_map(M) -> {ok, M};
        _ -> {error, {invalid_response, <<"微信响应解析失败"/utf8>>}}
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

%% 网关业务错误（HTTP 非 2xx）：取微信 message/code，打 {gateway_error, Msg}。
-spec wechat_err_msg(binary()) -> {atom(), binary()}.
wechat_err_msg(RespBody) ->
    Msg =
        case epay_util:json_decode(RespBody) of
            {ok, #{<<"message">> := M}} -> M;
            {ok, #{<<"code">> := Code}} -> Code;
            _ -> <<"微信接口错误"/utf8>>
        end,
    {gateway_error, Msg}.

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

%% 传输层错误（inets）：打 {http_error, Msg}。
-spec http_err_bin(term()) -> {atom(), binary()}.
http_err_bin(R) ->
    {http_error, iolist_to_binary(io_lib:format("~p", [R]))}.

%%%===================================================================
%%% 主动查单（GET /v3/pay/transactions/out-trade-no/{no}?mchid=）
%%%===================================================================

%% @doc 按商户订单号查单。Q :: #{out_trade_no := binary()}。
-spec query(map(), map()) -> {ok, map()} | epay_gateway:err().
query(Cfg, Q) ->
    OutTradeNo = maps:get(out_trade_no, Q),
    MchId = maps:get(mch_id, Cfg),
    Path = <<"/v3/pay/transactions/out-trade-no/", OutTradeNo/binary, "?mchid=", MchId/binary>>,
    case get_signed(Cfg, Path) of
        {ok, #{<<"trade_state">> := St} = Resp} ->
            {ok, #{trade_state => map_wechat_state(St), raw_state => St, raw => Resp}};
        {ok, Resp} ->
            {ok, #{trade_state => unknown, raw => Resp}};
        {error, _} = Err ->
            Err
    end.

%% @doc 申请交易账单下载地址。Req :: #{bill_date := binary(), bill_type => binary()}。
-spec download_bill(map(), map()) -> {ok, map()} | epay_gateway:err().
download_bill(Cfg, Req) ->
    BillDate = maps:get(bill_date, Req),
    BillType = maps:get(bill_type, Req, <<"ALL">>),
    Path = <<"/v3/bill/tradebill?bill_date=", BillDate/binary, "&bill_type=", BillType/binary>>,
    case get_signed(Cfg, Path) of
        {ok, #{<<"download_url">> := Url} = Resp} ->
            {ok, #{type => wechat_bill, download_url => Url, raw => Resp}};
        {ok, _Resp} ->
            {error, {invalid_response, <<"微信对账单响应缺少 download_url"/utf8>>}};
        {error, _} = Err ->
            Err
    end.

%% APIv3 签名 + GET（查单/对账共用），复用 sign_request（Method=GET, Body=<<>>）。
%% EP-11：2xx 应答先验签（Wechatpay-* 头 + 平台公钥）后解析。
-spec get_signed(map(), binary()) -> {ok, map()} | epay_gateway:err().
get_signed(Cfg, Path) ->
    case sign_request(Cfg, <<"GET">>, Path, <<>>) of
        {ok, Auth} ->
            Url = <<(maps:get(base_url, Cfg, ?BASE_URL))/binary, Path/binary>>,
            Headers = [
                {<<"Authorization">>, Auth},
                {<<"Accept">>, <<"application/json">>},
                {<<"User-Agent">>, <<"erlang_pay/0.1.0">>}
            ],
            case epay_http:get(Url, Headers) of
                {ok, Status, RespHeaders, RespBody} when Status >= 200, Status < 300 ->
                    case verify_response(Cfg, RespHeaders, RespBody) of
                        ok -> decode_ok(RespBody);
                        {error, _} = Err -> Err
                    end;
                {ok, _Status, _H, RespBody} ->
                    {error, wechat_err_msg(RespBody)};
                {error, Reason} ->
                    {error, http_err_bin(Reason)}
            end;
        {error, _} ->
            {error, {sign_failed, <<"微信请求签名失败"/utf8>>}}
    end.

-spec map_wechat_state(binary()) -> atom().
map_wechat_state(<<"SUCCESS">>) -> success;
map_wechat_state(<<"REFUND">>) -> refunded;
map_wechat_state(<<"NOTPAY">>) -> pending;
map_wechat_state(<<"USERPAYING">>) -> pending;
map_wechat_state(<<"CLOSED">>) -> closed;
map_wechat_state(<<"REVOKED">>) -> revoked;
map_wechat_state(<<"PAYERROR">>) -> error;
map_wechat_state(_) -> unknown.
