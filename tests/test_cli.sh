#!/usr/bin/env bash
set -u

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PSW="$ROOT_DIR/power-switch.sh"
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/psw-cli-test.XXXXXX") || exit 1

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    grep -q -- "$2" "$1" || fail "$1 中未找到: $2"
}

assert_not_contains() {
    if grep -q -- "$2" "$1"; then
        fail "$1 中不应出现: $2"
    fi
}

psw() {
    HOME="$TEST_TMP/home" \
    POWER_SWITCH_HOME="$TEST_TMP/data" \
    NO_COLOR=1 \
    "$PSW" "$@"
}

mkdir -p "$TEST_TMP/home"

psw --version > "$TEST_TMP/version.out" || fail "version 命令失败"
assert_contains "$TEST_TMP/version.out" "power-switch v1.1.0"

if psw provider add --name > "$TEST_TMP/missing.out" 2> "$TEST_TMP/missing.err"; then
    fail "缺少选项值时应返回失败"
fi
assert_contains "$TEST_TMP/missing.err" "参数 '--name' 缺少值"

psw provider add \
    --name proxy \
    --preset custom \
    --format openai \
    --base-url https://proxy.example/v1 \
    --key secret-openai \
    --model model-main \
    --small-model model-small \
    --wire-api responses > "$TEST_TMP/add-proxy.out" || fail "添加 OpenAI 接入商失败"

psw provider add \
    --name anthro \
    --preset custom \
    --format anthropic \
    --base-url https://proxy.example/anthropic \
    --key secret-anthropic \
    --model claude-main \
    --small-model claude-small > "$TEST_TMP/add-anthro.out" || fail "添加 Anthropic 接入商失败"

psw provider edit proxy --key - > "$TEST_TMP/key-clear.out" || fail "清除 Key 失败"
psw provider show proxy > "$TEST_TMP/show.out" || fail "查看接入商失败"
assert_contains "$TEST_TMP/show.out" "(未设置)"
psw provider edit proxy --key secret-openai > "$TEST_TMP/key-restore.out" || fail "恢复 Key 失败"
assert_contains "$TEST_TMP/data/env.sh" '^export PSW2_70726F7879_API_KEY='
assert_contains "$TEST_TMP/data/env.sh" '^export PSW_PROXY_API_KEY='

psw agent codex use proxy > "$TEST_TMP/codex.out" 2>&1 || fail "写入 Codex 配置失败"
psw agent opencode use proxy > "$TEST_TMP/opencode.out" 2>&1 || fail "写入 OpenCode 配置失败"
psw agent hermes use proxy > "$TEST_TMP/hermes.out" 2>&1 || fail "写入 Hermes 配置失败"
psw agent claude use anthro > "$TEST_TMP/claude-1.out" 2>&1 || fail "写入 Claude 配置失败"
psw agent claude use anthro > "$TEST_TMP/claude-2.out" 2>&1 || fail "重复写入 Claude 配置失败"

assert_contains "$TEST_TMP/home/.codex/config.toml" 'model_provider = "psw_proxy"'
assert_contains "$TEST_TMP/home/.config/opencode/opencode.json" '"@ai-sdk/openai"'
assert_contains "$TEST_TMP/home/.hermes/config.yaml" 'api_mode: "codex_responses"'
assert_contains "$TEST_TMP/home/.claude/settings.json" 'ANTHROPIC_AUTH_TOKEN'

backup_count=$(find "$TEST_TMP/home/.claude" -maxdepth 1 -name 'settings.json.psw-bak-*' | wc -l | tr -d ' ')
[ "$backup_count" -ge 3 ] || fail "同秒备份未保留，实际数量: $backup_count"

if psw agent claude use proxy < /dev/null > "$TEST_TMP/claude-protocol.out" 2> "$TEST_TMP/claude-protocol.err"; then
    fail "Claude CLI 不应接受 OpenAI 格式"
fi
assert_contains "$TEST_TMP/claude-protocol.err" "Claude Code 只支持 Anthropic"

if psw agent codex use anthro > "$TEST_TMP/protocol.out" 2> "$TEST_TMP/protocol.err"; then
    fail "Codex 不应接受 Anthropic 原生协议"
fi
assert_contains "$TEST_TMP/protocol.err" "Codex 不支持 Anthropic"

if psw agent hermes use proxy --mode env > "$TEST_TMP/mode.out" 2> "$TEST_TMP/mode.err"; then
    fail "非 Claude Agent 不应接受 --mode env"
fi
assert_contains "$TEST_TMP/mode.err" "--mode 仅适用于 Claude Code"

psw provider add \
    --name chat \
    --preset custom \
    --format openai \
    --base-url https://chat.example/v1 \
    --key secret-chat \
    --model chat-model \
    --wire-api chat > "$TEST_TMP/add-chat.out" || fail "添加 Chat 接入商失败"
psw agent opencode use chat > "$TEST_TMP/opencode-chat.out" 2>&1 || fail "写入 OpenCode Chat 配置失败"
psw agent hermes use chat > "$TEST_TMP/hermes-chat.out" 2>&1 || fail "写入 Hermes Chat 配置失败"
assert_contains "$TEST_TMP/home/.config/opencode/opencode.json" '"@ai-sdk/openai-compatible"'
assert_contains "$TEST_TMP/home/.hermes/config.yaml" 'api_mode: "chat_completions"'

psw agent opencode use anthro > "$TEST_TMP/opencode-anthro.out" 2>&1 || fail "写入 OpenCode Anthropic 配置失败"
psw agent hermes use anthro > "$TEST_TMP/hermes-anthro.out" 2>&1 || fail "写入 Hermes Anthropic 配置失败"
assert_contains "$TEST_TMP/home/.config/opencode/opencode.json" '"@ai-sdk/anthropic"'
assert_contains "$TEST_TMP/home/.hermes/config.yaml" 'api_mode: "anthropic_messages"'

psw provider add \
    --name foo-bar \
    --preset custom \
    --format openai \
    --base-url https://dash.example/v1 \
    --key dash-key \
    --model dash-model > "$TEST_TMP/add-dash.out" || fail "添加连字符名称失败"
psw provider add \
    --name foo_bar \
    --preset custom \
    --format openai \
    --base-url https://underscore.example/v1 \
    --key underscore-key \
    --model underscore-model > "$TEST_TMP/add-underscore.out" || fail "添加下划线名称失败"
assert_contains "$TEST_TMP/data/env.sh" 'PSW2_666F6F2D626172_API_KEY='
assert_contains "$TEST_TMP/data/env.sh" 'PSW2_666F6F5F626172_API_KEY='
assert_not_contains "$TEST_TMP/data/env.sh" '^export PSW_FOO_BAR_API_KEY='

psw provider add \
    --name Foo \
    --preset custom \
    --format openai \
    --base-url https://upper.example/v1 \
    --key upper-key \
    --model upper-model > "$TEST_TMP/add-upper.out" || fail "添加大写名称失败"
psw provider add \
    --name foo \
    --preset custom \
    --format openai \
    --base-url https://lower.example/v1 \
    --key lower-key \
    --model lower-model > "$TEST_TMP/add-lower.out" || fail "添加小写名称失败"
assert_contains "$TEST_TMP/data/env.sh" "PSW2_466F6F_API_KEY='upper-key'"
assert_contains "$TEST_TMP/data/env.sh" "PSW2_666F6F_API_KEY='lower-key'"
assert_not_contains "$TEST_TMP/data/env.sh" '^export PSW_FOO_API_KEY='
bash -n "$TEST_TMP/data/env.sh" || fail "生成的 env.sh 语法无效"

psw agent codex use foo-bar > "$TEST_TMP/codex-dash.out" 2>&1 || fail "应用连字符名称失败"
assert_contains "$TEST_TMP/home/.codex/config.toml" 'model_provider = "psw_foo-bar"'
psw agent codex use foo_bar > "$TEST_TMP/codex-underscore.out" 2>&1 || fail "应用下划线名称失败"
assert_contains "$TEST_TMP/home/.codex/config.toml" 'model_provider = "psw_foo_bar"'
assert_not_contains "$TEST_TMP/home/.codex/config.toml" '\[model_providers.psw_foo-bar\]'

# 恢复 proxy 为使用中状态，验证禁用提示。
psw agent codex use proxy > "$TEST_TMP/codex-restore.out" 2>&1 || fail "恢复 Codex 接入商失败"
psw provider disable proxy > "$TEST_TMP/disable.out" 2> "$TEST_TMP/disable.err" || fail "禁用接入商失败"
assert_contains "$TEST_TMP/disable.err" "不会自动失效"

psw status > "$TEST_TMP/status.out" || fail "状态总览失败"
assert_contains "$TEST_TMP/status.out" "proxy"

printf 'PASS: CLI 与四个 Agent 配置回归\n'
