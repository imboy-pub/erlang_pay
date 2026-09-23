-module(erlang_pay_api_contract_tests).
%%%===================================================================
%%% @doc EP-20 公开 API 最小输入合同 EUnit —— 门面层校验先于 provider 分发。
%%%
%%% meck 三个 provider 模块（epay_alipay/epay_wechat/epay_stripe），断言：
%%%   1) 坏输入（缺字段 / 错类型 / 非 map）在门面被 {error,{bad_request,_}}
%%%      前置拒绝，provider 业务函数零调用；
%%%   2) 合法请求原样透传到 provider 且返回值直通（哨兵断言）；
%%%   3) unknown_gateway / unsupported 语义不因新增校验而改变。
%%%
%%% 风格对齐 epay_bill_tests：每个用例自带 with_mocks 包装（不用 foreach
%%% 生成器，避免 eunit 对 *_test/0 双重发现导致无 mock 裸跑）。
%%% capabilities 期望值与各网关真实清单一致，保证能力门控路径真实。
%%% @end
%%%===================================================================
-include_lib("eunit/include/eunit.hrl").

%% 全凭据超集：覆盖三网关出站所需全部 Cfg 键（门面按网关取所需子集校验，
%% 多余键无害）。凭据内容为测试假值，不触网（provider 被 meck）。
-define(CFG, #{app_id => <<"test-cfg">>, private_key => <<"test-key">>,
               mch_id => <<"test-mch">>, mch_serial_no => <<"test-serial">>,
               secret_key => <<"sk_test">>}).
%% 哨兵返回值：验证「门面原样透传 provider 结果」
-define(SENTINEL, {ok, #{contract => passthrough}}).

%%%-------------------------------------------------------------------
%%% meck 脚手架
%%%-------------------------------------------------------------------

providers() -> [epay_alipay, epay_wechat, epay_stripe].

%% 各 provider 的业务函数面（behaviour 回调，均为 /2；不含 capabilities/0，
%% 因门面能力门控路径会合法调用 capabilities）。
business_funs() ->
    Alipay = [create_payment, refund, verify_notify, query, download_bill,
              close, cancel],
    Wechat = [create_payment, refund, verify_notify, build_pay_sign, query,
              download_bill, close],
    Stripe = [create_payment, refund, verify_notify, query, download_bill,
              cancel],
    [{epay_alipay, F} || F <- Alipay]
        ++ [{epay_wechat, F} || F <- Wechat]
        ++ [{epay_stripe, F} || F <- Stripe].

with_mocks(Fun) ->
    [meck:new(M) || M <- providers()],
    %% capabilities 对齐真实清单（见各 provider src），保证 unsupported 门控真实
    meck:expect(epay_alipay, capabilities,
        fun() -> [create_payment, refund, query, download_bill, verify_notify,
                  close, cancel] end),
    meck:expect(epay_wechat, capabilities,
        fun() -> [create_payment, refund, query, download_bill, verify_notify,
                  build_pay_sign, close] end),
    meck:expect(epay_stripe, capabilities,
        fun() -> [create_payment, refund, query, download_bill, verify_notify,
                  cancel] end),
    [meck:expect(M, F, fun(_Cfg, _Req) -> ?SENTINEL end)
     || {M, F} <- business_funs()],
    try
        Fun()
    after
        [catch meck:unload(M) || M <- providers()]
    end.

%% 断言三个 provider 的全部业务函数零调用（坏输入不得触达 provider）。
assert_zero_provider_calls() ->
    [?assertEqual(0, meck:num_calls(M, F, '_'))
     || {M, F} <- business_funs()].

%% 断言合法请求被对应 provider 处理一次且结果原样透传。
assert_passthrough(Mod, Fun, Result) ->
    ?assertEqual(?SENTINEL, Result),
    ?assertEqual(1, meck:num_calls(Mod, Fun, '_')).

%%%-------------------------------------------------------------------
%%% create_payment：三网关必填 out_trade_no(b) + amount_fen(+int)
%%%-------------------------------------------------------------------

create_payment_missing_out_trade_no_test() ->
    with_mocks(fun() ->
        [?assertMatch({error, {bad_request, _}},
             erlang_pay:create_payment(G, ?CFG, #{amount_fen => 100}))
         || G <- [alipay, wechat, stripe]],
        assert_zero_provider_calls()
    end).

create_payment_zero_amount_test() ->
    with_mocks(fun() ->
        [?assertMatch({error, {bad_request, _}},
             erlang_pay:create_payment(G, ?CFG,
                 #{out_trade_no => <<"NO1">>, amount_fen => 0}))
         || G <- [alipay, wechat, stripe]],
        assert_zero_provider_calls()
    end).

create_payment_negative_amount_test() ->
    with_mocks(fun() ->
        [?assertMatch({error, {bad_request, _}},
             erlang_pay:create_payment(G, ?CFG,
                 #{out_trade_no => <<"NO1">>, amount_fen => -100}))
         || G <- [alipay, wechat, stripe]],
        assert_zero_provider_calls()
    end).

create_payment_atom_amount_test() ->
    with_mocks(fun() ->
        [?assertMatch({error, {bad_request, _}},
             erlang_pay:create_payment(G, ?CFG,
                 #{out_trade_no => <<"NO1">>, amount_fen => hundred}))
         || G <- [alipay, wechat, stripe]],
        assert_zero_provider_calls()
    end).

create_payment_bad_out_trade_no_type_test() ->
    with_mocks(fun() ->
        %% 空串 / 整数 / 列表均不合规（必须非空 binary）
        ?assertMatch({error, {bad_request, _}},
            erlang_pay:create_payment(alipay, ?CFG,
                #{out_trade_no => <<>>, amount_fen => 100})),
        ?assertMatch({error, {bad_request, _}},
            erlang_pay:create_payment(wechat, ?CFG,
                #{out_trade_no => 123, amount_fen => 100})),
        ?assertMatch({error, {bad_request, _}},
            erlang_pay:create_payment(stripe, ?CFG,
                #{out_trade_no => [<<"no">>], amount_fen => 100})),
        assert_zero_provider_calls()
    end).

create_payment_valid_passthrough_test() ->
    with_mocks(fun() ->
        Req = #{out_trade_no => <<"NO1">>, amount_fen => 100},
        [assert_passthrough(M, create_payment,
             erlang_pay:create_payment(G, ?CFG, Req))
         || {G, M} <- [{alipay, epay_alipay}, {wechat, epay_wechat},
                       {stripe, epay_stripe}]]
    end).

%%%-------------------------------------------------------------------
%%% refund：按网关差异化必填；stripe 幂等键候选（对齐 W1 合同）
%%%-------------------------------------------------------------------

refund_wechat_missing_out_refund_no_test() ->
    with_mocks(fun() ->
        ?assertMatch({error, {bad_request, _}},
            erlang_pay:refund(wechat, ?CFG,
                #{refund_fen => 10, total_fen => 100})),
        assert_zero_provider_calls()
    end).

refund_stripe_missing_payment_intent_test() ->
    with_mocks(fun() ->
        ?assertMatch({error, {bad_request, _}},
            erlang_pay:refund(stripe, ?CFG, #{out_refund_no => <<"R1">>})),
        assert_zero_provider_calls()
    end).

refund_stripe_missing_idempotency_candidates_test() ->
    with_mocks(fun() ->
        %% 缺 out_refund_no 且缺 idempotency_key：门面层拦截，与 provider 层
        %% W1 幂等合同双保险。
        ?assertMatch({error, {bad_request, _}},
            erlang_pay:refund(stripe, ?CFG, #{payment_intent => <<"pi_1">>})),
        assert_zero_provider_calls()
    end).

refund_alipay_non_integer_amount_test() ->
    with_mocks(fun() ->
        %% 浮点 / atom 均非正整数
        ?assertMatch({error, {bad_request, _}},
            erlang_pay:refund(alipay, ?CFG,
                #{out_trade_no => <<"NO1">>, refund_amount_fen => 12.5})),
        ?assertMatch({error, {bad_request, _}},
            erlang_pay:refund(alipay, ?CFG,
                #{out_trade_no => <<"NO1">>, refund_amount_fen => fifty})),
        assert_zero_provider_calls()
    end).

refund_valid_passthrough_test() ->
    with_mocks(fun() ->
        assert_passthrough(epay_alipay, refund,
            erlang_pay:refund(alipay, ?CFG,
                #{out_trade_no => <<"NO1">>, refund_amount_fen => 50})),
        assert_passthrough(epay_wechat, refund,
            erlang_pay:refund(wechat, ?CFG,
                #{out_refund_no => <<"R1">>, refund_fen => 10,
                  total_fen => 100})),
        assert_passthrough(epay_stripe, refund,
            erlang_pay:refund(stripe, ?CFG,
                #{payment_intent => <<"pi_1">>, out_refund_no => <<"R1">>}))
    end).

refund_stripe_idem_key_variant_test() ->
    with_mocks(fun() ->
        %% stripe：显式 idempotency_key 候选同样合法（独立用例，避免同一
        %% provider 函数多次调用导致计数断言叠加）
        assert_passthrough(epay_stripe, refund,
            erlang_pay:refund(stripe, ?CFG,
                #{payment_intent => <<"pi_1">>, idempotency_key => <<"K1">>}))
    end).

%%%-------------------------------------------------------------------
%%% query / download_bill
%%%-------------------------------------------------------------------

query_missing_required_test() ->
    with_mocks(fun() ->
        ?assertMatch({error, {bad_request, _}},
            erlang_pay:query(alipay, ?CFG, #{})),
        ?assertMatch({error, {bad_request, _}},
            erlang_pay:query(wechat, ?CFG, #{other => 1})),
        ?assertMatch({error, {bad_request, _}},
            erlang_pay:query(stripe, ?CFG, #{out_trade_no => <<"NO1">>})),
        assert_zero_provider_calls()
    end).

query_valid_passthrough_test() ->
    with_mocks(fun() ->
        assert_passthrough(epay_alipay, query,
            erlang_pay:query(alipay, ?CFG, #{out_trade_no => <<"NO1">>})),
        assert_passthrough(epay_wechat, query,
            erlang_pay:query(wechat, ?CFG, #{out_trade_no => <<"NO1">>})),
        assert_passthrough(epay_stripe, query,
            erlang_pay:query(stripe, ?CFG, #{payment_intent => <<"pi_1">>}))
    end).

download_bill_missing_bill_date_test() ->
    with_mocks(fun() ->
        [?assertMatch({error, {bad_request, _}},
             erlang_pay:download_bill(G, ?CFG, #{}))
         || G <- [alipay, wechat]],
        assert_zero_provider_calls()
    end).

download_bill_valid_passthrough_test() ->
    with_mocks(fun() ->
        assert_passthrough(epay_alipay, download_bill,
            erlang_pay:download_bill(alipay, ?CFG,
                #{bill_date => <<"2026-09-01">>})),
        assert_passthrough(epay_wechat, download_bill,
            erlang_pay:download_bill(wechat, ?CFG,
                #{bill_date => <<"2026-09-01">>})),
        %% stripe 参数可选：空 map 即合法
        assert_passthrough(epay_stripe, download_bill,
            erlang_pay:download_bill(stripe, ?CFG, #{}))
    end).

%%%-------------------------------------------------------------------
%%% close / cancel / build_pay_sign
%%%-------------------------------------------------------------------

close_missing_out_trade_no_test() ->
    with_mocks(fun() ->
        [?assertMatch({error, {bad_request, _}},
             erlang_pay:close(G, ?CFG, #{amount_fen => 1}))
         || G <- [alipay, wechat]],
        assert_zero_provider_calls()
    end).

close_valid_passthrough_test() ->
    with_mocks(fun() ->
        [assert_passthrough(M, close,
             erlang_pay:close(G, ?CFG, #{out_trade_no => <<"NO1">>}))
         || {G, M} <- [{alipay, epay_alipay}, {wechat, epay_wechat}]]
    end).

cancel_missing_required_test() ->
    with_mocks(fun() ->
        ?assertMatch({error, {bad_request, _}},
            erlang_pay:cancel(alipay, ?CFG, #{})),
        ?assertMatch({error, {bad_request, _}},
            erlang_pay:cancel(stripe, ?CFG, #{out_trade_no => <<"NO1">>})),
        assert_zero_provider_calls()
    end).

cancel_valid_passthrough_test() ->
    with_mocks(fun() ->
        assert_passthrough(epay_alipay, cancel,
            erlang_pay:cancel(alipay, ?CFG, #{out_trade_no => <<"NO1">>})),
        assert_passthrough(epay_stripe, cancel,
            erlang_pay:cancel(stripe, ?CFG, #{payment_intent => <<"pi_1">>}))
    end).

build_pay_sign_missing_prepay_id_test() ->
    with_mocks(fun() ->
        ?assertMatch({error, {bad_request, _}},
            erlang_pay:build_pay_sign(wechat, ?CFG, #{})),
        ?assertMatch({error, {bad_request, _}},
            erlang_pay:build_pay_sign(wechat, ?CFG, #{prepay_id => <<>>})),
        assert_zero_provider_calls()
    end).

build_pay_sign_valid_passthrough_test() ->
    with_mocks(fun() ->
        assert_passthrough(epay_wechat, build_pay_sign,
            erlang_pay:build_pay_sign(wechat, ?CFG, #{prepay_id => <<"wx123">>}))
    end).

%%%-------------------------------------------------------------------
%%% verify_notify：门面只拦非 map，Ctx 结构交 provider 验签 fail-closed
%%%-------------------------------------------------------------------

verify_notify_non_map_ctx_test() ->
    with_mocks(fun() ->
        [?assertMatch({error, {bad_request, _}},
             erlang_pay:verify_notify(G, ?CFG, not_a_map))
         || G <- [alipay, wechat, stripe]],
        ?assertMatch({error, {bad_request, _}},
            erlang_pay:verify_notify(wechat, not_a_map, #{headers => #{}})),
        assert_zero_provider_calls()
    end).

verify_notify_valid_passthrough_test() ->
    with_mocks(fun() ->
        Ctx = #{headers => #{}, body => <<>>, form => #{}},
        [assert_passthrough(M, verify_notify,
             erlang_pay:verify_notify(G, ?CFG, Ctx))
         || {G, M} <- [{alipay, epay_alipay}, {wechat, epay_wechat},
                       {stripe, epay_stripe}]]
    end).

%%%-------------------------------------------------------------------
%%% Cfg 必需凭据：缺失/空值 → no_credential（fail-closed，不触 provider）
%%%-------------------------------------------------------------------

cfg_missing_stripe_secret_test() ->
    with_mocks(fun() ->
        ?assertMatch({error, {no_credential, _}},
            erlang_pay:create_payment(stripe, #{},
                #{out_trade_no => <<"NO1">>, amount_fen => 100})),
        %% 空串凭据视同缺失
        ?assertMatch({error, {no_credential, _}},
            erlang_pay:refund(stripe, #{secret_key => <<>>},
                #{payment_intent => <<"pi_1">>, out_refund_no => <<"R1">>})),
        assert_zero_provider_calls()
    end).

cfg_missing_wechat_credentials_test() ->
    with_mocks(fun() ->
        %% refund 出站签名需 mch_serial_no/private_key（mch_id 单独不足以签名）
        ?assertMatch({error, {no_credential, _}},
            erlang_pay:refund(wechat, #{mch_id => <<"m">>},
                #{out_refund_no => <<"R1">>, refund_fen => 10, total_fen => 100})),
        %% build_pay_sign 只需 app_id + private_key
        ?assertMatch({error, {no_credential, _}},
            erlang_pay:build_pay_sign(wechat, #{app_id => <<"a">>},
                #{prepay_id => <<"p">>})),
        assert_zero_provider_calls()
    end).

cfg_missing_alipay_credential_test() ->
    with_mocks(fun() ->
        ?assertMatch({error, {no_credential, _}},
            erlang_pay:refund(alipay, #{app_id => <<"a">>},
                #{out_trade_no => <<"NO1">>, refund_amount_fen => 50})),
        assert_zero_provider_calls()
    end).

cfg_missing_credential_msg_content_test() ->
    with_mocks(fun() ->
        {error, {no_credential, Msg}} =
            erlang_pay:create_payment(stripe, #{},
                #{out_trade_no => <<"NO1">>, amount_fen => 100}),
        [?assertMatch({_, _}, binary:match(Msg, Needle))
         || Needle <- [<<"stripe">>, <<"create_payment">>, <<"secret_key">>,
                       <<"缺少商户凭据"/utf8>>]]
    end).

%% 优先级合同：Req 字段错误先于 Cfg 凭据错误（同为坏输入时报 bad_request）
cfg_req_field_error_precedence_test() ->
    with_mocks(fun() ->
        ?assertMatch({error, {bad_request, _}},
            erlang_pay:create_payment(stripe, #{}, #{amount_fen => 100})),
        assert_zero_provider_calls()
    end).

%% 回归：verify_notify 不做凭据级校验（各网关内部已 fail-closed），
%% 保护 imboy 等调用方「最小 Cfg 回调」形态（stripe 仅 webhook_secret）。
verify_notify_minimal_cfg_passthrough_test() ->
    with_mocks(fun() ->
        Ctx = #{headers => #{}, body => <<>>},
        assert_passthrough(epay_stripe, verify_notify,
            erlang_pay:verify_notify(stripe, #{webhook_secret => <<"whsec">>}, Ctx))
    end).

%%%-------------------------------------------------------------------
%%% 通用：Cfg / Req 非 map
%%%-------------------------------------------------------------------

non_map_cfg_test() ->
    with_mocks(fun() ->
        ?assertMatch({error, {bad_request, _}},
            erlang_pay:create_payment(alipay, not_a_map,
                #{out_trade_no => <<"NO1">>, amount_fen => 100})),
        ?assertMatch({error, {bad_request, _}},
            erlang_pay:refund(stripe, {tuple, cfg}, #{})),
        assert_zero_provider_calls()
    end).

non_map_req_test() ->
    with_mocks(fun() ->
        ?assertMatch({error, {bad_request, _}},
            erlang_pay:query(wechat, ?CFG, [out_trade_no])),
        ?assertMatch({error, {bad_request, _}},
            erlang_pay:download_bill(alipay, ?CFG, <<"2026-09-01">>)),
        assert_zero_provider_calls()
    end).

%%%-------------------------------------------------------------------
%%% 回归：unknown_gateway / unsupported 语义不变
%%%-------------------------------------------------------------------

unknown_gateway_regression_test() ->
    with_mocks(fun() ->
        Req = #{out_trade_no => <<"NO1">>, amount_fen => 100},
        ?assertMatch({error, {unknown_gateway, _}},
            erlang_pay:create_payment(foobar, ?CFG, Req)),
        ?assertMatch({error, {unknown_gateway, _}},
            erlang_pay:verify_notify(foobar, ?CFG, #{})),
        ?assertMatch({error, {unknown_gateway, _}},
            erlang_pay:refund(foobar, ?CFG, Req)),
        assert_zero_provider_calls()
    end).

unsupported_regression_test() ->
    with_mocks(fun() ->
        %% stripe 无 close 能力、wechat 无 cancel、alipay 无 build_pay_sign：
        %% 合法 map 输入下仍返回 unsupported（非 bad_request）
        ?assertMatch({error, {unsupported, _}},
            erlang_pay:close(stripe, ?CFG, #{})),
        ?assertMatch({error, {unsupported, _}},
            erlang_pay:cancel(wechat, ?CFG, #{out_trade_no => <<"NO1">>})),
        ?assertMatch({error, {unsupported, _}},
            erlang_pay:build_pay_sign(alipay, ?CFG, #{})),
        %% 业务函数零调用（仅能力门控查询 capabilities）
        assert_zero_provider_calls()
    end).

%%%-------------------------------------------------------------------
%%% 错误 Msg 内容：指明 gateway + action + 字段名 + 期望形态
%%%-------------------------------------------------------------------

bad_request_msg_content_test() ->
    with_mocks(fun() ->
        {error, {bad_request, Msg}} =
            erlang_pay:create_payment(alipay, ?CFG, #{amount_fen => 100}),
        ?assert(is_binary(Msg)),
        %% 注意：含中文的 needle 必须带 /utf8 后缀（与门面实现一致）
        [?assertMatch({_, _}, binary:match(Msg, Needle))
         || Needle <- [<<"alipay">>, <<"create_payment">>, <<"out_trade_no">>,
                       <<"binary">>]],
        {error, {bad_request, Msg2}} =
            erlang_pay:create_payment(wechat, ?CFG,
                #{out_trade_no => <<"NO1">>, amount_fen => 0}),
        [?assertMatch({_, _}, binary:match(Msg2, Needle))
         || Needle <- [<<"wechat">>, <<"amount_fen">>, <<"正整数"/utf8>>]],
        {error, {bad_request, Msg3}} =
            erlang_pay:refund(stripe, ?CFG, #{payment_intent => <<"pi_1">>}),
        [?assertMatch({_, _}, binary:match(Msg3, Needle))
         || Needle <- [<<"stripe">>, <<"refund">>, <<"out_refund_no">>]]
    end).
