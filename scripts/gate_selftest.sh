#!/bin/bash
# gate_selftest.sh — scripts/gate.sh 的假绿路径回归 / false-green regression.
#
# 原理：把一个 stub rebar3（行为由 EPAY_STUB_MODE 驱动的可执行 shell 脚本）
# 放进临时 PATH 前置目录，运行 gate.sh，断言总退出码。全部用例都用
# /bin/bash 执行（macOS 自带 bash 3.2），顺带验证 gate.sh 的 3.2 兼容性。
#
# 覆盖形态：
#   1. ok             全 stub 成功                  → gate 退出 0（正向）
#   2. clean_fail     rebar3 clean 非零             → gate 红
#   3. compile_fail   rebar3 compile 非零           → gate 红
#   4. compile_warn   compile 零退出但输出含 Warning → gate 红（含 set -u 下
#                       warning 分支的真实触发，验证无 unbound variable 崩溃）
#   5. eunit_fail     rebar3 eunit 非零             → gate 红
#   6. dialyzer_fail  dialyzer 非零退出且无 src 路径 → gate 红（旧版假绿路径：
#                       旧 gate 只 grep src 路径，此形态会误报绿灯）
#   7. dialyzer_warn  dialyzer 零退出但输出含 erlang_pay/src 路径 → gate 红
#   8. dry_run        --dry-run 仅打印计划           → gate 退出 0
#
# 自身退出 0 当且仅当全部断言成立。
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/gate.sh"
BASH_BIN="/bin/bash"

PASS=0
FAIL=0

if [ ! -f "$GATE" ]; then
  echo "SELFTEST FAIL: 找不到 $GATE" >&2
  exit 1
fi

WORK="$(mktemp -d /tmp/epay_gate_selftest.XXXXXX)" || exit 1
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
trap 'rm -rf "$WORK"' EXIT

# ---- stub rebar3：按 EPAY_STUB_MODE × 子命令返回指定失败形态 ----
cat > "$STUB_DIR/rebar3" <<'STUB_EOF'
#!/bin/bash
# stub rebar3 for gate_selftest — never touches a real project.
mode="${EPAY_STUB_MODE:-ok}"
cmd="${1:-}"
case "$mode" in
  ok)
    exit 0
    ;;
  clean_fail)
    if [ "$cmd" = "clean" ]; then echo "stub: rebar3 clean exploded"; exit 1; fi
    exit 0
    ;;
  compile_fail)
    if [ "$cmd" = "compile" ]; then echo "stub: dependency failure foo"; exit 1; fi
    exit 0
    ;;
  compile_warn)
    if [ "$cmd" = "compile" ]; then
      echo "===> Compiling erlang_pay"
      echo "src/epay_stub.erl:10: Warning: variable X is unused"
      exit 0
    fi
    exit 0
    ;;
  eunit_fail)
    if [ "$cmd" = "eunit" ]; then echo "stub: 157 tests, 1 failures"; exit 1; fi
    exit 0
    ;;
  dialyzer_fail)
    if [ "$cmd" = "dialyzer" ]; then
      echo "escript: exception error: stub dialyzer crash (no src path in output)"
      exit 1
    fi
    exit 0
    ;;
  dialyzer_warn)
    if [ "$cmd" = "dialyzer" ]; then
      echo "/Users/x/project/erlang_pay/src/epay_stub.erl:12: Warning: call to missing function epay_stub:nope/0"
      exit 0
    fi
    exit 0
    ;;
  *)
    echo "stub: unknown EPAY_STUB_MODE=$mode" >&2
    exit 99
    ;;
esac
STUB_EOF
chmod +x "$STUB_DIR/rebar3"

report() { # name result(0/1)
  if [ "$2" -eq 0 ]; then
    echo "PASS: $1"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $1"
    FAIL=$((FAIL + 1))
  fi
}

# run_case <name> <mode> <want: zero|nonzero> <extra args...>
run_case() {
  name="$1"; mode="$2"; want="$3"; shift 3
  out="$WORK/out_${mode}.log"
  EPAY_STUB_MODE="$mode" PATH="$STUB_DIR:$PATH" "$BASH_BIN" "$GATE" "$@" > "$out" 2>&1
  rc=$?
  if [ "$want" = "zero" ]; then
    [ "$rc" -eq 0 ]
  else
    [ "$rc" -ne 0 ]
  fi
  result=$?
  if [ "$result" -ne 0 ]; then
    echo "---- gate output ($name, exit=$rc, want $want) ----"
    cat "$out"
    echo "---------------------------------------------------"
  fi
  report "$name" "$result"
}

echo "gate_selftest: GATE=$GATE  BASH=$($BASH_BIN --version | head -1)"
echo ""

# 0) 两脚本 bash 3.2 语法解析
"$BASH_BIN" -n "$GATE" && "$BASH_BIN" -n "$SCRIPT_DIR/gate_selftest.sh"
report "syntax_check /bin/bash -n gate.sh gate_selftest.sh" $?

# 1) 正向：全 stub 成功（含 dialyzer 门）→ 退出 0
run_case "ok / 全部成功 → 退出 0" ok zero --dialyze

# 2) clean 非零 → 红
run_case "clean_fail / rebar3 clean 非零 → 红" clean_fail nonzero

# 3) compile 非零 → 红
run_case "compile_fail / rebar3 compile 非零 → 红" compile_fail nonzero

# 4) compile 零退出但输出含 Warning → 红（真实触发 warning 分支）
run_case "compile_warn / 编译零退出但含 Warning → 红" compile_warn nonzero

# 5) eunit 非零 → 红
run_case "eunit_fail / rebar3 eunit 非零 → 红" eunit_fail nonzero

# 6) dialyzer 非零退出且无 src 路径 → 红（旧版假绿路径）
run_case "dialyzer_fail / dialyzer 非零退出无 src 路径 → 红（旧假绿路径）" dialyzer_fail nonzero --dialyze

# 7) dialyzer 零退出但输出含 erlang_pay/src 路径 → 红
run_case "dialyzer_warn / dialyzer 含 erlang_pay/src warning → 红" dialyzer_warn nonzero --dialyze

# 8) --dry-run 仅打印计划 → 退出 0（不触发任何 rebar3）
run_case "dry_run / --dry-run 打印计划 → 退出 0" ok zero --dry-run

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "gate_selftest 全绿：$PASS PASS, 0 FAIL"
  exit 0
else
  echo "gate_selftest 有红：$PASS PASS, $FAIL FAIL"
  exit 1
fi
