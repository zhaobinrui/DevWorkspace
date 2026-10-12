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
通过命令行传入密码；脚本只接收非机密的 Team ID 和 Keychain 凭据配置名。

```bash
./release/release.sh TEAMID1234 devworkspace-notary /private/tmp/DevWorkspace-release-0.1.0
```

独立发布前还必须在 macOS 14 上验证发行包安装、首次启动、更新与菜单栏/Profile 交互；
仅在较新 macOS 上通过编译和单元测试不能代替该验收。逐项记录见
[`release/acceptance.md`](release/acceptance.md)。
