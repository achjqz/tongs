# tongs

**让 AI 编程 agent 用你的 API key，但永远看不到它。**

[English](README.md)

Claude Code、Codex 这类 agent 经常需要凭据：GitHub token、Stripe key、数据库密码。常见做法要么是把 key 贴进对话，要么是留在明文 `.env` 里。无论哪种，值都会进 agent 的对话记录：每一轮都会重新发给模型服务商，还会一直留在磁盘上。

tongs 把密钥放在 macOS 钥匙串里，agent 只通过**名字**使用：

```console
$ tongs request STRIPE_SECRET_KEY --why "部署脚本要创建支付链接"
stored shop/STRIPE_SECRET_KEY (project shop, 107 chars). Use it with: tongs run STRIPE_SECRET_KEY -- <command>

$ tongs run STRIPE_SECRET_KEY -- sh -c 'curl -sv https://api.stripe.com/v1/balance -u "$STRIPE_SECRET_KEY:"'
> Authorization: Basic ‹redacted:STRIPE_SECRET_KEY›…
```

- **让人粘贴，不经过对话**：`tongs request` 弹出原生面板，由人在里面粘贴；agent 只知道"已存好"。
- **注入后打码**：`tongs run` 把值放进子进程的环境变量，并把输出里的原值、Base64 和 URL 编码形式都替换掉。
- **Touch ID 审批**：某个 agent 第一次在某个项目里用某个密钥时，需要按一次 Touch ID，有效期 12 小时。
- **堵住旁路**：给 Claude Code 和 Codex 装一个 PreToolUse hook，不让 agent 直接读钥匙串。
- **没有常驻进程**：没有后台服务，也没有菜单栏图标，弹窗都由当次 CLI 调用临时拉起。

## 系统要求

macOS 15 及以上。录入面板在 macOS 26+ 使用 Liquid Glass，在 15 上使用系统毛玻璃。

## 安装

从源码构建（需要 Swift 6.2 / Xcode 26）：

```bash
git clone https://github.com/<you>/tongs && cd tongs
swift build -c release
ln -sf "$PWD/.build/release/tongs" ~/.local/bin/tongs
tongs doctor
```

接入 agent（不加 `--apply` 只打印将要做的改动；加上后，每个被改的文件会保留一份 `.tongs-backup`）：

```bash
tongs setup claude --apply   # PreToolUse 守卫 hook + ~/.claude/skills/tongs
tongs setup codex --apply    # ~/.codex/hooks.json + AGENTS.md 片段 + ~/.codex/rules/tongs.rules
```

`tongs setup claude|codex --remove --apply` 可以撤销，已存的密钥不受影响。

## 命令

| 命令 | 作用 |
|---|---|
| `tongs ls [--all] [--json]` | 列出当前能用的密钥：名字、作用范围、说明。不取值，不弹窗 |
| `tongs run NAME... -- CMD` | 把每个 `NAME` 作为环境变量注入 `CMD`，并给输出打码 |
| `tongs request NAME [--why T] [--url U] [--global]` | 弹出原生面板，让人粘贴密钥 |
| `tongs add NAME [--desc T] [--global]` | 自己录入（隐藏输入，或从 stdin 读） |
| `tongs rm NAME` | 删除（需要 Touch ID） |
| `tongs grants` / `tongs revoke [NAME] [--agent A]` | 查看 / 撤销授权 |
| `tongs log [-n N]` | 活动记录：谁、在哪个项目、为哪条命令用了什么（不含值） |
| `tongs doctor` | 检查当前环境能否访问钥匙串、Touch ID 和面板 |
| `tongs hook` | PreToolUse 守卫（从 stdin 读 hook JSON） |

shell 会在 tongs 运行前就把 `$NAME` 展开，而那时它是空的。如果命令行本身要用到这个值，要用单引号包起来：`tongs run GH_TOKEN -- sh -c 'curl -H "Authorization: Bearer $GH_TOKEN" …'`。

## 命名与作用范围

- 名字用环境变量风格，最好直接用调用它的工具文档里写的变量名（`STRIPE_SECRET_KEY`、`DATABASE_URL`、`GH_TOKEN`），不要把项目名写进名字。
- 密钥要么是**全局**的（`NAME`），要么属于某个**项目**（`<项目>/NAME`）。项目就是所在 git 仓库的目录名；worktree 会归到它的主仓库，所以在 worktree 里干活的 agent 和主仓库共用同一套密钥和授权。
- `tongs run NAME` 先找当前项目的 `NAME`，没有再用全局的；注入的环境变量名始终是 `NAME`。
- `tongs request` 默认存到当前项目；`--global` 用于每个项目都共用的个人账号凭据。面板里可以改。

## agent 与沙箱

agent 的沙箱（Codex 的 Seatbelt、Claude Code 的 sandbox）会挡住钥匙串、LocalAuthentication、WindowServer 和本地 socket，所以 tongs 必须在沙箱外运行。`tongs setup codex` 会加上 Codex 规则：`ls`、`request` 直接放行，`run` 设为 `prompt`，Codex 会先把命令给你看，再在沙箱外执行。开了 Claude Code 沙箱的话，要把 `tongs` 加进 `sandbox.excludedCommands`。

这意味着 `tongs run` 是一个经你批准的沙箱出口。具体能防什么、不能防什么，见 [SECURITY.md](SECURITY.md)。

## 开发

```bash
swift test                                    # 打码、授权签名、命名、守卫规则
TONGS_SERVICE=dev.tongs.test tongs …          # 测试数据和真实密钥分开放
TONGS_UI_PREVIEW="filled,dark,snap=/tmp/p.png" tongs request DEMO --why preview
```

`TONGS_UI_PREVIEW` 有这些选项：
- `filled`：预填一个假值；
- `light` / `dark`：强制深浅色；
- `legacy`：强制显示 macOS 15 的样式；
- `snap=`：把面板截图存到指定路径后退出。进程截自己的窗口不需要录屏权限，但截不到玻璃后面的桌面。

从源码构建的是 ad-hoc 签名，每次构建签名都会变。钥匙串会把新版本当成另一个程序，每个密钥都会问一次登录密码，选"始终允许"就行。用 Developer ID 签名的正式版本不会有这个问题。

## 许可证

[Apache-2.0](LICENSE)
