-module(epay_http).
-moduledoc """
支付出站 HTTP 客户端 / Outbound HTTP for payment gateways

基于 OTP httpc（同步、低频下单退款场景足够），强制 TLS 证书 + 主机名
校验（防中间人劫持支付请求）。绝不打印请求/响应报文（含密钥/签名/单据）。

EP-21 HTTPS-only 出站边界：所有 URL 在发起网络调用前经 validate_url/1
校验 —— 仅接受 https scheme（大小写不敏感），拒绝明文 http/ftp、
无 scheme 裸字符串、携带 userinfo（user:pass@host）及无 host 的 URL。
支付凭据 / 签名请求绝不走明文 HTTP 通道；校验失败在 httpc 之前返回
{error, {insecure_url, binary()}}，绝不起任何网络调用。

与 imboy 的 elib_req 区别：elib_req 硬编码 JSON、且 DEBUG 打印整个响应、
未校验对端证书 —— 不可用于支付。本模块为支付专用安全客户端。
""".

-export([post_json/3, post_json/4, post_form/3, post_form/4, get/2, get/3]).

-define(DEFAULT_TIMEOUT, 15000).
-define(DEFAULT_CONNECT_TIMEOUT, 5000).

-type headers() :: [{binary() | string(), binary() | string()}].
-type result() :: {ok, Status :: pos_integer(), RespHeaders :: list(), Body :: binary()}
    | {error, term()}.

-doc "POST application/json。Body 为已序列化的 JSON 二进制。".
-spec post_json(binary() | string(), headers(), binary()) -> result().
post_json(Url, Headers, Body) ->
    post_json(Url, Headers, Body, #{}).

-spec post_json(binary() | string(), headers(), binary(), map()) -> result().
post_json(Url, Headers, Body, Opts) ->
    request(Url, Headers, "application/json", Body, Opts).

-doc "POST application/x-www-form-urlencoded（Stripe）。Body 为已编码表单串。".
-spec post_form(binary() | string(), headers(), binary()) -> result().
post_form(Url, Headers, Body) ->
    post_form(Url, Headers, Body, #{}).

-spec post_form(binary() | string(), headers(), binary(), map()) -> result().
post_form(Url, Headers, Body, Opts) ->
    request(Url, Headers, "application/x-www-form-urlencoded", Body, Opts).

-doc "GET（主动查单 / 对账用）。Headers 通常含 Authorization。无请求体。".
-spec get(binary() | string(), headers()) -> result().
get(Url, Headers) ->
    get(Url, Headers, #{}).

-spec get(binary() | string(), headers(), map()) -> result().
get(Url, Headers, Opts) ->
    %% EP-21：HTTPS-only 出站边界 —— 校验失败时绝不起网络调用
    case validate_url(Url) of
        ok ->
            _ = application:ensure_all_started(ssl),
            _ = application:ensure_all_started(inets),
            UrlStr = to_list(Url),
            HdrList = [{to_list(K), to_list(V)} || {K, V} <- Headers],
            HttpOpts = [
                {timeout, maps:get(timeout, Opts, ?DEFAULT_TIMEOUT)},
                {connect_timeout, maps:get(connect_timeout, Opts, ?DEFAULT_CONNECT_TIMEOUT)},
                {ssl, tls_opts()}
            ],
            case httpc:request(get, {UrlStr, HdrList}, HttpOpts, [{body_format, binary}]) of
                {ok, {{_Ver, Status, _Reason}, RespHeaders, RespBody}} ->
                    {ok, Status, RespHeaders, ensure_binary(RespBody)};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, _} = Err ->
            Err
    end.

%%%===================================================================
%%% Internal
%%%===================================================================

-spec request(binary() | string(), headers(), string(), binary(), map()) -> result().
request(Url, Headers, ContentType, Body, Opts) ->
    %% EP-21：HTTPS-only 出站边界 —— 校验失败时绝不起网络调用
    case validate_url(Url) of
        ok ->
            do_request(Url, Headers, ContentType, Body, Opts);
        {error, _} = Err ->
            Err
    end.

-spec do_request(binary() | string(), headers(), string(), binary(), map()) -> result().
do_request(Url, Headers, ContentType, Body, Opts) ->
    _ = application:ensure_all_started(ssl),
    _ = application:ensure_all_started(inets),
    UrlStr = to_list(Url),
    HdrList = [{to_list(K), to_list(V)} || {K, V} <- Headers],
    Request = {UrlStr, HdrList, ContentType, Body},
    HttpOpts = [
        {timeout, maps:get(timeout, Opts, ?DEFAULT_TIMEOUT)},
        {connect_timeout, maps:get(connect_timeout, Opts, ?DEFAULT_CONNECT_TIMEOUT)},
        {ssl, tls_opts()}
    ],
    %% body_format binary：响应体直接返回 binary，便于验签/解析
    case httpc:request(post, Request, HttpOpts, [{body_format, binary}]) of
        {ok, {{_Ver, Status, _Reason}, RespHeaders, RespBody}} ->
            {ok, Status, RespHeaders, ensure_binary(RespBody)};
        {error, Reason} ->
            {error, Reason}
    end.

-doc """
出站 URL 安全校验（EP-21）：仅允许 https。

- scheme 必须为 https（大小写不敏感），http / ftp 等一律拒绝
- 拒绝携带 userinfo（https://user:pass@host）的 URL，防凭据随 URL 泄露
- 拒绝无 host（如 https:///path）或解析失败的 URL

基于 OTP stdlib uri_string:parse/1（无新依赖）；parse 可能抛异常，
统一 try/catch 转为 {error, {insecure_url, binary()}}。
""".
-spec validate_url(binary() | string()) -> ok | {error, {insecure_url, binary()}}.
validate_url(Url) ->
    %% 统一转 binary 再解析：uri_string:parse 的 map 值类型随输入走
    %%（string 输入得 string 值），统一 binary 保证后续比较类型一致
    UrlBin = unicode:characters_to_binary(Url),
    try uri_string:parse(UrlBin) of
        Parsed when is_map(Parsed) ->
            check_url_parts(Parsed)
    catch
        _:_ ->
            {error, {insecure_url,
                <<"URL 非法或解析失败，支付出站仅允许合法 https 地址"/utf8>>}}
    end.

-spec check_url_parts(map()) -> ok | {error, {insecure_url, binary()}}.
check_url_parts(Parsed) ->
    %% 注意：OTP29 下 uri_string:parse 不小写化 scheme，需显式转换
    Scheme = string:lowercase(maps:get(scheme, Parsed, <<>>)),
    Host = maps:get(host, Parsed, <<>>),
    HasUserinfo = maps:is_key(userinfo, Parsed),
    if
        HasUserinfo ->
            {error, {insecure_url,
                <<"URL 禁止携带 userinfo（user:pass@host），防凭据明文泄露"/utf8>>}};
        Scheme =/= <<"https">> ->
            {error, {insecure_url,
                <<"支付出站仅允许 https，拒绝明文或非 https scheme 的 URL"/utf8>>}};
        Host =:= <<>> ->
            {error, {insecure_url,
                <<"URL 缺少 host，支付出站仅允许合法 https 地址"/utf8>>}};
        true ->
            ok
    end.

-doc "出站 TLS 安全选项：校验对端证书链 + 主机名（httpc 默认两者都不做）。".
-spec tls_opts() -> list().
tls_opts() ->
    [
        {verify, verify_peer},
        {cacerts, public_key:cacerts_get()},
        {depth, 9},
        {customize_hostname_check, [
            {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
        ]}
    ].

-spec to_list(binary() | string() | atom()) -> string().
to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L;
to_list(A) when is_atom(A) -> atom_to_list(A).

-spec ensure_binary(binary() | list()) -> binary().
ensure_binary(B) when is_binary(B) -> B;
ensure_binary(L) when is_list(L) -> iolist_to_binary(L).
