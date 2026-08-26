# DSH Swift Native Shell 发布交接

本文档记录 `deepseek-harness-swift` 的构建、DMG 打包、Sparkle 签名和 GitHub Release 发布流程。

当前发布链路仍然是“脚本自动化构建 + 人工完成签名和发布”。仓库中没有保存 Sparkle 私钥，也没有配置包含私钥的 GitHub Actions 工作流。发布人员必须在已配置 Sparkle 私钥的 macOS 上完成最后的签名步骤。

## 1. 项目边界

- 仓库：<https://github.com/krystal-cao/deepseek-harness-swift>
- 工程：`DSH.xcodeproj`
- 支持系统：macOS 13+
- 支持架构：`arm64`（Apple Silicon）和 `x86_64`（Intel）
- 当前版本配置：`Version.xcconfig`
- 当前更新源：<https://raw.githubusercontent.com/krystal-cao/deepseek-harness-swift/main/appcast-swift.xml>
- GitHub Release 资产目录：`v$SWIFT_APP_VERSION`

这是独立的 Swift 原生项目，不依赖 Electron 仓库，也不需要执行 `npm install` 或 `npm ci` 来准备应用构建依赖。`package.json` 仅提供不依赖第三方 npm 包的源代码测试命令。

应用包内置 Node.js 和 pnpm，但不内置 DSH 本体。构建时脚本会准备 Node.js 和 pnpm；应用首次运行时再从 npm Registry 安装 DSH 运行时。

当前线上状态：

- 应用版本：`1.0.0`
- 应用 build：`2`
- tag：`v1.0.0`
- 两个架构 DMG 已上传到该 Release
- `appcast-swift.xml` 已使用 build 2 的签名和文件大小

## 2. 哪些步骤自动，哪些步骤手动

| 环节 | 当前处理方式 | 说明 |
| --- | --- | --- |
| Swift 编译 | `scripts/build-app.sh` 自动调用 `xcodebuild` | 支持分架构构建，并校验二进制架构、最低系统版本和资源 |
| Node.js 准备 | 构建脚本自动调用 `scripts/fetch-node.sh` | 发布构建使用官方 Node.js，按目标架构下载 |
| pnpm 准备 | `fetch-node.sh` 自动调用 `scripts/fetch-pnpm.sh` | 下载固定版本并校验 SHA-512 |
| macOS ad-hoc 签名 | `build-app.sh` 自动执行 `codesign --sign -` | 不是 Developer ID 签名，也不包含 notarization |
| DMG 制作 | `scripts/package-dmg.sh` 自动执行 `hdiutil` | 默认生成 arm64 和 x86_64 两个 DMG，并验证镜像 |
| Sparkle Ed25519 签名 | 手动执行 `sign_update` | 私钥在本机 Keychain，不能交给仓库脚本或提交到 Git |
| appcast 更新 | 手动填写 `appcast-swift.xml` | 需要把签名、文件大小、构建号和下载地址对应起来 |
| GitHub Release | 手动使用 `gh` 上传或替换资产 | appcast 指向 Release 资产，资产必须先可下载 |
| GitHub Actions | 当前不使用 | 私钥只在本地 Keychain，未配置安全的远程签名环境 |

## 3. 一次性准备发布机器

### 3.1 系统工具

发布机器需要 macOS、Xcode（包含支持 Swift 5.9 的工具链）以及以下命令：

```bash
xcodebuild
codesign
hdiutil
lipo
curl
tar
shasum
git
gh
```

首次打开工程或第一次执行构建时，Xcode 需要通过 Swift Package Manager 下载 Sparkle。构建机器必须能够访问 GitHub、Node.js 官方下载地址和 npm Registry；pnpm 脚本也准备了 npm 镜像回退地址。

### 3.2 GitHub CLI

需要登录具有该仓库写权限的 GitHub 账号：

```bash
gh auth login
gh auth status
```

后续命令默认使用：

```bash
REPO="krystal-cao/deepseek-harness-swift"
```

### 3.3 Sparkle 签名工具和 Keychain

需要准备 Sparkle 工具目录，并将其路径放到环境变量中：

```bash
export SPARKLE_BIN="/path/to/Sparkle/bin"
test -x "$SPARKLE_BIN/generate_keys"
test -x "$SPARKLE_BIN/sign_update"
```

具体路径取决于 Sparkle 的安装方式。只要目录中能找到 `generate_keys` 和 `sign_update` 即可。

Sparkle 私钥只应保存在发布机器的 Keychain。项目约定的 Keychain account 名称是 `dsh-swift`。

首次创建密钥（仅在没有该 account 时执行）：

```bash
"$SPARKLE_BIN/generate_keys" --account dsh-swift
```

查看或输出公钥：

```bash
"$SPARKLE_BIN/generate_keys" --account dsh-swift -p
```

`Info.plist` 中的 `SUPublicEDKey` 必须与该 account 对应的公钥一致。公钥可以提交到仓库；私钥、Keychain 导出文件和任何包含私钥的日志都不能提交或上传。

如果 `sign_update` 报告找不到 account，不要新建另一套密钥后直接替换公钥。先确认当前登录用户、Keychain 状态和 `SPARKLE_BIN` 是否指向同一套 Sparkle 工具。

## 4. 发布前检查

在仓库根目录执行：

```bash
cd ~/Documents/ChatGPT/deepseek-harness-swift
git status --short
git switch main
git pull --ff-only origin main
npm test
bash -n scripts/build-app.sh scripts/package-dmg.sh scripts/fetch-node.sh scripts/fetch-pnpm.sh
```

发布前工作区最好保持干净。`npm test` 不需要安装 npm 依赖，测试只读取 Swift 源码、Xcode 工程和脚本配置。

确认版本配置：

```bash
sed -n '1,8p' Version.xcconfig
```

版本规则：

- `SWIFT_APP_VERSION` 是用户看到的版本号，例如 `1.0.0`。
- `SWIFT_APP_BUILD` 是 Sparkle 比较用的构建号，必须单调递增。
- 同一个营销版本发布修复包时，只增加 build，例如 `1.0.0 / 2`、`1.0.0 / 3`。
- 新的营销版本通常使用新的 tag，例如 `1.0.1 / 1` 对应 `v1.0.1`。
- 不要让已经发布的 DMG、`Version.xcconfig`、appcast 和 tag 使用互相矛盾的版本信息。

修改 `Version.xcconfig` 后，不要手动修改 `Info.plist` 的版本字段。Xcode 构建会通过 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION` 注入 `CFBundleShortVersionString` 与 `CFBundleVersion`。

## 5. 构建 Swift 应用

### 5.1 默认分架构构建

发布时使用官方 Node.js：

```bash
DSH_NODE_SOURCE=official bash scripts/build-app.sh
```

脚本会按目标架构依次完成：

1. 下载或复用对应架构的 Node.js。
2. 准备并校验固定版本的 pnpm。
3. 使用 `xcodebuild -configuration Release` 编译 `DSH.xcodeproj`。
4. 校验 Swift 可执行文件、内置 Node.js、最低 macOS 版本和图标资源。
5. 对 `.app` 执行 ad-hoc codesign。

在 Apple Silicon 机器上，默认会构建 `x86_64` 和 `arm64`；在 Intel 机器上也会尝试构建两个目标架构。输出应用包位于：

```text
dist/arm64/DSH.app
dist/x86_64/DSH.app
```

构建脚本会使用 `.build/xcode/<arch>/` 保存 Xcode 派生数据。`.build/`、`dist/`、`assets/node/` 和 `assets/bin/pnpm-pkg/` 都是被 `.gitignore` 排除的生成内容，不要提交。

### 5.2 单架构构建

需要只构建一个架构时：

```bash
DSH_BUILD_ARCH=arm64 DSH_NODE_SOURCE=official bash scripts/build-app.sh
DSH_BUILD_ARCH=x86_64 DSH_NODE_SOURCE=official bash scripts/build-app.sh
```

单架构发布仍然要确认目标 DMG 和 appcast 的 `sparkle:hardwareRequirements` 对应正确。不要把 x86_64 DMG 标成 arm64，反之亦然。

### 5.3 构建缓存和失败处理

正常成功的 DMG 打包会清理 `.build/`。如果构建或打包中途失败，`.build/` 会保留用于排查；修复问题后可以直接重新执行脚本。

如果 `assets/node/bin/node` 是错误架构或缓存损坏，可以清理生成缓存后重新准备：

```bash
rm -rf assets/node assets/bin/pnpm-pkg
DSH_NODE_SOURCE=official bash scripts/build-app.sh
```

只删除上述生成目录，不要删除 `assets/dsh-desktop-host`、`assets/dsh-family.json`、`app.icon` 或源代码。

## 6. 制作并验证 DMG

应用构建成功后执行：

```bash
DSH_NODE_SOURCE=official bash scripts/package-dmg.sh
```

默认输出：

```text
dist/DSH-Desktop-<APP_VERSION>-arm64.dmg
dist/DSH-Desktop-<APP_VERSION>-x64.dmg
```

`package-dmg.sh` 会对每个 `.app` 做以下检查：

- 应用二进制只能包含目标架构。
- ad-hoc codesign 验证通过。
- 使用 `hdiutil create -format UDZO` 创建 DMG。
- 使用 `hdiutil verify` 验证 DMG。
- 所有请求架构都成功后，清理 `.build/`。

检查产物名称、架构和大小：

```bash
stat -f '%N %z bytes' dist/DSH-Desktop-*.dmg
lipo -archs dist/arm64/DSH.app/Contents/MacOS/DSH
lipo -archs dist/x86_64/DSH.app/Contents/MacOS/DSH
```

期望的架构输出分别是：

```text
arm64
x86_64
```

也可以检查应用内版本字段：

```bash
plutil -p dist/arm64/DSH.app/Contents/Info.plist
plutil -p dist/x86_64/DSH.app/Contents/Info.plist
```

检查其中的 `CFBundleShortVersionString`、`CFBundleVersion`、`SUFeedURL` 和 `SUPublicEDKey`。

## 7. 生成 Sparkle Ed25519 签名

必须在最终 DMG 生成后签名。任何重新打包、重新压缩或替换 DMG 内容都会使之前的签名失效。

对两个架构分别执行：

```bash
"$SPARKLE_BIN/sign_update" --account dsh-swift dist/DSH-Desktop-<APP_VERSION>-arm64.dmg
"$SPARKLE_BIN/sign_update" --account dsh-swift dist/DSH-Desktop-<APP_VERSION>-x64.dmg
```

命令会输出类似下面的两项信息：

```text
sparkle:edSignature="..." length="..."
```

必须分别记录：

- arm64 的 `sparkle:edSignature`
- arm64 DMG 的字节数 `length`
- x86_64 的 `sparkle:edSignature`
- x86_64 DMG 的字节数 `length`

建议用文件系统大小复核 `sign_update` 输出：

```bash
stat -f '%N %z' dist/DSH-Desktop-<APP_VERSION>-arm64.dmg dist/DSH-Desktop-<APP_VERSION>-x64.dmg
```

Sparkle 的 DMG 签名和 macOS ad-hoc codesign 是两套不同的签名：

- ad-hoc codesign 用于让应用包能够在当前 macOS 上启动。
- Sparkle Ed25519 签名用于验证更新 DMG 是否由本项目发布。

不要把 Ed25519 私钥放到脚本、环境变量、仓库文件或普通 GitHub Actions secret 中。当前项目的私钥保存在本地 Keychain，因此签名步骤只能在已配置该 Keychain 的机器上执行。

## 8. 更新 appcast-swift.xml

`Info.plist` 中的 `SUFeedURL` 固定指向：

```text
https://raw.githubusercontent.com/krystal-cao/deepseek-harness-swift/main/appcast-swift.xml
```

每个架构各有一个 `<item>`。更新发布时需要同步修改以下字段：

```xml
<title>1.0.0</title>
<pubDate>Tue, 25 Aug 2026 18:00:00 +0800</pubDate>
<sparkle:version>2</sparkle:version>
<sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>
<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
<enclosure url="https://github.com/krystal-cao/deepseek-harness-swift/releases/download/v1.0.0/DSH-Desktop-1.0.0-arm64.dmg" length="这里填 sign_update 输出的字节数" type="application/octet-stream" sparkle:edSignature="这里填 sign_update 输出的签名"/>
```

x86_64 条目使用 `<sparkle:hardwareRequirements>x86_64</sparkle:hardwareRequirements>` 和 x64 DMG 的签名、大小。

注意事项：

- `sparkle:version` 必须等于 `SWIFT_APP_BUILD`，而不是只看 `SWIFT_APP_VERSION`。
- `sparkle:shortVersionString` 必须等于 `SWIFT_APP_VERSION`。
- `length` 必须是最终上传文件的真实字节数。
- `url` 的 tag、文件名和架构必须与 GitHub Release 资产完全一致。
- 同一版本不同架构的签名不能互换。
- `description` 可以复用上一条更新说明，但版本和已知限制要与实际发布内容一致。

验证 XML：

```bash
ruby -rrexml/document -e 'REXML::Document.new(File.read("appcast-swift.xml")); puts "appcast XML valid"'
```

如果安装了 `xmllint`，也可以执行：

```bash
xmllint --noout appcast-swift.xml
```

## 9. Git 提交、tag 和 GitHub Release

### 9.1 新版本发布推荐顺序

新版本建议按下面顺序执行，确保 tag、版本配置和 appcast 属于同一份源代码：

1. 修改 `Version.xcconfig` 中的版本和 build。
2. 完成测试、构建、DMG 打包和 Sparkle 签名。
3. 用签名结果更新 `appcast-swift.xml`。
4. 提交所有源代码和 appcast 改动。
5. 创建并推送对应 tag。
6. 创建 GitHub Release 并上传两个 DMG。
7. 验证 raw appcast 和两个 Release 下载链接。

示例：

```bash
APP_VERSION="1.0.1"
TAG="v$APP_VERSION"
REPO="krystal-cao/deepseek-harness-swift"

git add Version.xcconfig appcast-swift.xml Sources README.md
git commit -m "release: publish $TAG"
git push origin main

git tag -a "$TAG" -m "Release $TAG"
git push origin "$TAG"

gh release create "$TAG" dist/DSH-Desktop-$APP_VERSION-arm64.dmg dist/DSH-Desktop-$APP_VERSION-x64.dmg --repo "$REPO" --title "DSH Swift $APP_VERSION" --notes "DSH Swift Native Shell $APP_VERSION"
```

如果 Release 已经存在、只是同一个版本重新生成了同名 DMG（例如当前 `v1.0.0` 的 build 2 替换 build 1），使用：

```bash
gh release upload v1.0.0 dist/DSH-Desktop-1.0.0-arm64.dmg dist/DSH-Desktop-1.0.0-x64.dmg --repo krystal-cao/deepseek-harness-swift --clobber
```

`--clobber` 会替换同名资产。替换资产后，appcast 中的 `length` 和 `sparkle:edSignature` 也必须对应替换后的文件。

不要复用已经指向其他内容的 tag。正常的新版本应创建新 tag；只有同一个版本的构建修复，且明确需要覆盖旧资产时，才使用同一个 Release 的 `--clobber`。

### 9.2 推送前检查

```bash
git diff --check
git status --short
git log -1 --oneline
```

推送完成后确认：

```bash
git status --short
git ls-remote --tags origin "refs/tags/$TAG"
gh release view "$TAG" --repo "$REPO"
```

## 10. 发布后的远端验证

首先确认两个 Release 资产的大小：

```bash
gh release view v1.0.0 --repo krystal-cao/deepseek-harness-swift --json assets
```

确认 `size` 与 appcast 中的 `length` 一致。

确认更新源已经包含最新 build：

```bash
curl -fsSL https://raw.githubusercontent.com/krystal-cao/deepseek-harness-swift/main/appcast-swift.xml
```

确认下载 URL 可访问并返回正确的文件大小：

```bash
curl -sSIL -L --max-redirs 3 https://github.com/krystal-cao/deepseek-harness-swift/releases/download/v1.0.0/DSH-Desktop-1.0.0-arm64.dmg
curl -sSIL -L --max-redirs 3 https://github.com/krystal-cao/deepseek-harness-swift/releases/download/v1.0.0/DSH-Desktop-1.0.0-x64.dmg
```

最终安装测试时，建议：

1. 从 DMG 安装新应用。
2. 检查 `/Applications/DSH.app/Contents/Info.plist` 的 `CFBundleShortVersionString` 和 `CFBundleVersion`。
3. 在“关于”页面确认版本号和项目主页链接。
4. 从一个较低 build 的旧应用执行“检查更新”。
5. 确认 Sparkle 能看到新 build、下载对应架构 DMG，并在安装前通过签名校验。

同一 `SWIFT_APP_VERSION` 和同一 `SWIFT_APP_BUILD` 的应用不会把自己识别为更新。测试 Sparkle 时，已安装应用必须使用更低的 build，或者发布一个更高的 build。

## 11. 常见问题

### 11.1 “检查更新”报错

依次检查：

1. 已安装应用的 `SUFeedURL` 是否是 Swift 仓库的 raw appcast 地址。
2. raw appcast 是否返回 HTTP 200，且 XML 可解析。
3. appcast 的 `sparkle:version` 是否大于已安装应用的 `CFBundleVersion`。
4. `SUPublicEDKey` 是否与 `dsh-swift` account 的公钥一致。
5. enclosure URL 是否返回 HTTP 200，而不是 404。
6. appcast 的 `length` 是否与 Release 资产大小一致。
7. `sparkle:edSignature` 是否来自最终上传的同一个 DMG。
8. 当前机器架构是否匹配 `sparkle:hardwareRequirements`。

### 11.2 `sign_update` 找不到 account

检查以下内容：

```bash
echo "$SPARKLE_BIN"
test -x "$SPARKLE_BIN/sign_update"
"$SPARKLE_BIN/generate_keys" --account dsh-swift -p
```

如果公钥与 `Info.plist` 不一致，不要直接修改线上 appcast。先确认使用的是正确的 Keychain 用户和正确的 Sparkle 工具目录。

### 11.3 DMG 上传后签名不匹配

最常见原因是先签名、后重新打包，或 `gh release upload --clobber` 上传了另一份同名文件。重新执行以下流程：

1. 删除或覆盖本地旧 DMG。
2. 重新执行 `package-dmg.sh`。
3. 重新执行两个 `sign_update`。
4. 用新的 `length` 和签名更新 appcast。
5. 再次使用 `--clobber` 上传同名 DMG。

### 11.4 Node.js 或 pnpm 架构错误

确认目标架构变量，并清除生成缓存：

```bash
rm -rf assets/node assets/bin/pnpm-pkg
DSH_BUILD_ARCH=arm64 DSH_NODE_SOURCE=official bash scripts/build-app.sh
```

跨架构构建时，脚本会下载目标架构 Node.js；不要把当前机器上已有的单架构 Node 二进制直接复制到另一架构的应用包中。

### 11.5 Xcode 无法解析 Sparkle

先在 Xcode 中确认 Swift Package 依赖能够下载，也可以执行：

```bash
xcodebuild -project DSH.xcodeproj -scheme DSH -resolvePackageDependencies
```

这一步需要网络访问 Sparkle GitHub 仓库。不要把 `.build/` 或本地 DerivedData 提交到 Git。

## 12. 安全与后续自动化边界

- Sparkle Ed25519 私钥只在本地 Keychain 中，不能提交到 Git、DMG、appcast 或 README。
- 当前构建使用 ad-hoc codesign，没有 Developer ID 证书和 notarization。
- GitHub Actions 当前不能直接完成签名发布，因为工作流没有本地 Keychain。
- 如果未来要自动化，需要单独设计受保护的签名环境（例如专用 macOS runner、受控 Keychain、短期凭证和审计流程），不能仅把私钥文本放进普通仓库 secret。
- 在自动化之前，最值得脚本化的是 appcast 生成和校验：从两个 DMG 自动读取文件大小、调用本机 `sign_update`、更新两个架构条目并检查 URL；签名私钥仍应由发布者在本地确认。

当前最安全、可复现的流程是：本地构建 → 本地签名 → 手动上传 Release → 手动更新并推送 appcast → 远端验证。
