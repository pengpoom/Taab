# Taab

Taab 是一个基于 AltTab 演进的原生 macOS 窗口工作流工具，目标是把三个高频动作统一起来：

1. 用横向窗口缩略图切换器替代系统纵向/图标式切换体验；
2. 为每一块显示器分别配置左侧、右侧或关闭的窗口侧边栏；
3. 让程序坞图标具备类似 Windows 的“悬停预览、点击唤起、再次点击最小化”行为。

当前已经完成首个可运行 MVP：横向 `Command-Tab`、每屏独立侧边栏，以及 Windows 风格 Dock 悬停预览与点击切换均已接入。产品边界见 [PRODUCT.md](PRODUCT.md)，技术设计见 [ARCHITECTURE.md](ARCHITECTURE.md)，剩余验收见 [TODO.md](TODO.md)。

设置窗口左侧的 `Taab` 页面集中管理程序坞预览、程序坞点击行为，以及每块显示器的侧边栏位置。

当前版本为 `0.0.6`，仍处于早期开发阶段。

## 开发路线

为尽快得到稳定可用的本机版本，Taab 以 AltTab 的成熟窗口切换能力为底座，整合 DockMinimize 的程序坞交互思路，并新增每块显示器独立配置的侧边栏。

## 本地开发

内部工程文件仍为 `Glide.xcodeproj`，使用 Xcode 打开后选择 `Debug` scheme 运行；构建产物为 `Taab.app`。

命令行构建：

```bash
xcodebuild -project Glide.xcodeproj -scheme Debug -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

窗口切换、聚焦和程序坞行为需要“辅助功能”权限；真实窗口缩略图还需要“屏幕与系统音频录制”权限。

## 来源与许可

Taab 以 [AltTab](https://github.com/lwouis/alt-tab-macos) 的 GPL-3.0 代码为底座，并参考了 [DockMinimize](https://github.com/oidd/DockMinimize) 的程序坞交互实现。详细说明见 [Acknowledgments](docs/acknowledgments.md) 与 [Third-party notices](THIRD_PARTY_NOTICES.md)。

本项目使用 [GNU GPL v3](LICENCE.md) 发布。
