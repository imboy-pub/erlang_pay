-module(epay_state_tests).
%%%===================================================================
%%% @doc epay_state EUnit —— 统一交易状态词汇表与三态分类。
%%%
%%% 对标 omnipay NotificationInterface：is_paid/is_pending 为三态读取，
%%% is_final 标识状态已收敛（无需再轮询查单）。纯函数，无 mock。
%%% @end
%%%===================================================================
-include_lib("eunit/include/eunit.hrl").

%%%-------------------------------------------------------------------
%%% 词汇表：单一真相源
%%%-------------------------------------------------------------------
states_is_the_canonical_set_test() ->
    Expected = [success, pending, closed, refunded, revoked, error, unknown],
    ?assertEqual(lists:sort(Expected), lists:sort(epay_state:states())).

is_state_accepts_canonical_test() ->
    [?assert(epay_state:is_state(S)) || S <- epay_state:states()].

is_state_rejects_foreign_test() ->
    ?assertNot(epay_state:is_state(paid)),
    ?assertNot(epay_state:is_state(<<"success">>)),
    ?assertNot(epay_state:is_state(undefined)).

%%%-------------------------------------------------------------------
%%% is_paid —— omnipay isSuccessful（仅 success 为真）
%%%-------------------------------------------------------------------
is_paid_only_success_test() ->
    ?assert(epay_state:is_paid(success)),
    ?assertNot(epay_state:is_paid(pending)),
    ?assertNot(epay_state:is_paid(refunded)),
    ?assertNot(epay_state:is_paid(closed)),
    ?assertNot(epay_state:is_paid(error)),
    ?assertNot(epay_state:is_paid(unknown)).

%%%-------------------------------------------------------------------
%%% is_pending —— omnipay isPending（仅 pending 为真，须继续轮询）
%%%-------------------------------------------------------------------
is_pending_only_pending_test() ->
    ?assert(epay_state:is_pending(pending)),
    ?assertNot(epay_state:is_pending(success)),
    ?assertNot(epay_state:is_pending(unknown)).

%%%-------------------------------------------------------------------
%%% is_final —— 状态已收敛（终态）；pending/unknown 非终态须再查
%%%-------------------------------------------------------------------
is_final_terminal_states_test() ->
    [?assert(epay_state:is_final(S)) || S <- [success, closed, refunded, revoked, error]].

is_final_nonterminal_states_test() ->
    ?assertNot(epay_state:is_final(pending)),
    ?assertNot(epay_state:is_final(unknown)).

%%%-------------------------------------------------------------------
%%% 三态互斥不变量：任一 canonical 状态至多命中 is_paid/is_pending 之一
%%%-------------------------------------------------------------------
paid_and_pending_mutually_exclusive_test() ->
    [?assertNot(epay_state:is_paid(S) andalso epay_state:is_pending(S))
        || S <- epay_state:states()].
