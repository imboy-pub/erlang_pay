-module(epay_alipay).
-behaviour(epay_gateway).
%%%===================================================================
%%% @doc 支付宝网关 / Alipay gateway（App 支付 alipay.trade.app.pay）
%%%
%%% 移植自支付宝官方 PHP SDK 的 AlipaySignature（签名串构造）与
%%% 社区 alipay-sdk-go 的 RSA2 流程。覆盖：
%%%   - app_pay/4     : 生成已签名 orderStr 供客户端 SDK 唤起（无需服务端 HTTP）
%%%   - refund/2      : alipay.trade.refund，服务端 HTTP POST 到 gateway.do
%%%   - verify_notify/2: 异步通知 RSA2 验签
%%%
%%% Cfg :: #{app_id := binary(), private_key := binary(), public_key := binary(),
%%%          gateway_url => binary(), notify_url => binary()}
%%% 金额统一以「分」(integer) 传入，内部转支付宝要求的「元」字符串。
%%% @end
%%%===================================================================

%% epay_gateway behaviour
-export([create_payment/2, refund/2, verify_notify/2, query/2, download_bill/2, capabilities/0]).
%% 低层 API（直接使用）
-export([app_pay/4, verify_form/2]).

-define(DEFAULT_GATEWAY, <<"https://openapi.alipay.com/gateway.do">>).
-define(REFUND_RESP_KEY, <<"alipay_trade_refund_response">>).

%% @doc 能力声明。App 支付 orderStr 由服务端签名后客户端直用，无独立二次签名。
-spec capabilities() -> [atom()].
capabilities() ->
    [create_payment, refund, query, download_bill, verify_notify].

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
%% 验签通过返回 {ok, FormMap}（含 out_trade_no/trade_no/trade_status/...）。
-spec verify_notify(map(), map()) -> {ok, map()} | epay_gateway:err().
verify_notify(Cfg, Ctx) ->
    Form = maps:get(form, Ctx, #{}),
    case verify_form(Cfg, Form) of
        ok -> {ok, Form};
        {error, _} = Err -> Err
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
    Params = maybe_put(<<"notify_url">>, maps:get(notify_url, Cfg, <<>>), Params0),
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
    Params = #{
        <<"app_id">> => AppId,
        <<"method">> => <<"alipay.trade.refund">>,
        <<"format">> => <<"JSON">>,
        <<"charset">> => <<"utf-8">>,
        <<"sign_type">> => <<"RSA2">>,
        <<"timestamp">> => now_beijing(),
        <<"version">> => <<"1.0">>,
        <<"biz_content">> => epay_util:json_encode(Biz)
    },
    case sign_params(Params, PriKey) of
        {ok, Signed} ->
            Url = maps:get(gateway_url, Cfg, ?DEFAULT_GATEWAY),
            Body = build_query(Signed),
            do_refund_request(Url, Body);
        {error, _} = Err ->
            normalize_err(Err)
    end.

-spec do_refund_request(binary(), binary()) -> {ok, map()} | epay_gateway:err().
do_refund_request(Url, Body) ->
    case epay_http:post_form(Url, [], Body) of
        {ok, 200, _H, RespBody} ->
            parse_refund_response(RespBody);
        {ok, Status, _H, _B} ->
            {error, {gateway_error, <<"支付宝退款 HTTP "/utf8, (integer_to_binary(Status))/binary>>}};
        {error, Reason} ->
            {error, http_err_bin(Reason)}
    end.

-spec parse_refund_response(binary()) -> {ok, map()} | epay_gateway:err().
parse_refund_response(RespBody) ->
    case epay_util:json_decode(RespBody) of
        {ok, #{?REFUND_RESP_KEY := Resp}} when is_map(Resp) ->
            case maps:get(<<"code">>, Resp, <<>>) of
                <<"10000">> ->
                    {ok, Resp};
                _ ->
                    SubMsg = maps:get(<<"sub_msg">>, Resp, maps:get(<<"msg">>, Resp, <<"退款失败"/utf8>>)),
                    {error, {gateway_error, SubMsg}}
            end;
        _ ->
            {error, {invalid_response, <<"支付宝退款响应解析失败"/utf8>>}}
    end.

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
    Params = build_params(AppId, <<"alipay.trade.query">>, Biz),
    case sign_params(Params, PriKey) of
        {ok, Signed} ->
            Url = maps:get(gateway_url, Cfg, ?DEFAULT_GATEWAY),
            do_open_request(Url, build_query(Signed), ?QUERY_RESP_KEY, fun query_ok/1);
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
    Params = build_params(AppId, <<"alipay.data.dataservice.bill.downloadurl.query">>, Biz),
    case sign_params(Params, PriKey) of
        {ok, Signed} ->
            Url = maps:get(gateway_url, Cfg, ?DEFAULT_GATEWAY),
            do_open_request(Url, build_query(Signed), ?BILL_RESP_KEY, fun bill_ok/1);
        {error, _} = Err ->
            normalize_err(Err)
    end.

%% 构造支付宝开放平台公共请求参数。
-spec build_params(binary(), binary(), map()) -> map().
build_params(AppId, Method, Biz) ->
    #{
        <<"app_id">> => AppId,
        <<"method">> => Method,
        <<"format">> => <<"JSON">>,
        <<"charset">> => <<"utf-8">>,
        <<"sign_type">> => <<"RSA2">>,
        <<"timestamp">> => now_beijing(),
        <<"version">> => <<"1.0">>,
        <<"biz_content">> => epay_util:json_encode(Biz)
    }.

%% 发请求 + 取响应业务节点 + code 校验 + 委托 OkFun 构造成功返回。
-spec do_open_request(binary(), binary(), binary(), fun((map()) -> map())) ->
    {ok, map()} | epay_gateway:err().
do_open_request(Url, Body, RespKey, OkFun) ->
    case epay_http:post_form(Url, [], Body) of
        {ok, 200, _H, RespBody} ->
            parse_open_response(RespBody, RespKey, OkFun);
        {ok, Status, _H, _B} ->
            {error, {gateway_error, <<"支付宝接口 HTTP "/utf8, (integer_to_binary(Status))/binary>>}};
        {error, Reason} ->
            {error, http_err_bin(Reason)}
    end.

-spec parse_open_response(binary(), binary(), fun((map()) -> map())) ->
    {ok, map()} | epay_gateway:err().
parse_open_response(RespBody, RespKey, OkFun) ->
    case epay_util:json_decode(RespBody) of
        {ok, #{RespKey := Resp}} when is_map(Resp) ->
            case maps:get(<<"code">>, Resp, <<>>) of
                <<"10000">> ->
                    {ok, OkFun(Resp)};
                _ ->
                    {error,
                        {gateway_error,
                            maps:get(
                                <<"sub_msg">>, Resp, maps:get(<<"msg">>, Resp, <<"接口失败"/utf8>>)
                            )}}
            end;
        _ ->
            {error, {invalid_response, <<"支付宝响应解析失败"/utf8>>}}
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
