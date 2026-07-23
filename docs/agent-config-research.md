# Agent CLI 自定义模型接入配置调研

> 调研时间：2026-07。本文是 power-switch 脚本各 Agent 适配器的设计依据。
> 信息来源见各节末尾。

## 总览

| 工具 | 配置文件 | 协议要求 | Key 存放 |
|---|---|---|---|
| Claude Code | `~/.claude/settings.json` 的 `env` | 仅 Anthropic Messages | 直接写 env 值 |
| Codex CLI | `~/.codex/config.toml` `[model_providers.x]` | 新版仅 Responses（`chat` 已移除） | `env_key` 指向环境变量 |
| OpenCode | `~/.config/opencode/opencode.json` `provider` | OpenAI 兼容 / Anthropic 兼容均可 | 直接写或 `{env:VAR}` 引用 |
| Hermes | `~/.hermes/config.yaml` + `~/.hermes/.env` | `base_url` 直调，按端点路径自动识别 | `api_key` 或 `.env` |

## 1. Claude Code

**机制确认**：`settings.json` 的 `env` 字段会被 Claude Code 读取——启动时把键值写入进程环境，
应用到每个会话及其子进程。同一变量同时出现在 shell 与 `env` 中时，**settings.json 胜出**；
保存后运行中的会话会重新应用。设为空字符串 `""` 等价于 unset。

关键变量：

| 变量 | 含义 |
|---|---|
| `ANTHROPIC_BASE_URL` | 覆盖 API 端点（代理/网关/中转） |
| `ANTHROPIC_AUTH_TOKEN` | 自定义 `Authorization` 头，自动加 `Bearer ` 前缀 |
| `ANTHROPIC_API_KEY` | 作为 `X-Api-Key` 头发送；与 AUTH_TOKEN 二选一 |
| `ANTHROPIC_MODEL` | 主模型 |
| `ANTHROPIC_SMALL_FAST_MODEL` | Haiku 级后台小模型（已标记 DEPRECATED） |
| `ANTHROPIC_DEFAULT_OPUS_MODEL` / `ANTHROPIC_DEFAULT_SONNET_MODEL` | 档位默认模型 |
| `ANTHROPIC_CUSTOM_HEADERS` | 附加请求头，`Name: Value` 多行 |
| `API_TIMEOUT_MS` | 请求超时（默认 600000） |

示例（Anthropic 格式中转）：

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://your-gateway.example.com",
    "ANTHROPIC_AUTH_TOKEN": "sk-your-key",
    "ANTHROPIC_MODEL": "claude-sonnet-4-5",
    "ANTHROPIC_SMALL_FAST_MODEL": "claude-haiku-4-5"
  }
}
```

**注意**：OpenAI 格式端点不能直接配，需 One-API / LiteLLM 等网关转换为 Anthropic 协议。
power-switch 写入时必须**合并** `.env`，保留用户已有的 `hooks`、`theme` 等配置。

来源：https://code.claude.com/docs/en/settings ，https://code.claude.com/docs/en/env-vars

## 2. Codex CLI（OpenAI）

**重要变更（2026，源码核实）**：`openai/codex` main 分支的 `WireApi` 枚举只剩 `Responses` 一个变体；
`wire_api = "chat"` 已被移除，配置它会直接报错（见 GitHub discussion #7782）。
即新版 Codex 要求自定义 provider 提供 **OpenAI Responses API**；只支持 Chat Completions 的
中转需升级网关或使用旧版 Codex。power-switch 因此默认 `wire_api=responses`，并允许
`psw provider edit <名称> --wire-api chat` 适配旧版。

`ModelProviderInfo` 主要字段：`name`、`base_url`、`env_key`、`wire_api`、`query_params`、
`http_headers`、`env_http_headers`、`request_max_retries`、`stream_max_retries`、
`stream_idle_timeout_ms` 等。内建保留 ID 不可复用：`openai`、`ollama`、`lmstudio`。

示例：

```toml
model = "gpt-5.4"
model_provider = "myproxy"

[model_providers.myproxy]
name = "My LLM Proxy"
base_url = "https://proxy.example.com/v1"
env_key = "MY_PROXY_API_KEY"     # Key 从环境变量读取，不写进配置文件
wire_api = "responses"           # 新版只支持 responses；旧版可用 "chat"
```

TOML 顶层键（`model`、`model_provider`）必须出现在任何 `[section]` 之前——power-switch
写入时把顶层键放在文件头部，provider 段放末尾，并保留 `projects`/`features` 等既有段。

Codex **不支持 Anthropic 原生协议**。

来源：https://learn.chatgpt.com/docs/config-file/config-advanced ，
https://github.com/openai/codex/blob/main/codex-rs/model-provider-info/src/lib.rs

## 3. OpenCode

配置文件：项目根 `opencode.json` 或全局 `~/.config/opencode/opencode.json`；
顶层键为 `provider`，schema 为 `https://opencode.ai/config.json`。
支持 `{env:VARIABLE_NAME}` 语法引用环境变量。

自定义 OpenAI 兼容 provider（Chat Completions 用 `@ai-sdk/openai-compatible`；
Responses API 用 `@ai-sdk/openai`）：

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "myprovider": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "My AI Provider",
      "options": {
        "baseURL": "https://api.myprovider.com/v1",
        "apiKey": "{env:MYPROVIDER_API_KEY}"
      },
      "models": {
        "my-model": { "name": "My Model" }
      }
    }
  }
}
```

自定义 Anthropic 兼容 provider：同一结构，`npm` 换成 `@ai-sdk/anthropic`。
当前模型选择写为顶层 `"model": "<provider>/<model>"`。

来源：https://opencode.ai/docs/providers/ ，https://opencode.ai/docs/config/

## 4. Hermes（NousResearch/hermes-agent）

GitHub: https://github.com/NousResearch/hermes-agent （注意 `hermes-agent.app` 等域名是
蹭流量的非官方站，以 GitHub 仓库和 `hermes-agent.nousresearch.com` 为准）。

配置文件：
- `~/.hermes/config.yaml` — 非敏感设置
- `~/.hermes/.env` — 密钥

官方原文："When `base_url` is set, Hermes ignores the provider and calls that endpoint
directly (using `api_key` or `OPENAI_API_KEY` for auth)." 端点路径含 `/anthropic` 时
自动走 Anthropic 格式。

```yaml
model:
  default: MiniMax-M2.7
  provider: custom
  base_url: https://api.minimax.io/anthropic
  api_key: sk-...
```

交互式切换命令：`hermes model`。

来源：https://github.com/NousResearch/hermes-agent ，
https://hermes-agent.nousresearch.com/docs/user-guide/configuration

## 5. 常见接入商端点（power-switch 预设）

| 预设 | OpenAI 格式 | Anthropic 格式 |
|---|---|---|
| DeepSeek | `https://api.deepseek.com/v1` | `https://api.deepseek.com/anthropic` |
| Kimi（月之暗面） | `https://api.moonshot.cn/v1` | `https://api.moonshot.cn/anthropic` |
| 智谱 GLM | `https://open.bigmodel.cn/api/paas/v4` | `https://open.bigmodel.cn/api/anthropic` |
| 华为 ModelArts | — | `https://api.modelarts-maas.com/anthropic` |
| OpenAI | `https://api.openai.com/v1` | — |
| Anthropic | — | `https://api.anthropic.com` |
| OpenRouter | `https://openrouter.ai/api/v1` | — |
| Ollama | `http://localhost:11434/v1` | — |

## 6. 实现要点（跨平台）

- Windows 下这些工具同样使用 `%USERPROFILE%` 下的配置目录（Git Bash 中即 `$HOME`），
  因此 `$HOME/.claude` 等路径三平台一致；Windows 需经 Git Bash / MSYS2 / Cygwin / WSL 运行。
- macOS 自带 bash 3.2：避免关联数组、`mapfile`、`${var^^}`、负数子串偏移等 bash 4+ 特性。
- JSON 编辑按 `jq → python3 → node` 顺序探测可用后端；TOML/YAML 用 awk 做行级手术，
  只管理脚本自己写入的段落，其余内容原样保留。
- 每次写配置前备份为 `<文件>.psw-bak-<时间戳>`。
