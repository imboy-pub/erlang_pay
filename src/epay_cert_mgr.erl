-module(epay_cert_mgr).
-behaviour(gen_server).
%%%===================================================================
%%% @doc 微信平台证书自动轮换 / WeChat platform certificate manager
%%%
%%% 可选 OTP 组件（gen_server + 私有 ETS）：自动下载、缓存、定时轮换微信
%%% APIv3 平台证书，供回调验签取最新平台公钥。对标 wechatpay-go 的
%%% CertificateDownloaderMgr —— 用 OTP supervisor 重启替代 Go 手写 recover。
%%%
%%% 设计铁律（保持库纯函数核心）：
%%%   - epay_crypto/epay_wechat 的验签函数仍接受【外部传入】公钥，本模块
%%%     仅为可选附加；不依赖本模块也能完成全部验签。
%%%   - 多租户：ETS 键为 {MchId, Serial}，一个 mgr 实例可管理多个商户。
%%%   - 崩溃由 supervisor 重启；定时刷新用 erlang:send_after。
%%%
%%% 典型用法：
%%%   {ok, Pid} = epay_cert_mgr:start_link(#{refresh_interval => 43200000}),
%%%   ok = epay_cert_mgr:add_merchant(Pid, MchCfg),
%%%   {ok, CertPem} = epay_cert_mgr:get_cert(Pid, MchId, Serial).
%%%
%%% MchCfg :: #{mch_id := binary(), mch_serial_no := binary(),
%%%             private_key := binary(), api_v3_key := binary()}
%%% @end
%%%===================================================================

%% API
-export([
    start_link/0, start_link/1,
    add_merchant/2,
    get_cert/3,
    list_serials/2,
    refresh/1,
    stop/1
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(CERT_PATH, <<"/v3/certificates">>).
-define(DEFAULT_BASE_URL, <<"https://api.mch.weixin.qq.com">>).
%% 默认 12 小时刷新一次（微信证书有效期约 1 年，远早于过期即轮换）。
-define(DEFAULT_REFRESH_INTERVAL, 43200000).

-record(state, {
    ets :: ets:tid(),
    merchants = #{} :: #{binary() => map()},
    base_url :: binary(),
    interval :: non_neg_integer(),
    timer :: reference() | undefined
}).

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    start_link(#{}).

%% @doc 启动证书管理器。Opts :: #{refresh_interval => ms, base_url => binary()}。
-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) when is_map(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

%% @doc 注册商户并立即拉取其平台证书。成功返回 ok，下载失败返回 {error, _}。
-spec add_merchant(pid(), map()) -> ok | epay_gateway:err().
add_merchant(Mgr, MchCfg) when is_map(MchCfg) ->
    gen_server:call(Mgr, {add_merchant, MchCfg}, 30000).

%% @doc 取指定商户 + 序列号的平台证书 PEM。
-spec get_cert(pid(), binary(), binary()) -> {ok, binary()} | {error, not_found}.
get_cert(Mgr, MchId, Serial) ->
    gen_server:call(Mgr, {get_cert, MchId, Serial}).

%% @doc 列出某商户已缓存的全部证书序列号。
-spec list_serials(pid(), binary()) -> [binary()].
list_serials(Mgr, MchId) ->
    gen_server:call(Mgr, {list_serials, MchId}).

%% @doc 强制刷新所有已注册商户的证书。
-spec refresh(pid()) -> ok.
refresh(Mgr) ->
    gen_server:call(Mgr, refresh, 30000).

-spec stop(pid()) -> ok.
stop(Mgr) ->
    gen_server:stop(Mgr).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

-spec init(map()) -> {ok, #state{}}.
init(Opts) ->
    Ets = ets:new(epay_certs, [set, private]),
    Interval = maps:get(refresh_interval, Opts, ?DEFAULT_REFRESH_INTERVAL),
    BaseUrl = maps:get(base_url, Opts, ?DEFAULT_BASE_URL),
    Timer = schedule_refresh(Interval),
    {ok, #state{ets = Ets, base_url = BaseUrl, interval = Interval, timer = Timer}}.

handle_call({add_merchant, MchCfg}, _From, State) ->
    MchId = maps:get(mch_id, MchCfg),
    Merchants = maps:put(MchId, MchCfg, State#state.merchants),
    case fetch_and_store(MchCfg, State#state.base_url, State#state.ets) of
        ok ->
            {reply, ok, State#state{merchants = Merchants}};
        {error, _} = Err ->
            %% 仍登记商户（下次定时刷新可重试），但回报本次下载失败。
            {reply, Err, State#state{merchants = Merchants}}
    end;
handle_call({get_cert, MchId, Serial}, _From, State) ->
    Reply =
        case ets:lookup(State#state.ets, {MchId, Serial}) of
            [{_, CertPem}] -> {ok, CertPem};
            [] -> {error, not_found}
        end,
    {reply, Reply, State};
handle_call({list_serials, MchId}, _From, State) ->
    Serials = [S || {{M, S}, _} <- ets:tab2list(State#state.ets), M =:= MchId],
    {reply, Serials, State};
handle_call(refresh, _From, State) ->
    refresh_all(State),
    {reply, ok, State};
handle_call(_Req, _From, State) ->
    {reply, {error, {bad_request, <<"未知请求"/utf8>>}}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(refresh_tick, State) ->
    refresh_all(State),
    Timer = schedule_refresh(State#state.interval),
    {noreply, State#state{timer = Timer}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    catch ets:delete(State#state.ets),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal
%%%===================================================================

-spec schedule_refresh(non_neg_integer()) -> reference().
schedule_refresh(Interval) ->
    erlang:send_after(Interval, self(), refresh_tick).

%% 刷新全部已注册商户（错误吞掉不崩溃，等下个周期重试）。
-spec refresh_all(#state{}) -> ok.
refresh_all(State) ->
    maps:foreach(
        fun(_MchId, MchCfg) ->
            _ = fetch_and_store(MchCfg, State#state.base_url, State#state.ets)
        end,
        State#state.merchants
    ).

%% 下载 + 解密 + 写入 ETS。返回 ok 或 {error, {Code, Msg}}。
-spec fetch_and_store(map(), binary(), ets:tid()) -> ok | epay_gateway:err().
fetch_and_store(MchCfg, BaseUrl, Ets) ->
    case fetch_certificates(MchCfg, BaseUrl) of
        {ok, Items} ->
            MchId = maps:get(mch_id, MchCfg),
            ApiV3Key = maps:get(api_v3_key, MchCfg, <<>>),
            store_items(Ets, MchId, ApiV3Key, Items),
            ok;
        {error, _} = Err ->
            Err
    end.

%% 逐条解密证书并写入 ETS（解密失败的条目跳过，不影响其它）。
-spec store_items(ets:tid(), binary(), binary(), [map()]) -> ok.
store_items(Ets, MchId, ApiV3Key, Items) ->
    lists:foreach(
        fun(Item) ->
            Serial = maps:get(<<"serial_no">>, Item, <<>>),
            case decrypt_cert(Item, ApiV3Key) of
                {ok, CertPem} when Serial =/= <<>> ->
                    ets:insert(Ets, {{MchId, Serial}, CertPem});
                _ ->
                    skip
            end
        end,
        Items
    ).

-spec decrypt_cert(map(), binary()) -> {ok, binary()} | {error, atom()}.
decrypt_cert(Item, ApiV3Key) ->
    case maps:get(<<"encrypt_certificate">>, Item, undefined) of
        #{<<"ciphertext">> := Cipher, <<"nonce">> := Nonce} = Enc ->
            Aad = maps:get(<<"associated_data">>, Enc, <<>>),
            epay_crypto:aes_256_gcm_decrypt(Cipher, ApiV3Key, Nonce, Aad);
        _ ->
            {error, no_encrypt_certificate}
    end.

%% GET /v3/certificates（APIv3 签名），返回 data 列表。
-spec fetch_certificates(map(), binary()) -> {ok, [map()]} | epay_gateway:err().
fetch_certificates(MchCfg, BaseUrl) ->
    case sign_auth(MchCfg, <<"GET">>, ?CERT_PATH, <<>>) of
        {ok, Auth} ->
            Url = <<BaseUrl/binary, ?CERT_PATH/binary>>,
            Headers = [
                {<<"Authorization">>, Auth},
                {<<"Accept">>, <<"application/json">>},
                {<<"User-Agent">>, <<"erlang_pay/0.1.0">>}
            ],
            case epay_http:get(Url, Headers) of
                {ok, Status, _H, Body} when Status >= 200, Status < 300 ->
                    parse_cert_body(Body);
                {ok, _S, _H, _B} ->
                    {error, {gateway_error, <<"微信证书下载 HTTP 非 2xx"/utf8>>}};
                {error, Reason} ->
                    {error, {http_error, iolist_to_binary(io_lib:format("~p", [Reason]))}}
            end;
        {error, _} ->
            {error, {sign_failed, <<"微信证书请求签名失败"/utf8>>}}
    end.

-spec parse_cert_body(binary()) -> {ok, [map()]} | epay_gateway:err().
parse_cert_body(Body) ->
    case epay_util:json_decode(Body) of
        {ok, #{<<"data">> := Data}} when is_list(Data) ->
            {ok, Data};
        _ ->
            {error, {invalid_response, <<"微信证书响应缺少 data 列表"/utf8>>}}
    end.

%% 构造 APIv3 Authorization 头（Method\nPath\nTimestamp\nNonce\nBody\n 私钥签名）。
-spec sign_auth(map(), binary(), binary(), binary()) -> {ok, binary()} | {error, atom()}.
sign_auth(MchCfg, Method, Path, Body) ->
    MchId = maps:get(mch_id, MchCfg),
    Serial = maps:get(mch_serial_no, MchCfg),
    PriKey = maps:get(private_key, MchCfg),
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
