#!/usr/bin/env bash
# erlang_pay — autonomous loop 绿灯门 / green-light gate
#
# 参照 imboy.pub/.claude/scripts/ddd_loop_gate.sh 约定：顺序跑门，任一红即非零
# 退出（供 loop 熔断）。库定位为「现代简洁高效通用纯 Erlang 支付模块」，故门
# 只认三条硬指标：编译零 warning、EUnit 全绿、（可选）dialyzer 零 erlang_pay warning。
#
# Runs gates in order; any red exits non-zero so the loop circuit-breaks.
#
# 2026-09-22 加固（scripts/gate_selftest.sh 以 stub rebar3 全路径回归）：
#   1) 门1 前先 rebar3 clean，杜绝增量编译缓存把 warning/失败藏成假绿；
#   2) dialyzer 门显式检查退出码——旧版只 grep src 路径，rebar3 dialyzer
#      崩溃（非零退出、无 warning 输出）时会假绿；
#   3) 所有子命令一律 `if ! cmd; then` 显式判退出码，兼容 macOS bash 3.2。
#
# 用法 / Usage:
#   bash scripts/gate.sh            # clean + compile(零 warning) + eunit
#   bash scripts/gate.sh --dialyze  # 额外跑 dialyzer（首次建 PLT 较慢）
#   bash scripts/gate.sh --dry-run  # 仅打印计划，不执行（退出 0）
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLEAN_LOG="/tmp/epay_gate_clean.log"
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
  echo "  门1 编译门 : 清 _build(default+test) 项目产物 + rebar3 clean + rebar3 compile（判据：退出码均 0 且编译输出无 Warning）"
  echo "  门2 单测门 : rebar3 eunit（判据：退出码 0）"
  [ "$RUN_DIALYZE" -eq 1 ] && echo "  门3 类型门 : rebar3 dialyzer（判据：退出码 0 且无 erlang_pay/src warning）"
  echo "  ROOT=$ROOT"
  exit 0
fi

cd "$ROOT" || { red "无法进入 $ROOT"; exit 1; }

# ---- 门1 编译门（clean 后全量编译，零 warning）/ Compile gate (clean + zero warning) ----
step "门1 编译门 rebar3 clean（default+test profile）+ rebar3 compile"
# rebar3 clean 只清 default profile；test profile 的项目产物必须一并手动
# 清除，否则已删除模块的孤儿 beam（如 epay_cert_mgr.beam）会残留在
# _build/test 里，被 eunit 加载出非确定行为。
if ! rm -rf _build/default/lib/erlang_pay _build/test/lib/erlang_pay; then
  red "清除 _build 项目产物失败（_build/{default,test}/lib/erlang_pay）"
  exit 1
fi
if ! rebar3 clean > "$CLEAN_LOG" 2>&1; then
  red "rebar3 clean 失败（见 $CLEAN_LOG）"
  tail -30 "$CLEAN_LOG" >&2
  exit 1
fi
ok "  clean 完成（default+test profile，杜绝增量缓存/孤儿 beam 假绿）"
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
ok "门1 通过：清洁编译零 warning"

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
  # 退出码本身必须为 0：dialyzer 崩溃/被杀时非零退出且往往没有 src 路径
  # 输出，旧版只 grep src 路径会在此形态下假绿。
  if ! rebar3 dialyzer > "$DIALYZE_LOG" 2>&1; then
    red "rebar3 dialyzer 退出码非零（见 $DIALYZE_LOG）"
    tail -30 "$DIALYZE_LOG" >&2
    exit 1
  fi
  if grep -qE "erlang_pay/src|/src/epay_|/src/erlang_pay" "$DIALYZE_LOG"; then
    red "dialyzer 出现 erlang_pay/src 相关 warning（见 $DIALYZE_LOG）"
    grep -nE "erlang_pay/src|/src/epay_|/src/erlang_pay" "$DIALYZE_LOG" >&2
    exit 1
  fi
  ok "门3 通过：dialyzer 零 erlang_pay/src warning"
fi

echo "✅✅ erlang_pay 全部绿灯门通过 / all gates green"
exit 0
