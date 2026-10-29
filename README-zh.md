# Hermit

[English](README.md) · **中文**

**Hermit 是 iPhone 和 iPad 上的 SSH / Mosh 终端，用于在远程机器上操作 coding agent。**
支持 tmux、herdr、直连 SSH、Cloudflare Access 和内置 Tailscale，提供本地及可选云端语音输入，
并在锁屏和灵动岛展示连接与任务状态。

Hermit 在本仓库维护，基于 [Cluas 的 Moshpit](https://github.com/Cluas/moshpit)
继续开发，保留上游来源、原有版权及许可证声明。

[代码仓库](https://github.com/Aias00/hermit) ·
[架构文档](docs/ARCHITECTURE.md) ·
[构建指南](CONTRIBUTING.md) ·
[问题反馈](https://github.com/Aias00/hermit/issues)

## 截图

以下截图继承自上游 Moshpit，展示终端、agent 状态和图标功能。Hermit 当前的主机列表
和语音审阅流程已在此基础上调整。

| Agent 状态 | Agent 的窗格 | tmux 窗口 | 锁屏通知 | 九个图标 |
|---|---|---|---|---|
| ![上游主界面的 agent 状态](docs/assets/agents.png) | ![终端中的 Claude Code 窗格](docs/assets/agent-terminal.png) | ![带 agent 状态的 tmux 窗口列表](docs/assets/tmux-windows.png) | ![锁屏上的主机加密通知](docs/assets/lock-screen.png) | ![Liquid Glass 图标库](docs/assets/icons.png) |

## 功能

**终端与连接**

- SSH 和 Mosh，提供网络切换后的连接恢复与诊断。
- 可配置的 [Cloudflare Access](docs/design/cloudflare-herdr-access.md) 和
  [内置 Tailscale](docs/design/tailcat-ssh.md) 接入，以及实验性的 Tailcat 传输。
- tmux 控制模式，原生渲染、窗口与窗格导航、会话管理。
- 支持 [herdr](https://github.com/herdrdev/herdr)，一次渲染一个满宽窗格。
- iPad 主机侧栏、原生选择器、外接键盘快捷键、自定义主题与字体、快捷键栏、输入法组合输入和可点击链接。

**输入与会话状态**

- Apple 设备端语音识别和可选的本地 Whisper 模型。停止录音后可以审阅、编辑、
  换语言重新识别或恢复最初结果，再加入草稿。
- 本地技术词表支持项目名和工具名；录音测试可使用同一段录音对比本地引擎，
  展示准备、首字及结束等待耗时。词表不发送到豆包，也不通过 iCloud 同步。
- 可选豆包云识别，使用自己的 API Key。设置中的录音测试无需连接 SSH；
  选择云识别后，停止转写或重试会将录音发送到火山引擎。
- 草稿通过飞机按钮发送到远端；语音审阅和取消只处理本地内容。
- 实时活动展示连接状态和已上报的任务状态。iOS 挂起 App 时停止更新，返回前台后恢复。
- 继承 Moshpit 的 agent 通知、图片分享和远程 worktree 工作流。远程推送需要配置
  中继、APNs 和对应签名能力，详见[推送文档](docs/PUSH.md)。
- 可选的 iCloud 主机配置与设置同步，并提供凭据同步开关。

**数据与主机操作**

- 密码和私钥保存在 iOS Keychain；可同步的凭据是否跨设备同步，由 iCloud 设置控制。
- Apple 与 Whisper 在本地识别；豆包将录音发送到火山引擎，适用所用服务的条款和计费。
  豆包 API Key 保存在本机 Keychain，不纳入 SSH 凭据同步；接受或取消审阅后释放临时录音。
- 主机安装和创建会话由用户在 App 中明确操作，各种连接传输均保留 SSH 主机密钥校验。

任何 SSH 服务器均可使用。Mosh、tmux、herdr 按需安装，App 内提供安装说明。

## 从源码构建

需要 macOS、Xcode 26 或更高版本、[XcodeGen](https://github.com/yonaskolb/XcodeGen)、
用于构建内置网络库的 Go 1.27.3，以及 iOS 18 或更高版本的模拟器或设备。

```sh
git clone https://github.com/Aias00/hermit.git
cd hermit
brew install xcodegen
scripts/build-tailcat.sh # 先安装 Go；此步骤构建固定版本的原生网络库
xcodegen generate        # project.yml 是工程配置的唯一来源
open Hermit.xcodeproj
```

选择 **Hermit** scheme 和模拟器，再按 ⌘R。Swift 依赖会在首次构建时解析。
真机需要在 `Signing.xcconfig` 中配置签名，详见[贡献指南](CONTRIBUTING.md)和
[个人设备安装说明](docs/install-free-account.md)。

模拟器测试使用 ad hoc 签名，让系统 Keychain 测试保有必要的 entitlement：

```sh
xcodebuild test -project Hermit.xcodeproj -scheme Hermit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= CODE_SIGNING_REQUIRED=YES
```

将 `-destination` 改为本机已安装的模拟器。外部集成测试需要相应 fixture，测试日志会说明跳过的用例。

## 仓库结构

| 路径 | 内容 |
|---|---|
| `Hermit/` | App 界面、SSH / Mosh / tmux / herdr 服务、网络接入、同步与语音输入 |
| `Extensions/` | `HermitIsland/` 小组件和实时活动、`HermitPush/` 加密通知扩展、`HermitShare/` 图片分享扩展 |
| `Packages/HermitKit/` | App 和扩展共用的库；为兼容已有功能，Swift 模块仍为 `MoshpitKit` |
| `Tests/` | `HermitTests/` 单元测试、`HermitUITests/` 界面测试 |
| `push-relay/` | 主机与 APNs 之间的 Go 中继，部署文件在 `deploy/` |
| `docs/` | [架构](docs/ARCHITECTURE.md)、[推送协议](docs/PUSH.md)、[SwiftTerm 修改](docs/PATCHES.md)和设计、验证记录 |
| `scripts/` | 主机辅助脚本、生成器、验证 fixture、截图和发布工具 |

继承的默认推送中继属于上游 Moshpit；[推送文档](docs/PUSH.md)说明了协议及自行部署的方法。

## 覆盖升级兼容

更名为 Hermit 不要求改变已安装 App 的身份。既有 bundle、Keychain、App Group、云记录
和主机协议标识继续沿用，以兼容已保存的主机、密钥、实时活动及远端辅助脚本。
主 App 的 Swift 模块仍为 `Moshpit`，共享模块仍为 `MoshpitKit`。历史验证记录和产物路径
保留生成时的原名。

## 参与开发

请阅读[贡献指南](CONTRIBUTING.md)了解 XcodeGen 工作流和代码约定；安全问题先看
[SECURITY.md](SECURITY.md)。参与者遵守[行为准则](CODE_OF_CONDUCT.md)。

## 许可证与上游

Hermit 基于 [Moshpit](https://github.com/Cluas/moshpit)，采用
[GNU General Public License v3.0](LICENSE)（GPL-3.0-only），并保留原有版权及许可证声明。
第三方组件保留各自许可证，见 [NOTICES.md](NOTICES.md)。
