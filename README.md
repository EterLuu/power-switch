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

  ⚡ Power Switch v1.1.0   概览   接入商   帮助
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   Agent       接入商            模式        应用时间
  ❯ claude      kimi              settings    2026-07-22 09:27
    codex       (默认)            -           -
    ...
  ──────────────────────────────────────────────
  数据目录: ~/.config/power-switch  │  JSON 后端: python3
   ←/→ 标签  ↑/↓ 移动  Enter 切换接入商  q 退出

```

- **←/→**（或 `Tab`/`1`/`2`/`3`）切换顶栏标签；**↑/↓** 移动；**Enter** 确认；**←/Esc/q** 返回/退出
- **概览**（默认页）：实时显示所有 Agent 当前接入商；Enter 直接为选中 Agent 切换接入商（或选「⊘ 关闭」恢复默认）
- **接入商**页：`a` 添加、`e` 修改、`d` 删除、`空格` 快速启停、Enter 进入操作菜单
- 界面默认保留上下 1 行、左右 2 列的 padding；长 URL/模型会自适应截断，终端过小时显示尺寸提示
- 全屏表单修改 API Key 时，留空保留原值，输入 `-` 清除
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
| `psw provider disable <名称>` | 禁用（禁止后续应用；已写入 Agent 的配置不会自动失效） |

`add` 选项：`--name --preset --format openai|anthropic --base-url --key --model --small-model --wire-api responses|chat`。

`edit` 选项：`--format --base-url --key --model --small-model --wire-api`；使用 `--key -` 可清除已有 Key。

`--wire-api` 表示 OpenAI 格式接入商使用的协议，同时控制 Codex、OpenCode 与 Hermes：
`responses` 选择 Responses API，`chat` 选择 Chat Completions。新版 Codex 只接受
`responses`；Anthropic 格式接入商忽略此选项。

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
├── env.sh             # 自动生成的环境变量（名称使用无碰撞可逆编码）
└── env/claude.sh      # Claude env 模式的变量文件
```

每次修改 Agent 配置文件前自动备份为 `<文件>.psw-bak-<时间戳>`；同一秒内有多次写入时自动追加序号，避免覆盖备份。

环境变量名使用 `PSW2_<名称的 ASCII 十六进制>_API_KEY` 可逆编码。例如
`foo-bar` 与 `foo_bar` 分别使用 `PSW2_666F6F2D626172_API_KEY` 和
`PSW2_666F6F5F626172_API_KEY`；编码结果不依赖环境变量名是否区分大小写。
升级后会为没有名称碰撞的接入商继续生成 1.0.x `PSW_...` 旧变量名作为兼容别名；
发生碰撞的旧变量名因含义不明确而不会生成。

## 各 Agent 的配置机制

| Agent | 配置文件 | 接入方式 |
|---|---|---|
| Claude Code | `~/.claude/settings.json` 的 `env` | 写入 `ANTHROPIC_BASE_URL/AUTH_TOKEN/MODEL/...`，仅支持 Anthropic 协议 |
| Codex | `~/.codex/config.toml` | 新增 `[model_providers.psw_<名称>]`，`env_key` 指向环境变量；新版仅支持 Responses API（旧版可 `--wire-api chat`） |
| OpenCode | `~/.config/opencode/opencode.json` | Anthropic 使用 `@ai-sdk/anthropic`；OpenAI 按 `wire_api` 使用 `@ai-sdk/openai`（Responses）或 `@ai-sdk/openai-compatible`（Chat） |
| Hermes | `~/.hermes/config.yaml` | 写入 `model:` 段，明确设置 `anthropic_messages`、`codex_responses` 或 `chat_completions` |

注意：Claude Code 只讲 Anthropic Messages 协议，OpenAI 格式的接入商需先经
One-API / LiteLLM 等网关转换后再接入。详细调研见 [docs/agent-config-research.md](docs/agent-config-research.md)。

## 环境变量

- `POWER_SWITCH_HOME`：覆盖数据目录（默认 `${XDG_CONFIG_HOME:-~/.config}/power-switch`）
- `POWER_SWITCH_PAD_X`：仪表盘左右 padding，默认 `2`
- `POWER_SWITCH_PAD_Y`：仪表盘上下 padding，默认 `1`
- `NO_COLOR`：禁用彩色输出

## 测试

测试用例统一保存在 `tests/`，所有配置均写入临时目录，不会修改用户的 Agent 配置：

```bash
./tests/run.sh
```

其中 CLI 测试覆盖接入商管理和四个 Agent 配置适配；TUI 测试覆盖 padding、底部状态栏、
小终端提示和主要交互流程。TUI 测试依赖 util-linux `script` 与 `perl`，缺失时会自动跳过。
