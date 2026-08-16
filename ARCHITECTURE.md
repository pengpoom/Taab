# Taab 技术架构

## 总体设计

Taab 采用原生 Swift + AppKit。主进程作为菜单栏应用运行，不在程序坞中显示自己的常驻图标；设置界面使用 SwiftUI，窗口面板和低层输入监听使用 AppKit/Core Graphics。

```text
Command-Tab ─┐
Dock 点击 ───┼─> Input Monitors ─> Window Coordinator ─> AX 聚焦/最小化
显示器变化 ─┘          │                  │
                       │                  ├─> 横向 Switcher Panels
                       │                  └─> 每屏 Sidebar Panels
                       └─> 权限与安全降级

CGWindow/AX ─> Window Catalog ─> Window Store ─> Thumbnail Service
```

## 模块

### App

- `GlideApp`：应用生命周期与设置窗口。
- `AppDelegate`：组装服务、启动/停止监听、建立菜单栏入口。
- `AppModel`：向设置界面暴露权限、功能开关和状态。

### Windowing

- `WindowDescriptor`：Taab 内部统一的窗口模型。
- `WindowCatalog`：通过 Core Graphics 枚举候选窗口，再用 PID、标题和边界与 Accessibility 窗口关联。
- `WindowController`：恢复、聚焦和最小化窗口；无法关联时返回明确失败，不猜测操作对象。
- `WindowHistory`：记录最近激活顺序，为 Command-Tab 和程序坞点击提供一致的排序。

### Thumbnails

- `ThumbnailService`：通过 ScreenCaptureKit 获取公开授权的窗口图像。
- 缩略图异步生成并缓存；切换器先出现，图像随后更新。
- 无录屏权限、窗口已消失或捕获失败时使用应用图标占位。

### Switcher

- `CommandTabMonitor`：全局事件监听、快捷键状态机和安全回退。
- `SwitcherController`：在当前鼠标所在显示器创建无激活面板。
- `SwitcherView`：横向卡片、选中动画和滚动定位。

状态机：

```text
idle -> Command-Tab -> visible -> Tab/Shift-Tab -> selecting
visible/selecting -> Command released -> activate selection -> idle
visible/selecting -> Escape -> cancel -> idle
```

### Sidebar

- `DisplayIdentity`：基于 `CGDirectDisplayID` 保存单块显示器设置，并预留硬件标识迁移。
- `SidebarPreferences`：每屏保存 `left / right / off`。
- `SidebarCoordinator`：为每块屏幕维护独立面板，响应屏幕连接和布局变化。
- `SidebarView`：显示该屏窗口，点击后交给 `WindowController`。

### Dock

- `DockClickMonitor`：仅在权限齐全且能确定目标应用时接管点击。
- `DockToggleController`：根据前台应用、当前焦点窗口和最近激活窗口决定恢复、聚焦或最小化。
- 首版不修改 Dock，不注入其他进程；监听关闭或失败时保留系统行为。

## 系统权限

| 权限 | 用途 | 缺失时行为 |
| --- | --- | --- |
| 辅助功能 | 全局按键、Dock 点击识别、窗口聚焦/最小化 | 不启动对应监听，保留系统行为 |
| 屏幕与系统音频录制 | 真实窗口缩略图 | 显示应用图标占位 |

权限只在用户主动点击按钮时请求；启动时只读取状态并说明影响。

## 公开 API 与兼容性边界

- 优先使用 Accessibility、Core Graphics 和 ScreenCaptureKit 的公开能力。
- 窗口模型、捕获和横向切换器沿用 AltTab 的成熟实现；侧边栏和程序坞切换接入同一份窗口状态。
- 若公开 API 无法可靠完成跨桌面空间或特殊窗口操作，将能力标记为受限；是否引入私有 API 单独决策。
- 最低系统版本暂定 macOS 14，发布前根据真实机器验证结果调整。

## 数据与隐私

- 窗口标题、缩略图和使用顺序仅在本机内存或本地设置中处理。
- 不上传窗口内容，不记录键盘文本，不监听与功能无关的按键。
- 日志默认不包含完整窗口标题或缩略图。

## 测试策略

- 单元测试：快捷键状态机、窗口排序、每屏配置、Dock 决策表。
- 集成测试：AX 窗口匹配、显示器热插拔、权限变化。
- 手工矩阵：单屏/双屏、左右排列、最小化、全屏、多个桌面空间、舞台管理。
- 每个低层监听器必须验证停止后事件恢复系统默认。
