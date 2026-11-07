# kv（MVP）

让 AI agent 用名字使用密钥，而看不到值。密钥存在 macOS 钥匙串里；没有常驻进程，所有交互（Touch ID、录入对话框）都由 CLI 在当次调用里拉起。

## 构建与安装

需要 macOS 15+。录入面板在 macOS 26+ 用 Liquid Glass，在 15 上退回系统毛玻璃（`NSVisualEffectView`）和普通按钮，布局相同；`KV_UI_PREVIEW` 里加 `legacy` 可以在新系统上预览旧样式。

```bash
swift build -c release
ln -sf "$PWD/.build/release/kv" ~/.local/bin/kv
kv doctor
```

接入 agent（默认只打印将要做的改动，加 `--apply` 才写入，并为每个被改的文件保留一次 `.kv-backup`）：

```bash
kv setup claude   # PreToolUse 守卫 hook + ~/.claude/skills/kv/SKILL.md
kv setup codex    # ~/.codex/hooks.json + AGENTS.md 片段 + ~/.codex/rules/kv.rules
```

## 命令

| 命令 | 作用 |
|---|---|
| `kv ls [--json]` | 列出名字和说明，只读属性，不取值、不触发授权 |
| `kv run NAME... -- CMD` | 把 NAME 作为同名环境变量注入 CMD；stdout/stderr 流式打码为 `‹redacted:NAME›` |
| `kv request NAME --why … --url …` | 弹原生对话框让人粘贴；agent 只拿到“已存好、N 个字符、像 GitHub token”。输入框不是 `NSSecureTextField`（它会开启 Secure Event Input，挡住剪贴板工具的 ⌥V 等全局快捷键），粘贴后立即替换成掩码显示；窗口不置顶、不抢焦点，用户在别的应用里时只在 Dock 弹跳提示 |
| `kv add NAME` | 人自己录入（隐藏输入，或 stdin） |
| `kv rm NAME` | 删除，需要 Touch ID |
| `kv grants` / `kv revoke` | 查看 / 撤销授权 |
| `kv log` | 活动记录（不含值） |
| `kv hook` | 守卫：拦截 `security find-*-password`、`dump-keychain`、读 `Library/Keychains`；exit 2 拦截，Claude Code 和 Codex 通用 |

## 录入面板

`kv request` 弹出的是 SwiftUI 写的无边框玻璃卡片（`glassEffect`、`.glass` / `.glassProminent` 按钮、分段选择可用范围），跟随系统深浅色，可拖动。调外观时可以让面板截下自己（进程截取自己的窗口不需要录屏权限）：

```bash
KV_SERVICE=dev.kv.test KV_UI_PREVIEW="filled,dark,snap=/tmp/panel.png" kv request DEMO --why "预览"
```

自截图拍不到窗口后面的桌面，所以玻璃在截图里是平的灰色，真机上会透出并模糊背后的内容。

## 命名与作用范围

- 名字统一用环境变量风格（`STRIPE_SECRET_KEY`、`DATABASE_URL`、`GH_TOKEN`），按使用它的工具文档里的变量名取，不要把项目名写进名字。
- 每个密钥要么属于某个项目，存为 `<项目>/NAME`；要么是全局的，存为 `NAME`。项目 = 所在 git 仓库的目录名；agent 用的 worktree 会归到它的主仓库，所以共享同一套密钥和授权。不在 git 仓库里时只有全局密钥。
- `kv run NAME` 先找当前项目的 `NAME`，没有再用全局的；注入的环境变量名总是 `NAME`。也可以写全名 `shop/NAME` 显式指定。
- `kv request` 默认存到当前项目，`--global` 用于跨项目共用的个人账号凭据；对话框里可以改。`kv add` 在仓库里默认存到项目，不在仓库里或加 `--global` 时存为全局。
- `kv ls` 先列当前项目的，再列全局的，并标出被项目密钥覆盖的全局项；`kv ls --all` 列出所有项目。

## 安全模型

- **存储**：login keychain 的 generic password，service `dev.kv.secrets`，account 为名字。条目 ACL 只信任创建它的 kv 二进制，别的程序（例如 agent 直接调 `security … -w`）读取会触发系统密码弹窗。
- **审批**：某 agent 在某项目第一次用某密钥时弹 Touch ID，原因里写清 agent、项目、密钥和命令；批准后 12 小时内同组合不再询问。
- **授权记录防伪造**：`~/Library/Application Support/kv/grants.json` 每条带 HMAC，密钥存在钥匙串里。agent 能删授权（只会让它更受限），伪造不了。
- **输出打码**：原值、URL 编码，以及 3 种字节对齐下的 Base64 核心串（能抓到 `Authorization: Basic base64(user:token)`）。跨读取块的部分匹配会暂扣到下一块再判断。

## 验证结果（2026-10-28，macOS 27，本机）

| 项目 | 普通 shell / Claude Code（未开沙箱） | Codex seatbelt 沙箱内 |
|---|---|---|
| 读写钥匙串 | ✓ | ✗ `One or more parameters … not valid` |
| Touch ID 审批 | ✓（人工按指纹通过） | ✗ `Couldn't communicate with a helper application` |
| 原生录入对话框 | ✓（人工录入 7 个字符后存入） | ✗ 连不上 WindowServer |
| 写状态目录（授权、日志） | ✓ | ✗ 无写权限 |
| 连本地 unix socket | — | ✗ `Operation not permitted` |
| 输出打码（原值 / stderr / Base64 嵌入） | ✓ | — |
| 退出码透传、授权复用 | ✓ | — |
| `security` 直接读 kv 条目 | 弹系统密码框；拒绝后 exit 128 | — |

接入验证（2026-11-07，`kv setup claude|codex --apply` 之后）：

- Claude Code：hook 在已打开的会话里即时生效，`security find-generic-password … -w` 被拦截，其他工具调用照常；skill 同样即时出现。
- Codex（0.167，`hooks` 特性默认开启）：`codex execpolicy check` 显示 `kv ls` / `kv request` → allow，`kv run` → prompt，其他 `kv` 子命令不受特殊对待。检查器不会拆开 `zsh -lc "kv …"`，运行时是否会拆开、新 hook 是否需要先在 `/hooks` 里信任，都要在真实 Codex 会话里确认。

单元测试：`swift test`，9 个用例覆盖跨块打码、逐字节输入、Basic auth、百分号编码、授权签名与过期、守卫规则。

## 关键发现

1. **kv 必须在 agent 沙箱之外运行。** Codex 沙箱把钥匙串、LocalAuthentication、WindowServer、unix socket 全挡了，所以“按需拉起的 launchd helper”在沙箱里也连不上，不能靠它绕。可行的路是 agent 自带的放行机制：Codex 用 `~/.codex/rules/kv.rules`（`ls`、`request` 直接放行，`run` 设为 `prompt`，由 Codex 先把命令给人看）；Claude Code 开沙箱时对应 `sandbox.excludedCommands`。
2. **这带来一个必须正视的问题：`kv run` 在沙箱外执行 agent 给的命令。** 等于一个经批准的沙箱出口。MVP 用 Codex 的 `prompt` 规则兜底；产品化时应考虑让 kv 在注入后再把子进程放回等价的沙箱里。
3. **ad-hoc 签名每次重新构建都会变**，钥匙串会把新二进制当成陌生程序，再次读取旧条目要输密码。开发时用 `KV_SERVICE=dev.kv.<随便>` 隔离测试数据；正式分发需要 Developer ID 签名来获得稳定身份。

## 已知限制

- `kv run X -- sh -c 'echo $X | rev'` 这类自行变换后输出的方式能绕过打码；审批弹窗显示命令，但 12 小时授权期内不再逐条审查。
- 子进程的 stdout 是管道不是 TTY，彩色输出、交互式程序会退化。
- agent 识别靠进程祖先和环境变量，只用于展示和授权分组，不是安全边界（识别不到时记为 Terminal，照样要审批）。
- Codex 的 rules 是否能匹配 `zsh -lc "kv …"` 这种包装形式、hooks 是否需要额外 feature flag，还没在真实 Codex 会话里验证。

## 清理测试数据

测试用的条目在 service `dev.kv.test1` 下（`TEST_TOKEN`、`DEMO_KEY`、`__kv_grant_key__`），可在“钥匙串访问”里搜索 `kv:` 删除。
