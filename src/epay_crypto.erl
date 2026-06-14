-module(epay_crypto).
%%%===================================================================
%%% @doc 支付密码学原语 / Payment cryptographic primitives
%%%
%%% 仅依赖 OTP 内置 crypto / public_key，无第三方依赖。覆盖三家网关 live
%%% 分支所需的全部算法（对标官方 wechatpay-go/utils 与 stripe-go）：
%%%   - RSA SHA256withRSA(PKCS#1 v1.5) 签名/验签（支付宝 RSA2、微信 APIv3）
%%%   - HMAC-SHA256（Stripe Webhook）
%%%   - AES-256-GCM 解密（微信 v3 回调 resource 解密；APIv3 key 直用，无 KDF）
%%%   - 常量时间比较（防时序攻击）
%%%   - PEM 私钥/公钥解析（支持裸 base64 公钥自动补 PEM 头，适配支付宝）
%%%   - 小写 hex（Stripe 签名为小写 hex）
%%%
%%% 安全约束：本模块不打印任何密钥/签名/明文；调用方亦不得将其入日志。
%%% @end
%%%===================================================================

-export([
    rsa_sign_sha256/2,
    rsa_verify_sha256/3,
    hmac_sha256/2,
    hmac_sha256_hex/2,
    aes_256_gcm_decrypt/4,
    constant_time_equal/2,
    lower_hex/1,
    nonce/1
]).

-include_lib("public_key/include/public_key.hrl").

%%%===================================================================
%%% RSA SHA256withRSA（PKCS#1 v1.5）
%%%===================================================================

%% @doc 用 PEM 私钥对 Message 做 SHA256withRSA 签名，返回原始签名字节。
%% 支持 PKCS#1（-----BEGIN RSA PRIVATE KEY-----）与
%% PKCS#8（-----BEGIN PRIVATE KEY-----）两种私钥格式。
-spec rsa_sign_sha256(binary(), binary()) -> {ok, binary()} | {error, atom()}.
rsa_sign_sha256(Message, PrivKeyPem) when is_binary(Message), is_binary(PrivKeyPem) ->
    case decode_private_key(PrivKeyPem) of
        {ok, PrivKey} ->
            try
                {ok, public_key:sign(Message, sha256, PrivKey)}
            catch
                _:_ -> {error, sign_failed}
            end;
        {error, _} = Err ->
            Err
    end;
rsa_sign_sha256(_, _) ->
    {error, bad_args}.

%% @doc 用 PEM 公钥（或 X.509 SubjectPublicKeyInfo / 裸 base64 公钥）验证
%% SHA256withRSA 签名。Signature 为原始签名字节（非 base64/hex）。
-spec rsa_verify_sha256(binary(), binary(), binary()) -> boolean().
rsa_verify_sha256(Message, Signature, PubKeyPem) when
    is_binary(Message), is_binary(Signature), is_binary(PubKeyPem)
->
    case decode_public_key(PubKeyPem) of
        {ok, PubKey} ->
            try
                public_key:verify(Message, sha256, Signature, PubKey)
            catch
                _:_ -> false
            end;
        {error, _} ->
            false
    end;
rsa_verify_sha256(_, _, _) ->
    false.

%%%===================================================================
%%% HMAC-SHA256
%%%===================================================================

%% @doc HMAC-SHA256，返回原始字节。
-spec hmac_sha256(binary(), binary()) -> binary().
hmac_sha256(Key, Data) when is_binary(Key), is_binary(Data) ->
    crypto:mac(hmac, sha256, Key, Data).

%% @doc HMAC-SHA256，返回小写 hex（Stripe v1 签名格式）。
-spec hmac_sha256_hex(binary(), binary()) -> binary().
hmac_sha256_hex(Key, Data) ->
    lower_hex(hmac_sha256(Key, Data)).

%%%===================================================================
%%% AES-256-GCM 解密（微信 v3 回调 resource）
%%%===================================================================

%% @doc AES-256-GCM 解密。
%% 微信约定：密文 = base64(密文 || 16 字节 GCM Tag)；Key=APIv3Key(32 字节，
%% 直接使用，不做任何 KDF 派生)；Nonce/AAD 为明文字符串字节。
%% Tag 校验失败（认证失败/密文被篡改）返回 {error, auth_failed}。
-spec aes_256_gcm_decrypt(binary(), binary(), binary(), binary()) ->
    {ok, binary()} | {error, atom()}.
aes_256_gcm_decrypt(CipherB64, Key, Nonce, Aad) when
    is_binary(CipherB64), is_binary(Key), is_binary(Nonce), is_binary(Aad)
->
    try
        CipherWithTag = base64:decode(CipherB64),
        Len = byte_size(CipherWithTag),
        case Len >= 16 andalso byte_size(Key) =:= 32 of
            false ->
                {error, bad_args};
            true ->
                CipherLen = Len - 16,
                Cipher = binary:part(CipherWithTag, 0, CipherLen),
                Tag = binary:part(CipherWithTag, CipherLen, 16),
                case
                    crypto:crypto_one_time_aead(
                        aes_256_gcm, Key, Nonce, Cipher, Aad, Tag, false
                    )
                of
                    Plain when is_binary(Plain) -> {ok, Plain};
                    _ -> {error, auth_failed}
                end
        end
    catch
        _:_ -> {error, auth_failed}
    end.

%%%===================================================================
%%% 常量时间比较 / 小写 hex / 随机串
%%%===================================================================

%% @doc 常量时间二进制比较，防时序侧信道。等长才逐字节异或累计；不等长直接
%% false（长度本身非秘密）。
-spec constant_time_equal(binary(), binary()) -> boolean().
constant_time_equal(A, B) when is_binary(A), is_binary(B) ->
    case byte_size(A) =:= byte_size(B) of
        false -> false;
        true -> ct_equal(A, B, 0)
    end;
constant_time_equal(_, _) ->
    false.

-spec ct_equal(binary(), binary(), non_neg_integer()) -> boolean().
ct_equal(<<>>, <<>>, Acc) ->
    Acc =:= 0;
ct_equal(<<A, RA/binary>>, <<B, RB/binary>>, Acc) ->
    ct_equal(RA, RB, Acc bor (A bxor B)).

%% @doc 原始字节转小写 hex。
-spec lower_hex(binary()) -> binary().
lower_hex(Bin) when is_binary(Bin) ->
    binary:encode_hex(Bin, lowercase).

%% @doc 生成 N 字节强随机数的小写 hex 串（请求 nonce_str 用）。
-spec nonce(pos_integer()) -> binary().
nonce(NBytes) when is_integer(NBytes), NBytes > 0 ->
    lower_hex(crypto:strong_rand_bytes(NBytes)).

%%%===================================================================
%%% Internal —— PEM 解析
%%%===================================================================

-spec decode_private_key(binary()) -> {ok, term()} | {error, atom()}.
decode_private_key(Pem) ->
    try
        case public_key:pem_decode(Pem) of
            [Entry | _] ->
                {ok, public_key:pem_entry_decode(Entry)};
            [] ->
                %% 裸 base64 私钥（无 PEM 头）：按 PKCS#8 补头重试
                case has_pem_header(Pem) of
                    true -> {error, bad_private_key};
                    false -> decode_private_key(wrap_pem(<<"PRIVATE KEY">>, Pem))
                end
        end
    catch
        _:_ -> {error, bad_private_key}
    end.

-spec decode_public_key(binary()) -> {ok, term()} | {error, atom()}.
decode_public_key(Pem) ->
    try
        case public_key:pem_decode(Pem) of
            [Entry | _] ->
                {ok, extract_pubkey(public_key:pem_entry_decode(Entry))};
            [] ->
                %% 支付宝公钥常以裸 base64（X.509 SPKI）下发，无 PEM 头：补头重试
                case has_pem_header(Pem) of
                    true -> {error, bad_public_key};
                    false -> decode_public_key(wrap_pem(<<"PUBLIC KEY">>, Pem))
                end
        end
    catch
        _:_ -> {error, bad_public_key}
    end.

%% 从证书 / SPKI / 裸 RSA 公钥统一提取可供 public_key:verify 使用的公钥项
-spec extract_pubkey(term()) -> term().
extract_pubkey(#'RSAPublicKey'{} = K) ->
    K;
extract_pubkey({#'RSAPublicKey'{} = K, _Params}) ->
    K;
extract_pubkey(Other) ->
    Other.

-spec wrap_pem(binary(), binary()) -> binary().
wrap_pem(Label, Body0) ->
    Body = normalize_b64(Body0),
    <<"-----BEGIN ", Label/binary, "-----\n", Body/binary, "\n-----END ", Label/binary,
        "-----\n">>.

%% 去掉可能存在的空白，按 64 列重新折行（PEM 规范）
-spec normalize_b64(binary()) -> binary().
normalize_b64(Bin) ->
    Clean = << <<C>> || <<C>> <= Bin, C =/= $\n, C =/= $\r, C =/= $\s, C =/= $\t >>,
    wrap64(Clean, <<>>).

-spec wrap64(binary(), binary()) -> binary().
wrap64(<<Chunk:64/binary, Rest/binary>>, Acc) when byte_size(Rest) > 0 ->
    wrap64(Rest, <<Acc/binary, Chunk/binary, "\n">>);
wrap64(Rest, Acc) ->
    <<Acc/binary, Rest/binary>>.

-spec has_pem_header(binary()) -> boolean().
has_pem_header(Bin) ->
    binary:match(Bin, <<"-----BEGIN">>) =/= nomatch.
