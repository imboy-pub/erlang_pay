-module(epay_util_tests).
%%%===================================================================
%%% @doc epay_util EUnit —— 固化 URL/表单/JSON/类型/金额换算行为。
%%% @end
%%%===================================================================
-include_lib("eunit/include/eunit.hrl").

%%%-------------------------------------------------------------------
%%% URL / 表单编码
%%%-------------------------------------------------------------------

urlencode_test() ->
    ?assertEqual(<<"a%20b">>, epay_util:urlencode(<<"a b">>)),
    %% 非保留字符原样
    ?assertEqual(<<"AZaz09-_.~">>, epay_util:urlencode(<<"AZaz09-_.~">>)),
    %% 整数自动转串
    ?assertEqual(<<"123">>, epay_util:urlencode(123)),
    %% 保留字符按大写 %HH 编码
    ?assertEqual(<<"%2F%3D%26">>, epay_util:urlencode(<<"/=&">>)).

form_encode_test() ->
    %% 保持入参顺序（不排序），值编码、键原样
    ?assertEqual(
        <<"b=2&a=1%201">>,
        epay_util:form_encode([{<<"b">>, <<"2">>}, {<<"a">>, <<"1 1">>}])
    ),
    ?assertEqual(<<>>, epay_util:form_encode([])).

%%%-------------------------------------------------------------------
%%% JSON
%%%-------------------------------------------------------------------

json_roundtrip_test() ->
    Map = #{<<"a">> => 1, <<"b">> => <<"x">>},
    Bin = epay_util:json_encode(Map),
    ?assertEqual({ok, Map}, epay_util:json_decode(Bin)).

json_decode_invalid_test() ->
    ?assertEqual({error, invalid_json}, epay_util:json_decode(<<"{bad json">>)).

%%%-------------------------------------------------------------------
%%% 类型转换
%%%-------------------------------------------------------------------

to_bin_test() ->
    ?assertEqual(<<"x">>, epay_util:to_bin(<<"x">>)),
    ?assertEqual(<<"42">>, epay_util:to_bin(42)),
    ?assertEqual(<<"ok">>, epay_util:to_bin(ok)),
    ?assertEqual(<<"ab">>, epay_util:to_bin(["a", "b"])).

%%%-------------------------------------------------------------------
%%% 金额换算（整数运算避浮点误差）
%%%-------------------------------------------------------------------

yuan_to_fen_test() ->
    ?assertEqual(1000, epay_util:yuan_to_fen(10)),
    ?assertEqual(1050, epay_util:yuan_to_fen(10.5)),
    ?assertEqual(1000, epay_util:yuan_to_fen(<<"10">>)),
    ?assertEqual(1050, epay_util:yuan_to_fen(<<"10.5">>)),
    ?assertEqual(1005, epay_util:yuan_to_fen(<<"10.05">>)),
    %% 超两位小数截断到分
    ?assertEqual(1055, epay_util:yuan_to_fen(<<"10.555">>)),
    %% 非法输入归零
    ?assertEqual(0, epay_util:yuan_to_fen(invalid_atom_xx)).

fen_to_yuan_bin_test() ->
    ?assertEqual(<<"10.50">>, epay_util:fen_to_yuan_bin(1050)),
    ?assertEqual(<<"0.05">>, epay_util:fen_to_yuan_bin(5)),
    ?assertEqual(<<"1.00">>, epay_util:fen_to_yuan_bin(100)).
