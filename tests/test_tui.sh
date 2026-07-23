#!/usr/bin/env bash
set -u

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PSW="$ROOT_DIR/power-switch.sh"
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/psw-tui-test.XXXXXX") || exit 1

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

if ! command -v script >/dev/null 2>&1 || ! command -v perl >/dev/null 2>&1; then
    printf 'SKIP: TUI 测试需要 script 和 perl\n'
    exit 0
fi

if ! script --version 2>/dev/null | grep -q 'util-linux'; then
    printf 'SKIP: 当前 script 实现不支持 util-linux 测试参数\n'
    exit 0
fi

mkdir -p "$TEST_TMP/home"
HOME="$TEST_TMP/home" POWER_SWITCH_HOME="$TEST_TMP/data" NO_COLOR=1 \
    "$PSW" provider add \
        --name openai-chat \
        --preset custom \
        --format openai \
        --base-url https://example.test/v1 \
        --key test \
        --model test-model \
        --wire-api chat > "$TEST_TMP/add.out" || fail "准备 TUI 接入商失败"

run_tui() {
    local keys="$1" rows="$2" cols="$3" output="$4" extra_env="${5:-}"
    local command
    command="stty rows $rows cols $cols; env TERM=xterm-256color $extra_env HOME=$TEST_TMP/home POWER_SWITCH_HOME=$TEST_TMP/data $PSW dash"
    printf '%b' "$keys" | script -qefc "$command" "$output" >/dev/null || fail "TUI 运行失败: $output"
}

strip_ansi() {
    perl -pe 's/\e\[[0-9;?]*[ -\/]*[@-~]//g; s/\r//g' "$1" > "$2"
}

run_tui '12321q' 24 100 "$TEST_TMP/normal.typescript"
strip_ansi "$TEST_TMP/normal.typescript" "$TEST_TMP/normal.txt"
grep -q '  ⚡ Power Switch v1.1.0' "$TEST_TMP/normal.txt" || fail "默认左右 padding 未生效"
grep -q '数据目录: .*JSON 后端:' "$TEST_TMP/normal.txt" || fail "底部状态信息缺失"
perl -0777 -e '$s = <>; exit((index($s, "\e[H\e[J") < 0) ? 0 : 1)' \
    "$TEST_TMP/normal.typescript" || fail "TUI 重绘不应执行整屏清空"
perl -0777 -e '$s = <>; exit((index($s, "\e[J") < 0) ? 0 : 1)' \
    "$TEST_TMP/normal.typescript" || fail "正常切换不应清空包含底栏的屏幕区域"
perl -0777 -e '$s = <>; $n = () = ($s =~ /JSON 后端:/g); exit(($n == 1) ? 0 : 1)' \
    "$TEST_TMP/normal.typescript" || fail "未变化的数据目录状态不应重复重画"
perl -0777 -e '$s = <>; $n = () = ($s =~ /━━━/g); exit(($n == 1) ? 0 : 1)' \
    "$TEST_TMP/normal.typescript" || fail "未变化的顶部绿色分割线不应重复重画"
perl -0777 -e '$s = <>; exit((index($s, "\e[2;1H\e[2K") < 0) ? 0 : 1)' \
    "$TEST_TMP/normal.typescript" || fail "顶部 Tab 更新不应先清空整行"
perl -0777 -e '$s = <>; $n = () = ($s =~ /Power Switch v1\.1\.0/g); exit(($n == 5) ? 0 : 1)' \
    "$TEST_TMP/normal.typescript" || fail "标签和统计未变化时不应重复重画顶栏"
perl -0777 -e '$s = <>; $n = () = ($s =~ /Agent       接入商/g); exit(($n == 2) ? 0 : 1)' \
    "$TEST_TMP/normal.typescript" || fail "概览表头未变化时不应重复重画"
perl -0777 -e 'exit((<> =~ /\e\[21;1H.*?数据目录:.*?JSON 后端:/s) ? 0 : 1)' \
    "$TEST_TMP/normal.typescript" || fail "数据目录信息未固定到底栏"

run_tui 'kq' 24 100 "$TEST_TMP/top-boundary.typescript"
perl -0777 -e '$s = <>; $n = () = ($s =~ /\e\[7m❯ /g); exit(($n == 2) ? 0 : 1)' \
    "$TEST_TMP/top-boundary.typescript" || fail "概览首行继续上移时选中高亮不应消失"

run_tui 'jjjjq' 24 100 "$TEST_TMP/bottom-boundary.typescript"
perl -0777 -e '$s = <>; $n = () = ($s =~ /\e\[7m❯ /g); exit(($n == 5) ? 0 : 1)' \
    "$TEST_TMP/bottom-boundary.typescript" || fail "概览末行继续下移时选中高亮不应消失"

run_tui 'q' 12 60 "$TEST_TMP/small.typescript"
strip_ansi "$TEST_TMP/small.typescript" "$TEST_TMP/small.txt"
grep -q '终端空间不足' "$TEST_TMP/small.txt" || fail "小终端提示缺失"

run_tui 'q' 26 100 "$TEST_TMP/padded.typescript" 'POWER_SWITCH_PAD_X=4 POWER_SWITCH_PAD_Y=2'
strip_ansi "$TEST_TMP/padded.typescript" "$TEST_TMP/padded.txt"
grep -q '    ⚡ Power Switch v1.1.0' "$TEST_TMP/padded.txt" || fail "自定义 padding 未生效"

run_tui '2aqq' 24 100 "$TEST_TMP/form.typescript"
strip_ansi "$TEST_TMP/form.typescript" "$TEST_TMP/form.txt"
grep -q '添加接入商' "$TEST_TMP/form.txt" || fail "全屏添加表单未渲染"

run_tui '\r\r\rq' 24 100 "$TEST_TMP/protocol.typescript"
strip_ansi "$TEST_TMP/protocol.typescript" "$TEST_TMP/protocol.txt"
grep -q 'Claude 仅支持 Anthropic 协议' "$TEST_TMP/protocol.txt" || fail "Claude 协议保护未生效"

printf 'PASS: TUI padding、底栏、尺寸提示与交互流程\n'
