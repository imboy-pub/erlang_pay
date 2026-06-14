-module(epay_webhook_tests).
%%%===================================================================
%%% @doc Stripe webhook 验签 + 时间戳容差防重放 EUnit。
%%%
%%% 不 mock crypto：用真实 HMAC-SHA256 生成 Stripe-Signature，覆盖
%%%   - 窗口内有效签名 → {ok, Event}
%%%   - 超容差窗口（过期）→ {error, {timestamp_expired, _}}
%%%   - 篡改签名 → {error, {bad_signature, _}}
%%%   - 缺 webhook_secret → {error, {no_credential, _}}
%%%   - 头格式非法 → {error, {malformed_signature, _}}
%%%   - webhook_tolerance 可配置收紧窗口
%%% 时间戳相对真实时钟取偏移，300s 默认窗口足以吸收测试执行抖动。
%%% @end
%%%===================================================================
-include_lib("eunit/include/eunit.hrl").

-define(SECRET, <<"whsec_test_123">>).
-define(BODY, <<"{\"id\":\"evt_1\",\"type\":\"payment_intent.succeeded\"}">>).

cfg() -> #{webhook_secret => ?SECRET}.

cfg(Tolerance) -> #{webhook_secret => ?SECRET, webhook_tolerance => Tolerance}.

now_s() -> erlang:system_time(second).

%% 用 Secret 对 "Ts.Body" 签名，构造 Stripe-Signature 头。
sig_header(Ts) ->
    sig_header(Ts, ?SECRET, ?BODY).

sig_header(Ts, Secret, Body) ->
    TsBin = integer_to_binary(Ts),
    Payload = <<TsBin/binary, ".", Body/binary>>,
    V1 = epay_crypto:hmac_sha256_hex(Secret, Payload),
    <<"t=", TsBin/binary, ",v1=", V1/binary>>.

ctx(SigHeader, Body) ->
    #{headers => #{<<"stripe-signature">> => SigHeader}, body => Body}.

%%%-------------------------------------------------------------------
%%% 窗口内有效 → 通过
%%%-------------------------------------------------------------------
within_window_ok_test() ->
    Header = sig_header(now_s()),
    ?assertMatch(
        {ok, #{<<"id">> := <<"evt_1">>}},
        epay_stripe:verify_notify(cfg(), ctx(Header, ?BODY))
    ).

%%%-------------------------------------------------------------------
%%% 超容差窗口（过期）→ 拒绝（防重放核心）
%%%-------------------------------------------------------------------
expired_timestamp_rejected_test() ->
    Header = sig_header(now_s() - 400),
    ?assertMatch(
        {error, {timestamp_expired, _}},
        epay_stripe:verify_notify(cfg(), ctx(Header, ?BODY))
    ).

%% 未来时间戳超窗同样拒绝（abs 双向）
future_timestamp_rejected_test() ->
    Header = sig_header(now_s() + 400),
    ?assertMatch(
        {error, {timestamp_expired, _}},
        epay_stripe:verify_notify(cfg(), ctx(Header, ?BODY))
    ).

%%%-------------------------------------------------------------------
%%% 可配置容差：收紧到 1s，偏移 10s 即过期
%%%-------------------------------------------------------------------
custom_tolerance_rejects_test() ->
    Header = sig_header(now_s() - 10),
    ?assertMatch(
        {error, {timestamp_expired, _}},
        epay_stripe:verify_notify(cfg(1), ctx(Header, ?BODY))
    ).

%%%-------------------------------------------------------------------
%%% 篡改签名 → 拒绝
%%%-------------------------------------------------------------------
tampered_signature_rejected_test() ->
    Ts = now_s(),
    Bad = <<"t=", (integer_to_binary(Ts))/binary, ",v1=deadbeef">>,
    ?assertMatch(
        {error, {bad_signature, _}},
        epay_stripe:verify_notify(cfg(), ctx(Bad, ?BODY))
    ).

%% body 被篡改（签名对应原 body）→ 验签失败
tampered_body_rejected_test() ->
    Header = sig_header(now_s()),
    ?assertMatch(
        {error, {bad_signature, _}},
        epay_stripe:verify_notify(cfg(), ctx(Header, <<"{\"id\":\"evil\"}">>))
    ).

%%%-------------------------------------------------------------------
%%% 缺凭据 / 头格式非法
%%%-------------------------------------------------------------------
no_secret_test() ->
    Header = sig_header(now_s()),
    ?assertMatch(
        {error, {no_credential, _}},
        epay_stripe:verify_notify(#{}, ctx(Header, ?BODY))
    ).

malformed_header_test() ->
    ?assertMatch(
        {error, {malformed_signature, _}},
        epay_stripe:verify_notify(cfg(), ctx(<<"garbage">>, ?BODY))
    ).
