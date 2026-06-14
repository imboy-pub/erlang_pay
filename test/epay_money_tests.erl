-module(epay_money_tests).
%%%===================================================================
%%% @doc epay_money EUnit —— 多币种 exponent 换算往返与边界。
%%% @end
%%%===================================================================
-include_lib("eunit/include/eunit.hrl").

exponent_known_test() ->
    ?assertEqual({ok, 2}, epay_money:exponent(<<"USD">>)),
    ?assertEqual({ok, 0}, epay_money:exponent(<<"JPY">>)),
    ?assertEqual({ok, 3}, epay_money:exponent(<<"BHD">>)).

exponent_case_insensitive_test() ->
    ?assertEqual({ok, 2}, epay_money:exponent(<<"usd">>)),
    ?assertEqual({ok, 0}, epay_money:exponent(<<"jpy">>)).

exponent_unsupported_test() ->
    ?assertEqual({error, {unsupported_currency, <<"XYZ">>}}, epay_money:exponent(<<"XYZ">>)).

to_minor_2decimals_test() ->
    ?assertEqual({ok, 1234}, epay_money:to_minor(<<"12.34">>, <<"USD">>)),
    ?assertEqual({ok, 10000}, epay_money:to_minor(<<"100">>, <<"USD">>)),
    ?assertEqual({ok, 1230}, epay_money:to_minor(<<"12.3">>, <<"USD">>)),
    ?assertEqual({ok, 1204}, epay_money:to_minor(<<"12.04">>, <<"USD">>)).

to_minor_0decimals_test() ->
    ?assertEqual({ok, 100}, epay_money:to_minor(<<"100">>, <<"JPY">>)),
    ?assertEqual({ok, 0}, epay_money:to_minor(<<"0">>, <<"JPY">>)).

to_minor_3decimals_test() ->
    ?assertEqual({ok, 1234}, epay_money:to_minor(<<"1.234">>, <<"BHD">>)),
    ?assertEqual({ok, 1000}, epay_money:to_minor(<<"1">>, <<"BHD">>)),
    ?assertEqual({ok, 1004}, epay_money:to_minor(<<"1.004">>, <<"BHD">>)).

to_minor_too_many_decimals_test() ->
    ?assertMatch({error, {too_many_decimals, _, 2}}, epay_money:to_minor(<<"12.345">>, <<"USD">>)),
    ?assertMatch({error, {too_many_decimals, _, 0}}, epay_money:to_minor(<<"100.5">>, <<"JPY">>)).

to_minor_unsupported_currency_test() ->
    ?assertEqual(
        {error, {unsupported_currency, <<"XYZ">>}}, epay_money:to_minor(<<"1.00">>, <<"XYZ">>)
    ).

to_minor_invalid_amount_test() ->
    ?assertMatch({error, {invalid_amount, _}}, epay_money:to_minor(<<"abc">>, <<"USD">>)),
    ?assertMatch({error, {invalid_amount, _}}, epay_money:to_minor(<<"-1.00">>, <<"USD">>)),
    %% 小数位带符号/非数字字符必须拒绝，防止静默算错金额。
    ?assertMatch({error, {invalid_amount, _}}, epay_money:to_minor(<<"12.-3">>, <<"USD">>)),
    ?assertMatch({error, {invalid_amount, _}}, epay_money:to_minor(<<"1.+5">>, <<"USD">>)),
    ?assertMatch({error, {invalid_amount, _}}, epay_money:to_minor(<<"1.2x">>, <<"USD">>)).

to_major_2decimals_test() ->
    ?assertEqual({ok, <<"12.34">>}, epay_money:to_major(1234, <<"USD">>)),
    ?assertEqual({ok, <<"12.04">>}, epay_money:to_major(1204, <<"USD">>)),
    ?assertEqual({ok, <<"0.05">>}, epay_money:to_major(5, <<"USD">>)).

to_major_0decimals_test() ->
    ?assertEqual({ok, <<"100">>}, epay_money:to_major(100, <<"JPY">>)).

to_major_3decimals_test() ->
    ?assertEqual({ok, <<"1.234">>}, epay_money:to_major(1234, <<"BHD">>)),
    ?assertEqual({ok, <<"1.004">>}, epay_money:to_major(1004, <<"BHD">>)).

to_major_negative_test() ->
    ?assertEqual({error, negative_amount}, epay_money:to_major(-1, <<"USD">>)).

to_major_unsupported_currency_test() ->
    ?assertEqual({error, {unsupported_currency, <<"XYZ">>}}, epay_money:to_major(100, <<"XYZ">>)).

roundtrip_test() ->
    Cases = [
        {<<"12.34">>, <<"USD">>},
        {<<"100">>, <<"JPY">>},
        {<<"1.234">>, <<"BHD">>}
    ],
    lists:foreach(
        fun({Major, Cur}) ->
            {ok, Minor} = epay_money:to_minor(Major, Cur),
            {ok, Back} = epay_money:to_major(Minor, Cur),
            ?assertEqual(Major, Back)
        end,
        Cases
    ).
