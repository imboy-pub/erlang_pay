-module(epay_util).
-moduledoc "通用工具：URL 编码 / 表单编码 / JSON / 类型转换 / 金额换算。".
-export([
    urlencode/1,
    form_encode/1,
    json_encode/1,
    json_decode/1,
    to_bin/1,
    yuan_to_fen/1,
    fen_to_yuan_bin/1
]).

-doc """
RFC3986 application/x-www-form-urlencoded 百分号编码。
不编码的非保留字符：A-Z a-z 0-9 - _ . ~；其余按 %HH 编码（空格→%20）。
""".
-spec urlencode(binary() | string() | integer()) -> binary().
urlencode(V) ->
    Bin = to_bin(V),
    << <<(enc_byte(B))/binary>> || <<B>> <= Bin >>.

-spec enc_byte(byte()) -> binary().
enc_byte(B) when
    (B >= $A andalso B =< $Z);
    (B >= $a andalso B =< $z);
    (B >= $0 andalso B =< $9);
    B =:= $-; B =:= $_; B =:= $.; B =:= $~
->
    <<B>>;
enc_byte(B) ->
    Hi = hex_digit(B bsr 4),
    Lo = hex_digit(B band 16#0F),
    <<$%, Hi, Lo>>.

-spec hex_digit(0..15) -> byte().
hex_digit(N) when N < 10 -> $0 + N;
hex_digit(N) -> $A + (N - 10).

-doc "把 `[{Key, Value}]` 编码为 urlencoded 表单串（值做百分号编码，键原样）。".
-spec form_encode([{binary() | string(), term()}]) -> binary().
form_encode(Pairs) ->
    Parts = [<<(to_bin(K))/binary, "=", (urlencode(V))/binary>> || {K, V} <- Pairs],
    join(Parts, <<"&">>).

-spec json_encode(term()) -> binary().
json_encode(Term) ->
    jsone:encode(Term, [native_utf8]).

-spec json_decode(binary()) -> {ok, term()} | {error, atom()}.
json_decode(Bin) ->
    try
        {ok, jsone:decode(Bin, [{object_format, map}])}
    catch
        _:_ -> {error, invalid_json}
    end.

-spec to_bin(term()) -> binary().
to_bin(V) when is_binary(V) -> V;
to_bin(V) when is_integer(V) -> integer_to_binary(V);
to_bin(V) when is_float(V) -> float_to_binary(V, [{decimals, 2}]);
to_bin(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_bin(V) when is_list(V) -> iolist_to_binary(V).

-doc "元 → 分 安全换算（整数运算避浮点误差）。".
-spec yuan_to_fen(term()) -> integer().
yuan_to_fen(V) when is_integer(V) -> V * 100;
yuan_to_fen(V) when is_float(V) -> round(V * 100);
yuan_to_fen(V) when is_binary(V) -> yuan_to_fen_bin(V);
yuan_to_fen(V) when is_list(V) -> yuan_to_fen_bin(iolist_to_binary(V));
yuan_to_fen(_) -> 0.

-spec yuan_to_fen_bin(binary()) -> integer().
yuan_to_fen_bin(Bin) ->
    case binary:split(Bin, <<".">>) of
        [IntPart] -> safe_int(IntPart) * 100;
        [IntPart, Frac] -> safe_int(IntPart) * 100 + safe_int(norm_frac(Frac));
        _ -> 0
    end.

-spec norm_frac(binary()) -> binary().
norm_frac(F) ->
    case byte_size(F) of
        0 -> <<"00">>;
        1 -> <<F/binary, "0">>;
        _ -> binary:part(F, 0, 2)
    end.

-spec safe_int(binary()) -> integer().
safe_int(B) ->
    try binary_to_integer(B) catch _:_ -> 0 end.

-doc "分 → 元字符串（两位小数，供支付宝 total_amount 等用）。".
-spec fen_to_yuan_bin(integer()) -> binary().
fen_to_yuan_bin(Fen) when is_integer(Fen) ->
    Yuan = Fen div 100,
    Cents = Fen rem 100,
    CentsBin = list_to_binary(io_lib:format("~2..0B", [Cents])),
    <<(integer_to_binary(Yuan))/binary, ".", CentsBin/binary>>.

-spec join([binary()], binary()) -> binary().
join([], _Sep) -> <<>>;
join([H | T], Sep) ->
    lists:foldl(fun(X, Acc) -> <<Acc/binary, Sep/binary, X/binary>> end, H, T).
