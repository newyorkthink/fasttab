# FastTab

<p align="center">
  <img src="packaging/fasttab.svg" alt="FastTab 图标" width="160">
</p>

<p align="center">
  <a href="README.md">English</a> · <strong>简体中文</strong>
</p>

FastTab 是一款面向 X11 的高性能窗口切换器，使用 Zig、Raylib 和 OpenGL 编写，支持 `Alt+Tab` 与 `Win+Tab`。

## FastTab 2.0.7

FastTab 2.0.7 修复窗口预览偶发透明问题，同时保留通用实时预览机制，主要包括：

- X11 客户端提供有效 RGB 但 pixmap Alpha 为 0 或未定义时，仍保留正常画面。
- 在所有应用共用的着色器中修复，不添加 Firefox 专用规则。
- 当工作区栏宽于窗口网格时，按工作区栏的实际测量宽度扩展切换器。
- 当前只有一个窗口时保持卡片居中，并完整显示最后一个工作区标签。
- 恢复浏览器、视频、Remmina 等所有 X11 客户端共用的 GLX 实时预览，不再按应用名称打补丁。
- FastTab 隐藏时释放 XComposite/GLX 绑定，再次显示时重新获取最新的窗口 backing pixmap。
- 缓存截图仅用于跨工作区或窗口暂时未映射时的兜底。
- 保留默认选中当前窗口、i3 工作区总览、工作区角标、鼠标操作和多显示器布局。
- 继续提供 x86_64 与 ARM64/AArch64 的 AppImage、DEB 和 RPM 安装包。

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
- 基于最近使用顺序的选择逻辑，键盘操作优先。
- `Win+Tab` 当前工作区过滤。
- 支持多显示器和较小的虚拟显示器分辨率。
- 单实例保护，重复启动不会终止已有进程。

## 系统要求

- 使用 X11 会话的 Linux 系统。
- 支持硬件加速的 OpenGL。
- x86_64 或 ARM64/AArch64 处理器。

暂不支持原生 Wayland 会话。

## 下载文件

每个正式版本均提供：

| 架构 | AppImage | DEB | RPM |
|---|---|---|---|
| x86_64 / AMD64 | `FastTab-2.0.7-x86_64.AppImage` | `fasttab_2.0.7_amd64.deb` | `fasttab-2.0.7-1.x86_64.rpm` |
| ARM64 / AArch64 | `FastTab-2.0.7-aarch64.AppImage` | `fasttab_2.0.7_arm64.deb` | `fasttab-2.0.7-1.aarch64.rpm` |

发布页面同时提供 SHA-256 校验文件和 AppImage zsync 更新元数据。

### AppImage

```bash
chmod +x FastTab-2.0.7-x86_64.AppImage
./FastTab-2.0.7-x86_64.AppImage
```

ARM64 设备请使用文件名中包含 `aarch64` 的版本。

### Debian / Ubuntu

```bash
sudo apt install ./fasttab_2.0.7_amd64.deb
```

ARM64 设备请安装 `fasttab_2.0.7_arm64.deb`。

### Fedora / RHEL 系列

```bash
sudo dnf install ./fasttab-2.0.7-1.x86_64.rpm
```

ARM64 设备请安装文件名中包含 `aarch64` 的 RPM 包。

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
fasttab version          显示版本
fasttab -v, -V, --version
                         显示版本
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

在当前原生架构上构建全部安装包：

```bash
bash ./build_packages.sh
```

仅构建 AppImage：

```bash
./build_appimage.sh
```

## 安装后的图标结构

DEB 和 RPM 包会安装：

```text
/usr/share/applications/fasttab.desktop
/usr/share/icons/hicolor/16x16/apps/fasttab.png
/usr/share/icons/hicolor/32x32/apps/fasttab.png
/usr/share/icons/hicolor/64x64/apps/fasttab.png
/usr/share/icons/hicolor/128x128/apps/fasttab.png
/usr/share/icons/hicolor/256x256/apps/fasttab.png
/usr/share/icons/hicolor/scalable/apps/fasttab.svg
/usr/share/pixmaps/fasttab.png
/usr/share/doc/fasttab/LICENSE.md
```

## 许可证

FastTab 使用 GNU 通用公共许可证第 3 版（`GPL-3.0-only`）发布，完整条款见 `LICENSE.md`。

## 技术原理

FastTab 以守护进程方式运行，持续跟踪 X11 窗口并维护 GLX 缩略图；切换器界面由 Raylib/OpenGL 渲染。由于不需要在按下快捷键后临时生成截图，窗口切换延迟较低。
