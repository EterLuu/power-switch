# Power Switch (psw)

一个纯 Bash 脚本，用于管理 AI Agent CLI 的模型接入商（Provider），支持接入商的
**添加 / 修改 / 删除 / 启用 / 禁用**，并可将接入商一键应用到各 Agent 的配置文件。

- 支持的 Agent：**Claude Code、Codex、OpenCode、Hermes**
- 支持的 API 格式：**OpenAI 格式** 与 **Anthropic 格式**
- 跨平台：**Linux / macOS / Windows（Git Bash、MSYS2、Cygwin、WSL）**
- 兼容 **bash 3.2+**（macOS 自带 bash 即可运行），JSON 编辑自动选用 `jq` / `python3` / `node` 中任意一个

## 安装

```bash
chmod +x power-switch.sh
# 建议加入 PATH，例如:
sudo ln -s "$PWD/power-switch.sh" /usr/local/bin/psw
```

不带参数运行进入**全屏仪表盘**（htop 风格）：

```bash
psw            # 全屏仪表盘（默认）
psw menu       # 经典方向键菜单
```

仪表盘布局：

```
 Power Switch v1.0.0 │ 概览 │ 接入商 │ 帮助 │
──────────────────────────────────────────────
  Agent       接入商            模式        应用时间
❯ claude      kimi              settings    2026-07-22 09:27
  codex       (默认)            -           -
  ...
──────────────────────────────────────────────
 ←/→ 或 1-3 切换标签  ↑/↓ 移动  Enter 切换该 Agent 接入商  q 退出
```

- **←/→**（或 `Tab`/`1`/`2`/`3`）切换顶栏标签；**↑/↓** 移动；**Enter** 确认；**←/Esc/q** 返回/退出
- **概览**（默认页）：实时显示所有 Agent 当前接入商；Enter 直接为选中 Agent 切换接入商（或选「⊘ 关闭」恢复默认）
- **接入商**页：`a` 添加、`e` 修改、`d` 删除、`空格` 快速启停、Enter 进入操作菜单
- 非 TTY 环境（管道/重定向）自动回退为数字输入菜单

## 快速开始

```bash
# 1. 添加接入商（选 deepseek 预设会自动填充 API 地址和模型）
psw provider add
# 或非交互:
psw provider add --name deepseek --preset deepseek --format anthropic --key sk-xxx

# 2. 应用到 Claude Code（写入 ~/.claude/settings.json 的 env，保留原有 hooks 等配置）
psw agent claude use deepseek

# 3. 应用到 Codex（写入 ~/.codex/config.toml；Key 经环境变量注入）
psw agent codex use deepseek
psw install-shell        # 向 ~/.bashrc / ~/.zshrc 添加 env.sh 的 source 行（Codex 必需）

# 4. 应用到 OpenCode / Hermes
psw agent opencode use deepseek
psw agent hermes  use deepseek

# 5. 查看状态 / 恢复默认
psw status
psw agent claude off
```

## 命令参考

### 接入商管理

| 命令 | 说明 |
|---|---|
| `psw provider list` | 列出所有接入商 |
| `psw provider show <名称>` | 查看详情（Key 打码显示） |
| `psw provider add [选项]` | 添加（无选项时交互式） |
| `psw provider edit <名称> [选项]` | 修改（无选项时交互式，回车保留原值） |
| `psw provider remove <名称>` | 删除（正被 Agent 使用时拒绝） |
| `psw provider enable <名称>` | 启用 |
| `psw provider disable <名称>` | 禁用（禁用后不可应用到 Agent） |

`add`/`edit` 选项：`--name --preset --format openai|anthropic --base-url --key --model --small-model --wire-api responses|chat`

预设模板（自动填充 Base URL 与模型）：`deepseek`、`kimi`、`glm`、`huawei`、`openai`、`anthropic`、`openrouter`、`ollama`、`local`、`custom`。

### Agent 配置

| 命令 | 说明 |
|---|---|
| `psw agent <agent> use <接入商> [--model M] [--small-model M]` | 应用接入商 |
| `psw agent claude use <接入商> --mode env` | Claude 改用环境变量文件方式 |
| `psw agent <agent> off` | 移除 psw 管理的配置，恢复默认 |
| `psw agent <agent> status` / `psw agent status` | 查看状态 |
| `psw status` | 状态总览 |
| `psw install-shell` | 安装 shell 环境变量 source 行 |

## 数据存储

```
${XDG_CONFIG_HOME:-~/.config}/power-switch/
├── providers/<名称>   # 接入商数据（含 Key，权限 600）
├── state/<agent>      # 各 Agent 当前使用的接入商
├── env.sh             # 自动生成的环境变量（PSW_<名称>_API_KEY）
└── env/claude.sh      # Claude env 模式的变量文件
```

每次修改 Agent 配置文件前自动备份为 `<文件>.psw-bak-<时间戳>`。

## 各 Agent 的配置机制

| Agent | 配置文件 | 接入方式 |
|---|---|---|
| Claude Code | `~/.claude/settings.json` 的 `env` | 写入 `ANTHROPIC_BASE_URL/AUTH_TOKEN/MODEL/...`，仅支持 Anthropic 协议 |
| Codex | `~/.codex/config.toml` | 新增 `[model_providers.psw_<名称>]`，`env_key` 指向环境变量；新版仅支持 Responses API（旧版可 `--wire-api chat`） |
| OpenCode | `~/.config/opencode/opencode.json` | 新增 `provider.<名称>`，按格式选用 `@ai-sdk/openai-compatible` 或 `@ai-sdk/anthropic` |
| Hermes | `~/.hermes/config.yaml` | 写入 `model:` 段（`base_url` 直调，自动按端点走对应协议） |

注意：Claude Code 只讲 Anthropic Messages 协议，OpenAI 格式的接入商需先经
One-API / LiteLLM 等网关转换后再接入。详细调研见 [docs/agent-config-research.md](docs/agent-config-research.md)。

## 环境变量

- `POWER_SWITCH_HOME`：覆盖数据目录（默认 `${XDG_CONFIG_HOME:-~/.config}/power-switch`）
- `NO_COLOR`：禁用彩色输出
