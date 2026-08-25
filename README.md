<h1 align="center">
  <img src="app.icon/Assets/icon-1024.png" width="72" alt="DSH 标志" />
  <br />
  DSH Swift Native Shell
</h1>

<p align="center">
  基于 AppKit、SwiftUI 和 WKWebView 的原生 macOS 桌面壳。
</p>

<p align="center">
  <a href="https://github.com/krystal-cao/deepseek-harness-desktop/releases/tag/v1.0.0-swift"><img alt="Swift 原生版 v1.0.0" src="https://img.shields.io/badge/Swift%20Native-v1.0.0-171513.svg?style=flat-square" /></a>
  <a href="LICENSE"><img alt="许可证：MIT" src="https://img.shields.io/badge/License-MIT-171513.svg?style=flat-square" /></a>
  <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-171513.svg?style=flat-square" />
  <img alt="Apple Silicon 与 Intel" src="https://img.shields.io/badge/arch-arm64%20%7C%20x86__64-171513.svg?style=flat-square" />
</p>

DSH Swift Native Shell 是 DSH Desktop 的独立 Swift 原生 macOS 实现。它负责窗口、菜单、设置页、运行时生命周期和桌面系统集成，核心 DSH Web UI 仍由官方 `@deepseek-ai/dsh` 运行时提供。

本项目是一个独立的 Xcode 工程，不依赖 Electron 仓库，也不需要通过 `npm install` 或 `npm ci` 准备应用构建依赖。

> [!IMPORTANT]
> 这是非官方社区项目，当前为预发布版本。macOS 构建使用 ad-hoc 签名，尚未接入 Developer ID 和 notarization。首次打开如遇系统拦截，请右键选择“打开”，或前往“系统设置 → 隐私与安全性”放行。

## 下载

当前 Swift 原生版安装包发布在 [DSH Desktop Releases](https://github.com/krystal-cao/deepseek-harness-desktop/releases/tag/v1.0.0-swift)。

| 平台 | 架构 | 安装包 | 下载 |
| --- | --- | --- | --- |
| macOS | Apple Silicon | DMG | [下载 arm64](https://github.com/krystal-cao/deepseek-harness-desktop/releases/download/v1.0.0-swift/DSH-Desktop-1.0.0-arm64.dmg) |
| macOS | Intel | DMG | [下载 x86_64](https://github.com/krystal-cao/deepseek-harness-desktop/releases/download/v1.0.0-swift/DSH-Desktop-1.0.0-x64.dmg) |

## 界面预览

### 主界面

<p align="center">
  <img alt="DSH Swift 主界面" src="assets/主界面.heic" />
</p>

### 独立设置中心

设置窗口采用接近 macOS 系统设置的布局，支持通用设置、版本管理、插件管理和关于页面。

<h4 align="center">通用设置</h4>
<p align="center">
  <img alt="DSH Swift 通用设置" src="assets/通用设置.heic" />
</p>

<h4 align="center">版本管理</h4>
<p align="center">
  <img alt="DSH Swift 版本管理" src="assets/版本管理.heic" />
</p>

<h4 align="center">插件管理</h4>
<p align="center">
  <img alt="DSH Swift 插件管理" src="assets/插件管理.heic" />
</p>

## 主要特性

- **原生 macOS 窗口体验**：使用 AppKit 管理主窗口、交通灯、Dock 恢复、窗口拖拽、双击标题栏和独立设置窗口。
- **SwiftUI 设置中心**：提供通用、版本、插件和关于页面，界面跟随系统深浅色模式。
- **DSH 运行时管理**：应用包只内置 Node.js 和 pnpm，首次启动时从 npm Registry 下载并安装 DSH 运行时。
- **版本切换与回滚**：支持官方 DSH 版本安装、切换、卸载和自动跟随 npm latest；切换失败时会恢复原版本并尝试恢复服务。
- **插件管理**：支持 web profile 插件的安装、更新、卸载和服务重启，桥接插件随应用内置。
- **桌面通知**：支持 DSH 任务完成通知，并可从通知恢复应用窗口。
- **Sparkle 更新**：Swift 应用包使用 Sparkle 提供检查更新和签名更新；应用版本与 DSH npm 运行时版本彼此独立。
- **分架构构建**：支持 Apple Silicon（arm64）和 Intel（x86_64）单独构建与打包。

## 运行架构

```text
DSH Swift Native Shell
├── AppKit / SwiftUI / WKWebView
│   ├── 主窗口、菜单和 macOS 系统交互
│   └── 设置与关于窗口
│
├── DSH Service
│   ├── 应用内置 Node.js
│   ├── 应用内置 pnpm
│   └── 从 npm 安装的 DSH 运行时
│
├── Desktop Host Bridge
│   └── web profile 桥接插件
│
└── Sparkle
    └── Swift 应用包更新
```

## 构建

### 环境要求

- macOS 13 或更高版本
- 支持 Swift 5.9 的 Xcode
- 构建时可访问 Swift Package Manager、Node.js 和 npm Registry

### 构建应用与 DMG

在仓库根目录执行：

```bash
bash scripts/build-app.sh
bash scripts/package-dmg.sh
```

默认会构建并打包 arm64 与 x86_64 两个架构。只构建一个架构时：

```bash
DSH_BUILD_ARCH=arm64 bash scripts/build-app.sh
DSH_BUILD_ARCH=arm64 bash scripts/package-dmg.sh
```

应用包和 DMG 默认输出到 `dist/`。如需指定输出目录：

```bash
SWIFT_DIST_DIR=/path/to/output bash scripts/build-app.sh
SWIFT_DIST_DIR=/path/to/output bash scripts/package-dmg.sh
```

构建脚本会自动准备对应架构的 Node.js，并下载、校验固定版本的 pnpm CLI。`assets/node/` 和 `assets/bin/pnpm-pkg/` 是构建时生成的缓存，已通过 `.gitignore` 排除，不需要提交。

Xcode 工程是标准构建入口；`Package.swift` 仅作为辅助 Swift Package 清单保留。若要获得完整的资源准备和分架构产物，请使用 `scripts/` 下的脚本。

## 测试

测试只读取源代码和工程配置，不需要安装 npm 依赖：

```bash
npm test
```

## 版本与更新

- Swift 应用版本和构建号独立维护在 [Version.xcconfig](Version.xcconfig) 中。
- Swift 应用版本不等同于 DSH npm 运行时版本；后者在应用内的版本管理页单独安装和切换。
- Sparkle 公钥写入 [Info.plist](Info.plist)，Ed25519 私钥只保存在发布机器的 Keychain 中，禁止提交到仓库。
- 当前更新 feed 位于 `appcast-swift.xml`，发布新版本时需要先构建两个架构的 DMG，再使用 Sparkle `sign_update` 生成签名并更新 feed。

## 已知限制

- 当前使用 ad-hoc 签名，未提供 Developer ID 签名和 notarization。
- 通知点击恢复隐藏主窗口等少数系统交互仍有待完善。
- 应用更新和 DSH npm 运行时更新是两套独立流程。
- 目前仅提供 macOS 13+、Apple Silicon 与 Intel 构建。

## 许可证

本项目采用 [MIT License](LICENSE)。DSH 运行时在首次启动时从 npm Registry 获取，其版权和许可证归对应上游项目所有。

本项目与 DeepSeek 不存在隶属或官方合作关系。DeepSeek Harness 及相关名称的权利归其各自所有者所有。
