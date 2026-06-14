-module(epay_money).
%%%===================================================================
%%% @doc 多币种金额换算 / ISO 4217 minor-unit conversion
%%%
%%% 金额货币铁律：最小单位与货币码同存，小数位数（exponent）随币种而变，
%%% 不可假定恒为 2 位（×100）。USD/EUR/CNY=2，JPY/KRW=0，BHD/KWD=3。
%%%
%%% 为杜绝浮点误差，主单位一律以 binary 字符串传入/返回（如 <<"12.34">>），
%%% 内部全程整数运算。最小单位为 integer（如 1234 表示 12.34 USD）。
%%% @end
%%%===================================================================
-export([exponent/1, to_minor/2, to_major/2]).

-type currency() :: binary().

%% ISO 4217 常用币种小数位数。可按需扩充。
-define(EXPONENTS, #{
    <<"USD">> => 2, <<"EUR">> => 2, <<"GBP">> => 2, <<"CNY">> => 2,
    <<"AUD">> => 2, <<"CAD">> => 2, <<"HKD">> => 2, <<"SGD">> => 2,
    <<"JPY">> => 0, <<"KRW">> => 0,
    <<"BHD">> => 3, <<"KWD">> => 3, <<"JOD">> => 3, <<"OMR">> => 3
}).

%% @doc 查币种小数位数。未知币种返回明确错误。
-spec exponent(currency()) -> {ok, non_neg_integer()} | {error, {unsupported_currency, currency()}}.
exponent(Cur) when is_binary(Cur) ->
    case maps:find(normalize(Cur), ?EXPONENTS) of
        {ok, E} -> {ok, E};
        error -> {error, {unsupported_currency, Cur}}
    end.

%% @doc 主单位字符串 → 最小单位整数。如 to_minor(<<"12.34">>, <<"USD">>) = {ok, 1234}。
-spec to_minor(binary(), currency()) -> {ok, integer()} | {error, term()}.
to_minor(Major, Cur) when is_binary(Major) ->
    case exponent(Cur) of
        {ok, E} -> parse_major(Major, E);
        {error, _} = Err -> Err
    end.

%% @doc 最小单位整数 → 主单位字符串。如 to_major(1234, <<"USD">>) = {ok, <<"12.34">>}。
-spec to_major(integer(), currency()) -> {ok, binary()} | {error, term()}.
to_major(Minor, Cur) when is_integer(Minor), Minor >= 0 ->
    case exponent(Cur) of
        {ok, 0} ->
            {ok, integer_to_binary(Minor)};
        {ok, E} ->
            Base = pow10(E),
            Int = Minor div Base,
            Frac = Minor rem Base,
            FracBin = pad_left(integer_to_binary(Frac), E),
            {ok, <<(integer_to_binary(Int))/binary, ".", FracBin/binary>>};
        {error, _} = Err ->
            Err
    end;
to_major(_, _) ->
    {error, negative_amount}.

%%%===================================================================
%%% Internal
%%%===================================================================

-spec normalize(currency()) -> currency().
normalize(Cur) ->
    list_to_binary(string:to_upper(binary_to_list(Cur))).

%% 解析主单位字符串为最小单位整数，校验小数位不超 exponent。
-spec parse_major(binary(), non_neg_integer()) -> {ok, integer()} | {error, term()}.
parse_major(Major, E) ->
    case binary:split(Major, <<".">>) of
        [Int] -> combine(Int, <<>>, E);
        [Int, Frac] -> combine(Int, Frac, E);
        _ -> {error, {invalid_amount, Major}}
    end.

-spec combine(binary(), binary(), non_neg_integer()) -> {ok, integer()} | {error, term()}.
combine(IntPart, FracPart, E) ->
    case byte_size(FracPart) > E of
        true ->
            {error, {too_many_decimals, FracPart, E}};
        false ->
            try
                IntVal = parse_nonneg(IntPart),
                FracPadded = pad_right(FracPart, E),
                FracVal = parse_frac(FracPadded),
                {ok, IntVal * pow10(E) + FracVal}
            catch
                _:_ -> {error, {invalid_amount, IntPart}}
            end
    end.

-spec parse_nonneg(binary()) -> non_neg_integer().
parse_nonneg(B) ->
    V = binary_to_integer(B),
    true = V >= 0,
    V.

-spec parse_frac(binary()) -> non_neg_integer().
parse_frac(<<>>) -> 0;
parse_frac(B) -> binary_to_integer(B).

-spec pow10(non_neg_integer()) -> pos_integer().
pow10(0) -> 1;
pow10(N) -> 10 * pow10(N - 1).

%% 右补 0 到长度 E（小数部分对齐）。
-spec pad_right(binary(), non_neg_integer()) -> binary().
pad_right(B, E) ->
    case E - byte_size(B) of
        N when N =< 0 -> B;
        N -> <<B/binary, (binary:copy(<<"0">>, N))/binary>>
    end.

%% 左补 0 到长度 E（最小单位还原主单位小数部分）。
-spec pad_left(binary(), non_neg_integer()) -> binary().
pad_left(B, E) ->
    case E - byte_size(B) of
        N when N =< 0 -> B;
        N -> <<(binary:copy(<<"0">>, N))/binary, B/binary>>
    end.
