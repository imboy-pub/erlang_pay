-module(epay_alipay).
-behaviour(epay_gateway).
%%%===================================================================
%%% @doc 支付宝网关 / Alipay gateway（App 支付 alipay.trade.app.pay）
%%%
%%% 移植自支付宝官方 PHP SDK 的 AlipaySignature（签名串构造）与
%%% 社区 alipay-sdk-go 的 RSA2 流程。覆盖：
%%%   - app_pay/4     : 生成已签名 orderStr 供客户端 SDK 唤起（无需服务端 HTTP）
%%%   - refund/2      : alipay.trade.refund，服务端 HTTP POST 到 gateway.do
%%%   - verify_notify/2: 异步通知 RSA2 验签 + app_id 绑定
%%%
%%% 同步应答验签（对标官方 Java SDK AbstractAlipayClient.checkResponseSign）：
%%% 在「原始响应字符串」上定位 <method>_response / error_response 节点的原始
%%% JSON 字节验签（绝不 decode 后 re-encode）；code=10000 无 sign 一律
%%% fail-closed（missing_signature）；失败响应带 sign 也验签；验签失败先做
%%% 一次 `\/`→`/` 替换重试（官方 JSON 转义兼容）。
%%%
%%% Cfg :: #{app_id := binary(), private_key := binary(),
%%%          public_key => binary(),            %% 公钥模式验签公钥
%%%          alipay_public_cert => binary(),    %% 证书模式：支付宝公钥证书 PEM（优先）
%%%          gateway_url => binary(), notify_url => binary(),
%%%          app_cert_sn => binary(), alipay_root_cert_sn => binary()}
%%% 金额统一以「分」(integer) 传入，内部转支付宝要求的「元」字符串。
%%% @end
%%%===================================================================


%% epay_gateway behaviour
-export([
    create_payment/2, refund/2, verify_notify/2, query/2, download_bill/2,
    close/2, cancel/2, capabilities/0
]).
%% 低层 API（直接使用）
-export([app_pay/4, verify_form/2]).

-define(DEFAULT_GATEWAY, <<"https://openapi.alipay.com/gateway.do">>).
-define(REFUND_RESP_KEY, <<"alipay_trade_refund_response">>).
-define(CLOSE_RESP_KEY, <<"alipay_trade_close_response">>).
-define(CANCEL_RESP_KEY, <<"alipay_trade_cancel_response">>).
-define(ERROR_RESP_KEY, <<"error_response">>).

-include_lib("public_key/include/public_key.hrl").

%% @doc 能力声明。App 支付 orderStr 由服务端签名后客户端直用，无独立二次签名；
%% 支付宝支持关单（alipay.trade.close）与撤单（alipay.trade.cancel）。
-spec capabilities() -> [atom()].
capabilities() ->
    [create_payment, refund, query, download_bill, verify_notify, close, cancel].

%% @doc 关单（alipay.trade.close）。Req :: #{out_trade_no := binary()}。
-spec close(map(), map()) -> {ok, map()} | epay_gateway:err().
close(Cfg, Req) ->
    trade_action(Cfg, Req, <<"alipay.trade.close">>, ?CLOSE_RESP_KEY, fun close_ok/1).

%% @doc 撤单（alipay.trade.cancel）。Req :: #{out_trade_no := binary()}。
-spec cancel(map(), map()) -> {ok, map()} | epay_gateway:err().
cancel(Cfg, Req) ->
    trade_action(Cfg, Req, <<"alipay.trade.cancel">>, ?CANCEL_RESP_KEY, fun cancel_ok/1).

%% close/cancel 共用：按 out_trade_no 构造 biz、签名、发请求、解析。
-spec trade_action(map(), map(), binary(), binary(), fun((map()) -> map())) ->
    {ok, map()} | epay_gateway:err().
trade_action(Cfg, Req, Method, RespKey, OkFun) ->
    #{app_id := AppId, private_key := PriKey} = Cfg,
    Biz = #{<<"out_trade_no">> => maps:get(out_trade_no, Req)},
    Params = build_params(AppId, Method, Biz, Cfg),
    case sign_params(Params, PriKey) of
        {ok, Signed} ->
            Url = maps:get(gateway_url, Cfg, ?DEFAULT_GATEWAY),
            do_open_request(Url, build_query(Signed), Cfg, RespKey, OkFun);
        {error, _} = Err ->
            normalize_err(Err)
    end.

-spec close_ok(map()) -> map().
close_ok(Resp) ->
    #{type => alipay_close, raw => Resp}.

-spec cancel_ok(map()) -> map().
cancel_ok(Resp) ->
    #{type => alipay_cancel, action => maps:get(<<"action">>, Resp, <<>>), raw => Resp}.

%%%===================================================================
%%% epay_gateway behaviour
%%%===================================================================

%% @doc 下单。Order :: #{out_trade_no, amount_fen, subject => binary()}
-spec create_payment(map(), map()) -> {ok, map()} | epay_gateway:err().
create_payment(Cfg, Order) ->
    OrderNo = maps:get(out_trade_no, Order),
    AmountFen = maps:get(amount_fen, Order),
    Opts = maps:with([subject], Order),
    case app_pay(Cfg, OrderNo, AmountFen, Opts) of
        {ok, #{order_str := OrderStr}} ->
            {ok, #{type => alipay_app, order_str => OrderStr}};
        {error, _} = Err ->
            Err
    end.

%% @doc 回调验签。Ctx :: #{form := map()}（已 url-decode 的异步通知表单）。
%% 验签通过返回 {ok, FormMap}：除原始字段（out_trade_no/trade_no/trade_status/…）
%% 外，加性附带归一 trade_state（epay_state:state()），调用方无须再认识渠道词汇。
%% 另核对通知 app_id 与配置一致（官方通知必带；seller/订单号/金额留给调用方）。
-spec verify_notify(map(), map()) -> {ok, map()} | epay_gateway:err().
verify_notify(Cfg, Ctx) ->
    Form = maps:get(form, Ctx, #{}),
    case check_app_id(Cfg, Form) of
        ok ->
            case verify_form(Cfg, Form) of
                ok ->
                    St = map_alipay_state(maps:get(<<"trade_status">>, Form, <<>>)),
                    {ok, Form#{trade_state => St}};
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

%% 通知 app_id 绑定（fail-closed）：通知缺 app_id 或与配置不一致即拒绝，
%% 防止其它 app 的通知被误受理。
-spec check_app_id(map(), map()) -> ok | epay_gateway:err().
check_app_id(Cfg, Form) ->
    case maps:get(<<"app_id">>, Form, <<>>) of
        <<>> ->
            {error, {missing_app_id, <<"支付宝通知缺少 app_id"/utf8>>}};
        AppId ->
            case maps:get(app_id, Cfg, <<>>) of
                <<>> ->
                    {error, {missing_app_id, <<"支付宝配置缺少 app_id"/utf8>>}};
                AppId ->
                    ok;
                _ ->
                    {error, {app_id_mismatch, <<"支付宝通知 app_id 与配置不一致"/utf8>>}}
            end
    end.

%%%===================================================================
%%% App 支付：服务端只签名生成 orderStr，客户端 SDK 本地唤起
%%%===================================================================

%% @doc 生成 App 支付 orderStr。AmountFen 单位分；Opts 可含 subject。
-spec app_pay(map(), binary(), integer(), map()) ->
    {ok, #{order_str := binary()}} | epay_gateway:err().
app_pay(Cfg, OrderNo, AmountFen, Opts) ->
    #{app_id := AppId, private_key := PriKey} = Cfg,
    Subject = maps:get(subject, Opts, <<"充值"/utf8>>),
    Biz = #{
        <<"out_trade_no">> => OrderNo,
        <<"total_amount">> => epay_util:fen_to_yuan_bin(AmountFen),
        <<"subject">> => Subject,
        <<"product_code">> => <<"QUICK_MSECURITY_PAY">>
    },
    Params0 = #{
        <<"app_id">> => AppId,
        <<"method">> => <<"alipay.trade.app.pay">>,
        <<"format">> => <<"JSON">>,
        <<"charset">> => <<"utf-8">>,
        <<"sign_type">> => <<"RSA2">>,
        <<"timestamp">> => now_beijing(),
        <<"version">> => <<"1.0">>,
        <<"biz_content">> => epay_util:json_encode(Biz)
    },
    Params1 = maybe_put(<<"notify_url">>, maps:get(notify_url, Cfg, <<>>), Params0),
    Params = maybe_put_cert_sn(Params1, Cfg),
    case sign_params(Params, PriKey) of
        {ok, Signed} ->
            {ok, #{order_str => build_query(Signed)}};
        {error, _} = Err ->
            normalize_err(Err)
    end.

%%%===================================================================
%%% 退款：alipay.trade.refund（服务端 HTTP POST）
%%%===================================================================

%% @doc 退款。Req :: #{out_trade_no := binary(), refund_amount_fen := integer(),
%%   out_request_no => binary(), refund_reason => binary()}
-spec refund(map(), map()) -> {ok, map()} | epay_gateway:err().
refund(Cfg, Req) ->
    #{app_id := AppId, private_key := PriKey} = Cfg,
    OutTradeNo = maps:get(out_trade_no, Req),
    AmountFen = maps:get(refund_amount_fen, Req),
    Biz0 = #{
        <<"out_trade_no">> => OutTradeNo,
        <<"refund_amount">> => epay_util:fen_to_yuan_bin(AmountFen)
    },
    Biz1 = maybe_put(<<"out_request_no">>, maps:get(out_request_no, Req, <<>>), Biz0),
    Biz = maybe_put(<<"refund_reason">>, maps:get(refund_reason, Req, <<>>), Biz1),
    Params0 = #{
        <<"app_id">> => AppId,
        <<"method">> => <<"alipay.trade.refund">>,
        <<"format">> => <<"JSON">>,
        <<"charset">> => <<"utf-8">>,
        <<"sign_type">> => <<"RSA2">>,
        <<"timestamp">> => now_beijing(),
        <<"version">> => <<"1.0">>,
        <<"biz_content">> => epay_util:json_encode(Biz)
    },
    Params = maybe_put_cert_sn(Params0, Cfg),
    case sign_params(Params, PriKey) of
        {ok, Signed} ->
            Url = maps:get(gateway_url, Cfg, ?DEFAULT_GATEWAY),
            Body = build_query(Signed),
            do_refund_request(Url, Body, Cfg);
        {error, _} = Err ->
            normalize_err(Err)
    end.

-spec do_refund_request(binary(), binary(), map()) -> {ok, map()} | epay_gateway:err().
do_refund_request(Url, Body, Cfg) ->
    case epay_http:post_form(Url, [], Body) of
        {ok, 200, _H, RespBody} ->
            parse_refund_response(RespBody, Cfg);
        {ok, Status, _H, _B} ->
            {error, {gateway_error, <<"支付宝退款 HTTP "/utf8, (integer_to_binary(Status))/binary>>}};
        {error, Reason} ->
            {error, http_err_bin(Reason)}
    end.

-spec parse_refund_response(binary(), map()) -> {ok, map()} | epay_gateway:err().
parse_refund_response(RespBody, Cfg) ->
    parse_signed_response(RespBody, Cfg, ?REFUND_RESP_KEY, <<"退款失败"/utf8>>, fun(R) -> R end).

%%%===================================================================
%%% 异步通知验签（RSA2）
%%%===================================================================

%% @doc 验证支付宝异步通知签名。Params 为已 url-decode 的表单 map（binary k/v）。
-spec verify_form(map(), map()) -> ok | epay_gateway:err().
verify_form(Cfg, Params) ->
    PubKey = maps:get(public_key, Cfg, <<>>),
    Sign = maps:get(<<"sign">>, Params, <<>>),
    case {PubKey, Sign} of
        {<<>>, _} -> {error, {no_credential, <<"缺少支付宝公钥"/utf8>>}};
        {_, <<>>} -> {error, {missing_signature, <<"缺少通知签名"/utf8>>}};
        _ ->
            Content = verify_content(Params),
            case safe_b64_decode(Sign) of
                {ok, SigBin} ->
                    case epay_crypto:rsa_verify_sha256(Content, SigBin, PubKey) of
                        true -> ok;
                        false -> {error, {bad_signature, <<"支付宝通知验签失败"/utf8>>}}
                    end;
                error ->
                    {error, {bad_signature, <<"支付宝通知签名 base64 解析失败"/utf8>>}}
            end
    end.

%%%===================================================================
%%% Internal —— 签名串构造（对标 AlipaySignature）
%%%===================================================================

%% 请求签名：排除 sign 与空值（保留 sign_type），按 key 字典序，原值拼接 k=v&
-spec sign_params(map(), binary()) -> {ok, map()} | {error, atom()}.
sign_params(Params, PriKey) ->
    Content = sign_content(Params),
    case epay_crypto:rsa_sign_sha256(Content, PriKey) of
        {ok, Sig} -> {ok, Params#{<<"sign">> => base64:encode(Sig)}};
        {error, _} = Err -> Err
    end.

-spec sign_content(map()) -> binary().
sign_content(Params) ->
    Pairs = [
        {K, V}
     || K <- lists:sort(maps:keys(Params)),
        K =/= <<"sign">>,
        V <- [maps:get(K, Params)],
        V =/= <<>>
    ],
    join_kv(Pairs).

%% 通知验签：排除 sign 与 sign_type，按 key 字典序，原值拼接
-spec verify_content(map()) -> binary().
verify_content(Params) ->
    Pairs = [
        {K, V}
     || K <- lists:sort(maps:keys(Params)),
        K =/= <<"sign">>,
        K =/= <<"sign_type">>,
        V <- [maps:get(K, Params)],
        V =/= <<>>
    ],
    join_kv(Pairs).

-spec join_kv([{binary(), binary()}]) -> binary().
join_kv([]) ->
    <<>>;
join_kv([{K0, V0} | T]) ->
    First = <<K0/binary, "=", (epay_util:to_bin(V0))/binary>>,
    lists:foldl(
        fun({K, V}, Acc) ->
            <<Acc/binary, "&", K/binary, "=", (epay_util:to_bin(V))/binary>>
        end,
        First,
        T
    ).

%% orderStr / 退款请求体：全参数（含 sign）按 key 字典序，值百分号编码
-spec build_query(map()) -> binary().
build_query(Params) ->
    Pairs = [{K, maps:get(K, Params)} || K <- lists:sort(maps:keys(Params))],
    epay_util:form_encode(Pairs).

-spec maybe_put(binary(), binary(), map()) -> map().
maybe_put(_K, <<>>, M) -> M;
maybe_put(K, V, M) -> M#{K => V}.

%% 证书模式下追加 app_cert_sn / alipay_root_cert_sn 到公共参数。
%% 证书模式判定：app_cert_sn 非空即视为证书模式（与 alipay_openapi 一致）。
-spec maybe_put_cert_sn(map(), map()) -> map().
maybe_put_cert_sn(Params, Cfg) ->
    Params1 = maybe_put(<<"app_cert_sn">>, maps:get(app_cert_sn, Cfg, <<>>), Params),
    maybe_put(<<"alipay_root_cert_sn">>, maps:get(alipay_root_cert_sn, Cfg, <<>>), Params1).

-spec now_beijing() -> binary().
now_beijing() ->
    Secs = erlang:system_time(second) + 8 * 3600,
    {{Y, Mo, D}, {H, Mi, S}} = calendar:system_time_to_universal_time(Secs, second),
    list_to_binary(
        io_lib:format(
            "~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B",
            [Y, Mo, D, H, Mi, S]
        )
    ).

-spec safe_b64_decode(binary()) -> {ok, binary()} | error.
safe_b64_decode(B) ->
    try {ok, base64:decode(B)} catch _:_ -> error end.

%% 本地签名失败（crypto 返回的 atom 原因）：打 {sign_failed, Msg}。
-spec normalize_err({error, atom()}) -> epay_gateway:err().
normalize_err({error, A}) when is_atom(A) ->
    {error, {sign_failed, <<"支付宝签名失败:"/utf8, (atom_to_binary(A, utf8))/binary>>}}.

%% 传输层错误（inets）：打 {http_error, Msg}。
-spec http_err_bin(term()) -> {atom(), binary()}.
http_err_bin(R) ->
    {http_error, iolist_to_binary(io_lib:format("~p", [R]))}.

%%%===================================================================
%%% 主动查单（alipay.trade.query）与对账单下载
%%%===================================================================

-define(QUERY_RESP_KEY, <<"alipay_trade_query_response">>).
-define(BILL_RESP_KEY, <<"alipay_data_dataservice_bill_downloadurl_query_response">>).

%% @doc 查单。Q :: #{out_trade_no := binary()}。
-spec query(map(), map()) -> {ok, map()} | epay_gateway:err().
query(Cfg, Q) ->
    #{app_id := AppId, private_key := PriKey} = Cfg,
    OutTradeNo = maps:get(out_trade_no, Q),
    Biz = #{<<"out_trade_no">> => OutTradeNo},
    Params = build_params(AppId, <<"alipay.trade.query">>, Biz, Cfg),
    case sign_params(Params, PriKey) of
        {ok, Signed} ->
            Url = maps:get(gateway_url, Cfg, ?DEFAULT_GATEWAY),
            do_open_request(Url, build_query(Signed), Cfg, ?QUERY_RESP_KEY, fun query_ok/1);
        {error, _} = Err ->
            normalize_err(Err)
    end.

%% @doc 申请账单下载地址。Req :: #{bill_date := binary(), bill_type => binary()}。
-spec download_bill(map(), map()) -> {ok, map()} | epay_gateway:err().
download_bill(Cfg, Req) ->
    #{app_id := AppId, private_key := PriKey} = Cfg,
    BillType = maps:get(bill_type, Req, <<"trade">>),
    BillDate = maps:get(bill_date, Req),
    Biz = #{<<"bill_type">> => BillType, <<"bill_date">> => BillDate},
    Params = build_params(AppId, <<"alipay.data.dataservice.bill.downloadurl.query">>, Biz, Cfg),
    case sign_params(Params, PriKey) of
        {ok, Signed} ->
            Url = maps:get(gateway_url, Cfg, ?DEFAULT_GATEWAY),
            do_open_request(Url, build_query(Signed), Cfg, ?BILL_RESP_KEY, fun bill_ok/1);
        {error, _} = Err ->
            normalize_err(Err)
    end.

%% 构造支付宝开放平台公共请求参数。证书模式下追加 app_cert_sn/alipay_root_cert_sn。
-spec build_params(binary(), binary(), map(), map()) -> map().
build_params(AppId, Method, Biz, Cfg) ->
    Base = #{
        <<"app_id">> => AppId,
        <<"method">> => Method,
        <<"format">> => <<"JSON">>,
        <<"charset">> => <<"utf-8">>,
        <<"sign_type">> => <<"RSA2">>,
        <<"timestamp">> => now_beijing(),
        <<"version">> => <<"1.0">>,
        <<"biz_content">> => epay_util:json_encode(Biz)
    },
    maybe_put_cert_sn(Base, Cfg).

%% 发请求 + 原始字节验签解析 + code 校验 + 委托 OkFun 构造成功返回。
-spec do_open_request(binary(), binary(), map(), binary(), fun((map()) -> map())) ->
    {ok, map()} | epay_gateway:err().
do_open_request(Url, Body, Cfg, RespKey, OkFun) ->
    case epay_http:post_form(Url, [], Body) of
        {ok, 200, _H, RespBody} ->
            parse_signed_response(RespBody, Cfg, RespKey, <<"接口失败"/utf8>>, OkFun);
        {ok, Status, _H, _B} ->
            {error, {gateway_error, <<"支付宝接口 HTTP "/utf8, (integer_to_binary(Status))/binary>>}};
        {error, Reason} ->
            {error, http_err_bin(Reason)}
    end.

%%%===================================================================
%%% 同步应答解析 + 原始字节验签
%%%（对标官方 AbstractAlipayClient.checkResponseSign / JsonConverter.getSignSourceData）
%%%===================================================================

%% 同步应答统一入口：json_decode 后定位业务节点（<method>_response，
%% 缺失时回退 error_response），在「原始响应字节」上验签（绝不 re-encode），
%% 再按 code 分流。ErrDefault 为业务失败兜底文案，OkFun 构造成功 map。
-spec parse_signed_response(binary(), map(), binary(), binary(), fun((map()) -> map())) ->
    {ok, map()} | epay_gateway:err().
parse_signed_response(RespBody, Cfg, RespKey, ErrDefault, OkFun) ->
    case epay_util:json_decode(RespBody) of
        {ok, Top} when is_map(Top) ->
            case pick_node_key(Top, RespKey) of
                {ok, NodeKey} ->
                    handle_response_node(RespBody, Top, NodeKey, Cfg, ErrDefault, OkFun);
                error ->
                    {error, {invalid_response, <<"支付宝响应解析失败"/utf8>>}}
            end;
        _ ->
            {error, {invalid_response, <<"支付宝响应解析失败"/utf8>>}}
    end.

%% 节点选择：优先业务方法节点；缺失时回退 error_response（官方顺序）。
-spec pick_node_key(map(), binary()) -> {ok, binary()} | error.
pick_node_key(Top, RespKey) ->
    case Top of
        #{RespKey := R} when is_map(R) -> {ok, RespKey};
        #{?ERROR_RESP_KEY := E} when is_map(E) -> {ok, ?ERROR_RESP_KEY};
        _ -> error
    end.

%% 验签分流（fail-closed）：
%%   - code=10000 且有 sign → 验签通过才成功；
%%   - code=10000 无 sign    → missing_signature（成功响应必有签名）；
%%   - 失败响应带 sign       → 必须验签，通过后仍报 gateway_error；
%%   - 失败响应无 sign       → 不验签，维持 gateway_error（对齐官方）。
-spec handle_response_node(binary(), map(), binary(), map(), binary(), fun((map()) -> map())) ->
    {ok, map()} | epay_gateway:err().
handle_response_node(RespBody, Top, NodeKey, Cfg, ErrDefault, OkFun) ->
    Resp = maps:get(NodeKey, Top),
    Code = maps:get(<<"code">>, Resp, <<>>),
    Sign = maps:get(<<"sign">>, Top, <<>>),
    case {Code =:= <<"10000">>, Sign =/= <<>>} of
        {true, false} ->
            {error, {missing_signature, <<"支付宝成功响应缺少签名"/utf8>>}};
        {true, true} ->
            verify_then(
                RespBody, NodeKey, Sign, Cfg, fun() -> {ok, OkFun(Resp)} end
            );
        {false, false} ->
            biz_error(Resp, ErrDefault);
        {false, true} ->
            verify_then(RespBody, NodeKey, Sign, Cfg, fun() -> biz_error(Resp, ErrDefault) end)
    end.

%% 先验签再执行 Continue；验签失败返回 bad_signature。
-spec verify_then(binary(), binary(), binary(), map(),
    fun(() -> {ok, map()} | epay_gateway:err())) ->
    {ok, map()} | epay_gateway:err().
verify_then(RespBody, NodeKey, Sign, Cfg, Continue) ->
    case check_response_sign(RespBody, NodeKey, Sign, Cfg) of
        ok -> Continue();
        {error, _} = Err -> Err
    end.

%% 业务失败文案：sub_msg 优先，msg 次之，兜底 ErrDefault。
-spec biz_error(map(), binary()) -> epay_gateway:err().
biz_error(Resp, ErrDefault) ->
    SubMsg = maps:get(<<"sub_msg">>, Resp, maps:get(<<"msg">>, Resp, ErrDefault)),
    {error, {gateway_error, SubMsg}}.

%% 应答验签核心：从原始响应字节提取节点 JSON 原文作验签串，base64 解顶层
%% sign 后验签；验签串提取失败按 invalid_response 处理。
-spec check_response_sign(binary(), binary(), binary(), map()) -> ok | epay_gateway:err().
check_response_sign(RespBody, NodeKey, SignB64, Cfg) ->
    case extract_sign_source(RespBody, NodeKey) of
        {ok, Source} ->
            case safe_b64_decode(SignB64) of
                {ok, SigBin} ->
                    verify_sign_source(Source, SigBin, response_verify_key(Cfg));
                error ->
                    {error, {bad_signature, <<"支付宝响应签名 base64 解析失败"/utf8>>}}
            end;
        error ->
            {error, {invalid_response, <<"支付宝响应验签串提取失败"/utf8>>}}
    end.

%% 验签（官方 JSON 转义兼容）：先对原始字节验签；失败则把字节序列 `\/`
%% （反斜杠+斜杠）替换为 `/` 再重试一次；仍失败报 bad_signature。
-spec verify_sign_source(binary(), binary(), {ok, binary()} | epay_gateway:err()) ->
    ok | epay_gateway:err().
verify_sign_source(_Source, _SigBin, {error, _} = Err) ->
    Err;
verify_sign_source(Source, SigBin, {ok, PubKey}) ->
    case epay_crypto:rsa_verify_sha256(Source, SigBin, PubKey) of
        true ->
            ok;
        false ->
            Unescaped = binary:replace(Source, <<"\\/">>, <<"/">>, [global]),
            case epay_crypto:rsa_verify_sha256(Unescaped, SigBin, PubKey) of
                true -> ok;
                false -> {error, {bad_signature, <<"支付宝响应验签失败"/utf8>>}}
            end
    end.

%% 应答验签公钥：证书模式（alipay_public_cert 非空）优先——提取证书
%% subjectPublicKey 转 'RSAPublicKey' PEM（适配 epay_crypto 的 PEM 入参形态）；
%% 否则用公钥模式 public_key；两者皆缺 fail-closed。
-spec response_verify_key(map()) -> {ok, binary()} | epay_gateway:err().
response_verify_key(Cfg) ->
    case Cfg of
        #{alipay_public_cert := CertPem} when CertPem =/= <<>> ->
            case cert_pubkey_pem(CertPem) of
                {ok, PubPem} -> {ok, PubPem};
                error -> {error, {no_credential, <<"支付宝公钥证书解析失败"/utf8>>}}
            end;
        _ ->
            case maps:get(public_key, Cfg, <<>>) of
                <<>> -> {error, {no_credential, <<"缺少支付宝公钥"/utf8>>}};
                PubKey -> {ok, PubKey}
            end
    end.

%% 从 X.509 证书（PEM）提取 RSA 公钥并转 'RSAPublicKey' PEM。仅取钥，
%% 不校验链/有效期（与官方 SDK 取证书公钥验签同语义）。
-spec cert_pubkey_pem(binary()) -> {ok, binary()} | error.
cert_pubkey_pem(CertPem) ->
    try
        [{'Certificate', Der, _}] = public_key:pem_decode(CertPem),
        #'OTPCertificate'{tbsCertificate = TBSC} = public_key:pkix_decode_cert(Der, otp),
        #'OTPTBSCertificate'{subjectPublicKeyInfo = SPKI} = TBSC,
        #'OTPSubjectPublicKeyInfo'{subjectPublicKey = Pub} = SPKI,
        Key =
            case Pub of
                {#'RSAPublicKey'{} = K, _} -> K;
                #'RSAPublicKey'{} = K -> K
            end,
        {ok, public_key:pem_encode([public_key:pem_entry_encode('RSAPublicKey', Key)])}
    catch
        _:_ -> error
    end.

%%%===================================================================
%%% 原始响应字节验签串提取（对标官方 JsonConverter.getSignSourceData）
%%%===================================================================

%% 在原始响应 binary 上定位 NodeKey 节点的 JSON 原文：找到 `"key"` 后跳过
%% 空白与 `:` 到起始 `{`，做字符串感知的括号配对，取匹配 `}` 的原始字节。
-spec extract_sign_source(binary(), binary()) -> {ok, binary()} | error.
extract_sign_source(RespBody, NodeKey) ->
    KeyPat = <<"\"", NodeKey/binary, "\"">>,
    case binary:match(RespBody, KeyPat) of
        nomatch ->
            error;
        {KeyStart, KeyLen} ->
            find_node_open_brace(RespBody, KeyStart + KeyLen)
    end.

%% 跳过键后的空白与 `:`，定位节点对象起始 `{`（节点非对象则 error）。
-spec find_node_open_brace(binary(), non_neg_integer()) -> {ok, binary()} | error.
find_node_open_brace(Bin, Pos) when Pos < byte_size(Bin) ->
    case binary:at(Bin, Pos) of
        C when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r ->
            find_node_open_brace(Bin, Pos + 1);
        $: ->
            find_brace_after_colon(Bin, Pos + 1);
        _ ->
            error
    end;
find_node_open_brace(_Bin, _Pos) ->
    error.

-spec find_brace_after_colon(binary(), non_neg_integer()) -> {ok, binary()} | error.
find_brace_after_colon(Bin, Pos) when Pos < byte_size(Bin) ->
    case binary:at(Bin, Pos) of
        C when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r ->
            find_brace_after_colon(Bin, Pos + 1);
        ${ ->
            match_braces(Bin, Pos, Pos, 0, outside);
        _ ->
            error
    end;
find_brace_after_colon(_Bin, _Pos) ->
    error.

%% 字符串感知括号配对：从 Start（指向 `{`）扫描至匹配 `}`，提取含两端括号的
%% 原始字节。字符串内的 `{`/`}` 不计数；`\"` 转义吞掉后一个字节；支持嵌套
%% 对象与数组（数组元素的花括号照常计数）。
-spec match_braces(binary(), non_neg_integer(), non_neg_integer(), non_neg_integer(),
    outside | in_string | in_escape) ->
    {ok, binary()} | error.
match_braces(Bin, _Start, Pos, _Depth, _State) when Pos >= byte_size(Bin) ->
    %% 扫描到末尾仍未闭合：响应截断
    error;
match_braces(Bin, Start, Pos, Depth, State) ->
    C = binary:at(Bin, Pos),
    case State of
        in_escape ->
            match_braces(Bin, Start, Pos + 1, Depth, in_string);
        in_string ->
            NewState =
                if
                    C =:= $\\ -> in_escape;
                    C =:= $" -> outside;
                    true -> in_string
                end,
            match_braces(Bin, Start, Pos + 1, Depth, NewState);
        outside ->
            case C of
                $" ->
                    match_braces(Bin, Start, Pos + 1, Depth, in_string);
                ${ ->
                    match_braces(Bin, Start, Pos + 1, Depth + 1, outside);
                $} when Depth =:= 1 ->
                    {ok, binary:part(Bin, Start, Pos - Start + 1)};
                $} ->
                    match_braces(Bin, Start, Pos + 1, Depth - 1, outside);
                _ ->
                    match_braces(Bin, Start, Pos + 1, Depth, outside)
            end
    end.

-spec query_ok(map()) -> map().
query_ok(Resp) ->
    St = maps:get(<<"trade_status">>, Resp, <<>>),
    #{trade_state => map_alipay_state(St), raw_state => St, raw => Resp}.

-spec bill_ok(map()) -> map().
bill_ok(Resp) ->
    #{type => alipay_bill, download_url => maps:get(<<"bill_download_url">>, Resp, <<>>), raw => Resp}.

-spec map_alipay_state(binary()) -> atom().
map_alipay_state(<<"TRADE_SUCCESS">>) -> success;
map_alipay_state(<<"TRADE_FINISHED">>) -> success;
map_alipay_state(<<"WAIT_BUYER_PAY">>) -> pending;
map_alipay_state(<<"TRADE_CLOSED">>) -> closed;
map_alipay_state(_) -> unknown.
