# Cloudflare SSH 实施记录

当前项目名为 Hermit，仓库为 [Aias00/hermit](https://github.com/Aias00/hermit)。
下文的历史验证产物、部署标识和当时使用的仓库名称按原记录保留。

本轮交付是可配置的实验客户端与验证工具。**不代表设计中的 P0/G1/G2、P1/P2 已全部通过真实环境验收。** 真实联调另建了隔离的测试 Tunnel、DNS 与仅允许本人登录的 Access 应用；2026-10-27 又按用户要求部署 Mac mini 常驻 SSH 入口（见下节）。已有 Magpie 等服务及策略未改动。入口部署、真实验证结果与本地 fixture 结果分开记录。

## 2026-10-27：Mac mini 常驻 SSH 入口

用户明确要求“配置 ssh 地址”后，创建独立的 `moshpit-macmini-ssh` Tunnel、
`Mac mini SSH` Access 应用及其独立 allow 策略，再发布 DNS。此入口直接连接
Mac mini 已运行的系统 SSH；测试 fixture 的 `54242` 端口和临时凭据未用于此部署。

手机 Hermit 新建连接时填写：

| 字段 | 值 |
|---|---|
| 名称 | Mac mini Cloudflare |
| 协议 | SSH |
| 主机 | `terminal.aias.eu.org` |
| SSH 端口 | `22` |
| 用户名 | `aias` |
| 传输方式 | Cloudflare SSH（实验） |
| SSH 认证 | 沿用 Mac mini 原有账户密码或密钥 |
| 多路复用器 | Herdr（如需原有工作区） |

默认沿用主机域名作为入口，点击登录后自动获取并验证 Access 配置，无需重复填写
入口、团队域名或 AUD。仅在需要手动覆盖时展开“高级 Cloudflare 配置”：当前团队
为 `dream00.cloudflareaccess.com`，AUD 为
`15bca74b264bbb13ab470b13a67ac88c29e02b5cec8fd10482999fe49f9496a1`。

Access 复制现有 CPA 的单个精确本人邮箱规则与邮箱验证码 IDP，使用独立策略，
会话有效期 24 小时；没有增加 bypass、everyone 或 service token，也没有修改 CPA
的原策略。新应用有自己的 AUD，不能把旧测试或 CPA 应用的 token 当作该入口凭据。
配置保存后，使用 App 的“登录 Cloudflare Access”完成本人登录；Access 登录与 SSH
账户认证分别完成。桌面客户端可按 [Cloudflare 官方 SSH 接入说明](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/ssh/ssh-cloudflared-authentication/)
配置 `cloudflared access ssh --hostname %h` 作为 ProxyCommand。

本机安装位置：

- 配置与凭据目录：`~/.cloudflared/moshpit-ssh/`，目录 `0700`、文件 `0600`。
- 上游：`ssh://127.0.0.1:22`，其他 hostname 返回 `404`。
- LaunchAgent：`~/Library/LaunchAgents/com.aias.cloudflared-moshpit-ssh.plist`。
- 日志：`~/Library/Logs/moshpit-ssh-tunnel/connector.log`。
- 状态及验收报告：该私有配置目录下的 `deployment.json`、
  `local-verification.json`、`access-verification.json`、`public-verification.json`。

服务由当前用户的 launchd 管理，登录后启动并在进程退出后重启；这不是开机尚未
登录时运行的系统 LaunchDaemon，区别见 [官方 macOS 服务说明](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/as-a-service/macos/)。
停用仅此入口的本机服务：

```sh
launchctl bootout "gui/$(id -u)/com.aias.cloudflared-moshpit-ssh"
```

重新启用：

```sh
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.aias.cloudflared-moshpit-ssh.plist"
```

首次信任 SSH 主机密钥前，核对 Ed25519 指纹：
`SHA256:iKK6EXDfFALcYCaggiqUfP0PcryrRX4KtJgLoam+npA`。
该指纹已通过 localhost SSH 扫描与 `/etc/ssh` 对应公钥文件比对；不是测试 fixture
的主机密钥。原有 learn、magpie、resume 服务保持运行。

部署验收：Cloudflare API 显示 Tunnel healthy，本机实时指标为 4 条连接；独立
复核 Access 策略、OTP IDP、DNS CNAME、文件权限及 launchd 均通过。1.1.1.1、
8.8.8.8 的 A/AAAA 四项查询全部取得正向结果。初期出现暂态 DNS 请求失败和
HTTP 403，随后浏览器 UA 的直连及既有代理路径均取得正确 Access 302。
后续使用 cloudflared UA 的匿名 HTTP/WSS 探测，经既有代理均为 Access 302，
本机原生直连仍出现超时；未修改全局代理、VPN、DNS 或其他服务来掩盖该差异。

本节仅记录服务器入口部署。新的 Access 应用仍需本人登录并完成实际 SSH 连接，
不能把隧道在线、DNS 与匿名登录跳转通过计作 G1/G2 或手机端连接已通过。

## 用户自行配置

新建或编辑 Host，在「连接方式」选择「Cloudflare SSH (Experimental)」。默认只需
填写上方 Host 域名及原有 SSH 账户信息，然后点击“登录 Cloudflare Access”：

| 配置 | 含义 |
| --- | --- |
| Host | 自己已发布的 SSH Tunnel 域名，仅主机名，无协议、路径或端口 |
| Port、Username、密码或密钥 | SSH 逻辑主机身份和原有认证；Cloudflare 的实际上游由 Tunnel 配置决定 |
| 高级：入口域名覆盖 | 仅当 SSH 逻辑 Host 与 Cloudflare 入口不同才填写，留空跟随 Host |
| 高级：手动配置 Access | 可覆盖团队域名和 AUD；启用后两项都必须填写 |

配置可以先保存，不要求当场登录；「登录 Cloudflare Access」由用户主动触发。允许哪些邮箱/身份组登录，在自己的 Cloudflare Access 策略中配置，客户端不硬编码用户或租户。首次打开终端若无有效凭据，会提供登录操作；后台重连不会打开浏览器。

自动模式保存的入口覆盖、团队域名、AUD 保持为空，编辑 Host 后会跟随新的域名，
不会固化成旧入口。已有完整手动配置仍按原配置使用，并在编辑时展开高级设置；
关闭“手动配置 Access”即可改用自动获取。

自动获取采用固定 cloudflared 2026.10.3 的签名元数据流程：匿名 HTTPS HEAD，
请求 `Cf-Access-Metadata-Request`，限制候选团队域名后获取 JWKS，验证签名、
主机名、应用标识和时间窗口。未验证字段只能用于受限的公钥地址，不能直接用于
登录或凭据缓存。成功登录后，已验证的主机与应用绑定保存在 Keychain；读取登录
状态和后台重连只读取本地绑定，不因为用户编辑主机名就发起发现或浏览器登录。

2026-10-27 实网验证：仅提供 `terminal.aias.eu.org`，真实系统 URLSession 自动发现
并验签后，团队域名/AUD 与部署记录一致，用时 1.775 秒。修复了系统将无路径根 URL
补成 `/` 导致的严格地址比较误判；仍拒绝跨地址跳转。此验证仅使用匿名元数据和
公钥，不包含本人登录或 SSH 会话；默认系统网络可能使用已有代理，不计为强制
直连通过。测试日志：`/tmp/moshpit-access-discovery-live-test.log`。

同轮使用 ad hoc 签名的 iPhone 18 Pro 与 iPad mini (A17 Pro) 模拟器，各通过
67 项传输、表单、Access 缓存/退出竞态、主机指纹及恢复测试，包含真实系统
Keychain 的保存、读取和删除。两台模拟器均通过两项配置界面测试：仅填写 Host
即可离线保存，重启后修改 Host 仍跟随新入口；高级手动配置完整保存并恢复，
切回 Direct 后可再次选择 Mosh。测试未点击登录或连接，不计为本人认证和 SSH
实网会话验收。最终证据为工作区旁的
`moshpit-cloudflare-auto-config-final-unit-{phone,mini}.xcresult` 和
`moshpit-contact-auto-config-r3-ui-{phone,mini}.xcresult`。

同一构建将反馈邮件改为 `rokkki@163.com`，Issue 指向 `Aias00/moshpit`，并移除
终端草稿栏的手形按钮。两台模拟器各通过 6 项反馈组装测试及中英文设置页测试；
手机设置页证据在 `moshpit-contact-auto-config-r2-ui-phone.xcresult`，iPad mini
在上述 r3 结果中。界面测试修正了滑块截获整页上滑、开关标签误点及保存完成前
重启等自动化问题，保留实际字段值、开关状态、保存禁用和重载结果断言。

同轮个人签名包 `com.aias.moshpit.personal`，版本 `1.0.8 (1)`，已通过局域网
Wi-Fi 覆盖安装到原 iPhone 12 Pro Max。安装前核对 142 项源文件/工程与产物哈希、
签名及描述文件，安装后核对目标 bundle 和版本；未卸载、清数据或自动启动 App。
部署报告：`build/Personal/cloudflare-discovery-deployment-20261027-153605.json`。
此次安装不代表已完成真机上的本人 Access 登录及 SSH 会话验收。

传输与 Shell/tmux/Herdr 模式独立。Cloudflare 选项禁用 Mosh UDP，不自动切换其他入口；旧直连与 SOCKS 记录保持原行为。普通 Shell 的能力探测不检查 Herdr、tmux 或 mosh-server。

## 实现边界

- `Packages/CloudflareSSH`：固定 cloudflared 2026.10.3 行为的 WSS 字节流适配，以及官方 CLI 加密凭据交接机制的 Swift 实现。具体请求与官方源码来源见 [协议记录](../../scripts/spikes/cloudflare-ssh/protocol.md)。
- TLS 验证证书链与入口域名；SSH 仍独立验证逻辑 Host/Port 的主机指纹。HTTP 拒绝响应不进入 SSH；不跟随携带凭据的重定向。
- Access 凭据使用独立系统 Keychain 命名空间，按团队、入口、AUD 和账户隔离。JWT 校验签名、issuer、audience、有效期和用户身份；未实现未经真实验证的静默刷新，过期需要重新登录。
- 登录使用 ASWebAuthenticationSession 和一次性 NaCl 加密交接，浏览器 Cookie 不直接移入 App。SwiftSodium 0.11.0 的来源、commit、下载校验和及许可随本地依赖保留。
- 统一 `SSHService` 拨号路径供终端、exec、SFTP 和已有控制通道使用；真实 tmux/Herdr 重附着、推送和附件全流程仍待环境验收。
- 暂时性失败使用共享退避；认证取消、403、主机密钥拒绝、无效配置和 TLS 校验失败停止自动重试。普通 Shell 重新建立后提示旧进程状态未知，不重放已提交的命令。

## 可复现的本地验证

独立包测试：

```sh
swift test --package-path Packages/CloudflareSSH
```

本地集成测试通过一个仅监听 loopback 的临时 TLS/WebSocket → OpenSSH 服务验证协议。它不是 Cloudflare 服务，也不验证真实 Access 策略。临时 SSH key、主机 key、CA 和随机测试 header 只存于临时目录，不修改系统 sshd 或用户 `~/.ssh`。详见脚本 `--help`：

```sh
python3 scripts/spikes/cloudflare-ssh/local_fixture.py --help
```

App 测试通过 `TEST_RUNNER_MOSHPIT_CF_FIXTURE` 注入 fixture JSON 路径；只有测试代码信任临时 CA，生产默认信任不变。覆盖主机指纹、exec stdin（含 128 KiB）、PTY/resize、SFTP、缺少 header、拒绝不可信证书及拒绝 SSH 主机密钥。

模型、登录缓存与恢复测试在 `Tests/HermitTests`；`CloudflareConnectionUITest` 在 iPhone/iPad 共用表单执行保存、重启回读、Mosh 互斥和切回直连的无网络流程。

## 本轮验证结果（2026-10-27）

| 环境 | 结果 |
| --- | --- |
| macOS 独立包 | 23 项 WSS/TLS 测试 + 10 项 Access 加密/签名测试全部通过 |
| iPad mini (A17 Pro)，iOS 27.0 模拟器 | 全部单元测试及 Cloudflare 配置 UI：1093 通过、31 跳过、0 失败 |
| iPhone 18 Pro，iOS 27.0 模拟器 | 已执行整套单元回归及注入凭据的登录、主机密钥和恢复定向回归；最终重跑 8 项恢复测试和配置 UI，9 项全部通过 |

上述整套回归当时使用未签名构建；31 项跳过来自未配置的其他 SSH/tmux 外部 fixture，以及缺少系统 Keychain/App Group 权限，不能算作这些能力已通过验证。Cloudflare 本地 TLS/SSH fixture 已启用，exec、PTY/resize、SFTP 和证书/指纹拒绝均实际执行。Access 缓存单元测试注入隔离的测试 Keychain，不能代替浏览器真实登录。

后续改用 ad hoc 签名，iPhone 模拟器上的 `CloudflareSystemKeychainTests` 已实际通过系统 Keychain 保存、重新读取和删除；没有改用文件凭据库。另有 3 项一次性公开登录链接的权限与清理测试通过。CI 与贡献文档中的模拟器命令已使用同样签名方式；真机签名及发布配置不受影响。

另验证了两个重连竞态：短暂成功后断开仍遵循退避；用户手动重试成功后，旧定时器不能关闭新连接。用户拒绝指纹的决定会优先于底层稍后返回的通用超时，并立即停止自动重连。

验证命令使用 `xcodegen generate`、`xcodebuild build-for-testing`，再分别对两台模拟器执行 `test-without-building`。本地 fixture 的完整启动/注入/清理示例：

```sh
python3 scripts/spikes/cloudflare-ssh/local_fixture.py start --state /tmp/moshpit-cf.json
TEST_RUNNER_MOSHPIT_CF_FIXTURE=/tmp/moshpit-cf.json xcodebuild test \
  -project Hermit.xcodeproj -scheme Hermit \
  -destination 'platform=iOS Simulator,name=iPad mini (A17 Pro)' \
  -only-testing:HermitTests -only-testing:HermitUITests/CloudflareConnectionUITest \
  -parallel-testing-enabled NO -testLanguage en -testRegion US \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= CODE_SIGNING_REQUIRED=YES
python3 scripts/spikes/cloudflare-ssh/local_fixture.py stop --state /tmp/moshpit-cf.json
```

## 真实联调结果和未完成项

### 已完成的真实环境前置检查

- 创建独立的短期 Access 应用与测试 Tunnel，沿用现有本人邮箱准入条件，不添加 bypass 或共享 service token。匿名请求返回 Access 登录跳转；Tunnel 为 healthy。
- macOS Swift 探针已收到真实浏览器的加密交接，并通过 JWT 签名、issuer、AUD 和身份检查；首次 SSH 拨号遇到该 Mac 的 DNS 负缓存，不能算作 G1 通过。更换隔离测试域名后，系统解析与入口健康检查正常。
- 原生 URLSession 使用生产的 60 秒单次请求时限，对未发布的一次性随机键在约 54 秒收到正常未登录响应，未复现持续 DNS/TLS 故障。
- App 第一轮成功登录等待未获确认；随后检查时已无可用凭据，不能仅据之后的过期检查反推此前具体失败原因。第二轮实际打开系统认证页面，取消、本人登录交接、系统 Keychain 保存及 App 重启后复用均通过。用户通过自己的浏览器完成一次性加密交接，没有手工复制 Cookie/JWT；这不等于已验证内嵌 Safari 中手动完成 MFA。
- 新测试会在 App 返回错误时立即报告固定的错误类别；只输出 App 自身状态，不读取浏览器内容、账号标签或令牌。配置页面 smoke 重跑通过，产物审计为零附件。`keepNever` 不是绝对保证：此前动画中的点击重试曾生成浏览器界面层级诊断，实际登录测试的每次产物仍需单独审计。

### 实网结果（2026-10-27，最终状态：未全部通过）

| 项目 | 结果与范围 |
| --- | --- |
| iPhone 原生登录 UI | 取消 → 外部浏览器完成 App 发起的交接 → 保存 → 重启复用，1 项真实 UI 测试通过；本次 `.xcresult` 附件审计为零 |
| iPhone 真实 SSH 载体 | 获得真实 SSH 主机指纹；exec、PTY/resize、32 KiB SFTP 及匿名拒绝有成功用例，但不同轮次仍发生 WSS/认证超时，整套未通过 |
| iPad mini 真实 SSH 载体 | 普通 exec 与 128 KiB stdin/stdout 两个参数用例通过；PTY/resize 和 SFTP 有成功用例，整套仍有超时/关闭失败。使用同次 App 登录显式导出的受限测试文件，逐次重新校验 JWT；不声称 iPad 已完成自己的原生浏览器登录 |
| App 实际 `SSHService.connect` | 已实际调用 Cloudflare 传输分支，使用 App Access Keychain 和严格主机指纹；完整 exec/PTY 用例未通过，不能用底层载体的成功代替这一项 |
| 自然过期 | 等真实 15 分钟有效期结束，未修改时钟或撤销会话。JWT 校验和 App Keychain 读取要求重新登录；原样过期 token 的新 WSS 握手遭拒。首次边缘检查遇到网络超时，定向重跑 2 项均通过 |
| 官方 cloudflared 2026.10.3 对照 | JWT 校验和入口元数据匹配通过；echo / 128 KiB 未取得通过结果。脚本隔离问题已修复，11 项本地脚本回归通过，但不计为官方实网对照成功 |

实网暴露并修复了一个认证时序问题：Citadel 的 `connect(on:)` 只安装 handler 就返回，尚未完成 SSH 认证；此前上层立刻创建 exec/PTY 通道，提前消耗其 15 秒期限。新增 `SSHChannelAuthentication` 在释放载体缓冲前安装观察器，等待真正的认证成功事件及激活完成，最长 30 秒；原始认证/主机密钥错误、EOF、取消和超时均收敛并关闭通道。只接入 Cloudflare 分支，不绕过任何认证。5 项事件顺序、拒绝、超时、EOF 和真实 `Task.cancel()` 回归通过。随后 iPad mini 本地 TLS/WS → sshd 的全部 6 项测试（exec 含两个参数用例）在 0.787 秒内通过。

实网残余故障尚未解决。该 Mac 的系统代理为本地 `127.0.0.1:7890`，与 NIO/官方 Go 客户端的直连路径不同；没有修改代理、VPN 或 DNS。对同一过期凭据、相同 WSS headers 与正常 TLS 校验进行受控检查：直连一次 15 秒超时、另一次 1.16 秒返回 HTTP 302；本地 HTTP CONNECT 代理两次均在 TLS 阶段 EOF。直接访问隔离 sshd 的 OpenSSH exec 为 0.041 秒。Tunnel 保持 4 条连接、origin/request 错误计数为零，不能将全部故障归因于 QUIC 或客户端协议；也没有靠切换 Tunnel 协议掩盖失败。当前证据表明公网出口不稳定，无法完成稳定性与官方对照验收。

本机主要证据（位于工程相邻目录 `/Volumes/data/idea`）：

- `moshpit-cloudflare-live-ui-phone-retry.xcresult`：真实登录与重启复用通过。
- `moshpit-cloudflare-real-ssh-phone-auth-order.xcresult`、`moshpit-cloudflare-real-ssh-mini-auth-order.xcresult`：修复后实网测试，保留成功及失败记录。
- `moshpit-cloudflare-auth-expiry-phone.xcresult`：5 项等待器回归通过，首次边缘过期检查超时。
- `moshpit-cloudflare-natural-expiry-retry.xcresult`：2 项自然过期测试通过。
- `moshpit-cloudflare-auth-order-local-mini.xcresult`：修复后的本地 SSH 集成测试全部通过。

### 上一轮联调清理

已按创建记录逐项核对并删除两个测试 DNS、两个 Access 应用及其策略、一个独立 Tunnel，停止本次 connector。App 清理测试通过：只退出本次 Access scope 并删除精确匹配的测试 Host，重新读取确认其他连接完整保留。临时 SSH fixture、测试私钥及导出凭据已移除；保留脱敏验证记录。已有 CPA、Magpie 等服务以及全局代理、VPN、DNS 设置未改动。以后继续实网验收需要新建隔离入口并重新登录。

### 断连专项诊断

后续在新的独立、仅本人可登录的入口上继续定位；原测试资源没有恢复或复用。此轮区分建立连接失败、已认证会话关闭和错误被覆盖，不能用单一“网络不稳定”解释全部现象。

1. **已复现并修复 EOF 误报认证超时。** 固定版本 NIOSSH 的 `channelInactive` 只通知子通道，不向后续 handler 转发。认证等待器原先看不到实际 EOF，直到自己的期限到达才报告 `timedOut`。使用真正的 NIOSSH handler 和 loopback 对端关闭做回归，修复前预期 `connectionClosed` 却得到 `timedOut`；改为额外观察真实 channel 的 `closeFuture` 后约 1 ms 返回 `connectionClosed`。原始认证错误仍优先，正常成功与取消仍只完成一次。
2. **确认原始断开原因会被库覆盖。** WebSocket 的错误可能被 Citadel 已完成的握手 handler 消费；其 `withSFTP` 在 catch 中再次关闭客户端，也可能用 `Already closed` 覆盖原错误。因此旧日志的 `Already closed`/`tcpShutdown` 只能证明连接终止，不能证明是心跳、帧错误还是对端先关。
3. **新增保留首因的分阶段诊断。** 记录 TCP、TLS、WebSocket、激活、ping/pong 计数和单调耗时；明确区分首个 typed failure、peer WS close code、本地主动关闭、无 WS close 的传输 EOF。即使后续清理再次报错也不覆盖首因。没有 URL、headers、账号、JWT、SSH 字节或对端 close reason 文本。App、集成测试与 macOS 探针均已接入，未调整心跳/超时/重试策略。
4. **无登录也复现了进入 SSH 前的等待超时。** 同一保护入口连续 3 次原生匿名 WSS 探测：TCP 193–232 ms、TLS 3.13–3.82 s；一次等到 15 s 仍无 HTTP 响应，另外两次分别在 4.18 s、9.52 s 收到正常 Access 302。该轮没有发 SSH 数据，也没有用户凭据。超时/拒绝之后清理产生的 TLS EOF、系统错误 54 是后续事件，不能倒推成最早的失败原因。
5. **对照不局限于 NIO 或 WebSocket。** 同 UA 的 GET/HEAD/WS 各 3 次，现有本地代理路径 9/9 收到 302，约 0.51–1.16 s；直连 8/9 返回 302，其中一次普通 HEAD 在 TLS 完成后等待至 15 s 超时。因此已将这一类失败缩小到直连访问 Access 的 HTTP 响应阶段，尚不能仅凭此确定具体丢包点或 Cloudflare 内部处理原因。服务端同期保持 4 条 Tunnel 连接、origin 请求数为 0，没有相应 sshd 会话。系统代理、VPN、DNS 和 Tunnel 协议均未修改。
6. **存在可复现但尚未关联实网的上游并发风险。** 固定 cloudflared/gobwas 源码的自动 pong 写入不经过二进制写入锁。最小实验能强制将 pong 插入 binary 帧头与载荷之间；另验证服务端会正确响应 ping，但若 origin 暂停读取，pong 也会被延迟。这些是兼容性风险，不能据此认定上一次 SFTP 断开正由它们触发。4 项实验及限制见 [origin ping probe](../../scripts/spikes/cloudflare-ssh/origin_ping_probe/README.md)。
7. **同一连接的 TCP 统计确认实际重传。** 固定 IPv4/IPv6 各 3 次匿名 WSS：IPv4 三次超时；IPv6 一次超时，两次分别在 8.00 s、2.04 s 收到完整 302 响应头。按 Darwin SDK 核对结构后，读取同一 socket 的 `TCP_CONNECTION_INFO`，5/6 请求实际发送重传增加 1–3 包、544–3884 字节。不能把问题仅归给 IPv6，也不能从这些计数定位具体哪一跳。受测地址的 IPv4/IPv6 路由均走 en0、MTU 1500；Clash 未开启 TUN，系统代理和裸 socket 仍是不同出口路径。
8. **修复写入失败的重入诊断顺序。** 外部 write promise 的失败回调可能同步关闭连接。若先完成 promise 再记原因，最初的 buffer/write 失败会被误标为本地主动关闭。新增两项回归先复现该问题，再把记录首因提前，原写入、关闭及心跳行为不变。

验证：独立包最终 41 项通过；iPhone 与 iPad mini 各 12 项本地 SSH/认证等待回归通过。新一轮真实登录 UI 因未收到本人登录结果而到达等待上限，因此尚无带新诊断的认证后 SSH 断连记录，旧登录链接已失效。该失败结果审计为零附件。独立诊断入口和 loopback fixture 保留用于下一次本人登录复测，管理凭据未进入 App。服务端采样已停止，采样期间 Tunnel 始终为 4 条连接、origin 请求/错误为 0；随后 sshd 的本地模拟器回归流量已单独标注，不当成真实 Cloudflare 认证会话证据。

主要新证据：`moshpit-cloudflare-eof-reproduction.xcresult` 保留修复前失败；`moshpit-cloudflare-diagnostics-final-phone.xcresult` 和 `moshpit-cloudflare-diagnostics-final-mini.xcresult` 是最终修复版本的通过结果；匿名探测、HTTP 对照及服务端分类记录在受限的 `/tmp/moshpit-cloudflare-disconnect-diagnosis`。普通匿名请求和本地模拟器回归不能计作真实认证会话的 G1/G2 通过。

### 第二轮断连修复

在未取得新实网登录结果的情况下，继续用可控的写入拥塞、关闭竞态和真实本地 SSH 复现，修复了独立于公网出口的客户端缺陷：

- **心跳排队导致误断。** 原先 ping 入队即开始 10 秒 pong 倒计时；排队 8 秒、实际写出后 5 秒收到回复仍会被提前关闭。现在写入成功后才开始原有 10 秒响应期限。排队阶段另有 10 秒“无写入进展”上限，每个成功写出的 16 KiB 帧推进该期限；不会无限等待，也不会用数据写入延长已发出 ping 的响应期限。20 秒心跳间隔、缓冲上限及重试策略保持不变。新增 `pingQueued` 与 `heartbeatWriteTimedOut` 区分排队和等待远端响应。
- **过早 pong 与控制帧写入失败。** 同步到达的匹配 pong 原先仍可能遗留超时任务；ping/pong 的写入错误原先没有 promise 接收。现在提前回复会阻止后续错误地安装期限，控制帧的真实写入失败会立即保留并关闭连接。修复前 6 项新回归中 4 项失败；修复后的 8 项心跳回归及完整包 49 项均通过。
- **PTY 结束后的底层连接未清理。** 原先 `markClosed()` 只改变会话状态，后续 `close()` 因已关闭而直接返回；真实父 SSH/WebSocket 连接可继续存活。现在 EOF、取消和主动关闭共用一个 shutdown 任务，重复关闭会等待同一次清理。父连接先关闭，避免等待子 SFTP 通道阻塞清理；关闭后才返回的 PTY 不再被安装或报告成功。4 项初始回归在旧实现全部失败。
- **SFTP 清理覆盖原错误。** 上传文件和子通道改用保留原始错误的作用域清理；操作失败时，后续 close 失败不替换原错误或取消。操作成功但 close 失败仍会报告失败，既有 exec 回退策略不变。

新增可选 `MOSHPIT_CF_SUSTAINED=1` 集成测试，在同一真实 SSH 连接上等待 45 秒、验证至少两次匹配的 ping/pong，再完成 256 KiB exec 与 SFTP 往返。它使用本地 TLS/WS → sshd fixture 时仅证明本地互操作，不是 Cloudflare 实网验收。

本轮真实登录 UI 在等待本人登录 301 秒后超时；结果附件审计为零。同期 Connector 保持 4 条连接，origin 请求数为 0，没有新的已认证 Cloudflare SSH 流量。测试入口及 fixture 保留，采样已停止；旧登录链接已失效。上述客户端缺陷有独立复现证据，但尚不能认定为此前真实 SFTP 中断的唯一触发原因。

模拟器验证：iPhone 与 iPad mini 各执行 98 项定向测试，其中连接/生命周期的 63 项全部通过，包含上述持续传输。首轮唯一失败来自快捷键旧测试把新增的 `Shift + ←` 当作普通左键；将匹配限定为无修饰键后，两个模拟器的 35 项快捷键测试分别全部通过。没有将这些本地测试计入 Cloudflare G1/G2。

修复前证据：`moshpit-cloudflare-heartbeat-before.log`、`moshpit-cloudflare-disconnect-run2-before-mini.xcresult`；包最终结果：`moshpit-cloudflare-heartbeat-full.log`。双模拟器连接结果为 `moshpit-cloudflare-disconnect-run2-final-{phone,mini}.xcresult`，快捷键修正后的通过结果为 `moshpit-cloudflare-disconnect-run2-shortcuts-{phone,mini}.xcresult`。

### 尚待验收

1. 在稳定的公网出口上重跑 App 完整连接路径及官方 cloudflared 对照，取得同入口的握手、指纹、exec 和大流量结果（G1）。不得把散落在不同失败轮次中的成功用例合并成整套通过。
2. 单独验证撤销授权及不自动重试/弹浏览器；当前自然过期测试不代表撤销已测（G2）。内嵌 Safari 手动 MFA 和真机登录另行验证。
3. 关闭 Tailscale 后的手机蜂窝/异地 Wi-Fi、锁屏/后台/换网、Tunnel 重启与主机休眠。
4. tmux/Herdr 存续会话恢复、附件/推送、20 次拨号与两小时长连接，按设计矩阵单独记录。

完成这些关口之前，保持实验标记。已经完成部分真实 Cloudflare 登录及连接验证，但不能宣称 G1/G2 全部通过、连接稳定或可正式发版。

## 2026-10-28：真机蜂窝延迟与断线排查

用户报告 4G/5G 下进入终端慢、交互延迟及重连，前台使用和后台返回均会出现。
`IMG-20261028-092453-1503.jpg` 显示旧传输在 `+232413ms` 报
`tlsFailure(connectionClosed)`，随后为 `health: dropped (transport-closed)`。
这是连接生命周期内的关闭，不能仅凭错误枚举称为“握手失败”。新的一条连接
TCP/TLS/WebSocket 分别在 257/610/1274ms 完成，SSH 认证累计约 4699ms；另一个
herdr frame 从 boot 到首帧仅 246ms。日志交错且缺少逻辑会话角色关联，不能把
这些帧、push 与新拨号强行视为同一条传输。截图还记录 foreground after 525s，
但用户确认持续前台也会断线，因此不能仅归因于 iOS 后台挂起。

已通过 LaunchAgent PID 和其监听端口匹配 Mac mini 专用 connector，指标端口为
58691（20241 属于其他 tunnel，不用于本次结论）。该 connector 持续 4 条 QUIC
连接、origin 错误计数为 0，连接到 LAX 节点；采样 RTT 约 185–379ms，后续样本
185–215ms。Mac 直连同一域名的三次匿名 HEAD 为 2.86s、2.32s 和一次 TLS/connect
7s 期限超时；显式使用已有本机代理为 1.48s、0.50s、0.52s，均 Access 302。
这些是 Mac 侧证据，不是手机蜂窝路径测量。未修改 tunnel 协议、DNS、VPN、代理、
Access 策略或服务端会话。

发现并修复独立客户端问题：`HerdrControlClient.quicken/refresh` 可在慢 SSH
snapshot 尚未返回时继续开启 exec，导致请求堆积及乱序应用旧树。现在每代最多
一个在途 snapshot，后续触发合并为一个尾随批次；每个等待者在所属批次完成后
释放，stop 会取消并使旧回包失效。确定性测试验证 30 次 quicken 只产生当前和
尾随两个读请求、尾随期间新事件仍可刷新、失败保留旧树及 stop/restart 保护。
同时把 TLS connectionClosed 文案改为中性“连接已关闭”，不再误称只发生于握手。
这不是对截图 TLS 断线根因的最终认定。

iPhone 18 Pro 与 iPad mini (A17 Pro) 模拟器各 106 项定向回归通过；Cloudflare 包
XCTest 39 项通过，Swift Testing 报告 18 项、其中未配置的实网自动发现用例跳过。
证据为工程相邻 `moshpit-cf-cellular-{phone,mini}.xcresult` 与 package/build 日志，
汇总在 `build/verification/20261028-cloudflare-cellular/`。

真机 personal 构建成功，签名、bundle、有效 profile 与 IPA 完整性已验证；包含
本轮修复和上一轮远端回车、语音草稿、光标修复。用户目前只能使用 5G，明确要求
保留包，因此未安装。待安装包 `build/Personal/cloudflare-cellular-20261028.ipa`，
产物记录 `build/Personal/cloudflare-cellular-device-artifact.json`；profile 到期为
2026-10-31T13:55:04Z，若之后安装需重新签名。安装后的真实 5G 长连接仍待验收。
