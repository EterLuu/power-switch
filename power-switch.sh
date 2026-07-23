#!/usr/bin/env bash
#===============================================================================
# power-switch (psw) — AI Agent CLI 模型接入商管理工具
#
# 管理 Claude Code / Codex / OpenCode / Hermes 的模型接入商（Provider）：
#   - 接入商: 添加 / 修改 / 删除 / 启用 / 禁用 / 列表（支持 OpenAI / Anthropic 两种 API 格式）
#   - Agent : 将某个接入商应用到对应 Agent 的配置文件，或关闭（还原）
#
# 数据保存在 ${XDG_CONFIG_HOME:-~/.config}/power-switch/ 下。
# 跨平台: Linux / macOS / Windows (Git Bash / MSYS2 / Cygwin / WSL)。
# 兼容 bash 3.2+（macOS 自带 bash）。
#===============================================================================
set -u

PSW_VERSION="1.1.0"

#-------------------------------------------------------------------------------
# 基础工具
#-------------------------------------------------------------------------------

psw_uname() { uname -s 2>/dev/null || echo "Unknown"; }

is_windows() {
    case "$(psw_uname)" in
        MINGW*|MSYS*|CYGWIN*) return 0 ;;
        *) return 1 ;;
    esac
}

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'
    C_BLU=$'\033[34m'; C_CYN=$'\033[36m'; C_DIM=$'\033[2m'
    C_BOLD=$'\033[1m'; C_REV=$'\033[7m'; C_FGDF=$'\033[39m'; C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_CYN=""
    C_DIM=""; C_BOLD=""; C_REV=""; C_FGDF=""; C_RST=""
fi

info() { printf '%s[*]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s[✓]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
die()  { printf '%s[✗]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

confirm() { # confirm <提示> — 返回 0 表示确认
    local ans
    printf '%s [y/N] ' "$1" >&2
    read -r ans
    case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

upper() { printf '%s' "$1" | tr 'a-z' 'A-Z'; }

# require_option_value <选项> <剩余参数个数>
require_option_value() {
    [ "$2" -ge 2 ] || die "参数 '$1' 缺少值"
}

# disp_width <字符串> — 估算终端显示宽度（ASCII=1，多字节字符=2）
disp_width() {
    local s="$1" chars bytes
    chars=${#s}
    local LC_ALL=C
    bytes=${#s}
    printf '%d' $(( chars + (bytes - chars) / 2 ))
}

# pw <文本> <显示宽度> — 输出文本并按显示宽度右侧补空格（CJK 安全对齐）
pw() {
    local w pad
    w=$(disp_width "$1")
    printf '%s' "$1"
    pad=$(( $2 - w )); [ "$pad" -lt 0 ] && pad=0
    printf '%*s' "$pad" ''
}

# clip_text <文本> <显示宽度> — 超长时从右侧截断并添加省略号
clip_text() {
    local s="$1" max="$2" w out="" limit used=0 i=0 len ch cw
    [ "$max" -gt 0 ] || return 0
    w=$(disp_width "$s")
    if [ "$w" -le "$max" ]; then
        printf '%s' "$s"
        return 0
    fi
    limit=$((max - 1))
    [ "$limit" -lt 0 ] && limit=0
    len=${#s}
    while [ "$i" -lt "$len" ]; do
        ch=${s:$i:1}
        case "$ch" in ' '|[!-~]) cw=1 ;; *) cw=2 ;; esac
        [ $((used + cw)) -gt "$limit" ] && break
        out="$out$ch"
        used=$((used + cw))
        i=$((i+1))
    done
    printf '%s…' "$out"
}

# repeat_text <文本> <次数>
repeat_text() {
    local text="$1" count="$2" i=0
    while [ "$i" -lt "$count" ]; do
        printf '%s' "$text"
        i=$((i+1))
    done
}

# 校验接入商名称（作为文件名与 TOML/YAML 标识符使用）
valid_name() {
    case "$1" in
        *[!A-Za-z0-9_-]*|"") return 1 ;;
        *) return 0 ;;
    esac
}

# 单引号 shell 转义: a'b -> 'a'\''b'
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# TOML 双引号字符串转义
toml_str() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# YAML 双引号字符串转义
yaml_str() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# 简易 key=value 读取（不 eval，避免注入）
kv_get() { # kv_get <file> <key>
    [ -f "$1" ] || return 1
    awk -v k="$2" 'index($0, k"=")==1 { print substr($0, length(k)+2); exit }' "$1"
}

backup_file() { # backup_file <path> — 写入前备份
    [ -f "$1" ] || return 0
    local base dest i=1
    base="$1.psw-bak-$(date +%Y%m%d%H%M%S)"
    dest="$base"
    while [ -e "$dest" ]; do
        dest="$base-$i"
        i=$((i+1))
    done
    cp -p "$1" "$dest" || die "无法备份配置文件: $1"
}

atomic_mv() { # atomic_mv <tmp> <dest>
    chmod 600 "$1" 2>/dev/null
    mv -f "$1" "$2" || die "无法写入配置文件: $2"
}

mktmp() { mktemp "${TMPDIR:-/tmp}/psw.XXXXXX"; }

#-------------------------------------------------------------------------------
# 路径与目录
#-------------------------------------------------------------------------------

PSW_HOME="${POWER_SWITCH_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/power-switch}"
PROVIDERS_DIR="$PSW_HOME/providers"
STATE_DIR="$PSW_HOME/state"
ENV_DIR="$PSW_HOME/env"
ENV_FILE="$PSW_HOME/env.sh"

# Agent 配置文件路径（Windows 下这些工具同样使用 %USERPROFILE% 即 Git Bash 的 $HOME）
claude_settings()  { printf '%s' "$HOME/.claude/settings.json"; }
codex_config()     { printf '%s' "$HOME/.codex/config.toml"; }
opencode_config()  { printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json"; }
hermes_config()    { printf '%s' "$HOME/.hermes/config.yaml"; }

AGENTS="claude codex opencode hermes"

ensure_dirs() {
    mkdir -p "$PROVIDERS_DIR" "$STATE_DIR" "$ENV_DIR"
    chmod 700 "$PSW_HOME" "$PROVIDERS_DIR" "$STATE_DIR" "$ENV_DIR" 2>/dev/null
}

agent_exists() {
    case " $AGENTS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

#-------------------------------------------------------------------------------
# JSON 编辑后端: jq → python3 → node（任一可用即可）
#-------------------------------------------------------------------------------

json_backend() {
    if command -v jq      >/dev/null 2>&1; then echo "jq";      return 0; fi
    if command -v python3 >/dev/null 2>&1; then echo "python3"; return 0; fi
    if command -v node    >/dev/null 2>&1; then echo "node";    return 0; fi
    return 1
}

require_json_backend() {
    json_backend >/dev/null 2>&1 || die "编辑 JSON 配置需要 jq、python3 或 node 中的任意一个，请先安装。"
}

# json_env_merge <file> "K=V"... — 合并写入顶层 .env 对象（保留文件其余内容）
json_env_merge() {
    local file="$1"; shift
    local backend
    backend=$(json_backend) || die "编辑 JSON 配置需要 jq、python3 或 node 中的任意一个，请先安装。"
    [ -f "$file" ] || printf '{}\n' > "$file"
    backup_file "$file"
    local tmp; tmp=$(mktmp)
    case "$backend" in
        jq)
            local args=() filter='.env = (.env // {})' i=0 kv
            for kv in "$@"; do
                args+=(--arg "k$i" "${kv%%=*}" --arg "v$i" "${kv#*=}")
                filter="$filter | .env[\$k$i] = \$v$i"
                i=$((i+1))
            done
            jq "${args[@]}" "$filter" "$file" > "$tmp" || { rm -f "$tmp"; die "jq 处理 $file 失败（文件可能不是合法 JSON）"; }
            ;;
        python3)
            python3 - "$file" "$@" > "$tmp" <<'PYEOF' || { rm -f "$tmp"; die "python3 处理 $file 失败"; }
import json, sys
path, pairs = sys.argv[1], sys.argv[2:]
with open(path, encoding="utf-8") as f:
    doc = json.load(f)
env = doc.get("env")
if not isinstance(env, dict):
    env = {}
for p in pairs:
    k, _, v = p.partition("=")
    env[k] = v
doc["env"] = env
print(json.dumps(doc, indent=2, ensure_ascii=False))
PYEOF
            ;;
        node)
            node - "$file" "$@" > "$tmp" <<'JSEOF' || { rm -f "$tmp"; die "node 处理 $file 失败"; }
const fs = require("fs");
const [path, ...pairs] = process.argv.slice(2);
const doc = JSON.parse(fs.readFileSync(path, "utf8"));
if (typeof doc.env !== "object" || doc.env === null) doc.env = {};
for (const p of pairs) {
    const i = p.indexOf("=");
    doc.env[p.slice(0, i)] = p.slice(i + 1);
}
console.log(JSON.stringify(doc, null, 2));
JSEOF
            ;;
    esac
    atomic_mv "$tmp" "$file"
}

# json_env_delete <file> <key>... — 删除顶层 .env 中的指定键
json_env_delete() {
    local file="$1"; shift
    [ -f "$file" ] || return 0
    local backend
    backend=$(json_backend) || die "编辑 JSON 配置需要 jq、python3 或 node 中的任意一个，请先安装。"
    backup_file "$file"
    local tmp; tmp=$(mktmp)
    case "$backend" in
        jq)
            local args=() filter='.' i=0 k
            for k in "$@"; do
                args+=(--arg "k$i" "$k")
                filter="$filter | del(.env[\$k$i])"
                i=$((i+1))
            done
            jq "${args[@]}" "$filter" "$file" > "$tmp" || { rm -f "$tmp"; die "jq 处理 $file 失败"; }
            ;;
        python3)
            python3 - "$file" "$@" > "$tmp" <<'PYEOF' || { rm -f "$tmp"; die "python3 处理 $file 失败"; }
import json, sys
path, keys = sys.argv[1], sys.argv[2:]
with open(path, encoding="utf-8") as f:
    doc = json.load(f)
env = doc.get("env")
if isinstance(env, dict):
    for k in keys:
        env.pop(k, None)
print(json.dumps(doc, indent=2, ensure_ascii=False))
PYEOF
            ;;
        node)
            node - "$file" "$@" > "$tmp" <<'JSEOF' || { rm -f "$tmp"; die "node 处理 $file 失败"; }
const fs = require("fs");
const [path, ...keys] = process.argv.slice(2);
const doc = JSON.parse(fs.readFileSync(path, "utf8"));
if (doc.env) for (const k of keys) delete doc.env[k];
console.log(JSON.stringify(doc, null, 2));
JSEOF
            ;;
    esac
    atomic_mv "$tmp" "$file"
}

# opencode_apply <file> <provider_id> <npm包> <显示名> <base_url> <api_key> <model>
opencode_apply() {
    local file="$1" pid="$2" npm="$3" disp="$4" bu="$5" ak="$6" model="$7"
    local backend
    backend=$(json_backend) || die "编辑 JSON 配置需要 jq、python3 或 node 中的任意一个，请先安装。"
    if [ ! -f "$file" ]; then
        mkdir -p "$(dirname "$file")"
        printf '{\n  "$schema": "https://opencode.ai/config.json"\n}\n' > "$file"
    fi
    backup_file "$file"
    local tmp; tmp=$(mktmp)
    case "$backend" in
        jq)
            jq --arg n "$pid" --arg npm "$npm" --arg disp "$disp" \
               --arg bu "$bu" --arg ak "$ak" --arg m "$model" '
                .provider[$n] = {
                    npm: $npm,
                    name: $disp,
                    options: { baseURL: $bu, apiKey: $ak },
                    models: { ($m): { name: $m } }
                }
                | .model = ($n + "/" + $m)
            ' "$file" > "$tmp" || { rm -f "$tmp"; die "jq 处理 $file 失败"; }
            ;;
        python3)
            python3 - "$file" "$pid" "$npm" "$disp" "$bu" "$ak" "$model" > "$tmp" <<'PYEOF' || { rm -f "$tmp"; die "python3 处理 $file 失败"; }
import json, sys
path, pid, npm, disp, bu, ak, m = sys.argv[1:8]
with open(path, encoding="utf-8") as f:
    doc = json.load(f)
prov = doc.setdefault("provider", {})
prov[pid] = {
    "npm": npm,
    "name": disp,
    "options": {"baseURL": bu, "apiKey": ak},
    "models": {m: {"name": m}},
}
doc["model"] = pid + "/" + m
print(json.dumps(doc, indent=2, ensure_ascii=False))
PYEOF
            ;;
        node)
            node - "$file" "$pid" "$npm" "$disp" "$bu" "$ak" "$model" > "$tmp" <<'JSEOF' || { rm -f "$tmp"; die "node 处理 $file 失败"; }
const fs = require("fs");
const [path, pid, npm, disp, bu, ak, m] = process.argv.slice(2);
const doc = JSON.parse(fs.readFileSync(path, "utf8"));
doc.provider = doc.provider || {};
doc.provider[pid] = {
    npm, name: disp,
    options: { baseURL: bu, apiKey: ak },
    models: { [m]: { name: m } },
};
doc.model = pid + "/" + m;
console.log(JSON.stringify(doc, null, 2));
JSEOF
            ;;
    esac
    atomic_mv "$tmp" "$file"
}

# opencode_off <file> <provider_id>
opencode_off() {
    local file="$1" pid="$2"
    [ -f "$file" ] || return 0
    local backend
    backend=$(json_backend) || die "编辑 JSON 配置需要 jq、python3 或 node 中的任意一个，请先安装。"
    backup_file "$file"
    local tmp; tmp=$(mktmp)
    case "$backend" in
        jq)
            jq --arg n "$pid" '
                del(.provider[$n])
                | if ((.model // "") | startswith($n + "/")) then del(.model) else . end
            ' "$file" > "$tmp" || { rm -f "$tmp"; die "jq 处理 $file 失败"; }
            ;;
        python3)
            python3 - "$file" "$pid" > "$tmp" <<'PYEOF' || { rm -f "$tmp"; die "python3 处理 $file 失败"; }
import json, sys
path, pid = sys.argv[1:3]
with open(path, encoding="utf-8") as f:
    doc = json.load(f)
if isinstance(doc.get("provider"), dict):
    doc["provider"].pop(pid, None)
if str(doc.get("model", "")).startswith(pid + "/"):
    doc.pop("model", None)
print(json.dumps(doc, indent=2, ensure_ascii=False))
PYEOF
            ;;
        node)
            node - "$file" "$pid" > "$tmp" <<'JSEOF' || { rm -f "$tmp"; die "node 处理 $file 失败"; }
const fs = require("fs");
const [path, pid] = process.argv.slice(2);
const doc = JSON.parse(fs.readFileSync(path, "utf8"));
if (doc.provider) delete doc.provider[pid];
if (String(doc.model || "").startsWith(pid + "/")) delete doc.model;
console.log(JSON.stringify(doc, null, 2));
JSEOF
            ;;
    esac
    atomic_mv "$tmp" "$file"
}

#-------------------------------------------------------------------------------
# 接入商（Provider）存储: 每接入商一个 key=value 文件
#-------------------------------------------------------------------------------

P_NAME=""; P_FORMAT=""; P_BASE_URL=""; P_API_KEY=""
P_MODEL=""; P_SMALL_MODEL=""; P_WIRE_API=""; P_ENABLED=""

provider_file() { printf '%s/%s' "$PROVIDERS_DIR" "$1"; }

provider_exists() { [ -f "$(provider_file "$1")" ]; }

provider_load() { # provider_load <name>
    local f; f=$(provider_file "$1")
    [ -f "$f" ] || return 1
    P_NAME="$1"
    P_FORMAT=$(kv_get "$f" FORMAT)
    P_BASE_URL=$(kv_get "$f" BASE_URL)
    P_API_KEY=$(kv_get "$f" API_KEY)
    P_MODEL=$(kv_get "$f" MODEL)
    P_SMALL_MODEL=$(kv_get "$f" SMALL_MODEL)
    P_WIRE_API=$(kv_get "$f" WIRE_API)
    P_ENABLED=$(kv_get "$f" ENABLED)
    : "${P_FORMAT:=openai}" "${P_WIRE_API:=responses}" "${P_ENABLED:=1}"
    : "${P_SMALL_MODEL:=$P_MODEL}"
    return 0
}

provider_save() { # 使用当前 P_* 变量保存
    ensure_dirs
    local f; f=$(provider_file "$P_NAME")
    local tmp; tmp=$(mktmp)
    {
        printf 'FORMAT=%s\n'     "$P_FORMAT"
        printf 'BASE_URL=%s\n'   "$P_BASE_URL"
        printf 'API_KEY=%s\n'    "$P_API_KEY"
        printf 'MODEL=%s\n'      "$P_MODEL"
        printf 'SMALL_MODEL=%s\n' "$P_SMALL_MODEL"
        printf 'WIRE_API=%s\n'   "$P_WIRE_API"
        printf 'ENABLED=%s\n'    "$P_ENABLED"
    } > "$tmp"
    atomic_mv "$tmp" "$f"
}

provider_list_names() {
    [ -d "$PROVIDERS_DIR" ] || return 0
    local f
    for f in "$PROVIDERS_DIR"/*; do
        [ -f "$f" ] || continue
        basename "$f"
    done
}

# 接入商环境变量名（Codex env_key 等使用）。
# 将合法的 ASCII 名称逐字节编码为十六进制，避免 foo-bar、foo_bar、Foo、foo
# 等名称在区分或不区分环境变量大小写的平台上发生碰撞。
provider_env_key() {
    local s="$1" out="" i=0 len ch hex
    len=${#s}
    while [ "$i" -lt "$len" ]; do
        ch=${s:$i:1}
        hex=$(printf '%02X' "'$ch")
        out="${out}${hex}"
        i=$((i+1))
    done
    printf 'PSW2_%s_API_KEY' "$out"
}

# 1.0.x 使用的旧环境变量名，仅用于为无歧义名称生成迁移兼容别名。
provider_legacy_env_key() {
    printf 'PSW_%s_API_KEY' "$(upper "$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/_/g')")"
}

# Codex 内 provider id: psw_<name>
provider_codex_id() {
    # valid_name 已保证名称只含 TOML bare-key 允许的字符，直接保留即可避免碰撞。
    printf 'psw_%s' "$1"
}

# 重新生成 env.sh（导出所有接入商的 key 环境变量 + source agent env 文件）
# 注意: 内部会调用 provider_load，先保存当前 P_* 现场再恢复
regen_env_file() {
    ensure_dirs
    local sP_NAME="$P_NAME" sP_FORMAT="$P_FORMAT" sP_BASE_URL="$P_BASE_URL" \
          sP_API_KEY="$P_API_KEY" sP_MODEL="$P_MODEL" sP_SMALL_MODEL="$P_SMALL_MODEL" \
          sP_WIRE_API="$P_WIRE_API" sP_ENABLED="$P_ENABLED"
    local tmp; tmp=$(mktmp)
    {
        printf '# 由 power-switch 自动生成，请勿手改 (v%s)\n' "$PSW_VERSION"
        local names=() n m api_key env_key legacy_key legacy_count
        for n in $(provider_list_names); do names+=("$n"); done
        for n in "${names[@]}"; do
            provider_load "$n" || continue
            [ -n "$P_API_KEY" ] || continue
            api_key="$P_API_KEY"
            env_key=$(provider_env_key "$n")
            legacy_key=$(provider_legacy_env_key "$n")
            printf 'export %s=%s\n' "$env_key" "$(shq "$api_key")"
            if [ "$legacy_key" != "$env_key" ]; then
                legacy_count=0
                for m in "${names[@]}"; do
                    [ "$(provider_legacy_env_key "$m")" = "$legacy_key" ] && \
                        legacy_count=$((legacy_count+1))
                done
                if [ "$legacy_count" -eq 1 ]; then
                    printf 'export %s=%s # 兼容 power-switch 1.0.x\n' \
                        "$legacy_key" "$(shq "$api_key")"
                else
                    printf '# 未生成有歧义的旧变量名: %s\n' "$legacy_key"
                fi
            fi
        done
        local e
        for e in "$ENV_DIR"/*.sh; do
            [ -f "$e" ] || continue
            printf '[ -f %s ] && . %s\n' "$(shq "$e")" "$(shq "$e")"
        done
    } > "$tmp"
    atomic_mv "$tmp" "$ENV_FILE"
    P_NAME="$sP_NAME" P_FORMAT="$sP_FORMAT" P_BASE_URL="$sP_BASE_URL" \
    P_API_KEY="$sP_API_KEY" P_MODEL="$sP_MODEL" P_SMALL_MODEL="$sP_SMALL_MODEL" \
    P_WIRE_API="$sP_WIRE_API" P_ENABLED="$sP_ENABLED"
}

#-------------------------------------------------------------------------------
# 预设接入商模板: preset_get <preset> <format> <field(base_url|model|small_model)>
#-------------------------------------------------------------------------------

PRESETS="deepseek kimi glm huawei openai anthropic openrouter ollama local"

preset_get() {
    local preset="$1" fmt="$2" field="$3"
    case "$preset" in
        deepseek)
            case "$field" in
                base_url)    [ "$fmt" = anthropic ] && echo "https://api.deepseek.com/anthropic" || echo "https://api.deepseek.com/v1" ;;
                model)       echo "deepseek-chat" ;;
                small_model) echo "deepseek-chat" ;;
            esac ;;
        kimi)
            case "$field" in
                base_url)    [ "$fmt" = anthropic ] && echo "https://api.moonshot.cn/anthropic" || echo "https://api.moonshot.cn/v1" ;;
                model)       echo "kimi-k2" ;;
                small_model) echo "kimi-k2" ;;
            esac ;;
        glm)
            case "$field" in
                base_url)    [ "$fmt" = anthropic ] && echo "https://open.bigmodel.cn/api/anthropic" || echo "https://open.bigmodel.cn/api/paas/v4" ;;
                model)       echo "glm-4.6" ;;
                small_model) echo "glm-4.5-air" ;;
            esac ;;
        huawei)
            case "$field" in
                base_url)    echo "https://api.modelarts-maas.com/anthropic" ;;
                model)       echo "glm-5.2" ;;
                small_model) echo "glm-5.2" ;;
            esac ;;
        openai)
            case "$field" in
                base_url)    echo "https://api.openai.com/v1" ;;
                model)       echo "gpt-5" ;;
                small_model) echo "gpt-5-mini" ;;
            esac ;;
        anthropic)
            case "$field" in
                base_url)    echo "https://api.anthropic.com" ;;
                model)       echo "claude-sonnet-4-5" ;;
                small_model) echo "claude-haiku-4-5" ;;
            esac ;;
        openrouter)
            case "$field" in
                base_url)    echo "https://openrouter.ai/api/v1" ;;
                model)       echo "anthropic/claude-sonnet-4-5" ;;
                small_model) echo "anthropic/claude-haiku-4-5" ;;
            esac ;;
        ollama)
            case "$field" in
                base_url)    echo "http://localhost:11434/v1" ;;
                model)       echo "qwen3-coder" ;;
                small_model) echo "qwen3-coder" ;;
            esac ;;
        local)
            case "$field" in
                base_url)    echo "http://localhost:4000" ;;
                model)       echo "" ;;
                small_model) echo "" ;;
            esac ;;
        *) return 1 ;;
    esac
}

#-------------------------------------------------------------------------------
# 接入商命令
#-------------------------------------------------------------------------------

cmd_provider_list() {
    ensure_dirs
    local names; names=$(provider_list_names)
    if [ -z "$names" ]; then
        info "暂无接入商。使用 'psw provider add' 添加。"
        return 0
    fi
    printf '%s' "$C_BOLD$C_CYN"
    pw "名称" 16; printf ' '; pw "格式" 11; printf '    '; pw "BASE URL" 44; printf ' %s' "MODEL"
    printf '%s\n' "$C_RST"
    local n
    for n in $names; do
        provider_load "$n" || continue
        local badge
        if [ "$P_ENABLED" = "1" ]; then badge="${C_GRN}●${C_FGDF}"; else badge="${C_DIM}○${C_FGDF}"; fi
        local bu="$P_BASE_URL"
        [ ${#bu} -gt 44 ] && bu="${bu:0:41}..."
        local line; line=$(printf '%-16s %-11s %s  %-44s %s' "$n" "$P_FORMAT" "$badge" "$bu" "$P_MODEL")
        if [ "$P_ENABLED" = "1" ]; then printf '%s\n' "$line"; else printf '%s%s%s\n' "$C_DIM" "$line" "$C_RST"; fi
    done
}

cmd_provider_show() {
    local name="$1"
    provider_load "$name" || die "接入商 '$name' 不存在"
    local masked="(未设置)"
    if [ -n "$P_API_KEY" ]; then
        if [ ${#P_API_KEY} -gt 8 ]; then
            local klen=${#P_API_KEY}
            masked="${P_API_KEY:0:4}...${P_API_KEY:$((klen-4)):4}"
        else
            masked="****"
        fi
    fi
    local st_badge
    if [ "$P_ENABLED" = "1" ]; then
        st_badge="${C_GRN}● 启用${C_RST}"
    else
        st_badge="${C_DIM}○ 禁用${C_RST}"
    fi
    printf '%s\n' "${C_BOLD}${C_CYN}┌─ $P_NAME ${C_DIM}($P_FORMAT)${C_RST}"
    printf '%s %s %s\n' "${C_CYN}│${C_RST}" "$(pw "Base URL" 12)" "$P_BASE_URL"
    printf '%s %s %s\n' "${C_CYN}│${C_RST}" "$(pw "API Key" 12)" "$masked"
    printf '%s %s %s\n' "${C_CYN}│${C_RST}" "$(pw "主模型" 12)" "$P_MODEL"
    printf '%s %s %s\n' "${C_CYN}│${C_RST}" "$(pw "小/快模型" 12)" "$P_SMALL_MODEL"
    printf '%s %s %s\n' "${C_CYN}│${C_RST}" "$(pw "OpenAI API" 12)" "$P_WIRE_API"
    printf '%s %s %b\n' "${C_CYN}│${C_RST}" "$(pw "状态" 12)" "$st_badge"
    printf '%s %s %s\n' "${C_CYN}│${C_RST}" "$(pw "环境变量" 12)" "$(provider_env_key "$name")"
    printf '%s\n' "${C_CYN}└─${C_RST}"
}

# cmd_provider_add — 交互 + 参数混合模式
cmd_provider_add() {
    ensure_dirs
    local name="" preset="" format="" base_url="" api_key="" model="" small_model="" wire_api="responses"
    while [ $# -gt 0 ]; do
        case "$1" in
            --name|--preset|--format|--base-url|--key|--model|--small-model|--wire-api)
                require_option_value "$1" "$#"
                ;;
        esac
        case "$1" in
            --name)       name="$2"; shift 2 ;;
            --preset)     preset="$2"; shift 2 ;;
            --format)     format="$2"; shift 2 ;;
            --base-url)   base_url="$2"; shift 2 ;;
            --key)        api_key="$2"; shift 2 ;;
            --model)      model="$2"; shift 2 ;;
            --small-model) small_model="$2"; shift 2 ;;
            --wire-api)   wire_api="$2"; shift 2 ;;
            *) die "未知参数: $1" ;;
        esac
    done
    case "$wire_api" in responses|chat) ;; *) die "wire_api 必须是 responses 或 chat" ;; esac

    # 名称
    if [ -z "$name" ]; then
        [ -t 0 ] || die "非交互模式必须提供 --name"
        while true; do
            printf '接入商名称 (字母/数字/-/_，留空取消): ' >&2; read -r name
            [ -z "$name" ] && { info "已取消添加"; return 0; }
            if ! valid_name "$name"; then
                warn "名称 '$name' 不合法，请重新输入"
            elif provider_exists "$name"; then
                warn "接入商 '$name' 已存在，请换个名称"
            else
                break
            fi
        done
    fi
    valid_name "$name" || die "名称 '$name' 不合法"
    provider_exists "$name" && die "接入商 '$name' 已存在（用 'psw provider edit $name' 修改）"

    # 预设
    if [ -z "$preset" ] && [ -t 0 ]; then
        cat >&2 <<EOF
可选预设（自动填充 Base URL 与模型）:
  deepseek    DeepSeek (openai + anthropic 双格式)
  kimi        月之暗面 Kimi (openai + anthropic 双格式)
  glm         智谱 GLM (openai + anthropic 双格式)
  huawei      华为 ModelArts (anthropic 格式)
  openai      OpenAI 官方
  anthropic   Anthropic 官方
  openrouter  OpenRouter (openai 格式)
  ollama      本地 Ollama (openai 格式)
  local       本地网关 (LiteLLM/One-API 等)
  custom      自定义
EOF
        printf '选择预设 [custom]: ' >&2; read -r preset
    fi
    : "${preset:=custom}"
    [ "$preset" = "custom" ] || {
        case " $PRESETS " in *" $preset "*) ;; *) die "未知预设: $preset" ;; esac
    }

    # 格式
    if [ -z "$format" ]; then
        local default_fmt="openai"
        if [ "$preset" = "huawei" ] || [ "$preset" = "anthropic" ]; then default_fmt="anthropic"; fi
        if [ -t 0 ]; then
            printf 'API 格式 (openai/anthropic) [%s]: ' "$default_fmt" >&2; read -r format
        fi
        : "${format:=$default_fmt}"
    fi
    case "$format" in openai|anthropic) ;; *) die "格式必须是 openai 或 anthropic" ;; esac

    # Base URL
    local preset_bu=""
    [ "$preset" != "custom" ] && preset_bu=$(preset_get "$preset" "$format" base_url)
    if [ -z "$base_url" ]; then
        if [ -t 0 ]; then
            if [ -n "$preset_bu" ]; then
                printf 'Base URL [%s]: ' "$preset_bu" >&2; read -r base_url
            else
                printf 'Base URL: ' >&2; read -r base_url
            fi
        fi
        : "${base_url:=$preset_bu}"
    fi
    [ -n "$base_url" ] || die "Base URL 不能为空（非交互模式请提供 --base-url）"

    # API Key（隐藏输入）
    if [ -z "$api_key" ] && [ -t 0 ]; then
        printf 'API Key (输入不显示，可留空): ' >&2
        read -r -s api_key; printf '\n' >&2
    fi

    # 模型
    local preset_m="" preset_sm=""
    if [ "$preset" != "custom" ]; then
        preset_m=$(preset_get "$preset" "$format" model)
        preset_sm=$(preset_get "$preset" "$format" small_model)
    fi
    if [ -z "$model" ]; then
        if [ -t 0 ]; then
            printf '主模型 [%s]: ' "${preset_m:-必填}" >&2; read -r model
        fi
        : "${model:=$preset_m}"
    fi
    [ -n "$model" ] || die "主模型不能为空（非交互模式请提供 --model）"
    if [ -z "$small_model" ]; then
        if [ -t 0 ]; then
            printf '小/快模型 [%s]: ' "${preset_sm:-$model}" >&2; read -r small_model
        fi
        : "${small_model:=${preset_sm:-$model}}"
    fi

    P_NAME="$name"; P_FORMAT="$format"; P_BASE_URL="$base_url"; P_API_KEY="$api_key"
    P_MODEL="$model"; P_SMALL_MODEL="$small_model"; P_WIRE_API="$wire_api"; P_ENABLED="1"
    provider_save
    regen_env_file
    ok "接入商 '$name' 已保存"
    cmd_provider_show "$name"
}

cmd_provider_edit() {
    local name="$1"; shift
    provider_load "$name" || die "接入商 '$name' 不存在"
    local changed=0
    if [ $# -eq 0 ]; then
        # 交互模式：回车保留原值
        local v
        printf 'Base URL [%s]: ' "$P_BASE_URL" >&2; read -r v
        [ -n "$v" ] && P_BASE_URL="$v" changed=1
        printf 'API Key [保持不变，输入 - 清除] (隐藏): ' >&2; read -r -s v; printf '\n' >&2
        if [ "$v" = "-" ]; then P_API_KEY=""; changed=1
        elif [ -n "$v" ]; then P_API_KEY="$v"; changed=1; fi
        printf '主模型 [%s]: ' "$P_MODEL" >&2; read -r v
        [ -n "$v" ] && P_MODEL="$v" changed=1
        printf '小/快模型 [%s]: ' "$P_SMALL_MODEL" >&2; read -r v
        [ -n "$v" ] && P_SMALL_MODEL="$v" changed=1
        printf 'API 格式 (openai/anthropic) [%s]: ' "$P_FORMAT" >&2; read -r v
        if [ -n "$v" ]; then
            case "$v" in openai|anthropic) P_FORMAT="$v"; changed=1 ;; *) die "格式必须是 openai 或 anthropic" ;; esac
        fi
        printf 'OpenAI wire_api (responses/chat) [%s]: ' "$P_WIRE_API" >&2; read -r v
        if [ -n "$v" ]; then
            case "$v" in responses|chat) P_WIRE_API="$v"; changed=1 ;; *) die "wire_api 必须是 responses 或 chat" ;; esac
        fi
    else
        while [ $# -gt 0 ]; do
            case "$1" in
                --format|--base-url|--key|--model|--small-model|--wire-api)
                    require_option_value "$1" "$#"
                    ;;
            esac
            case "$1" in
                --format)      case "$2" in openai|anthropic) P_FORMAT="$2" ;; *) die "格式必须是 openai 或 anthropic" ;; esac; shift 2 ;;
                --base-url)    P_BASE_URL="$2"; shift 2 ;;
                --key)         if [ "$2" = "-" ]; then P_API_KEY=""; else P_API_KEY="$2"; fi; shift 2 ;;
                --model)       P_MODEL="$2"; shift 2 ;;
                --small-model) P_SMALL_MODEL="$2"; shift 2 ;;
                --wire-api)    case "$2" in responses|chat) P_WIRE_API="$2" ;; *) die "wire_api 必须是 responses 或 chat" ;; esac; shift 2 ;;
                *) die "未知参数: $1" ;;
            esac
            changed=1
        done
    fi
    if [ "$changed" = "1" ]; then
        provider_save
        regen_env_file
        ok "接入商 '$name' 已更新"
        # 若有 agent 正在使用，提醒重新应用
        local a st_prov
        for a in $AGENTS; do
            st_prov=$(kv_get "$STATE_DIR/$a" PROVIDER 2>/dev/null || true)
            if [ "$st_prov" = "$name" ]; then
                warn "Agent '$a' 正在使用该接入商，请重新应用: psw agent $a use $name"
            fi
        done
    else
        info "未做任何修改"
    fi
}

cmd_provider_remove() {
    local name="$1"
    provider_exists "$name" || die "接入商 '$name' 不存在"
    local a st_prov inuse=""
    for a in $AGENTS; do
        st_prov=$(kv_get "$STATE_DIR/$a" PROVIDER 2>/dev/null || true)
        [ "$st_prov" = "$name" ] && inuse="$inuse $a"
    done
    if [ -n "$inuse" ]; then
        warn "接入商正被以下 Agent 使用:$inuse"
        warn "删除前请先执行: psw agent <agent> off"
        die "已取消删除"
    fi
    confirm "确认删除接入商 '$name'?" || { info "已取消"; return 0; }
    rm -f "$(provider_file "$name")"
    regen_env_file
    ok "接入商 '$name' 已删除"
}

cmd_provider_enable() {
    local name="$1" val="$2"
    provider_load "$name" || die "接入商 '$name' 不存在"
    P_ENABLED="$val"
    provider_save
    regen_env_file
    if [ "$val" = "1" ]; then
        ok "接入商 '$name' 已启用"
    else
        local a active=""
        for a in $AGENTS; do
            [ "$(kv_get "$STATE_DIR/$a" PROVIDER 2>/dev/null || true)" = "$name" ] && active="$active $a"
        done
        [ -n "$active" ] && warn "已应用到以下 Agent 的配置不会自动失效:$active"
        ok "接入商 '$name' 已禁用"
    fi
}

#-------------------------------------------------------------------------------
# Agent 适配器
#-------------------------------------------------------------------------------

# ---- Claude Code: ~/.claude/settings.json 的 env（settings 模式）或 env 文件 ----

CLAUDE_ENV_KEYS="ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL"

agent_apply_claude() { # 需已 provider_load；$1 = mode (settings|env)
    local mode="$1"
    [ "$P_FORMAT" = "anthropic" ] || \
        die "Claude Code 只支持 Anthropic Messages 协议；请使用 anthropic 格式接入商或协议转换网关"
    case "$mode" in
        settings)
            require_json_backend
            local cfg; cfg=$(claude_settings)
            mkdir -p "$(dirname "$cfg")"
            # 先清掉 ANTHROPIC_API_KEY 避免与 AUTH_TOKEN 冲突，再写入
            json_env_delete "$cfg" ANTHROPIC_API_KEY
            json_env_merge "$cfg" \
                "ANTHROPIC_BASE_URL=$P_BASE_URL" \
                "ANTHROPIC_AUTH_TOKEN=$P_API_KEY" \
                "ANTHROPIC_MODEL=$P_MODEL" \
                "ANTHROPIC_SMALL_FAST_MODEL=$P_SMALL_MODEL"
            ok "已写入 $cfg (env)，重启 Claude Code 后生效"
            ;;
        env)
            ensure_dirs
            local f="$ENV_DIR/claude.sh"
            local tmp; tmp=$(mktmp)
            {
                printf '# Claude Code 环境变量 — 由 power-switch 生成\n'
                printf 'export ANTHROPIC_BASE_URL=%s\n'        "$(shq "$P_BASE_URL")"
                printf 'export ANTHROPIC_AUTH_TOKEN=%s\n'       "$(shq "$P_API_KEY")"
                printf 'export ANTHROPIC_MODEL=%s\n'            "$(shq "$P_MODEL")"
                printf 'export ANTHROPIC_SMALL_FAST_MODEL=%s\n' "$(shq "$P_SMALL_MODEL")"
            } > "$tmp"
            atomic_mv "$tmp" "$f"
            regen_env_file
            ok "已生成 $f"
            info "请确保 shell 启动文件 source 了 $ENV_FILE （可运行: psw install-shell）"
            ;;
        *) die "未知模式: $mode (settings|env)" ;;
    esac
}

agent_off_claude() {
    local cfg; cfg=$(claude_settings)
    if [ -f "$cfg" ] && json_backend >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        json_env_delete "$cfg" $CLAUDE_ENV_KEYS
        ok "已从 $cfg 移除 power-switch 管理的 env 配置"
    fi
    rm -f "$ENV_DIR/claude.sh"
    regen_env_file
}

# ---- Codex: ~/.codex/config.toml ----

# 删除 codex 配置中由 power-switch 管理的部分（psw_* provider 段 + 顶层 model/model_provider）
codex_strip_managed() { # codex_strip_managed <file> — 输出到 stdout
    awk '
        /^\[model_providers\.psw_[A-Za-z0-9_-]+\][ \t]*$/ { inprov=1; next }
        /^\[/ { sect="other"; inprov=0; print; next }
        inprov { next }
        sect!="other" && /^[ \t]*model[ \t]*=/          { next }
        sect!="other" && /^[ \t]*model_provider[ \t]*=/ { next }
        { print }
    ' "$1"
}

agent_apply_codex() {
    [ "$P_FORMAT" = "openai" ] || die "Codex 不支持 Anthropic 原生协议，请使用 OpenAI Responses 兼容端点"
    local cfg; cfg=$(codex_config)
    mkdir -p "$(dirname "$cfg")"
    [ -f "$cfg" ] || : > "$cfg"
    backup_file "$cfg"
    if [ "$P_WIRE_API" = "responses" ]; then
        info "wire_api=responses：Base URL 需支持 OpenAI Responses API (/responses)"
    else
        warn "wire_api=chat 仅兼容旧版 Codex；当前版本只接受 responses"
    fi
    local prov_id envk
    prov_id=$(provider_codex_id "$P_NAME")
    envk=$(provider_env_key "$P_NAME")
    local tmp stripped; tmp=$(mktmp); stripped=$(mktmp)
    codex_strip_managed "$cfg" > "$stripped"
    {
        # 顶层键必须在任何 [section] 之前
        printf 'model = "%s"\n'          "$(toml_str "$P_MODEL")"
        printf 'model_provider = "%s"\n' "$(toml_str "$prov_id")"
        printf '\n'
        cat "$stripped"
        # 去掉文件末尾多余空行后再追加 provider 段
        printf '\n[model_providers.%s]\n' "$prov_id"
        printf 'name = "%s"\n'        "$(toml_str "$P_NAME (power-switch)")"
        printf 'base_url = "%s"\n'    "$(toml_str "$P_BASE_URL")"
        printf 'env_key = "%s"\n'     "$(toml_str "$envk")"
        printf 'wire_api = "%s"\n'    "$(toml_str "$P_WIRE_API")"
    } | awk 'NF{b=0; print; next} !b{b=1; print}' > "$tmp"
    rm -f "$stripped"
    atomic_mv "$tmp" "$cfg"
    regen_env_file
    ok "已写入 $cfg (provider: $prov_id)"
    warn "Codex 通过环境变量 $envk 读取 API Key，请确保 shell 已 source $ENV_FILE"
    info "可运行 'psw install-shell' 自动配置，或手动: export $envk=<your-key>"
}

agent_off_codex() {
    local cfg; cfg=$(codex_config)
    if [ -f "$cfg" ]; then
        backup_file "$cfg"
        local tmp; tmp=$(mktmp)
        codex_strip_managed "$cfg" > "$tmp"
        atomic_mv "$tmp" "$cfg"
        ok "已从 $cfg 移除 power-switch 管理的配置"
    fi
}

# ---- OpenCode: ~/.config/opencode/opencode.json ----

agent_apply_opencode() {
    require_json_backend
    local cfg; cfg=$(opencode_config)
    local npm="@ai-sdk/openai-compatible"
    if [ "$P_FORMAT" = "anthropic" ]; then
        npm="@ai-sdk/anthropic"
    elif [ "$P_WIRE_API" = "responses" ]; then
        npm="@ai-sdk/openai"
    fi
    opencode_apply "$cfg" "$P_NAME" "$npm" "$P_NAME" "$P_BASE_URL" "$P_API_KEY" "$P_MODEL"
    ok "已写入 $cfg (provider: $P_NAME, npm: $npm)，当前模型: $P_NAME/$P_MODEL"
}

agent_off_opencode() {
    local cfg; cfg=$(opencode_config)
    local pid=""
    pid=$(kv_get "$STATE_DIR/opencode" PROVIDER 2>/dev/null || true)
    [ -z "$pid" ] && pid="$P_NAME"
    [ -n "$pid" ] && opencode_off "$cfg" "$pid"
    ok "已从 $cfg 移除 provider '$pid'"
}

# ---- Hermes: ~/.hermes/config.yaml ----

hermes_strip_managed() { # 移除顶层 model: 映射块，输出到 stdout
    awk '
        /^model:[ \t]*$/      { inm=1; next }
        inm && /^[^ \t#]/     { inm=0 }
        inm                   { next }
        { print }
    ' "$1"
}

agent_apply_hermes() {
    local cfg; cfg=$(hermes_config)
    mkdir -p "$(dirname "$cfg")"
    [ -f "$cfg" ] || : > "$cfg"
    backup_file "$cfg"
    local tmp api_mode="chat_completions"; tmp=$(mktmp)
    if [ "$P_FORMAT" = "anthropic" ]; then
        api_mode="anthropic_messages"
    elif [ "$P_WIRE_API" = "responses" ]; then
        api_mode="codex_responses"
    fi
    {
        hermes_strip_managed "$cfg"
        # 去除尾部空行
        printf 'model:\n'
        printf '  default: "%s"\n'  "$(yaml_str "$P_MODEL")"
        printf '  provider: custom\n'
        printf '  base_url: "%s"\n' "$(yaml_str "$P_BASE_URL")"
        printf '  api_key: "%s"\n'  "$(yaml_str "$P_API_KEY")"
        printf '  api_mode: "%s"\n' "$api_mode"
    } > "$tmp"
    atomic_mv "$tmp" "$cfg"
    ok "已写入 $cfg (model.default=$P_MODEL, base_url=$P_BASE_URL)"
    info "也可用 'hermes model' 交互式确认切换"
}

agent_off_hermes() {
    local cfg; cfg=$(hermes_config)
    if [ -f "$cfg" ]; then
        backup_file "$cfg"
        local tmp; tmp=$(mktmp)
        hermes_strip_managed "$cfg" > "$tmp"
        atomic_mv "$tmp" "$cfg"
        ok "已从 $cfg 移除 power-switch 管理的 model 配置"
    fi
}

#-------------------------------------------------------------------------------
# Agent 命令
#-------------------------------------------------------------------------------

state_save() { # state_save <agent> <provider> <mode>
    ensure_dirs
    {
        printf 'PROVIDER=%s\n' "$2"
        printf 'MODE=%s\n' "$3"
        printf 'APPLIED_AT=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$STATE_DIR/$1"
    chmod 600 "$STATE_DIR/$1" 2>/dev/null
}

cmd_agent_use() {
    local agent="$1" provider="$2"; shift 2
    local mode="settings" model_ov="" small_ov=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --mode|--model|--small-model) require_option_value "$1" "$#" ;;
        esac
        case "$1" in
            --mode)        mode="$2"; shift 2 ;;
            --model)       model_ov="$2"; shift 2 ;;
            --small-model) small_ov="$2"; shift 2 ;;
            *) die "未知参数: $1" ;;
        esac
    done
    case "$mode" in settings|env) ;; *) die "模式必须是 settings 或 env" ;; esac
    agent_exists "$agent" || die "未知 Agent: $agent (支持: $AGENTS)"
    [ "$agent" = "claude" ] || [ "$mode" = "settings" ] || die "--mode 仅适用于 Claude Code"
    provider_load "$provider" || die "接入商 '$provider' 不存在，先用 'psw provider add' 添加"
    if [ "$P_ENABLED" != "1" ]; then
        die "接入商 '$provider' 已禁用，先执行: psw provider enable $provider"
    fi
    [ -n "$model_ov" ]  && P_MODEL="$model_ov"
    [ -n "$small_ov" ]  && P_SMALL_MODEL="$small_ov"
    : "${P_SMALL_MODEL:=$P_MODEL}"

    case "$agent" in
        claude)   agent_apply_claude "$mode" || return 1 ;;
        codex)    agent_apply_codex ;;
        opencode) agent_apply_opencode ;;
        hermes)   agent_apply_hermes ;;
    esac
    state_save "$agent" "$provider" "$mode"
    ok "Agent '$agent' 现在使用接入商 '$provider' (模型: $P_MODEL)"
}

cmd_agent_off() {
    local agent="$1"
    agent_exists "$agent" || die "未知 Agent: $agent (支持: $AGENTS)"
    # off 时 P_NAME 供 opencode 兜底使用
    P_NAME=$(kv_get "$STATE_DIR/$agent" PROVIDER 2>/dev/null || true)
    case "$agent" in
        claude)   agent_off_claude ;;
        codex)    agent_off_codex ;;
        opencode) agent_off_opencode ;;
        hermes)   agent_off_hermes ;;
    esac
    rm -f "$STATE_DIR/$agent"
    ok "Agent '$agent' 已恢复为默认配置（原文件备份为 *.psw-bak-*）"
}

cmd_agent_status() {
    local agents="$1"
    [ "$agents" = "all" ] && agents="$AGENTS"
    local a prov mode at cfg
    printf '%s' "$C_BOLD$C_CYN"
    pw "AGENT" 12; printf ' '; pw "接入商" 18; printf ' '; pw "模式" 11; printf ' '; pw "应用时间" 20; printf ' %s' "配置文件"
    printf '%s\n' "$C_RST"
    for a in $agents; do
        agent_exists "$a" || die "未知 Agent: $a (支持: $AGENTS)"
        prov=$(kv_get "$STATE_DIR/$a" PROVIDER 2>/dev/null || true)
        mode=$(kv_get "$STATE_DIR/$a" MODE 2>/dev/null || true)
        at=$(kv_get "$STATE_DIR/$a" APPLIED_AT 2>/dev/null || true)
        case "$a" in
            claude)   cfg="~/.claude/settings.json" ;;
            codex)    cfg="~/.codex/config.toml" ;;
            opencode) cfg="~/.config/opencode/opencode.json" ;;
            hermes)   cfg="~/.hermes/config.yaml" ;;
        esac
        local line
        if [ -z "$prov" ]; then
            line="$(pw "$a" 12) $(pw "(默认)" 18) $(pw "-" 11) $(pw "-" 20) $cfg"
            printf '%s%s%s\n' "$C_DIM" "$line" "$C_RST"
        else
            line="$(pw "$a" 12) ${C_GRN}$(pw "$prov" 18)${C_FGDF} $(pw "$mode" 11) $(pw "$at" 20) ${C_DIM}${cfg}${C_RST}"
            printf '%s\n' "$line"
        fi
    done
}

#-------------------------------------------------------------------------------
# install-shell: 向 shell 启动文件添加 source 行
#-------------------------------------------------------------------------------

cmd_install_shell() {
    regen_env_file
    local line="[ -f \"$ENV_FILE\" ] && . \"$ENV_FILE\""
    local marker="# power-switch env"
    local rc installed=0
    for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.profile"; do
        [ -f "$rc" ] || continue
        if grep -qF "$ENV_FILE" "$rc" 2>/dev/null; then
            info "$rc 已包含 power-switch 配置，跳过"
            continue
        fi
        {
            printf '\n%s\n%s\n' "$marker" "$line"
        } >> "$rc"
        ok "已添加到 $rc"
        installed=1
    done
    if [ "$installed" = "0" ]; then
        warn "未找到 shell 启动文件。请手动添加:"
        printf '  %s\n' "$line"
    else
        info "重新打开终端或执行: . \"$ENV_FILE\""
    fi
}

#-------------------------------------------------------------------------------
# 状态总览
#-------------------------------------------------------------------------------

cmd_status() {
    printf '%s── 接入商 ──────────────────────────────────────────%s\n' "$C_BOLD$C_CYN" "$C_RST"
    cmd_provider_list
    printf '\n%s── Agent ───────────────────────────────────────────%s\n' "$C_BOLD$C_CYN" "$C_RST"
    cmd_agent_status all
    printf '\n'
    info "数据目录: $PSW_HOME"
    info "JSON 后端: $(json_backend 2>/dev/null || echo '未找到 (需要 jq/python3/node)')"
    is_windows && info "平台: Windows ($(psw_uname))"
    return 0
}

#-------------------------------------------------------------------------------
# TUI 组件: 方向键实时选择菜单（非 TTY 时回退为数字输入）
#-------------------------------------------------------------------------------

# _read1 [超时秒] — 用 dd 读 1 字节，绕开 bash 3.2 read -n1 的预读缓冲。
#   有字节: _READ1_OK=1, _READ1_BYTE=字节; 超时/EOF: _READ1_OK=0
_READ1_OK=0; _READ1_BYTE=""
_read1() {
    local timeout="${1:-}" tmp pid sp=""
    _READ1_OK=0; _READ1_BYTE=""
    tmp=$(mktmp)
    # 从 /dev/tty 读: 非交互 bash 会把后台作业的 stdin 重定向到 /dev/null，
    # 显式指定 /dev/tty 绕开，确保后台 dd 也能读到真实终端。
    ( dd bs=1 count=1 of="$tmp" < /dev/tty 2>/dev/null ) &
    pid=$!
    if [ -n "$timeout" ]; then
        ( sleep "$timeout"; kill -TERM "$pid" 2>/dev/null ) &
        sp=$!
    fi
    wait "$pid" 2>/dev/null
    [ -n "$sp" ] && { kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null; }
    if [ -s "$tmp" ]; then
        _READ1_OK=1
        IFS= read -r -d '' _READ1_BYTE < "$tmp" 2>/dev/null
    fi
    rm -f "$tmp"
}

# tui_read_key — 读取一个按键，输出: UP/DOWN/LEFT/RIGHT/ENTER/ESC/EOF 或单字符
# 方向键三字节一次写入: 第一字节 ESC 用 dd 读，跟随字节 100ms 超时再读，
# 故方向键瞬间识别，单独 Esc 仅 100ms 延迟（bash 3.2 无小数 read -t，故用 dd+sleep）。
tui_read_key() {
    _read1
    [ "$_READ1_OK" = "0" ] && { echo "EOF"; return 0; }
    local k="$_READ1_BYTE" k2 k3
    if [ "$k" = "$(printf '\033')" ]; then
        _read1 0.1
        if [ "$_READ1_OK" = "1" ]; then
            k2="$_READ1_BYTE"
            case "$k2" in
                '['|'O')
                    _read1; k3="$_READ1_BYTE"
                    case "$k3" in
                        A) echo "UP" ;; B) echo "DOWN" ;;
                        C) echo "RIGHT" ;; D) echo "LEFT" ;;
                        *) echo "ESC" ;;
                    esac
                    ;;
                *) echo "ESC" ;;
            esac
        else
            echo "ESC"
        fi
    elif [ "$k" = $'\n' ] || [ "$k" = $'\r' ]; then
        echo "ENTER"
    else
        printf '%s' "$k"
    fi
}

# tui_select <标题> <选项1> [选项2 ...]
#   方向键 ↑/↓ 移动，Enter 确认，←/q/Esc 取消
#   选中: TUI_IDX=0基索引, 返回 0；取消: 返回 1
TUI_IDX=255
tui_select() {
    local title="$1"; shift
    local n=$#
    TUI_IDX=255
    [ "$n" -gt 0 ] || return 1

    # 非 TTY 回退: 数字输入
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        local i=1 it sel
        printf '%s\n' "$title"
        for it in "$@"; do
            printf '  %d) %s\n' "$i" "$it"
            i=$((i+1))
        done
        printf '> ' >&2
        read -r sel || return 1
        case "$sel" in
            q|Q|0|"") return 1 ;;
            *[!0-9]*) return 1 ;;
            *) [ "$sel" -le "$n" ] && TUI_IDX=$((sel-1)) && return 0; return 1 ;;
        esac
    fi

    local idx=0 key i lines=$((n+2)) first=1 old_stty=""
    old_stty=$(stty -g 2>/dev/null) || old_stty=""
    [ -n "$old_stty" ] && stty -icanon -echo min 1 time 0 2>/dev/null
    printf '\033[?25l'                      # 隐藏光标
    trap 'printf "\033[?25h"; [ -n "$old_stty" ] && stty "$old_stty" 2>/dev/null' INT TERM
    while true; do
        [ "$first" = "0" ] && printf '\033[%dA' "$lines"   # 上移重绘
        first=0
        printf '\033[2K%s%s%s\n' "$C_CYN" "$title" "$C_RST"
        i=0
        for it in "$@"; do
            if [ "$i" = "$idx" ]; then
                printf '\033[2K%s❯ %s%s\n' "$C_GRN" "$it" "$C_RST"
            else
                printf '\033[2K  %s%s%s\n' "$C_DIM" "$it" "$C_RST"
            fi
            i=$((i+1))
        done
        printf '\033[2K%s↑/↓ 移动  Enter 确认  ←/q 返回%s\n' "$C_DIM" "$C_RST"
        key=$(tui_read_key)
        [ "$key" = "EOF" ] && { printf '\033[?25h'; break; }
        case "$key" in
            UP|k)         idx=$(( (idx - 1 + n) % n )) ;;
            DOWN|j)       idx=$(( (idx + 1) % n )) ;;
            LEFT|ESC|q|Q) break ;;
            ENTER)        TUI_IDX=$idx; break ;;
        esac
    done
    [ -n "$old_stty" ] && stty "$old_stty" 2>/dev/null
    printf '\033[?25h'                      # 恢复光标
    trap - INT TERM
    [ "$TUI_IDX" != "255" ]
}

# wait_key — “按任意键继续”，自行处理 raw 模式
wait_key() {
    printf '%s按任意键继续...%s' "$C_DIM" "$C_RST"
    local os="" dummy
    os=$(stty -g 2>/dev/null) || os=""
    [ -n "$os" ] && stty -icanon -echo min 1 time 0 2>/dev/null
    IFS= read -rsn1 dummy 2>/dev/null || true
    [ -n "$os" ] && stty "$os" 2>/dev/null
    printf '\n'
}

#-------------------------------------------------------------------------------
# 全屏仪表盘（htop 风格）: 顶栏标签 + 状态总览 + 快速切换接入商
#-------------------------------------------------------------------------------

DS_TAB=0            # 0=概览 1=接入商 2=帮助
DS_VIEW="main"      # main | pick_provider | pick_mode | provider_actions
DS_CURSOR=0
DS_OFFSET=0
DS_AGENT=""
DS_PROVIDER=""
DS_MSG=""
DS_STTY=""
DS_WIDTH=80
DS_PAD_X_ACTIVE=2
DS_TOO_SMALL=0
DS_CONTENT_LINES=0
DS_LAST_CONTENT_LINES=0
DS_ACTIVE_CONTENT_KEY=""
DS_LAST_CONTENT_KEY=""
DS_ROWS=24
DS_LAST_TOP_BAR_KEY=""
DS_LAST_TOP_RULE_LAYOUT=""
DS_LAST_FOOTER_LAYOUT=""
DS_LAST_STATUS_KEY=""
DS_LAST_HINTS_KEY=""

# 仪表盘四周留白。横向默认 2 列、纵向默认 1 行，可通过环境变量调整。
DS_PAD_X="${POWER_SWITCH_PAD_X:-2}"
DS_PAD_Y="${POWER_SWITCH_PAD_Y:-1}"
case "$DS_PAD_X" in ""|*[!0-9]*) DS_PAD_X=2 ;; esac
case "$DS_PAD_Y" in ""|*[!0-9]*) DS_PAD_Y=1 ;; esac
[ "$DS_PAD_X" -gt 20 ] && DS_PAD_X=20
[ "$DS_PAD_Y" -gt 5 ] && DS_PAD_Y=5

term_cols() {
    local size="" value=""
    size=$(stty size < /dev/tty 2>/dev/null || true)
    value=${size#* }
    case "$value" in ""|*[!0-9]*) value=$(tput cols 2>/dev/null || true) ;; esac
    case "$value" in ""|*[!0-9]*) value="${COLUMNS:-80}" ;; esac
    case "$value" in ""|*[!0-9]*|0) value=80 ;; esac
    printf '%s' "$value"
}

term_lines() {
    local size="" value=""
    size=$(stty size < /dev/tty 2>/dev/null || true)
    value=${size%% *}
    case "$value" in ""|*[!0-9]*) value=$(tput lines 2>/dev/null || true) ;; esac
    case "$value" in ""|*[!0-9]*) value="${LINES:-24}" ;; esac
    case "$value" in ""|*[!0-9]*|0) value=24 ;; esac
    printf '%s' "$value"
}

ds_clear_line() {
    printf '\033[2K%*s' "$DS_PAD_X_ACTIVE" ''
}

ds_blank_line() {
    ds_clear_line
    printf '\n'
}

ds_fixed_line() {
    local text="$1" plain w pad
    plain=$(printf '%s' "$text" | sed $'s/\033\[[0-9;]*m//g')
    w=$(disp_width "$plain")
    pad=$((DS_WIDTH - w)); [ "$pad" -lt 0 ] && pad=0
    printf '%*s%s%*s\n' "$DS_PAD_X_ACTIVE" '' "$text" "$pad" ''
}

ds_render_table_header() {
    local row=$((DS_PAD_Y + 3))
    if [ "$DS_ACTIVE_CONTENT_KEY" != "$DS_LAST_CONTENT_KEY" ]; then
        printf '\033[%d;1H' "$row"
        ds_fixed_line "$1"
    fi
    printf '\033[%d;1H' $((row + 1))
}

ds_invalidate_chrome() {
    DS_LAST_CONTENT_KEY=""
    DS_LAST_TOP_BAR_KEY=""
    DS_LAST_TOP_RULE_LAYOUT=""
    DS_LAST_FOOTER_LAYOUT=""
    DS_LAST_STATUS_KEY=""
    DS_LAST_HINTS_KEY=""
}

ds_enter() {
    DS_STTY=$(stty -g 2>/dev/null) || DS_STTY=""
    [ -n "$DS_STTY" ] && stty -icanon -echo min 1 time 0 2>/dev/null
    printf '\033[?1049h\033[?25l'        # 备用屏幕 + 隐藏光标
    ds_invalidate_chrome
    trap 'exit 130' INT TERM HUP
    trap 'ds_exit' EXIT
}

ds_exit() {
    [ -n "$DS_STTY" ] && stty "$DS_STTY" 2>/dev/null
    printf '\033[?25h\033[?1049l'        # 恢复光标 + 主屏幕
    trap - INT TERM HUP EXIT
}

ds_suspend() {  # 临时退出全屏（执行行输入表单）
    [ -n "$DS_STTY" ] && stty "$DS_STTY" 2>/dev/null
    printf '\033[?25h\033[?1049l'
}

ds_resume() {
    printf '\033[?1049h\033[?25l'
    [ -n "$DS_STTY" ] && stty -icanon -echo min 1 time 0 2>/dev/null
    ds_invalidate_chrome
}

# ds_collect_providers <0=全部|1=仅启用> → DS_P_NAMES 数组
ds_collect_providers() {
    DS_P_NAMES=()
    local n
    for n in $(provider_list_names); do
        if [ "$1" = "1" ]; then
            provider_load "$n" || continue
            [ "$P_ENABLED" = "1" ] || continue
        fi
        DS_P_NAMES+=("$n")
    done
}

# ds_clamp <行数> — 光标与滚动窗口约束
ds_clamp() {
    local rows="$1" avail="$2"
    [ "$rows" -lt 1 ] && rows=1
    [ "$DS_CURSOR" -ge "$rows" ] && DS_CURSOR=$((rows-1))
    [ "$DS_CURSOR" -lt 0 ] && DS_CURSOR=0
    [ "$DS_CURSOR" -lt "$DS_OFFSET" ] && DS_OFFSET=$DS_CURSOR
    if [ "$DS_CURSOR" -ge $((DS_OFFSET + avail)) ]; then
        DS_OFFSET=$((DS_CURSOR - avail + 1))
    fi
}

# ds_row <是否光标行 0/1> <文本> — 选中行整行反色高亮（htop 风格）
ds_row() {
    local text="$2"
    if [ "$1" = "1" ]; then
        local plain w pad
        plain=$(printf '%s' "$text" | sed $'s/\033\[[0-9;]*m//g')
        w=$(disp_width "$plain")
        pad=$((DS_WIDTH - 2 - w)); [ "$pad" -lt 0 ] && pad=0
        printf '%*s\033[7m❯ %s%*s\033[0m\n' "$DS_PAD_X_ACTIVE" '' "$text" "$pad" ''
    else
        local plain w pad
        plain=$(printf '%s' "$text" | sed $'s/\033\[[0-9;]*m//g')
        w=$(disp_width "$plain")
        pad=$((DS_WIDTH - 2 - w)); [ "$pad" -lt 0 ] && pad=0
        printf '%*s  %s%*s\n' "$DS_PAD_X_ACTIVE" '' "$text" "$pad" ''
    fi
}

ds_render() {
    local cols rows avail
    cols=$(term_cols);  : "${cols:=80}"
    rows=$(term_lines); : "${rows:=24}"
    DS_ROWS=$rows
    DS_PAD_X_ACTIVE=$DS_PAD_X
    [ $((DS_PAD_X_ACTIVE * 2 + 40)) -gt "$cols" ] && DS_PAD_X_ACTIVE=0
    DS_WIDTH=$((cols - DS_PAD_X_ACTIVE * 2))
    avail=$((rows - DS_PAD_Y * 2 - 6)); [ "$avail" -lt 3 ] && avail=3

    printf '\033[H'                        # 光标归位；逐行覆盖，避免整屏清空造成闪烁
    DS_TOO_SMALL=0
    if [ "$DS_WIDTH" -lt 68 ] || [ "$rows" -lt $((19 + DS_PAD_Y * 2)) ]; then
        DS_TOO_SMALL=1
        printf '\033[%d;1H' $((DS_PAD_Y + 1))
        ds_clear_line
        printf '%sPower Switch v%s%s\n' "$C_BOLD$C_CYN" "$PSW_VERSION" "$C_RST"
        ds_blank_line
        local size_msg
        size_msg="终端空间不足：当前 ${cols}x${rows}，至少需要 $((68 + DS_PAD_X_ACTIVE * 2))x$((19 + DS_PAD_Y * 2))。"
        ds_clear_line
        printf '%s%s%s\n' "$C_YLW" "$(clip_text "$size_msg" "$DS_WIDTH")" "$C_RST"
        ds_clear_line
        printf '%s%s%s\n' "$C_DIM" "$(clip_text "请放大终端，调整后按任意键刷新；按 q 退出。" "$DS_WIDTH")" "$C_RST"
        printf '\033[J'
        DS_LAST_CONTENT_LINES=0
        ds_invalidate_chrome
        return 0
    fi

    printf '\033[%d;1H' $((DS_PAD_Y + 1))
    # ---- 顶栏: ⚡ 品牌 + 标签胶囊 + 右侧统计 ----
    local sep; sep=$(repeat_text "─" "$DS_WIDTH")
    # 统计: 接入商数量 / 已配置 Agent 数
    local pcount=0 acount=0 n a
    for n in $(provider_list_names); do pcount=$((pcount+1)); done
    for a in $AGENTS; do
        [ -n "$(kv_get "$STATE_DIR/$a" PROVIDER 2>/dev/null || true)" ] && acount=$((acount+1))
    done
    local lstyled lplain t i=0
    local TAB_ON=$'\033[30;46;1m'   # 激活标签: 黑字青底加粗
    lstyled="${C_GRN}⚡ ${C_BOLD}${C_CYN}Power Switch${C_RST} ${C_DIM}v${PSW_VERSION}${C_RST}"
    lplain="⚡ Power Switch v${PSW_VERSION}"
    for t in 概览 接入商 帮助; do
        if [ "$i" = "$DS_TAB" ]; then
            lstyled="$lstyled  ${TAB_ON} $t ${C_RST}"
        else
            lstyled="$lstyled  ${C_DIM} $t ${C_RST}"
        fi
        lplain="$lplain   $t "
        i=$((i+1))
    done
    local rstyled rplain lw rw pad
    rstyled="${C_DIM}接入商 ${pcount} · Agent ${acount}/4${C_RST}"
    rplain="接入商 ${pcount} · Agent ${acount}/4"
    lw=$(disp_width "$lplain"); rw=$(disp_width "$rplain")
    pad=$((DS_WIDTH - lw - rw))
    if [ "$pad" -lt 1 ]; then
        rstyled=""; rplain=""; rw=0
        pad=$((DS_WIDTH - lw))
    fi
    [ "$pad" -lt 0 ] && pad=0
    local top_bar_key="${DS_PAD_Y}:${DS_PAD_X_ACTIVE}:${DS_WIDTH}:${DS_TAB}:${pcount}:${acount}"
    if [ "$top_bar_key" != "$DS_LAST_TOP_BAR_KEY" ]; then
        printf '\033[%d;1H%*s%s%*s%s' \
            $((DS_PAD_Y + 1)) "$DS_PAD_X_ACTIVE" '' "$lstyled" "$pad" '' "$rstyled"
        DS_LAST_TOP_BAR_KEY="$top_bar_key"
    fi
    local top_rule_layout="${DS_PAD_Y}:${DS_PAD_X_ACTIVE}:${DS_WIDTH}"
    if [ "$top_rule_layout" != "$DS_LAST_TOP_RULE_LAYOUT" ]; then
        printf '\033[%d;1H%*s%s━━━%s%s%s' \
            $((DS_PAD_Y + 2)) "$DS_PAD_X_ACTIVE" '' "$C_GRN" "$C_DIM" \
            "$(repeat_text "─" $((DS_WIDTH-3)))" "$C_RST"
        DS_LAST_TOP_RULE_LAYOUT="$top_rule_layout"
    fi
    printf '\033[%d;1H' $((DS_PAD_Y + 3))

    # ---- 内容区 ----
    DS_CONTENT_LINES=0
    DS_ACTIVE_CONTENT_KEY="${DS_VIEW}:${DS_TAB}"
    case "$DS_VIEW" in
        main)
            case "$DS_TAB" in
                0) ds_render_overview "$avail" ;;
                1) ds_render_providers "$avail" ;;
                2) ds_render_help ;;
            esac
            ;;
        pick_provider)    ds_render_pick_provider "$avail" ;;
        pick_mode)        ds_render_pick_mode ;;
        provider_actions) ds_render_provider_actions ;;
        form_provider)    ds_render_form_provider ;;
    esac
    # 只清理上一视图多出来的内容行，不触碰固定底栏。
    if [ "$DS_LAST_CONTENT_LINES" -gt "$DS_CONTENT_LINES" ]; then
        local clear_row=$((DS_PAD_Y + 3 + DS_CONTENT_LINES))
        local clear_end=$((DS_PAD_Y + 3 + DS_LAST_CONTENT_LINES))
        local footer_row=$((rows - DS_PAD_Y - 2))
        [ "$clear_end" -gt "$footer_row" ] && clear_end=$footer_row
        while [ "$clear_row" -lt "$clear_end" ]; do
            printf '\033[%d;1H\033[2K' "$clear_row"
            clear_row=$((clear_row+1))
        done
    fi
    DS_LAST_CONTENT_LINES=$DS_CONTENT_LINES
    DS_LAST_CONTENT_KEY=$DS_ACTIVE_CONTENT_KEY

    # ---- 底栏（钉在屏幕底部；内容未变化时不重复重画）----
    local footer_layout="${rows}:${DS_PAD_Y}:${DS_PAD_X_ACTIVE}:${DS_WIDTH}"
    if [ "$footer_layout" != "$DS_LAST_FOOTER_LAYOUT" ]; then
        printf '\033[%d;1H%*s%s%s%s' \
            $((rows - DS_PAD_Y - 2)) "$DS_PAD_X_ACTIVE" '' "$C_DIM" "$sep" "$C_RST"
        DS_LAST_FOOTER_LAYOUT="$footer_layout"
        DS_LAST_STATUS_KEY=""
        DS_LAST_HINTS_KEY=""
    fi
    if [ -n "$DS_MSG" ]; then
        local mc="$C_YLW"
        case "$DS_MSG" in
            *✓*) mc="$C_GRN" ;; *✗*) mc="$C_RED" ;;
        esac
        ds_render_status_line $((rows - DS_PAD_Y - 1)) "$mc" "$DS_MSG"
    else
        local meta
        meta="数据目录: $PSW_HOME  │  JSON 后端: $(json_backend 2>/dev/null || echo '无')"
        ds_render_status_line $((rows - DS_PAD_Y - 1)) "$C_DIM" "$meta"
    fi
    ds_render_hints $((rows - DS_PAD_Y))
}

ds_render_status_line() {
    local row="$1" color="$2" text w pad key
    text=$(clip_text "$3" "$DS_WIDTH")
    key="${row}:${DS_PAD_X_ACTIVE}:${DS_WIDTH}:${color}:${text}"
    [ "$key" = "$DS_LAST_STATUS_KEY" ] && return 0
    w=$(disp_width "$text")
    pad=$((DS_WIDTH - w)); [ "$pad" -lt 0 ] && pad=0
    printf '\033[%d;1H%*s%s%s%*s%s' \
        "$row" "$DS_PAD_X_ACTIVE" '' "$color" "$text" "$pad" '' "$C_RST"
    DS_LAST_STATUS_KEY="$key"
}

ds_render_hints() {
    local row="$1" h
    case "$DS_VIEW" in
        main)
            case "$DS_TAB" in
                0) h="[←/→] 标签  [↑/↓] 移动  [Enter] 切换接入商  [q] 退出" ;;
                1) h="[←/→] 标签  [↑/↓] 移动  [Enter] 操作  [a] 添加  [e] 修改  [d] 删除  [空格] 启停  [q] 退出" ;;
                2) h="[←/→] 标签  [q] 退出" ;;
            esac
            ;;
        pick_provider|pick_mode|provider_actions)
            h="[↑/↓] 移动  [Enter] 确认  [←/Esc] 返回"
            ;;
        form_provider)
            h="[↑/↓] 移动  [Enter] 编辑/确认  [←/→] 切换选项  [Esc] 取消"
            ;;
    esac
    h=$(clip_text "$h" $((DS_WIDTH - 2)))
    local hw hpad
    hw=$(disp_width "$h")
    hpad=$((DS_WIDTH - hw - 2)); [ "$hpad" -lt 0 ] && hpad=0
    local key="${row}:${DS_PAD_X_ACTIVE}:${DS_WIDTH}:${h}"
    [ "$key" = "$DS_LAST_HINTS_KEY" ] && return 0
    printf '\033[%d;1H%*s\033[7m %s%*s \033[0m' \
        "$row" "$DS_PAD_X_ACTIVE" '' "$h" "$hpad" ''
    DS_LAST_HINTS_KEY="$key"
}

ds_render_overview() {
    local avail="$1"
    # 先约束光标再绘制，避免在首尾继续移动时出现一帧没有选中行。
    ds_clamp 4 "$avail"
    ds_render_table_header "${C_BOLD}${C_CYN} $(pw "Agent" 11) $(pw "接入商" 17) $(pw "模式" 11) 应用时间${C_RST}"
    local a prov mode at i=0
    for a in $AGENTS; do
        prov=$(kv_get "$STATE_DIR/$a" PROVIDER 2>/dev/null || true)
        mode=$(kv_get "$STATE_DIR/$a" MODE 2>/dev/null || true)
        at=$(kv_get "$STATE_DIR/$a" APPLIED_AT 2>/dev/null || true)
        local line
        if [ -n "$prov" ]; then
            prov=$(clip_text "$prov" 17)
            mode=$(clip_text "$mode" 11)
            line="$(pw "$a" 11) ${C_GRN}$(pw "$prov" 17)${C_FGDF} $(pw "$mode" 11) $at"
            if [ "$i" = "$DS_CURSOR" ]; then ds_row 1 "$line"; else ds_row 0 "$line"; fi
        else
            line="$(pw "$a" 11) $(pw "(默认)" 17) $(pw "-" 11) -"
            if [ "$i" = "$DS_CURSOR" ]; then ds_row 1 "$line"; else ds_row 0 "$C_DIM$line$C_RST"; fi
        fi
        i=$((i+1))
    done
    DS_CONTENT_LINES=5
}

ds_render_providers() {
    local avail="$1"
    ds_collect_providers 0
    local n=${#DS_P_NAMES[@]}
    ds_render_table_header "${C_BOLD}${C_CYN} $(pw "接入商" 13) $(pw "格式" 11) $(pw "状态" 3) Base URL / Model${C_RST}"
    if [ "$n" -eq 0 ]; then
        ds_clear_line
        printf '  %s(空 — 按 a 添加接入商)%s\n' "$C_DIM" "$C_RST"
        DS_CURSOR=0; DS_OFFSET=0
        DS_CONTENT_LINES=2
        return 0
    fi
    local page_rows="$avail" show_scroll=0
    if [ "$n" -gt "$avail" ]; then
        show_scroll=1
        page_rows=$((avail - 1)); [ "$page_rows" -lt 1 ] && page_rows=1
    fi
    ds_clamp "$n" "$page_rows"
    local i end=$((DS_OFFSET + page_rows))
    [ "$end" -gt "$n" ] && end=$n
    i=$DS_OFFSET
    while [ "$i" -lt "$end" ]; do
        local name="${DS_P_NAMES[$i]}" badge details detail_width
        provider_load "$name" || continue
        if [ "$P_ENABLED" = "1" ]; then badge="${C_GRN}●${C_FGDF}"; else badge="${C_DIM}○${C_FGDF}"; fi
        name=$(clip_text "$name" 13)
        detail_width=$((DS_WIDTH - 32)); [ "$detail_width" -lt 8 ] && detail_width=8
        details=$(clip_text "$P_BASE_URL · $P_MODEL" "$detail_width")
        local line; line=$(printf '%-13s %-11s %b %s' "$name" "$P_FORMAT" "$badge" "$details")
        if [ "$P_ENABLED" = "1" ]; then
            if [ "$i" = "$DS_CURSOR" ]; then ds_row 1 "$line"; else ds_row 0 "$line"; fi
        else
            if [ "$i" = "$DS_CURSOR" ]; then ds_row 1 "$line"; else ds_row 0 "$C_DIM$line$C_RST"; fi
        fi
        i=$((i+1))
    done
    if [ "$show_scroll" = "1" ]; then
        ds_clear_line
        printf '%s[%d-%d/%d]%s\n' "$C_DIM" $((DS_OFFSET+1)) "$end" "$n" "$C_RST"
    fi
    DS_CONTENT_LINES=$((1 + end - DS_OFFSET + show_scroll))
}

ds_render_help() {
    cat <<'EOF' | while IFS= read -r l; do ds_clear_line; printf '%s\n' "$l"; done
 标签页:
   概览     所有 Agent 当前状态; Enter 可为选中 Agent 切换接入商
   接入商   管理接入商: 添加/修改/删除/启用/禁用

 快捷键:
   ←/→ 或 Tab/1/2/3   切换标签
   ↑/↓ (或 k/j)       移动光标
   Enter              确认 / 进入
   a / e / d          接入商: 添加 / 修改 / 删除
   空格               接入商: 启用/禁用 快速切换
   ← / Esc / q        返回 / 退出

 命令行用法与配置文件机制见: psw help
 数据目录: providers/ state/ env.sh (POWER_SWITCH_HOME 可覆盖)
EOF
    DS_CONTENT_LINES=14
}

ds_render_pick_provider() {
    local avail="$1"
    ds_clear_line
    printf '%s 为 Agent [%s] 选择接入商:%s\n' "$C_CYN" "$DS_AGENT" "$C_RST"
    ds_collect_providers 1
    local n=${#DS_P_NAMES[@]} rows=$(( ${#DS_P_NAMES[@]} + 1 ))
    ds_clamp "$rows" "$avail"
    if [ "$n" -eq 0 ]; then
        ds_clear_line
        printf '  %s(无已启用接入商，请到「接入商」标签添加)%s\n' "$C_DIM" "$C_RST"
    fi
    local i end=$((DS_OFFSET + avail))
    [ "$end" -gt "$rows" ] && end=$rows
    i=$DS_OFFSET
    while [ "$i" -lt "$end" ]; do
        local line
        if [ "$i" -eq "$n" ]; then
            line="⊘ 关闭 (恢复 $DS_AGENT 默认配置)"
        else
            provider_load "${DS_P_NAMES[$i]}"
            local pname pdetails pwidth
            pname=$(clip_text "${DS_P_NAMES[$i]}" 13)
            pwidth=$((DS_WIDTH - 29)); [ "$pwidth" -lt 8 ] && pwidth=8
            pdetails=$(clip_text "$P_BASE_URL · $P_MODEL" "$pwidth")
            line=$(printf '%-13s %-11s %s' "$pname" "$P_FORMAT" "$pdetails")
        fi
        if [ "$i" = "$DS_CURSOR" ]; then ds_row 1 "$line"; else ds_row 0 "$line"; fi
        i=$((i+1))
    done
    DS_CONTENT_LINES=$((1 + end - DS_OFFSET))
    [ "$n" -eq 0 ] && DS_CONTENT_LINES=$((DS_CONTENT_LINES + 1))
}

ds_render_pick_mode() {
    ds_clear_line
    printf '%s 选择 Claude 配置方式:%s\n' "$C_CYN" "$C_RST"
    if [ "$DS_CURSOR" -gt 1 ]; then DS_CURSOR=0; fi
    if [ "$DS_CURSOR" = "0" ]; then ds_row 1 "settings 模式 (写入 ~/.claude/settings.json, 推荐)"; else ds_row 0 "settings 模式 (写入 ~/.claude/settings.json, 推荐)"; fi
    if [ "$DS_CURSOR" = "1" ]; then ds_row 1 "env 模式 (生成环境变量文件, 需 install-shell)"; else ds_row 0 "env 模式 (生成环境变量文件, 需 install-shell)"; fi
    DS_CONTENT_LINES=3
}

ds_render_provider_actions() {
    provider_load "$DS_PROVIDER" || { DS_VIEW="main"; return 0; }
    local toggle
    if [ "$P_ENABLED" = "1" ]; then toggle="禁用"; else toggle="启用"; fi
    local summary
    summary="接入商 [$DS_PROVIDER]  $P_FORMAT  $P_BASE_URL"
    ds_clear_line
    printf '%s %s%s\n' "$C_CYN" "$(clip_text "$summary" "$((DS_WIDTH - 1))")" "$C_RST"
    [ "$DS_CURSOR" -gt 2 ] && DS_CURSOR=0
    local items=("$toggle 该接入商" "修改" "删除")
    local i
    for i in 0 1 2; do
        if [ "$i" = "$DS_CURSOR" ]; then ds_row 1 "${items[$i]}"; else ds_row 0 "${items[$i]}"; fi
    done
    DS_CONTENT_LINES=4
}

#-------------------------------------------------------------------------------
# 全屏表单视图（添加/修改接入商，与仪表盘同风格）
#-------------------------------------------------------------------------------

DS_FORM_MODE="add"      # add | edit
DS_FORM_FIELD=0         # 当前字段: 0名称 1预设 2格式 3BaseURL 4Key 5主模型 6小模型 7wire 8保存 9取消
DS_FORM_EDITING=""      # edit 模式下的原名称
DS_F_NAME=""; DS_F_PRESET="custom"; DS_F_FORMAT="openai"; DS_F_BU=""
DS_F_KEY=""; DS_F_MODEL=""; DS_F_SMALL=""; DS_F_WIRE="responses"; DS_F_ENABLED="1"

ds_start_add() {
    DS_FORM_MODE="add"; DS_FORM_FIELD=0; DS_FORM_EDITING=""
    DS_F_NAME=""; DS_F_PRESET="custom"; DS_F_FORMAT="openai"; DS_F_BU=""
    DS_F_KEY=""; DS_F_MODEL=""; DS_F_SMALL=""; DS_F_WIRE="responses"; DS_F_ENABLED="1"
    DS_VIEW="form_provider"
}

ds_start_edit() { # <name>
    provider_load "$1" || return 1
    DS_FORM_MODE="edit"; DS_FORM_FIELD=2; DS_FORM_EDITING="$1"
    DS_F_NAME="$1"; DS_F_PRESET="custom"; DS_F_FORMAT="$P_FORMAT"; DS_F_BU="$P_BASE_URL"
    DS_F_KEY="$P_API_KEY"; DS_F_MODEL="$P_MODEL"; DS_F_SMALL="$P_SMALL_MODEL"
    DS_F_WIRE="$P_WIRE_API"; DS_F_ENABLED="$P_ENABLED"
    DS_VIEW="form_provider"
}

ds_form_get() {
    case "$1" in
        NAME)  printf '%s' "$DS_F_NAME" ;;  BU)    printf '%s' "$DS_F_BU" ;;
        KEY)   printf '%s' "$DS_F_KEY" ;;   MODEL) printf '%s' "$DS_F_MODEL" ;;
        SMALL) printf '%s' "$DS_F_SMALL" ;;
    esac
}

ds_form_set() {
    case "$1" in
        NAME)  DS_F_NAME="$2" ;;  BU)    DS_F_BU="$2" ;;
        KEY)   DS_F_KEY="$2" ;;   MODEL) DS_F_MODEL="$2" ;;
        SMALL) DS_F_SMALL="$2" ;;
    esac
}

# ds_cycle_preset <+1|-1> — 切换预设并自动填充默认值
ds_cycle_preset() {
    local list="$PRESETS custom" item idx=0 cnt=0 i=0
    for item in $list; do
        [ "$item" = "$DS_F_PRESET" ] && idx=$i
        i=$((i+1)); cnt=$((cnt+1))
    done
    idx=$(( (idx + $1 + cnt) % cnt ))
    i=0
    for item in $list; do
        [ "$i" = "$idx" ] && { DS_F_PRESET="$item"; break; }
        i=$((i+1))
    done
    if [ "$DS_F_PRESET" != "custom" ]; then
        DS_F_BU=$(preset_get "$DS_F_PRESET" "$DS_F_FORMAT" base_url)
        DS_F_MODEL=$(preset_get "$DS_F_PRESET" "$DS_F_FORMAT" model)
        DS_F_SMALL=$(preset_get "$DS_F_PRESET" "$DS_F_FORMAT" small_model)
    fi
}

# ds_form_row <字段号> <标签> <值> [secret] [disabled] — 文本字段行
ds_form_row() {
    local idx="$1" label="$2" val="$3" secret="${4:-0}" disabled="${5:-0}"
    [ "$secret" = "1" ] && [ -n "$val" ] && val="********"
    val=$(clip_text "$val" $((DS_WIDTH - 16)))
    if [ "$disabled" = "1" ]; then
        ds_row 0 "${C_DIM}$(pw "$label" 12) ${val}${C_RST}"
    elif [ "$DS_FORM_FIELD" = "$idx" ]; then
        ds_row 1 "$(pw "$label" 12) ${C_GRN}${val}${C_FGDF}"
    else
        ds_row 0 "$(pw "$label" 12) ${C_GRN}${val}${C_FGDF}"
    fi
}

# ds_choice_row <字段号> <标签> <值> [disabled] — 选项字段行（‹ › 提示可切换）
ds_choice_row() {
    local idx="$1" label="$2" val="$3" disabled="${4:-0}"
    val=$(clip_text "$val" $((DS_WIDTH - 20)))
    if [ "$disabled" = "1" ]; then
        ds_row 0 "${C_DIM}$(pw "$label" 12) ${val}${C_RST}"
    elif [ "$DS_FORM_FIELD" = "$idx" ]; then
        ds_row 1 "$(pw "$label" 12) ${C_GRN}‹ ${val} ›${C_FGDF}"
    else
        ds_row 0 "$(pw "$label" 12) ${C_GRN}‹ ${val} ›${C_FGDF}"
    fi
}

ds_render_form_provider() {
    local title="添加接入商"
    [ "$DS_FORM_MODE" = "edit" ] && title="修改接入商: $DS_FORM_EDITING"
    ds_clear_line
    printf '%s %s%s\n' "$C_BOLD$C_CYN" "$(clip_text "$title" "$((DS_WIDTH - 1))")" "$C_RST"
    ds_blank_line
    local dis=0
    [ "$DS_FORM_MODE" = "edit" ] && dis=1
    ds_form_row   0 "名称"       "$DS_F_NAME"   0 "$dis"
    ds_choice_row 1 "预设"       "$DS_F_PRESET" "$dis"
    ds_choice_row 2 "格式"       "$DS_F_FORMAT"
    ds_form_row   3 "Base URL"   "$DS_F_BU"
    ds_form_row   4 "API Key"    "$DS_F_KEY"    1
    ds_form_row   5 "主模型"     "$DS_F_MODEL"
    ds_form_row   6 "小/快模型"  "$DS_F_SMALL"
    ds_choice_row 7 "OpenAI API" "$DS_F_WIRE"
    ds_blank_line
    # 按钮行
    ds_clear_line
    if [ "$DS_FORM_FIELD" = "8" ]; then
        printf '  \033[7m 保存 \033[0m    取消\n'
    elif [ "$DS_FORM_FIELD" = "9" ]; then
        printf '    保存   \033[7m 取消 \033[0m\n'
    else
        printf '%s    保存    取消%s\n' "$C_DIM" "$C_RST"
    fi
    DS_CONTENT_LINES=12
}

# ds_form_input <NAME|BU|KEY|MODEL|SMALL> <标签> <secret 0/1> — 在底栏上方读取一行输入
ds_form_input() {
    local var="$1" label="$2" secret="$3" rows cur v=""
    rows=$(term_lines); : "${rows:=24}"
    cur=$(ds_form_get "$var")
    if [ "$secret" = "1" ]; then
        if [ -n "$cur" ]; then cur="已设置；留空保留，输入 - 清除"; else cur="留空表示不设置"; fi
    fi
    cur=$(clip_text "$cur" $((DS_WIDTH - 16)))
    printf '\033[%d;1H\033[2K%*s%s%s:%s %s%s%s ' \
        "$((rows - DS_PAD_Y - 3))" "$DS_PAD_X_ACTIVE" '' \
        "$C_GRN" "$label" "$C_RST" "$C_DIM" "$cur" "$C_RST"
    printf '\033[?25h'
    [ -n "$DS_STTY" ] && stty "$DS_STTY" 2>/dev/null
    if [ "$secret" = "1" ]; then IFS= read -r -s v || v=""; else IFS= read -r v || v=""; fi
    [ -n "$DS_STTY" ] && stty -icanon -echo min 1 time 0 2>/dev/null
    printf '\033[?25l'
    if [ "$secret" = "1" ] && [ "$v" = "-" ]; then
        ds_form_set "$var" ""
        DS_MSG="API Key 已清除，保存后生效"
    elif [ -n "$v" ]; then
        ds_form_set "$var" "$v"
    fi
    printf '\033[%d;1H\033[2K' "$((rows - DS_PAD_Y - 3))"
}

ds_form_save() {
    if [ "$DS_FORM_MODE" = "add" ]; then
        if ! valid_name "$DS_F_NAME"; then
            DS_MSG="[✗] 名称不合法（字母/数字/-/_）"; DS_FORM_FIELD=0; return 1
        fi
        if provider_exists "$DS_F_NAME"; then
            DS_MSG="[✗] 接入商 '$DS_F_NAME' 已存在"; DS_FORM_FIELD=0; return 1
        fi
    fi
    if [ -z "$DS_F_BU" ]; then
        DS_MSG="[✗] Base URL 不能为空"; DS_FORM_FIELD=3; return 1
    fi
    if [ -z "$DS_F_MODEL" ]; then
        DS_MSG="[✗] 主模型不能为空"; DS_FORM_FIELD=5; return 1
    fi
    if [ "$DS_FORM_MODE" = "edit" ]; then P_NAME="$DS_FORM_EDITING"; else P_NAME="$DS_F_NAME"; fi
    P_FORMAT="$DS_F_FORMAT"; P_BASE_URL="$DS_F_BU"; P_API_KEY="$DS_F_KEY"
    P_MODEL="$DS_F_MODEL"; P_SMALL_MODEL="${DS_F_SMALL:-$DS_F_MODEL}"
    P_WIRE_API="$DS_F_WIRE"; P_ENABLED="$DS_F_ENABLED"
    provider_save
    regen_env_file
    DS_MSG="[✓] 接入商 '$P_NAME' 已保存"
    DS_VIEW="main"; DS_CURSOR=0; DS_OFFSET=0
    return 0
}

# ds_handle_form <key> — 表单视图按键处理
ds_handle_form() {
    local key="$1" minf=0
    [ "$DS_FORM_MODE" = "edit" ] && minf=2
    case "$key" in
        UP|k)
            DS_FORM_FIELD=$((DS_FORM_FIELD - 1))
            [ "$DS_FORM_FIELD" -lt "$minf" ] && DS_FORM_FIELD=$minf
            ;;
        DOWN|j)
            DS_FORM_FIELD=$((DS_FORM_FIELD + 1))
            [ "$DS_FORM_FIELD" -gt 9 ] && DS_FORM_FIELD=9
            ;;
        LEFT|RIGHT)
            local dir=1; [ "$key" = "LEFT" ] && dir=-1
            case "$DS_FORM_FIELD" in
                1) [ "$DS_FORM_MODE" = "add" ] && ds_cycle_preset "$dir" ;;
                2)
                    if [ "$DS_F_FORMAT" = "openai" ]; then DS_F_FORMAT="anthropic"; else DS_F_FORMAT="openai"; fi
                    [ "$DS_F_PRESET" != "custom" ] && \
                        DS_F_BU=$(preset_get "$DS_F_PRESET" "$DS_F_FORMAT" base_url)
                    ;;
                7) if [ "$DS_F_WIRE" = "responses" ]; then DS_F_WIRE="chat"; else DS_F_WIRE="responses"; fi ;;
                8) DS_FORM_FIELD=9 ;;
                9) DS_FORM_FIELD=8 ;;
            esac
            ;;
        ESC|q|Q)
            DS_VIEW="main"; DS_CURSOR=0; DS_OFFSET=0; DS_MSG="已取消"
            ;;
        ENTER)
            case "$DS_FORM_FIELD" in
                0) [ "$DS_FORM_MODE" = "add" ] && ds_form_input NAME "名称" 0 ;;
                3) ds_form_input BU "Base URL" 0 ;;
                4) ds_form_input KEY "API Key" 1 ;;
                5) ds_form_input MODEL "主模型" 0 ;;
                6) ds_form_input SMALL "小/快模型" 0 ;;
                1|2|7)
                    DS_FORM_FIELD=$((DS_FORM_FIELD + 1))
                    ;;
                8) ds_form_save ;;
                9) DS_VIEW="main"; DS_CURSOR=0; DS_OFFSET=0; DS_MSG="已取消" ;;
            esac
            ;;
    esac
    return 0
}

# ---- 仪表盘操作 ----

ds_apply_provider() { # agent provider [mode]
    local out
    provider_load "$2" || { DS_MSG="[✗] 接入商 '$2' 不存在"; return 1; }
    if [ "$1" = "claude" ] && [ "$P_FORMAT" != "anthropic" ]; then
        DS_MSG="[✗] Claude 仅支持 Anthropic 协议，请先修改接入商格式或配置协议转换网关"
        return 1
    fi
    if [ "$1" = "claude" ]; then
        out=$(cmd_agent_use "$1" "$2" --mode "${3:-settings}" 2>&1)
    else
        out=$(cmd_agent_use "$1" "$2" 2>&1)
    fi
    DS_MSG=$(printf '%s\n' "$out" | tail -1)
}

ds_agent_off() {
    local out; out=$(cmd_agent_off "$1" 2>&1)
    DS_MSG=$(printf '%s\n' "$out" | tail -1)
}

ds_toggle_provider() {
    provider_load "$1" || return 0
    local out
    if [ "$P_ENABLED" = "1" ]; then
        out=$(cmd_provider_enable "$1" 0 2>&1)
    else
        out=$(cmd_provider_enable "$1" 1 2>&1)
    fi
    DS_MSG=$(printf '%s\n' "$out" | tail -1)
}

ds_form() { # 挂起全屏执行行输入命令，恢复后回到全屏；子 shell 隔离 die 的 exit
    ds_suspend
    ( "$@" )
    local rc=$?
    wait_key
    ds_resume
    return $rc
}

# ds_handle <key> → 返回 1 表示退出仪表盘
ds_handle() {
    local key="$1"
    DS_MSG=""
    if [ "$DS_TOO_SMALL" = "1" ]; then
        case "$key" in q|Q|ESC) return 1 ;; *) return 0 ;; esac
    fi
    case "$DS_VIEW" in
    #------------------------------------------------------------------ 主视图
    main)
        case "$key" in
            RIGHT|"$DS_TAB_CHAR") DS_TAB=$(( (DS_TAB + 1) % 3 )); DS_CURSOR=0; DS_OFFSET=0 ;;
            LEFT)  DS_TAB=$(( (DS_TAB + 2) % 3 )); DS_CURSOR=0; DS_OFFSET=0 ;;
            1|2|3) DS_TAB=$((key - 1)); DS_CURSOR=0; DS_OFFSET=0 ;;
            UP|k)   DS_CURSOR=$((DS_CURSOR - 1)) ;;
            DOWN|j) DS_CURSOR=$((DS_CURSOR + 1)) ;;
            q|Q|ESC) return 1 ;;
            ENTER)
                case "$DS_TAB" in
                    0)
                        local i=0 a
                        for a in $AGENTS; do
                            if [ "$i" = "$DS_CURSOR" ]; then DS_AGENT="$a"; fi
                            i=$((i+1))
                        done
                        [ -n "$DS_AGENT" ] && { DS_VIEW="pick_provider"; DS_CURSOR=0; DS_OFFSET=0; }
                        ;;
                    1)
                        ds_collect_providers 0
                        [ "${#DS_P_NAMES[@]}" -gt 0 ] && [ "$DS_CURSOR" -lt "${#DS_P_NAMES[@]}" ] && {
                            DS_PROVIDER="${DS_P_NAMES[$DS_CURSOR]}"
                            DS_VIEW="provider_actions"; DS_CURSOR=0
                        }
                        ;;
                esac
                ;;
            a) [ "$DS_TAB" = "1" ] && ds_start_add ;;
            e)
                if [ "$DS_TAB" = "1" ]; then
                    ds_collect_providers 0
                    if [ "${#DS_P_NAMES[@]}" -gt 0 ] && [ "$DS_CURSOR" -lt "${#DS_P_NAMES[@]}" ]; then
                        ds_start_edit "${DS_P_NAMES[$DS_CURSOR]}"
                    fi
                fi
                ;;
            d)
                if [ "$DS_TAB" = "1" ]; then
                    ds_collect_providers 0
                    if [ "${#DS_P_NAMES[@]}" -gt 0 ] && [ "$DS_CURSOR" -lt "${#DS_P_NAMES[@]}" ]; then
                        ds_form cmd_provider_remove "${DS_P_NAMES[$DS_CURSOR]}" || DS_MSG="[✗] 删除未完成"
                    fi
                fi
                ;;
            ' ')
                if [ "$DS_TAB" = "1" ]; then
                    ds_collect_providers 0
                    [ "${#DS_P_NAMES[@]}" -gt 0 ] && [ "$DS_CURSOR" -lt "${#DS_P_NAMES[@]}" ] && \
                        ds_toggle_provider "${DS_P_NAMES[$DS_CURSOR]}"
                fi
                ;;
        esac
        ;;
    #-------------------------------------------------------- 为 Agent 选接入商
    pick_provider)
        ds_collect_providers 1
        local rows=$(( ${#DS_P_NAMES[@]} + 1 ))
        case "$key" in
            UP|k)   DS_CURSOR=$((DS_CURSOR - 1)) ;;
            DOWN|j) DS_CURSOR=$((DS_CURSOR + 1)) ;;
            LEFT|ESC|q|Q) DS_VIEW="main"; DS_CURSOR=0; DS_OFFSET=0 ;;
            ENTER)
                [ "$rows" -gt 0 ] || return 0
                if [ "$DS_CURSOR" -ge "${#DS_P_NAMES[@]}" ]; then
                    ds_agent_off "$DS_AGENT"
                    DS_VIEW="main"; DS_CURSOR=0; DS_OFFSET=0
                else
                    DS_PROVIDER="${DS_P_NAMES[$DS_CURSOR]}"
                    if [ "$DS_AGENT" = "claude" ]; then
                        DS_VIEW="pick_mode"; DS_CURSOR=0
                    else
                        ds_apply_provider "$DS_AGENT" "$DS_PROVIDER"
                        DS_VIEW="main"; DS_CURSOR=0; DS_OFFSET=0
                    fi
                fi
                ;;
        esac
        ;;
    #--------------------------------------------------------------- Claude 模式
    pick_mode)
        case "$key" in
            UP|k)   DS_CURSOR=0 ;;
            DOWN|j) DS_CURSOR=1 ;;
            LEFT|ESC|q|Q) DS_VIEW="pick_provider"; DS_CURSOR=0 ;;
            ENTER)
                if [ "$DS_CURSOR" = "0" ]; then
                    ds_apply_provider "$DS_AGENT" "$DS_PROVIDER" settings
                else
                    ds_apply_provider "$DS_AGENT" "$DS_PROVIDER" env
                fi
                DS_VIEW="main"; DS_CURSOR=0; DS_OFFSET=0
                ;;
        esac
        ;;
    #------------------------------------------------------------ 接入商操作
    provider_actions)
        case "$key" in
            UP|k)   DS_CURSOR=$(( (DS_CURSOR + 2) % 3 )) ;;
            DOWN|j) DS_CURSOR=$(( (DS_CURSOR + 1) % 3 )) ;;
            LEFT|ESC|q|Q) DS_VIEW="main"; DS_CURSOR=0 ;;
            ENTER)
                case "$DS_CURSOR" in
                    0) ds_toggle_provider "$DS_PROVIDER" ;;
                    1) ds_start_edit "$DS_PROVIDER" ;;
                    2)
                        ds_form cmd_provider_remove "$DS_PROVIDER" || DS_MSG="[✗] 删除未完成"
                        provider_exists "$DS_PROVIDER" || { DS_VIEW="main"; DS_CURSOR=0; }
                        ;;
                esac
                ;;
        esac
        ;;
    #------------------------------------------------------------ 全屏表单
    form_provider)
        ds_handle_form "$key"
        ;;
    esac
    return 0
}

menu_dashboard() {
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        menu_main        # 非 TTY 回退经典菜单（数字输入）
        return 0
    fi
    ensure_dirs
    DS_TAB=0; DS_VIEW="main"; DS_CURSOR=0; DS_OFFSET=0; DS_MSG=""
    DS_TAB_CHAR=$(printf '\t')
    ds_enter
    while true; do
        ds_render
        local key
        key=$(tui_read_key)
        [ "$key" = "EOF" ] && break
        ds_handle "$key" || break
    done
    ds_exit
    printf '\n'
}

#-------------------------------------------------------------------------------
# 经典交互菜单（方向键 TUI，psw menu）
#-------------------------------------------------------------------------------

menu_providers() {
    while true; do
        ensure_dirs
        local names=() items=() n st bu
        for n in $(provider_list_names); do
            provider_load "$n" || continue
            if [ "$P_ENABLED" = "1" ]; then st="启用"; else st="禁用"; fi
            bu="$P_BASE_URL"
            [ ${#bu} -gt 40 ] && bu="${bu:0:37}..."
            names+=("$n")
            items+=("$(printf '%-14s %-10s %-4s %s' "$n" "$P_FORMAT" "$st" "$bu")")
        done
        items+=("＋ 添加接入商" "← 返回")
        if ! tui_select "== 接入商管理（Enter 进入，选择「＋」添加）==" "${items[@]}"; then
            return 0
        fi
        if [ "$TUI_IDX" -eq "${#names[@]}" ]; then
            printf '\n'
            ( cmd_provider_add )
        elif [ "$TUI_IDX" -eq $(( ${#names[@]} + 1 )) ]; then
            return 0
        else
            menu_provider_actions "${names[$TUI_IDX]}"
        fi
    done
}

menu_provider_actions() {
    local name="$1" toggle
    while true; do
        provider_load "$name" || return 0
        if [ "$P_ENABLED" = "1" ]; then toggle="禁用"; else toggle="启用"; fi
        tui_select "== 接入商: $name ($P_FORMAT, $P_BASE_URL) ==" \
            "$toggle 该接入商" "修改" "删除" "← 返回" || return 0
        case "$TUI_IDX" in
            0) if [ "$P_ENABLED" = "1" ]; then ( cmd_provider_enable "$name" 0 ); else ( cmd_provider_enable "$name" 1 ); fi ;;
            1) printf '\n'; ( cmd_provider_edit "$name" ) ;;
            2) printf '\n'; ( cmd_provider_remove "$name" ); provider_exists "$name" || return 0 ;;
            3) return 0 ;;
        esac
    done
}

menu_agents() {
    while true; do
        local items=() a prov mode
        for a in $AGENTS; do
            prov=$(kv_get "$STATE_DIR/$a" PROVIDER 2>/dev/null || true)
            mode=$(kv_get "$STATE_DIR/$a" MODE 2>/dev/null || true)
            if [ -n "$prov" ]; then
                items+=("$(printf '%-10s 当前: %s [%s]' "$a" "$prov" "$mode")")
            else
                items+=("$(printf '%-10s (默认配置)' "$a")")
            fi
        done
        items+=("← 返回")
        tui_select "== Agent 配置（Enter 进入对应 Agent）==" "${items[@]}" || return 0
        [ "$TUI_IDX" -eq $(( ${#items[@]} - 1 )) ] && return 0
        # AGENTS 是空格分隔字符串，按下标取词
        local i=0 target=""
        for a in $AGENTS; do
            [ "$i" = "$TUI_IDX" ] && target="$a"
            i=$((i+1))
        done
        [ -n "$target" ] && menu_agent_actions "$target"
    done
}

menu_agent_actions() {
    local agent="$1"
    while true; do
        local prov
        prov=$(kv_get "$STATE_DIR/$agent" PROVIDER 2>/dev/null || true)
        tui_select "== Agent: $agent (当前: ${prov:-默认}) ==" \
            "应用接入商" "关闭 (恢复默认配置)" "← 返回" || return 0
        case "$TUI_IDX" in
            0) menu_agent_pick_provider "$agent" ;;
            1) printf '\n'; ( cmd_agent_off "$agent" ) ;;
            2) return 0 ;;
        esac
    done
}

menu_agent_pick_provider() {
    local agent="$1"
    local names=() items=() n
    for n in $(provider_list_names); do
        provider_load "$n" || continue
        [ "$P_ENABLED" = "1" ] || continue
        names+=("$n")
        items+=("$(printf '%-14s %-10s %s (%s)' "$n" "$P_FORMAT" "$P_BASE_URL" "$P_MODEL")")
    done
    if [ "${#names[@]}" -eq 0 ]; then
        warn "没有已启用的接入商，请先在「接入商管理」中添加"
        return 1
    fi
    tui_select "== 选择要应用到 $agent 的接入商 ==" "${items[@]}" || return 0
    local provider="${names[$TUI_IDX]}"
    printf '\n'
    if [ "$agent" = "claude" ]; then
        tui_select "== 选择 Claude 配置方式 ==" \
            "settings 模式 (写入 ~/.claude/settings.json, 推荐)" \
            "env 模式 (生成环境变量文件, 需 install-shell)" || return 0
        case "$TUI_IDX" in
            0) ( cmd_agent_use "$agent" "$provider" --mode settings ) ;;
            1) ( cmd_agent_use "$agent" "$provider" --mode env ) ;;
        esac
    else
        ( cmd_agent_use "$agent" "$provider" )
    fi
    wait_key
}

menu_main() {
    while true; do
        tui_select "Power Switch v$PSW_VERSION — AI Agent 模型接入商管理" \
            "接入商管理" "Agent 配置" "状态总览" "安装 shell 环境 (install-shell)" "退出" \
            || exit 0
        case "$TUI_IDX" in
            0) menu_providers ;;
            1) menu_agents ;;
            2) printf '\n'; cmd_status; wait_key ;;
            3) printf '\n'; cmd_install_shell; wait_key ;;
            4) exit 0 ;;
        esac
    done
}

#-------------------------------------------------------------------------------
# 帮助
#-------------------------------------------------------------------------------

cmd_help() {
    cat <<EOF
power-switch (psw) v${PSW_VERSION} — AI Agent CLI 模型接入商管理

用法: psw <命令> [参数]        （不带参数进入全屏仪表盘）

交互界面:
  psw                                      全屏仪表盘（htop 风格，默认）
  psw dash                                 同上
  psw menu                                 经典方向键菜单
  仪表盘按键: ←/→ 或 Tab/1/2/3 切换标签，↑/↓ 移动，Enter 确认，
              a/e/d 添加/修改/删除接入商，空格 启/停，q 退出
  布局留白: POWER_SWITCH_PAD_X（左右，默认 2）
            POWER_SWITCH_PAD_Y（上下，默认 1）

接入商管理:
  psw provider list                          列出所有接入商
  psw provider show <名称>                   查看详情
  psw provider add [选项]                    添加接入商（无选项时交互式）
    --name N --preset P --format openai|anthropic
    --base-url URL --key KEY --model M --small-model M --wire-api responses|chat
      wire_api 同时用于 Codex、OpenCode 与 Hermes；anthropic 格式时忽略
      预设: $PRESETS custom
  psw provider edit <名称> [选项]            修改（无选项时交互式）
    --format openai|anthropic --base-url URL --key KEY
    --model M --small-model M --wire-api responses|chat（--key - 清除 Key）
  psw provider remove <名称>                 删除
  psw provider enable <名称>                 启用
  psw provider disable <名称>                禁用

Agent 配置 (支持: $AGENTS):
  psw agent <agent> use <接入商> [--model M] [--small-model M]
      claude 额外支持 [--mode settings|env]（默认 settings，写入 settings.json）
  psw agent <agent> off                      关闭，恢复默认配置
  psw agent <agent> status                   查看状态
  psw agent status                           所有 Agent 状态

其他:
  psw status                                 状态总览
  psw install-shell                          向 ~/.bashrc 等添加 env.sh 的 source 行
                                             （Codex 经环境变量读取 Key，必须执行）
  psw help                                   本帮助

数据目录: $PSW_HOME
  providers/<名称>   接入商数据（含 Key，权限 600）
  state/<agent>      各 Agent 当前使用的接入商
  env.sh             自动生成的环境变量文件

说明:
  - Claude Code 只支持 Anthropic 协议；openai 格式接入商需先经网关转换
  - 新版 Codex 只支持 Responses API；旧版可 psw provider edit <名称> --wire-api chat
  - OpenCode/Hermes 会按 wire_api 选择 Responses 或 Chat Completions
  - 每次修改配置文件前自动备份为 <文件>.psw-bak-<时间戳>（重名自动追加序号）
  - 跨平台: Linux / macOS / Windows (Git Bash, MSYS2, Cygwin, WSL)
EOF
}

#-------------------------------------------------------------------------------
# 入口
#-------------------------------------------------------------------------------

main() {
    [ $# -eq 0 ] && { menu_dashboard; return 0; }
    local cmd="$1"; shift
    case "$cmd" in
        dash|dashboard) menu_dashboard ;;
        menu)           menu_main ;;
        provider|p|providers)
            [ $# -eq 0 ] && { cmd_provider_list; return 0; }
            local sub="$1"; shift
            case "$sub" in
                list|ls)        cmd_provider_list ;;
                show)           [ $# -eq 1 ] || die "用法: psw provider show <名称>"; cmd_provider_show "$1" ;;
                add)            cmd_provider_add "$@" ;;
                edit)           [ $# -ge 1 ] || die "用法: psw provider edit <名称> [选项]"; cmd_provider_edit "$@" ;;
                remove|rm|del)  [ $# -eq 1 ] || die "用法: psw provider remove <名称>"; cmd_provider_remove "$1" ;;
                enable)         [ $# -eq 1 ] || die "用法: psw provider enable <名称>"; cmd_provider_enable "$1" 1 ;;
                disable)        [ $# -eq 1 ] || die "用法: psw provider disable <名称>"; cmd_provider_disable "$1" ;;
                *) die "未知 provider 子命令: $sub（见 psw help）" ;;
            esac
            ;;
        agent|a|agents)
            [ $# -ge 1 ] || { cmd_agent_status all; return 0; }
            case "$1" in
                status) [ $# -eq 1 ] || die "用法: psw agent status"; cmd_agent_status all ;;
                *)
                    local agent="$1"; shift
                    [ $# -ge 1 ] || die "用法: psw agent <agent> use|off|status ..."
                    local sub="$1"; shift
                    case "$sub" in
                        use)    [ $# -ge 1 ] || die "用法: psw agent $agent use <接入商> [选项]"; cmd_agent_use "$agent" "$@" ;;
                        off)    [ $# -eq 0 ] || die "用法: psw agent $agent off"; cmd_agent_off "$agent" ;;
                        status) [ $# -eq 0 ] || die "用法: psw agent $agent status"; cmd_agent_status "$agent" ;;
                        *) die "未知 agent 子命令: $sub（use|off|status）" ;;
                    esac
                    ;;
            esac
            ;;
        status|st)          cmd_status ;;
        install-shell)      cmd_install_shell ;;
        presets)            printf '%s\n' $PRESETS custom ;;
        version|-v|--version) echo "power-switch v$PSW_VERSION" ;;
        help|-h|--help)     cmd_help ;;
        *) die "未知命令: $cmd（见 psw help）" ;;
    esac
}

# provider disable 的别名实现（复用 enable 函数）
cmd_provider_disable() { cmd_provider_enable "$1" 0; }

main "$@"
