-module(epay_gateway).
%%%===================================================================
%%% @doc 统一网关 behaviour / Unified gateway contract
%%%
%%% 借鉴 omnipay GatewayInterface 与 Go 的 interface segregation：三家网关
%%% 实现同一组动作，差异通过「打 tag 的返回 map」与「可选回调」隔离。
%%%
%%% 约定（与 epay_util 一致）：金额一律以「分/最小货币单位」integer 传入。
%%%
%%% create_payment/2 返回打 tag 的 map（调用方据 type 分支）：
%%%   支付宝 App   : #{type => alipay_app,            order_str    => binary()}
%%%   微信 JSAPI   : #{type => wechat_jsapi,          prepay_id    => binary()}
%%%   微信 Native  : #{type => wechat_native,         code_url     => binary()}
%%%   Stripe       : #{type => stripe_payment_intent, payment_no   => binary(),
%%%                    client_secret => binary()}
%%%
%%% verify_notify/2 返回验签（含微信 AES-GCM 解密）后的明文事件 map。
%%%
%%% Ctx :: #{headers => map(), body => binary(), form => map()}
%%%   - 微信/Stripe 用 headers + body（原始字节验签）
%%%   - 支付宝异步通知用 form（已 url-decode 的表单 map）
%%% @end
%%%===================================================================

%% 统一错误返回：{error, {Code::atom(), Msg::binary()}}
%%   Code 供程序判断语义（如 gateway_error/http_error/invalid_response/
%%   bad_signature/no_credential/unsupported/unknown_gateway…），Msg 供展示。
-type err() :: {error, {atom(), binary()}}.

-callback create_payment(Cfg :: map(), Order :: map()) ->
    {ok, map()} | err().

-callback refund(Cfg :: map(), RefundReq :: map()) ->
    {ok, map()} | err().

%% 主动查单，返回统一 #{trade_state := atom(), ...}
-callback query(Cfg :: map(), Query :: map()) ->
    {ok, map()} | err().

%% 申请对账/结算文件（返回 download_url 或报告任务 id）
-callback download_bill(Cfg :: map(), Req :: map()) ->
    {ok, map()} | err().

-callback verify_notify(Cfg :: map(), Ctx :: map()) ->
    {ok, map()} | err().

%% 客户端二次签名（仅部分网关需要，如微信 JSAPI paySign）
-callback build_pay_sign(Cfg :: map(), Args :: map()) ->
    {ok, map()} | err().

%% 关单：未支付订单主动关闭（微信 close、支付宝 alipay.trade.close）
-callback close(Cfg :: map(), Req :: map()) ->
    {ok, map()} | err().

%% 撤单：已下单未支付/超时撤销（支付宝 alipay.trade.cancel、Stripe cancel）
-callback cancel(Cfg :: map(), Req :: map()) ->
    {ok, map()} | err().

%% 能力声明：每网关显式列出支持的动作（atom），门面据此判断而非 function_exported
%% 反射探测。可在启动期校验，亦便于调用方按能力分支。
%% 取值如：create_payment | refund | query | download_bill | verify_notify |
%%         build_pay_sign | close | cancel
-callback capabilities() -> [atom()].

-export_type([err/0]).

-optional_callbacks([build_pay_sign/2, close/2, cancel/2]).
