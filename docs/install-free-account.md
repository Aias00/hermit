# 本地安装 Hermit 到 iPhone(免费 Apple 开发者账号)

已有安装升级时，沿用原来的签名团队、主 App 和扩展 Bundle ID。仅因品牌改为 Hermit
而修改 Bundle ID，会把它变成另一个 App，无法直接使用原有安装的数据与 Keychain。
本项目的个人安装继续使用 `com.aias.moshpit.personal` 及对应扩展 ID。新用户首次安装
才需要按自己的开发者账号选择唯一标识。

免费 Apple ID 足以把 Hermit 装到你自己的 iPhone——没有推送、没有后台模式,Live Activity
只是个 Info.plist 开关。唯一的 entitlement 是一个 App Group(`group.com.cluas.moshpit`,
主 App 与灵动岛扩展靠它共享 Agent 状态);免费账号签它偶尔会失败,遇到就看下面「常见问题」
里剥掉扩展只验主 App 的做法。

## 免费账号能做 / 不能做

| ✅ 可以 | ❌ 不行 |
|---|---|
| 装到自己配对过的 iPhone | TestFlight / 对外分发 |
| mosh + SSH + tmux 全功能 | 后台远程推送(我们不用) |
| 本地通知 + 灵动岛 Live Activity | App 不在同一网络时远程安装 |

**硬限制(记住)**:① App **7 天过期**,过期后图标在但打不开,重新 ⌘R 一次即可续(数据保留)。② 同时最多 **3 个**自签 App。③ 每 7 天最多 10 个 App ID(Hermit 占 2 个:主 App + 灵动岛扩展)。

### HERDR 手机通知与 Markdown 预览

HERDR 侧栏工作区、Agent 窗格列表及顶部标签页支持双击打开对应对象的操作菜单。
单击切换与双击菜单互斥：双击不会先切换到那一项，操作始终绑定菜单顶部标明的原对象。
工作区菜单可新建标签页、重命名或关闭工作区，空工作区也可使用；标签页菜单可分屏、重命名或关闭标签页；
窗格菜单可分屏、重命名所在标签页或关闭该窗格。关闭需要二次确认。菜单保留键盘、焦点与草稿。
连接重建或目标被替换后拒绝旧操作；结果未确认时不自动重试。终端双击恢复选词，长按仍选字复制；
鼠标／触控板在终端右键仍可打开当前窗格的菜单。

长按选词后继续拖动，或拖动选区手柄到终端上、下边缘，可自动滚动并跨屏扩选；手指停在边缘时继续滚动，松手后显示复制菜单。
选择只覆盖本地已加载的历史和远端画面，不向远端应用发送滚轮或按键。选中期间暂存新输出，避免覆盖正在复制的文字；
复制或取消选择后恢复显示，选择历史时继续保持阅读位置。进入后台、取消拖动或移除终端视图会停止自动滚动。

任务等待和完成只更新已有锁屏实时活动，不再发送普通通知；没有卡片时也不补发通知。
个人安装包无法在长期后台或进程被结束后持续读取远端状态，卡片会保留最后已知状态。

锁屏实时活动在单连接时以主机别名为标题；多个连接时标题为「Hermit · N 个连接」，
每条任务行首显示各自的主机别名，避免把跨服务器任务误认为来自顶部的某一台服务器。
卡片还展示最后成功读取的时间，以及最多三条工作区任务；待处理优先，
其余任务用 `+N` 表示。每行可返回对应窗格。任务描述只使用 HERDR/钩子报告的标题，
受「锁屏详情」开关控制；主机与工作区名称另受「显示主机名称」控制。
前台过期阈值为 120 秒，为 HERDR 的 45 秒兜底轮询和请求耗时留出余量；后台阈值仍为 45 秒。
后台显示的是最后已知状态，不会用本地刷新时间伪装远端已更新。任务行各自使用所在主机的观测时间，
每次系统渲染时分别判断是否过期；系统级过期时间取卡片中最新的观测时间，避免一台旧主机使整卡变灰。
卡片默认跳转目标优先选择在线、需要处理的任务；不会因此把总览标题改为该服务器名。
明确报告 `idle` 的 Agent 显示灰色暂停圆圈，不沿用上一条任务标题，也不计为完成。
大字号会减少可见行数并相应增加 `+N`，避免系统裁切卡片。

能耗策略：iOS Metal 按变化行累计重建绘制数据，历史滚动和结构变化保留完整失效处理。
正常模式最多 60 帧；低电量或轻度升温最多 30 帧，严重升温 15 帧，临界温度 10 帧。
画面和元信息采样随系统状态降频，键盘发送和终端字节解析仍立即执行。
状态小组件对相同内容合并写入，并保留 60 秒更新时间心跳，只请求刷新 Agent Status 小组件。
通知监控和实时活动共用 tmux 自动状态读取的限频与在途请求，进入后台后停止前台采样定时器。
HERDR 的事件通道与自适应轮询继续提供原生状态，空闲或暂时没有输出不会被推断为完成。

Whisper 实时预览只在录音样本增加后识别，相同文字不重复提交预览。
正常状态下，录音不足 15 秒每轮至少间隔 0.9 秒；15/30/60 秒后分别至少间隔 2/4/8 秒，
慢模型另按单次解码耗时退让。低电量及温控策略可进一步降低预览频率，临界温度暂停预览。
停录后的最终识别始终使用完整录音，不截断前文，也不等待预览的降频间隔。


锁屏后长时间后台、App 退出后的新任务事件需要远程推送。当前 Personal Team 包不具备这项签名权限，
设置会明确提示。具备 APNs 权限的版本可以在「配置主机」填写自建推送服务地址并配对；
不会默认连接原项目的公共推送服务。服务端 APNs 凭据必须与 App 的签名团队和 Bundle ID 对应。

HERDR 主机配对完成后会安装 `scripts/host/hermit-herdr-notify.py` 对应的用户服务：macOS 使用
LaunchAgent，Linux 使用 systemd user service。监听器通过 HERDR Unix socket 订阅事件并读取
`session.snapshot`，仅将等待与完成交给现有加密发送器，不需要 tmux 或 Codex/Claude 钩子，
也不发送终端输入或修改尺寸。需有 Python 3；Linux 用户服务在退出登录后持续运行还取决于主机的
user service/linger 配置。取消配对后，监听器发现对应配置已删除便退出。

终端右上角菜单的「Git 改动与批注」读取当前窗格目录所属仓库，分别显示暂存区、工作区和未跟踪文件。
点击文件查看只读差异，再点行号或「批注文件」添加意见。返回列表点「批注」，可编辑、排序、删除或分享意见。
「加入草稿，不发送」会保留原草稿并追加文件、行号及意见，返回终端后由你确认发送；可用草稿撤销恢复。
批注仅在内存中保存，未导出时关闭需确认；原连接或窗格变化后禁止写入其他草稿，可先分享导出。
行号对应读取时的文件，远端继续修改后需复核。只读审阅不执行提交、还原或分支切换；差异最多显示 256 KiB。

远端文件浏览器或终端文件链接打开 `.html`、`.htm` 时，会使用静态报告预览。
无需运行 HTTP 服务或填写端口，可加载报告所在目录内的 CSS、图片、字体；目录外的资源与符号链接被拒绝。
HTML 上限 512 KiB，单个资源上限 2 MiB，最多 64 次资源读取、合计 10 MiB。
脚本、表单、外部网络和页面跳转被禁用；依赖 JavaScript 的应用仍使用「网页预览」访问运行中的服务。
这些预览沿用已有文件传输 SSH，不要求安装新的远端桥接服务。

「网页预览」输入远端服务地址后，点击「打开预览」或键盘 Go 建立转发。
网页打开后自动收起地址编辑栏和初始说明，只保留顶部地址与主机别名；点击顶部地址可重新编辑、收藏或选择历史地址。
进入后台会暂停转发，返回后点击「继续预览」重新打开；关闭预览保留终端原草稿。

终端右上角菜单的「Markdown 预览」可将当前画面中的 Markdown 排版，支持表格、代码和 Mermaid。
远端文件浏览器打开不超过 1 MB 的 UTF-8 `.md`、`.markdown` 文件时，也会使用此预览。
渲染资源随 App 安装，预览不请求外部图片或渲染服务；HTTP(S) 链接仅在用户点击时打开。
预览最多渲染前 200,000 个字符。终端已经丢失的符号或未加载的历史无法从画面还原，内容不完整时
可打开远端原始 Markdown 文件；原文入口和复制内容始终保留。
连续更新时复用未变化的段落节点及已解析 token；引用定义变化仍会更新受影响的链接。
Mermaid 图表按源码及明暗主题复用，缓存最多 8 项且限制总大小；主题变化重新应用图表外观。
渲染任务串行执行并合并等待中的更新，过期结果不能覆盖新文档。

---

### 输入与发送

普通输入留在底部编辑器，回车发送，Shift+回车或「换行」插入换行。输入法组合态中的回车先确认候选。
底部方向键、Ctrl 和 Esc 直接控制远端，不切换编辑焦点；硬件方向键在有草稿时编辑本地光标，空草稿时控制远端。
Vim 等需要逐键输入的程序仍可显式切到「终端输入」。

每个窗格独立在内存中保存文字、光标、附件队列和发送状态；切换和重连会恢复，主动断开或结束 App 后不保留。
中文组词期间完成的上传和语音追加会与组词结果合并。图片上传完成不会展开键盘或切换输入模式；手动重连保留图片与重试数据，重试使用当前会话的连接。
发送目标在提交前固定，选择已经变化时拒绝发送；上传及语音的异步结果仍归开始操作时的草稿。
「已提交终端」表示该提交链路已确认，不表示命令运行成功；普通 SSH 确认的是本次写入完成。
「未确认」保留草稿并暂停再次提交，可以「查看远端」后确认结果。选择未收到仅解除提交保护，不会自动重发。

### 草稿追加、附件与语音对照

语音、图片和文件路径加入草稿后，可以用「撤销追加」恢复最近一次追加前的文字和光标。撤销只归当前草稿；继续改字或开始发送会取消撤销资格，避免覆盖后续编辑或被误解为撤回远端输入。撤销附件追加不会删除已经上传的远端文件。

文件上传详情支持逐项取消、移除记录和重试。移除/取消当前项后继续处理后面的文件，迟到的进度和成功结果不会回写已移除项或其他行；单项重试不会重复上传其他完成项。重试在当前批次结束后操作。已知大小的文件显示大小，上传显示百分比；移除记录不删除草稿路径或远端文件，取消时远端可能已留下部分或完整文件。

「设置 → 语音输入 → 录音测试」可以填写标准原文及每行一个的技术词，用同一段录音的原始识别结果计算字符错误率（错字、漏字、多字），并分别核对数字片段和技术词。默认忽略标点/空白；核对命令和参数时应关闭该选项，大小写仍严格比较。字符错误率可能超过 100%，不是置信度。末尾缺字来自文本对齐估计，不能证明录音截断。

每次对照限原文与识别结果各 2,000 个字符，超长时提示而不截断评分。评分在后台计算，改变原文或选项会撤销旧评分；手动编辑识别文字不参与准确率计算。原文、结果及评分仅保存在测试页内存，不写入诊断日志或 iCloud；新增对照不会请求云端识别。

### 锁屏任务与提醒

明确报告完成的任务使用独立绿色对号；观测过期后保留对号与绿色，并继续显示更新时间和历史状态提示。进行中仍为空心圆，等待操作用感叹号，过期的进行中和等待状态变灰；空闲、未知、断线或停止输出不会被推断为完成。

任务完成和等待输入仅静默更新已有实时活动，不发送普通通知、横幅或声音；卡片关闭、被划掉或任务无法解析时，也不补发通知。升级时清除旧通知，并停用普通 APNs 注册与通知权限申请。旧版通知设置不影响卡片状态更新。

刚完成的任务即使原来不在前三行，也会从完整会话模型解析并在前三行保留 30 秒，等待输入的任务仍优先；总数来自完整模型。任务轮次标识避免重复更新，较旧的采样不会覆盖刚收到的事件，其他任务的观测时间保持不变。

当前没有接入服务器端 ActivityKit `liveactivity` 推送。App 被 iOS 挂起或退出后，卡片可能保留最后已知状态，应以更新时间为准；回到前台后恢复同步。通知服务扩展不能可靠取消普通 APNs 通知，因此不能用空通知来模拟实时活动推送。

### Tailscale、SSH 与 HERDR 恢复

回前台时独立刷新内置 Tailscale 节点的账号、设备列表与健康信息，不因后台时长、某台主机 SSH 失败或 HERDR 输出超时重启共享节点。节点报告 `Running` 不代表指定主机、SSH 认证或 HERDR 正常。

已有 Tailscale SSH 连接使用有截止时间的真实命令往返验证；失效后只恢复对应连接，继续遵守重试退避。HERDR 渲染通道仍按释放确认和首帧超时恢复。长时间被 iOS 挂起后连接可能失效，这项拆分避免的是无证据的节点重建，不能保证后台永不断线。

### Tailscale 私有安装包下载页

`scripts/release/private-download-server.py` 仅监听 Mac 的 `127.0.0.1`，对外通过 Tailscale Serve 提供 HTTPS。手机浏览器需要系统 Tailscale 连接同一 tailnet；Hermit 内置的节点不会替 Safari 建立路由。访问范围沿用 tailnet 的访问规则。

```bash
python3 scripts/release/private-download-server.py \
  --ipa /absolute/path/Hermit.ipa --source-commit <实际构建的完整提交SHA> \
  --port 18749 --note '本次修复内容'

# 在另一个终端启用独立端口，不覆盖现有 Serve 服务。
TAILSCALE_BE_CLI=1 /Applications/Tailscale.app/Contents/MacOS/Tailscale \
  serve --bg --https=10443 http://127.0.0.1:18749
```

页面从 IPA 读取版本、大小、描述文件类型与有效期，显示 SHA-256，并支持断点续传。带源码构建戳的包不能标成不同的提交。更新 IPA 后需重启下载服务；不会自动把旧包标成最新源码。服务只提供固定页面和选定的 IPA，不提供工程目录浏览。

本机也通过 `https://app.aias.eu.org` 提供下载页：独立的 Cloudflare Tunnel 直接连接 `http://127.0.0.1:18749`，沿用现有仅本人邮箱的 Cloudflare Access 策略，登录会话有效期 24 小时。页面、版本接口、普通 IPA 地址和安装链接生成接口受 Access 保护，Tunnel 端再次校验 Access JWT 的团队和应用 audience。这个入口不依赖手机的系统 Tailscale；tailnet 下载入口可继续使用。

配置 `--ota-origin https://app.aias.eu.org` 后，已登录的同源页面可以通过 JSON POST `/api/install` 准备 `itms-services` 安装链接。接口只接受同源请求；未签名或描述文件过期时不生成链接。页面预先准备链接，让点击由用户手势直接交给 iOS；超过有效期后再次点击会更新链接，再由用户确认。

iOS 安装器通过 `/ota/<票据>/manifest.plist` 和 `/ota/<票据>/Hermit.ipa` 读取资源。仅 `/ota/*` 的 Access 应用跳过浏览器登录；Tunnel 也只对这两个精确文件名的路径免除 Access JWT 校验，源站继续校验 HMAC。票据绑定安装包 SHA-256、过期时间、随机数和具体资源，10 分钟内允许系统重试和断点续传；伪造、跨资源、过期或其他安装包的票据会被拒绝。密钥仅在服务内存中存在，重启后旧链接失效。服务不记录请求 URL，页面不持久化票据。不要对整个站点关闭 Access。

当前个人开发签名包的网页安装仍须由真机验证设备授权、签名及开发者模式，显示按钮不代表已安装成功。网页无法读取 iOS 的最终安装结果；失败时保留原 App，通过 Xcode 或已配置的重签工具更新。单独下载 IPA 仍只会保存文件。保持原签名团队和 Bundle ID 才能沿用已有安装的数据。关闭 Tailscale Serve 入口用 `tailscale serve --https=10443 off`，不要用 `serve reset` 清除其他服务。

## A. 一次性准备(在 Mac 上,手机可不在场)

1. **加 Apple ID**:Xcode ▸ Settings ▸ Accounts ▸ 左下 `+` ▸ Apple ID ▸ 登录。
   登录后会自动出现一个 **"(Personal Team)"**。

2. **拿到 Team ID**(10 位):
   ```bash
   ./scripts/release/team-id.sh
   ```
   若提示还没有 team:先在 Xcode 里打开 `Hermit.xcodeproj`,选 **Hermit** target ▸
   Signing & Capabilities ▸ Team 下拉选你的 Personal Team(这一步会触发 Xcode
   创建证书),再跑一次脚本。

3. **填进签名配置**(让重新生成工程也不丢):
   编辑根目录 `Signing.xcconfig`,把 Team ID 填到 `DEVELOPMENT_TEAM =` 后面。
   然后:
   ```bash
   xcodegen generate
   git update-index --skip-worktree Signing.xcconfig   # 防止 Team ID 误入 git
   ```

> 为什么走 xcconfig:本项目用 xcodegen 生成 `.xcodeproj`,每次 `xcodegen generate`
> 都会重置工程——若只在 Xcode GUI 里选 Team,下次生成就丢了。写进 `Signing.xcconfig`
> 才持久。

---

## B. 装到手机(手机需在场:USB 线,或与 Mac 同一 Wi-Fi)

4. **手机开开发者模式**:设置 ▸ 隐私与安全性 ▸ 开发者模式 ▸ 打开 ▸ 重启。
   (iOS 16+ 首次部署时 Xcode 也会提示你开。)

5. **连接**:USB 接上,手机弹窗点"信任此电脑"。或同 Wi-Fi 下 Xcode ▸ Window ▸
   Devices and Simulators 里勾 "Connect via network"。

6. **运行**:Xcode 顶部设备选择器选你的 iPhone ▸ 按 **⌘R**。
   首次会自动注册设备、生成 Personal Team 的 provisioning profile。

7. **信任证书**:首次启动会被拦截 → 手机 ▸ 设置 ▸ 通用 ▸ VPN 与设备管理 ▸
   点你的开发者 App ▸ 信任 ▸ 回到 App 再启动即可。

---

## C. 命令行安装(可选,完成 B 的首次 GUI 运行之后)

首次务必用 Xcode GUI ⌘R(它负责注册设备 + 建 profile)。之后可纯命令行:

```bash
# 设备 UDID:xcrun devicectl list devices
xcodebuild -project Hermit.xcodeproj -scheme Hermit -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/Device -allowProvisioningUpdates build

xcrun devicectl device install app --device <UDID> \
  build/Device/Build/Products/Debug-iphoneos/Hermit.app
```

---

## D. 用 AltStore 自动续签(免去每周手动 ⌘R)

7 天过期是免费账号最烦的点。**AltStore 正是为此而生**:它用你的免费 Apple ID
侧载,并由常驻电脑的 **AltServer** 在后台、过期前自动重新签名,你无需每周手动重装。
好处:**这条路连 `Signing.xcconfig` 的 Team ID 都不用填**——签名由 AltStore 用它自己
登录的 Apple ID 完成。

1. **出包**(未签名 .ipa,含灵动岛扩展):
   ```bash
   ./scripts/release/build-ipa.sh        # → build/Hermit.ipa
   ```
2. **装 AltStore**:Mac/PC 装 [AltServer](https://altstore.io),手机装 AltStore,
   在 AltStore 里用你的 Apple ID 登录。
3. **侧载**:把 `build/Hermit.ipa` 拖进 AltStore(或 `altserver -u <UDID> build/Hermit.ipa`)。
   AltStore 用你的 Apple ID 重签后安装。
4. **开自动续签**:AltStore ▸ Settings ▸ 打开 Background Refresh。让 AltServer 在
   电脑常驻,手机与电脑同一 Wi-Fi(并开启设备的 Wi-Fi 同步)即可后台续签。

**前提与现实**:
- AltServer 需要在一台电脑上常驻、且手机定期能与它同网可达——后台刷新才会发生;
  完全离线太久仍会过期(打开 App 触发一次前台刷新即可补上)。
- AltStore 本身占用免费账号 3 个 App 名额里的 1 个(剩 2 个;Hermit 是其中之一)。
- 后台刷新不是 100% 可靠(iOS 后台调度 + 设备可达性所限),但比每周手动强得多。
- **想完全摆脱"电脑常驻"**:用 [SideStore](https://sidestore.io)(AltStore 分支,
  靠设备本地 WireGuard 回环续签,无需电脑在同一网络)。流程同上,出包脚本通用。
- **Tailscale 内网能替代"同一 Wi-Fi"吗?基本不能**。经典 AltServer 靠局域网
  Bonjour/mDNS(链路本地组播)发现设备,**组播不跨 Tailscale 的 L3 overlay**,所以
  AltServer 隔着 Tailscale 通常发现不了手机;即便手动指定 IP,iOS 的 lockdownd 也未必
  在 Tailscale 接口上可达。别指望它做后台续签。**续签请用 SideStore(设备本地,
  与网络无关)**。Tailscale 真正的用武之地是下一条——连你的服务器。

## 常见问题

- **"Failed to register bundle identifier"** → `com.cluas.moshpit` 全球唯一被占用了。
  改 `project.yml` 里 `com.cluas.moshpit` → 更独特的(如 `com.<你的标识>.moshpit`),
  连带把 `.island` 后缀的扩展 id 一起改,`xcodegen generate` 后重试。
- **灵动岛扩展签名报错** → 免费账号偶发。临时验证主 App:在 `project.yml` 的 Hermit
  target `dependencies` 里去掉 `HermitIsland` 那两行,generate 后只装主 App(会暂时
  失去 Live Activity);确认主 App 能装后再加回来排查。
- **装上后 7 天打不开** → 正常,重新 ⌘R 续签。
- **想人不在家也能更新** → 免费账号做不到;升级 $99/年开发者账号后走 TestFlight(90 天)
  或直接上架。
- **签名报 "Push Notifications capability is not available"** → 免费个人账号签不了
  推送。把 `project.yml` 里 Hermit target entitlements 下的 `aps-environment:
  development` 那一行注释掉,`xcodegen generate` 后重试;同理可以照灵动岛扩展那条把
  `HermitPush` 从 `dependencies` 里去掉。代价是**远程推送整个失效**——agent 在你没
  开着 App 时叫不到你(`docs/PUSH.md` 讲的就是这条链路)。App 开着时的灵动岛、本地
  通知、锁屏 Allow/Deny 都不受影响,因为那条路不经过 APNs。
  注意 `project.yml` 是 Info.plist 和 entitlements 的**唯一源头**:直接改生成出来的
  `Hermit.entitlements` 会在下次 generate 时被覆盖回去。
- **签名报 Time Sensitive Notifications 相关的 capability 错误** → 同一个原因,同一个
  做法:把 `project.yml` 里 `com.apple.developer.usernotifications.time-sensitive`
  那一行注释掉再 `xcodegen generate`。这条 entitlement 让"agent 在等你批准"的通知能
  **穿透专注模式**、不被定时摘要攒起来;去掉之后 App 照常工作,通知也照常来,只是会
  和普通通知一样排在专注模式后面。App 和 relay 两边的代码都仍然会**请求**这个级别,
  iOS 在没有 entitlement 时静默降级,不报错也不打日志——所以不用改任何代码。

  注意这跟 Critical Alerts 不是一回事:后者(能无视静音键)要向 Apple 单独申请审批,
  Hermit 没用、也不打算用。
