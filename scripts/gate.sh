#!/usr/bin/env bash
# erlang_pay — autonomous loop 绿灯门 / green-light gate
#
# 参照 imboy.pub/.claude/scripts/ddd_loop_gate.sh 约定：顺序跑门，任一红即非零
# 退出（供 loop 熔断）。库定位为「现代简洁高效通用纯 Erlang 支付模块」，故门
# 只认三条硬指标：编译零 warning、EUnit 全绿、（可选）dialyzer 零 erlang_pay warning。
#
# Runs gates in order; any red exits non-zero so the loop circuit-breaks.
#
# 用法 / Usage:
#   bash scripts/gate.sh            # compile(零 warning) + eunit
#   bash scripts/gate.sh --dialyze  # 额外跑 dialyzer（首次建 PLT 较慢）
#   bash scripts/gate.sh --dry-run  # 仅打印计划，不执行（退出 0）
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPILE_LOG="/tmp/epay_gate_compile.log"
DIALYZE_LOG="/tmp/epay_gate_dialyze.log"

RUN_DIALYZE=0
DRY=0
for arg in "$@"; do
  case "$arg" in
    --dialyze) RUN_DIALYZE=1 ;;
    --dry-run) DRY=1 ;;
    *) echo "未知参数 / unknown arg: $arg" >&2; exit 64 ;;
  esac
done

red()  { echo "❌ GATE RED: $*" >&2; }
ok()   { echo "✅ $*"; }
step() { echo "── $* ──"; }

if [ "$DRY" -eq 1 ]; then
  echo "[dry-run] 计划执行的门 / planned gates:"
  echo "  门1 编译门 : rebar3 compile（判据：退出码 0 且输出无 Warning）"
  echo "  门2 单测门 : rebar3 eunit（判据：退出码 0）"
  [ "$RUN_DIALYZE" -eq 1 ] && echo "  门3 类型门 : rebar3 dialyzer（判据：无 erlang_pay/src warning）"
  echo "  ROOT=$ROOT"
  exit 0
fi

cd "$ROOT" || { red "无法进入 $ROOT"; exit 1; }

# ---- 门1 编译门（零 warning）/ Compile gate (zero warning) ----
step "门1 编译门 rebar3 compile"
if ! rebar3 compile > "$COMPILE_LOG" 2>&1; then
  red "rebar3 compile 失败（见 $COMPILE_LOG）"
  tail -30 "$COMPILE_LOG" >&2
  exit 1
fi
if grep -qiE "warning:" "$COMPILE_LOG"; then
  red "编译出现 warning（库要求零 warning，见 $COMPILE_LOG）"
  grep -niE "warning:" "$COMPILE_LOG" >&2
  exit 1
fi
ok "门1 通过：编译零 warning"

# ---- 门2 单测门 / EUnit gate ----
step "门2 单测门 rebar3 eunit"
if ! rebar3 eunit; then
  red "rebar3 eunit 失败"
  exit 1
fi
ok "门2 通过：EUnit 全绿"

# ---- 门3 类型门（可选）/ Dialyzer gate (optional) ----
if [ "$RUN_DIALYZE" -eq 1 ]; then
  step "门3 类型门 rebar3 dialyzer"
  rebar3 dialyzer > "$DIALYZE_LOG" 2>&1
  if grep -qE "erlang_pay/src|/src/epay_|/src/erlang_pay" "$DIALYZE_LOG"; then
    red "dialyzer 出现 erlang_pay/src 相关 warning（见 $DIALYZE_LOG）"
    grep -nE "erlang_pay/src|/src/epay_|/src/erlang_pay" "$DIALYZE_LOG" >&2
    exit 1
  fi
  ok "门3 通过：dialyzer 零 erlang_pay/src warning"
fi

echo "✅✅ erlang_pay 全部绿灯门通过 / all gates green"
exit 0
