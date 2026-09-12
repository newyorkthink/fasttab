# FastTab

<p align="center">
  <img src="packaging/fasttab.svg" alt="FastTab 图标" width="160">
</p>

FastTab 是一款面向 X11 的高性能窗口切换器，使用 Zig、Raylib 和 OpenGL 编写，支持 `Alt+Tab` 与 `Win+Tab`。

项目维护状态、已完成修改和上游同步记录见 [CHANGELOG.md](CHANGELOG.md)。

## 最新版本

当前保留的修复与功能如下：

- X11 客户端提供有效 RGB 但 pixmap Alpha 为 0 或未定义时，仍保留正常画面。
- 在所有应用共用的着色器中修复，不添加 Firefox 专用规则。
- 当工作区栏宽于窗口网格时，按工作区栏的实际测量宽度扩展切换器。
- 当前只有一个窗口时保持卡片居中，并完整显示最后一个工作区标签。
- 恢复浏览器、视频、Remmina 等所有 X11 客户端共用的 GLX 实时预览，不再按应用名称打补丁。
- FastTab 隐藏时释放 XComposite/GLX 绑定，再次显示时重新获取最新的窗口 backing pixmap。
- 缓存截图仅用于跨工作区或窗口暂时未映射时的兜底；已有缓存时，重新绑定成功且收到有效 XDamage 更新后才恢复实时画面。
- 应用图标默认按 `_NET_WM_ICON` → `WM_HINTS` → desktop/AppImage/目标进程根文件图标的顺序回退，并使用完整 `WM_CLASS` instance + class 作为缓存身份，避免共享 `Navigator` instance 的不同浏览器串用图标。
- kitty、BlueMail、Microsoft Edge 小图标已实机确认正常，保留现有解析和回退路径。
- 当前工作区优先，其余按顶部标签顺序分组，组内保留最近使用顺序；无有效预览时使用半透明灰色占位。
- 保留默认选中当前窗口、i3 工作区总览、工作区角标、鼠标操作和多显示器布局。
- Release 仅保留一个 x86_64 AppImage 文件：`fasttab.AppImage`。

## 快捷键

- `Alt+Tab`：显示所有已跟踪窗口。
- `Win+Tab`：仅显示当前工作区窗口；当前工作区只有一个窗口时也会正常显示。
- `Shift+Tab` 或 `Win+Shift+Tab`：反向选择。
- 方向键或 `h`、`j`、`k`、`l`：在窗口网格中移动。
- 鼠标单击：激活窗口。
- `Enter`：确认切换。
- `Esc`：取消切换。
- 松开 `Alt` 或 `Super`：确认当前选择。

启动 FastTab 前，需要关闭桌面环境中占用 `Alt+Tab` 或 `Super+Tab` 的原有快捷键。

## 功能

- 常驻后台的轻量守护进程，触发后立即显示。
- 基于 X11/GLX 的实时 GPU 窗口缩略图。
- 显示窗口标题、应用图标、工作区名称和工作区标记。
- 图标优先读取窗口自身 `_NET_WM_ICON`，其次读取 ICCCM `WM_HINTS`；两者都没有可用图标时，再按窗口实例名和应用类名查找宿主 desktop/icon、运行中 AppImage 内嵌图标及目标进程根目录中的容器/RunImage desktop/icon。
- 当前工作区窗口优先，其余窗口按顶部工作区标签顺序分组；同一工作区内保留最近使用顺序。
- 没有实时预览和缓存画面时，显示半透明灰色占位卡片及应用图标。
- `Win+Tab` 当前工作区过滤。
- 支持多显示器和较小的虚拟显示器分辨率。
- 单实例保护，重复启动不会终止已有进程。

## 系统要求

- 使用 X11 会话的 Linux 系统。
- 支持硬件加速的 OpenGL。
- x86_64 处理器。

暂不支持原生 Wayland 会话。

## 下载与运行

Release 仅提供一个文件：

```text
fasttab.AppImage
```

在 Linux 终端执行：

```bash
chmod +x fasttab.AppImage
./fasttab.AppImage
```

## 启动 FastTab

```bash
fasttab daemon
```

在 i3 配置中加入：

```text
exec --no-startup-id fasttab daemon
```

FastTab 使用按用户隔离的单实例锁。重复启动时只会报告错误，不会关闭正在运行的守护进程。

## 命令行参数

```text
fasttab                  启动守护进程（默认）
fasttab daemon           明确启动守护进程
fasttab --daemon         明确启动守护进程
fasttab help             显示帮助
fasttab -h, --help       显示帮助
```

未知参数返回退出码 `2`，错误信息输出到标准错误。

## 从源码构建

需要 Zig 0.14.0 或更高版本、C 编译工具链、`make`、`curl`、`tar`，以及 CI 工作流中列出的 X11/OpenGL 开发库。

```bash
git clone https://github.com/newyorkthink/fasttab.git
cd fasttab
./setup.sh
zig build test
zig build -Doptimize=ReleaseSafe -Dcpu=baseline
```

生成的程序位于 `zig-out/bin/fasttab`。

仅构建 AppImage：

```bash
./build_appimage.sh
```

## 许可证

FastTab 使用 GNU 通用公共许可证第 3 版（`GPL-3.0-only`）发布，完整条款见 `LICENSE.md`。

## 技术原理

FastTab 以守护进程方式运行，持续跟踪 X11 窗口并维护 GLX 缩略图；切换器界面由 Raylib/OpenGL 渲染。由于不需要在按下快捷键后临时生成截图，窗口切换延迟较低。
