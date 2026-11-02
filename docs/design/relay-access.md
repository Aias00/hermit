# Hermit 的 RemoteForge Relay 接入

Hermit 新增独立的 RemoteForge Relay 连接方式。电脑 Agent 主动连中继，手机用一次性邀请获取独立授权，然后通过原有 Citadel/SSH 层访问目标设备。Relay 不解析终端内容，不依赖 HERDR 或某个 AI 工具。

## 使用

先按 [独立 Relay 仓库](https://github.com/Aias00/remoteforge-relay) 的说明部署中继、启动电脑 Agent，并在电脑上生成邀请：

```sh
rf-agent pair --config runtime/agent.json --service ssh --out runtime/pairing.json --qr runtime/pairing.png
```

手机上进入「新增主机 → 连接方式 → RemoteForge Relay → 配对 Relay」。可以扫描二维码、粘贴邀请链接，或导入 JSON/二维码图片。解析后先核对公开的中继地址、设备和服务，再点「确认配对」。随后设置 SSH 用户名、密码或密钥和远端会话类型，保存主机，再连接。

邀请五分钟有效且只能使用一次。配对仅授予到目标服务的接入权；SSH 身份认证仍独立进行。目标地址和端口由电脑 Agent 的服务映射决定，手机只可选择邀请绑定的服务，不接受中继指定任意目标地址。App 隐藏 Relay 的网络端口输入，将显示主机名作为别名使用。

如果配对后取消新增主机，本轮尚未保存的凭据会随编辑页释放；需要重新生成邀请。遗留的远端授权可通过电脑上的 `rf-agent clients/revoke` 管理。授权默认九十天到期，失效后需重新配对，App 不自动兑换或续期。

## 实现

- `ServerConnection` 只新增可选的公开路由字段和本机凭据引用，兼容旧记录；无效/未知路由不回退直连。
- `RelayCredentials` 在真机和签名模拟器均使用独立的系统 Keychain service，保护级别为 WhenUnlockedThisDeviceOnly，不使用普通 SSH 模拟器文件仓库。
- 邀请只存在于临时配对页。收到凭据后先保存在编辑状态，保存主机时才暂存新的不可变 Keychain item；SSH 凭据保存失败时回滚新引用，保留旧凭据供重试。
- 更新主机先提交新引用再清理旧引用；删除主机只删除最后一个本机使用者的凭据。删除失败保留主机记录，供解锁后重试。
- iCloud 同步公开的中继/设备/服务信息，保留同作用域的已有本机绑定；Relay 授权按设备单独配对，不进入便携 SSH 凭据同步。新设备需生成自己的客户端授权。
- SSH 指纹按规范化中继 origin + device + service 区分，凭据轮换或别名修改不重置信任；编辑网络端口元数据不会拆分 Relay 的 SSH 信任记录。
- NIO handler 安装完成后才激活 carrier；等待真实 SSH 认证事件才返回 SSHSession。认证失败、取消和断开均清理 carrier；关闭会等待异步任务收尾。
- 401/403、凭据缺失/失效属于用户操作问题，不持续自动重试；暂时网络失败、超时和服务不可用可按现有恢复策略重试。

SDK 源码快照位于 `Packages/RemoteForgeRelay`，上游提交记录与 MIT 许可证一并保留。Hermit 构建无需检出私有的兄弟仓库；仅跨语言测试需要独立 Relay 源码。

## 验证

`scripts/verify/relay-access.py` 可在专用的可清空模拟器上复现：

```sh
python3 scripts/verify/relay-access.py \
  --relay-repo ../remoteforge-relay \
  --device PHONE_QA_UDID --device MINI_QA_UDID \
  --derived-data ../moshpit-build \
  --output ../hermit-relay-verification/new-run
```

脚本先构建，再为每个模拟器生成新的临时 Go Relay、Agent 与 SSH 服务，避免邀请在构建期间过期。合成账号和配对码只通过私有临时文件传递，不打印到命令行或报告；UI 测试通过系统粘贴控件输入，不把邀请放入 XCTest 的 typeText 活动日志。结束时关闭测试服务并删除私有文件。测试只连接 loopback，不访问用户主机；DEBUG 模拟器须显式启用 loopback 测试标记，Release 没有 HTTP/TLS 绕过选项。

测试覆盖路由校验、Keychain、QR 图片解码、iCloud 凭据隔离、删除失败与共享引用、错误恢复分类、现有 Citadel 经 Relay 认证/命令和并行连接生命周期，以及配对保存/重启/编辑的真实 UI。

2026-11-02 验证：iPhone 12 Pro Max 与 iPad mini（A17 Pro），均为 iOS 27.0 模拟器，各通过 78 项配置/存储/回归/真实 SSH 测试与 2 项 UI 测试，共 160 项，无失败。每台设备均启动独立 Go Relay/Agent/合成 SSH 服务，真实联调测试已启用。UI 验证包含无效邀请提示与取消、系统粘贴配对、保存主机、App 重启后重新编辑；iPad 测试等待键盘引起的居中窗口移动完成后才点击，避免使用旧坐标。

物理相机扫描、真机公网/蜂窝切换、长时运行和完整 SFTP 验收仍需后续验证。Hermit Chat 当前有独立的未提交改动，本轮没有将其工作区混入本次接入。
