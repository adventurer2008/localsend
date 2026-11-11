# LocalSend 可信设备中继

在改造版 LocalSend 的发送或接收页打开「可信设备」。加入同一个中继服务器白名单的设备会自动互相信任，设备名单自动同步。选择设备后，客户端先用设备签名名片中的 HTTPS 证书指纹验证可达的局域网端点。验证成功时使用 LocalSend 原有传输流程，无法确认局域网端点时使用公网中继。开始局域网传输后即固定使用这条路径，避免对同一次发送重复发起收件请求。

## 准备两台设备

1. 每台设备在「可信设备」页填写同一个服务器地址。
2. 每台设备点 **Copy relay allowlist key**。管理员在 VPS 的 `relay/allowlist.json` 中保存这些公钥，格式为 JSON 字符串数组，每台设备一项。部署前将下例替换为实际复制的公钥。

   ```json
   ["设备 A 的 Ed25519 公钥", "设备 B 的 Ed25519 公钥"]
   ```

3. 重启中继。各设备会自动重连、发布签名名片并显示其他白名单设备。十台设备各登记一次公钥即可。应用运行时会保持连接，切换页面也能接收请求。发送方在「可信设备」页点击设备选取一个文件，接收方看到名称和大小后接受或拒绝。收到的公网文件保存在应用文档目录的 `LocalSend Remote` 文件夹，也可以从页面直接打开最新接收的文件。

局域网选路使用现有设备发现，要求两端开启 LocalSend 的 HTTPS 和接收服务。局域网中能找到且能验证证书的设备，即使中继离线也可直传。局域网禁止发现时，客户端可以走已连接的中继。

## 在 VPS 运行

安装 Node.js 22 或更新版本。让域名解析到 VPS，在 `relay/` 目录执行下列命令。默认只监听 VPS 的 `127.0.0.1:8787`。生产运行可以用 systemd 或现有进程管理器，以普通用户启动。

```sh
npm ci --omit=dev
npm start
```

用 Caddy 或已有 HTTPS 反向代理对外提供 TLS，代理应保留 WebSocket Upgrade。下面是 Caddy 的配置示例。

```caddyfile
relay.example.com {
    reverse_proxy /v1/relay 127.0.0.1:8787
}
```

客户端严格使用 `wss://` 并校验服务器证书。`curl http://127.0.0.1:8787/health` 可用于检查本地中继是否启动。可通过 `RELAY_ALLOWLIST`、`RELAY_HOST`、`RELAY_PORT` 设置白名单路径、监听地址和端口。设备名片缓存默认位于白名单旁的 `devices.json`，可通过 `RELAY_DIRECTORY` 指定。

撤销设备时，从 VPS 的白名单删除公钥并重启中继，客户端重连后会自动移除该设备。设备换机或密钥重置后重新登记公钥，局域网证书变动会随下次连接自动发布。

## 传输边界

- 自建中继及其白名单是设备信任来源，白名单最多 32 台设备。中继通过 Ed25519 挑战签名验证登录，只有通过验证且已登记的设备能发布签名名片。客户端验证名片签名，并使用其中的 X25519 公钥派生传输密钥。文件名、大小、接收决定、数据块和完成回执都由 AES-256-GCM 认证加密。中继能看到设备连接、传输时机和流量大小。
- 文件在接收方确认后分块转发。中继进程不落盘，接收端只有在收到并验证完整文件后才把临时文件移到最终位置。第一版每台设备同一时间一个公网传输，一次发送一个文件。双方需要在线，断线后重新发起。
- 当前使用设备长期 X25519 密钥，未实现前向保密。移动系统暂停或终止应用时可能中断连接，回到应用后会重连。Linux 构建需要 `libsecret` 的开发包，运行远程功能需要可用的桌面 Secret Service。

## 验证

在 `relay/` 运行 `npm ci` 和 `npm test`。从 `app/` 运行 `flutter test test/unit/remote_transfer_test.dart`，设置 `LOCALSEND_RELAY_TEST=1` 可同时运行两端 Dart 客户端对本地中继的联调。

实际部署后，先在同一个局域网验证直传，再让一端切到蜂窝网络验证公网双向收发。两次都应先出现接收确认。VPS 中继停机时，已发现且证书匹配的局域网设备仍应能互传。

## 没有 Mac 时安装到 iPhone

可以用 Codemagic 的 macOS 构建机先验证 Flutter iOS 无签名构建。准备真机安装包时，在自己的 Apple Developer 团队下登记 iPhone 的 UDID，为主应用和 Share Extension 分配各自的 Bundle ID 及 Ad Hoc 描述文件。将两个 target 的 App Group 和代码中的 App Group 标识统一改为团队下登记的标识，再用 Codemagic 生成签名的 IPA。已登记的 iPhone 可以通过构建结果的安装二维码安装。签名凭据只配置在构建服务中。 [Codemagic 分发方式](https://docs.codemagic.io/knowledge-white-label/white-label-apps-overview/)

原项目的 iOS 局域网组播依赖 Apple 审批的 `com.apple.developer.networking.multicast` 权限。要保留 iPhone 真机的组播自动发现，需给自己的 App ID 申请此权限。公网中继走 WSS，不使用组播。 [Codemagic 签名](https://docs.codemagic.io/flutter-code-signing/ios-code-signing/) · [Apple 组播权限](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast)
