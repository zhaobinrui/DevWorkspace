# DevWorkspace

DevWorkspace 是独立的 macOS 14+ 菜单栏应用，用于查看本地项目状态并安全控制已信任的项目启动流程。
它不依赖其他 DevSpace 应用运行；项目清单仍保存在本机 Application Support 的
`com.zhaobinrui.devspace.workspace/projects-v1.json`，提取仓库不会更改 Bundle Identifier 或数据位置。

## 开发验证

```bash
xcodebuild -project DevWorkspace.xcodeproj -scheme DevWorkspace -configuration Debug \
  -derivedDataPath /private/tmp/DevWorkspaceDerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -project DevWorkspace.xcodeproj -scheme DevWorkspace -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/DevWorkspaceDerivedData CODE_SIGNING_ALLOWED=NO test
```

## 独立发行

`release/release.sh` 要求干净的 Git 工作区、有效的 Developer ID Application 证书和保存在
Keychain 中的 `notarytool` 凭据。它会使用 Xcode 归档与 Developer ID 导出，提交 Apple 公证，
对 App 附加公证票据，并验证签名、票据和 Gatekeeper 后生成 ZIP。凭据不得提交到仓库，也不要
通过命令行传入密码；脚本只接收非机密的 Team ID 和 Keychain 凭据配置名。发行前还需确定
HTTPS appcast 地址，用 Sparkle 工具 `generate_keys` 在本机 Keychain 创建 EdDSA 私钥，再把
公开的 feed URL 与公钥提供给构建；私钥绝不能放进源码、环境变量或发行包。

```bash
DEVWORKSPACE_UPDATE_FEED_URL=https://updates.example.com/devworkspace/appcast.xml \
DEVWORKSPACE_UPDATE_PUBLIC_KEY=BASE64_PUBLIC_KEY \
./release/release.sh TEAMID1234 devworkspace-notary /private/tmp/DevWorkspace-release-0.1.0
```

更新框架固定为 Sparkle 2.10.0（下载包约 9.7 MB，Debug 包内框架约 2.7 MB；许可证及
第三方声明随 App 收录在 `Sparkle-LICENSE.txt`）。未配置 feed 与公钥的开发构建不会启动更新器；发行 ZIP
需要由 Sparkle 的 `generate_appcast` 生成 EdDSA 签名条目，上传到与应用内 feed URL 一致的
HTTPS 地址后，才能进行“旧版 → 新版”的应用内更新验收。Sparkle 默认关闭系统概况采集，
自动检查由用户在设置中启用，项目内容不会发送到更新源。

独立发布前还必须在 macOS 14 上验证发行包安装、首次启动、更新与菜单栏/Profile 交互；
仅在较新 macOS 上通过编译和单元测试不能代替该验收。逐项记录见
[`release/acceptance.md`](release/acceptance.md)。
