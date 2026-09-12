# 变更记录

本文件用于记录本仓库已经实际发生的修改、当前稳定基线、上游同步状态和仍待验证的问题，供后续维护者与 AI coding agents 在修改前确认“已经改过什么、当前做到哪里、哪些内容不能重复返工”。

记录原则：

- 只记录已经实际发生或已经明确确认的事实，不根据猜测补写历史。
- 每次提交到 `main` 的实际修改都必须在同一次任务中追加记录；仅修正本文件自身错字或排版时可不递归新增记录。
- 已有记录不得为了“整理”而覆盖、删除或改写；后续状态发生变化时应追加新记录。
- 对运行结果使用明确状态：`完成`、`CI 通过`、`实机确认`、`待实机确认`、`未解决`。
- 已知历史提交的 SHA 可以直接记录；当前提交不要为了回填自身 SHA 再制造额外提交，以本条记录所在的 Git 提交为准。
- 如果修改涉及上游代码，必须记录上游仓库、上游 commit、采用/未采用的原因以及与本地稳定基线的关系。

## 当前稳定基线

截至 2026-09-10：

- 项目为 `LBognanni/fasttab` 的维护分支，当前主要面向 X11，核心使用 Zig、XCB、XComposite/GLX、Raylib 和 OpenGL。
- `Alt+Tab` 用于所有已跟踪窗口，`Win+Tab` 用于当前工作区；当前工作区只有一个窗口时仍保留可视切换界面。
- 窗口预览采用所有 X11 客户端共用的实时 GLX 路径，不以 Firefox、Edge、Remmina 等应用名称添加专用捕获规则。
- FastTab 隐藏时释放 XComposite/GLX 绑定，再次显示时重新获取窗口 backing pixmap；缓存截图只作为跨工作区或窗口暂时未映射时的兜底。
- 应用图标先走宿主系统 desktop/icon 解析；失败后可从运行中的 AppImage `APPDIR`、`.desktop`、`StartupWMClass`、`.DirIcon` 或内置图标继续做通用回退，不为单个应用写死规则。
- CLI 只保留默认启动、`daemon` / `--daemon` 与 `help` / `-h` / `--help`；已经删除 `version`、`-v`、`-V`、`--version` 和程序内版本显示。
- `VERSION` 文件仍保留，仅供现有打包流程内部生成包元数据和中间产物名称使用，不作为用户界面或 CLI 版本展示。
- GitHub Actions 只保留 `.github/workflows/ci.yml`。
- GitHub Release 使用固定 `latest` tag，标题为 `FastTab`，正文为空；对外只保留一个 x86_64 资产 `fasttab.AppImage`。
- `README.md` 与 `README.zh-CN.md` 当前保持相同内容，修改时必须同步检查。
- `spec.md` 作为历史设计与架构参考；如果与当前源码、README、CI 或本文件记录冲突，以当前已验证实现为准，不得因为旧规范回退现有行为。

## 上游同步核查

### 2026-09-10 — 核查 `LBognanni/fasttab`

- 状态：完成。
- 上游：`LBognanni/fasttab`，默认分支 `main`。
- 上游当前 HEAD：`e8aceb726c45dbf8d491e4a7eac79ec1cd97e363`。
- 上游最后提交时间：2026-05-16。
- 对比结果：本仓库 `main` 已包含该上游 HEAD；相对上游为 `ahead 126 / behind 0`。
- 结论：当前没有任何上游新提交需要合并或移植，禁止为了“同步上游”重新合并旧代码。
- 后续要求：以后涉及核心窗口逻辑、X11/GLX、输入处理或准备同步上游时，必须重新比较最新上游状态；若上游出现新提交，只逐项审查并选择性移植与本地基线兼容的部分，不直接整体覆盖本地实现。

## 2026-09-10

### 删除无用版本命令

- 状态：完成，CI 通过。
- Commit：`29293a9997a84f568e04529ab951eb0d50f362f1`。
- 修改文件：`src/main.zig`、`.github/workflows/ci.yml`、`README.md`、`README.zh-CN.md`。
- 原因：当前发布策略固定使用 `latest`，程序不再维护面向用户的具体版本显示。
- 修改内容：删除 `FASTTAB_VERSION`、`printVersion()`、`version` 子命令以及 `-v`、`-V`、`--version`；帮助输出同步移除版本号和版本命令；README 与 CI 检查同步更新。
- 结果：`--help` 不再显示 `FastTab 2.0.7`；`--version` 作为未知参数返回退出码 `2`。Actions #199 完整成功。

### 修复 AppImage 应用图标回退

- 状态：完成，CI 通过；具体第三方 AppImage 的最终显示效果仍以真实 Linux 环境反馈为准。
- Commit：`a7b48b6f72bfa69d0202cd7bc424b91239532dc2`。
- 修改文件：`src/desktop_icon.zig`。
- 原因：部分 AppImage 窗口无法仅通过宿主系统 desktop/icon 数据找到应用图标。
- 修改内容：在现有宿主图标解析失败后，增加通用 AppImage 回退：扫描运行进程的 `APPDIR`，匹配 `.desktop` / `StartupWMClass`，优先读取 `.DirIcon`，再读取 AppImage 内置图标。
- 结果：修复逻辑不绑定 kitty 或其他单一应用名称，不改变已有宿主图标查找优先级。

### 精简 Latest 发布内容

- 状态：完成，CI 通过。
- Commit：`85a9a6599b081e09e4a2a6e20a84b4d14440c450`。
- 主要修改文件：`.github/workflows/ci.yml`、`README.md`、`README.zh-CN.md`。
- 原因：对外发布只需要一个稳定 AppImage，不再维护多架构、多包格式和一组带版本号的 Release 资产。
- 修改内容：发布 Job 只构建并上传 x86_64 AppImage；最终资产统一为 `fasttab.AppImage`；Release 使用 `latest` tag；旧 Release、旧版本 tag 和多余资产由发布流程清理；Release 正文保持为空。
- 结果：当前 Latest Release 只包含 `fasttab.AppImage`。

### 统一 Latest 展示并移除固定版本号

- 状态：完成。
- Commit：`be99bc143c97d57d487e6e4bbe8b527a541ce7ae`。
- 主要修改文件：`.github/workflows/ci.yml`、`README.md`、`README.zh-CN.md`。
- 原因：避免 README、Release 标题和命令示例绑定某个具体版本号。
- 修改内容：Release 标题统一为 `FastTab`；README 使用“最新版本”表述；CI 不再要求固定 `2.0.7`。
- 结果：对外展示与后续发布不再依赖固定版本字符串。

### 建立仓库级 AI 维护规范和持续变更记录

- 状态：完成。
- 修改文件：`AGENTS.md`、`CHANGELOG.md`、`README.md`、`README.zh-CN.md`。
- 原因：原 `AGENTS.md` 仍是上游时期的英文开发说明，部分结构与当前仓库已经不一致，也没有强制记录后续修改和上游同步状态。
- 修改内容：按当前仓库实际状态重写中文 `AGENTS.md`；建立本文件作为持续变更记录；README 增加变更记录入口；明确本地稳定基线、上游选择性同步规则、单一 CI/Release 合约和提交前检查要求。
- 结果：后续 AI 修改前必须先读取本文件，任何提交到 `main` 的实际修改都必须同步追加记录。

## 2026-09-11

### 修正自定义窗口类名和 AppImage 图标回退

- 状态：待实机确认。
- 修改文件：`src/desktop_icon.zig`、`src/x11.zig`、`build.zig`、`README.md`、`README.zh-CN.md`、`CHANGELOG.md`。
- 原始现象：kitty 在 FastTab 中仍缺少小图标，而参考 alttab 能显示；此前 `a7b48b6f72bfa69d0202cd7bc424b91239532dc2` 的回退不足以覆盖该反馈。
- 检查结果：原代码只查询 `WM_CLASS` 的实例名，忽略应用类名；AppImage 回退扫描所有进程，并要求桌面文件名或 `StartupWMClass` 匹配后才读取 `.DirIcon`，因此自定义类名或缺少桌面元数据时仍会漏图标。
- 修改内容：宿主解析依次尝试实例名和应用类名；参照 `newyorkthink/linux-packaging` 的 alttab 通用实现，仅从窗口 PID 对应的进程读取 `APPDIR`，直接尝试 `.DirIcon`，并支持根目录相对的绝对符号链接、内嵌 desktop、hicolor 和 pixmaps PNG 回退；desktop 元数据限定读取 `[Desktop Entry]`；同时校验 PID 格式和范围，避免无效整数转换。
- 验证：独立工作目录完成 Zig 测试及 ReleaseSafe 构建；新增测试覆盖双 WM_CLASS、APPDIR 解析、目录边界、desktop action 隔离、无 desktop 的 `.DirIcon`、绝对符号链接、内嵌主题 PNG，以及受控子进程 PID 回退。真实 Linux GUI 中 kitty 的最终显示仍待确认，CI 状态以本提交 Actions 结果为准。
- 限制：保留现有 STB 解码能力，未新增 SVG/XPM 解码；原有浏览器预览已知问题不在本次修复范围内。
- 上游核查：`LBognanni/fasttab` 当前 `main` HEAD 仍为 `e8aceb726c45dbf8d491e4a7eac79ec1cd97e363`；修改前本仓库相对上游为 `ahead 127 / behind 0`，merge base 为该上游 HEAD。没有新提交需要采用，不重复合并，不改变现有窗口切换、实时预览、CLI 和 Release 基线。

### 确认图标修复并调整工作区排序与占位底色

- 状态：kitty 图标修复实机确认；本次排序和占位样式待实机确认。
- 已确认基线：用户确认 `222e945bb63406235247dcf393337dde19614708` 修复了 kitty 图标，本次不再改动图标解析。
- 修改文件：`src/app.zig`、`src/ui.zig`、`src/tests/app_filter_test.zig`、`README.md`、`README.zh-CN.md`、`AGENTS.md`、`CHANGELOG.md`。
- 原因：全局 MRU 排序会拆散同一工作区的窗口；没有预览时的近黑色占位卡片过暗。
- 修改内容：当前工作区优先，其他工作区按与顶部标签一致的 EWMH 索引稳定分组，组内保留 MRU 顺序；跨全部工作区的 sticky 窗口归入优先组，缺少工作区信息的窗口放在最后。打开前刷新工作区信息，后续分组保留当前选中的窗口身份。
- 样式：仅将没有实时预览且没有缓存画面的占位底色改为半透明中灰（RGBA 128/128/128/128），保留图标和标题；不更改有效预览、着色器的 Alpha 修复或 GLX 生命周期，不把真实黑色画面误判为空白。
- 验证：本地排序回归测试覆盖交错工作区、组内顺序、sticky/未知工作区、当前工作区变化和选中窗口保持；执行现有完整测试与 ReleaseSafe 构建，GUI 样式仍待实机确认。
- Actions：按用户要求，今后默认本地检查、提交和推送后结束，不手动触发、重跑或监控 Actions；本次未修改 workflow，不宣称 CI 或 Release 已完成。
- 上游核查：`LBognanni/fasttab` main 仍为 `e8aceb726c45dbf8d491e4a7eac79ec1cd97e363`，本次修改前 `ahead 128 / behind 0`，merge base 为该 HEAD；无新提交需要采用。

### 修复跨工作区后浏览器预览灰屏/黑屏

- 状态：待实机确认。
- 修改文件：`src/app.zig`、`CHANGELOG.md`。
- 原始现象：Chrome、Vivaldi、Firefox 等窗口在一个 i3 工作区中已经显示过正常缩略图后，切换到其他工作区再打开 FastTab，原有预览可能退化为灰色占位或黑色画面。
- 根因：GLX 渐进重获取和截图缓存没有把窗口是否仍为 X11 `VIEWABLE` 作为前置条件，i3 已经 unmap 的跨工作区窗口仍可能被重新绑定并标记为实时预览；无效或黑色 backing pixmap 随后还可能覆盖原有 `cached_snapshot`。跨工作区确认切换时又先激活目标窗口、后执行隐藏阶段批量截图，旧工作区可能已被 i3 unmap 才开始保存最后一帧。
- 修改内容：仅对当前仍 mapped/viewable 的窗口创建或重获取实时 GLX 纹理、处理 damage 和更新 snapshot；已知位于其他工作区的窗口不进入 pending reacquire，并继续使用最后一张有效缓存；不可见窗口禁止覆盖已有缓存。跨工作区激活目标窗口前先缓存当前仍可见窗口，隐藏状态下为活动窗口临时重获取的 GLX 绑定在截图后立即释放，新加入窗口也不再在 FastTab 隐藏期间建立绑定。
- 验证：已完整核对 `src/app.zig`、`src/x11.zig`、`src/ui.zig`、`src/main.zig` 的调用链、XComposite/GLX 资源生命周期和相关测试逻辑，并更新重获取选择测试以覆盖“全局窗口列表中跳过已知其他工作区窗口”。当前连接器会话没有可用的 Zig 本地编译环境，因此不把静态检查描述为本地构建或 GUI 实机验证；真实 Linux/i3 下的浏览器预览效果仍待确认。
- Actions：未修改 workflow；按仓库约定不手动触发、重跑或监控 GitHub Actions。
- 上游核查：`LBognanni/fasttab` main 仍为 `e8aceb726c45dbf8d491e4a7eac79ec1cd97e363`；本次修改前本仓库相对上游为 `ahead 129 / behind 0`，merge base 为该上游 HEAD，无新提交需要采用。

### 修复宿主 desktop ID 与大尺寸图标查找

- 状态：待实机确认。
- 修改文件：`src/desktop_icon.zig`、`CHANGELOG.md`。
- 原始现象：BlueMail 在 FastTab 中没有小图标，而同一环境中的 alttab 可以显示；kitty 图标修复已经实机确认，本次不改动该已验证路径。
- 根因：对照 `newyorkthink/linux-packaging/alttab` 后确认 FastTab 的宿主 desktop 查找仍比 alttab 窄：desktop 文件 ID 使用区分大小写的精确文件名匹配，缺少或不匹配 `StartupWMClass` 时会漏掉仅大小写不同的桌面项；hicolor 尺寸表只到 `512x512`，而 BlueMail 的公开 Linux RPM 安装记录包含 `bluemail.desktop` 和 `hicolor/1024x1024/apps/bluemail.png`；此外宿主 `Icon=` 已带 `.png` 时旧逻辑还会重复追加扩展名。
- 修改内容：宿主 desktop 文件 ID 改为大小写不敏感匹配，同时保留现有 `StartupWMClass` 第二阶段匹配；补齐常见 hicolor 尺寸到 `1024x1024`，优先请求尺寸及更大图标，找不到时再向较小尺寸回退；`Icon=*.png` 保留已有扩展名，不再生成 `.png.png`。现有“窗口实例名 + 应用类名 → 宿主 desktop/icon → 目标 PID 的 AppImage APPDIR → `_NET_WM_ICON`”优先级和 kitty 已验证逻辑不变，不增加 BlueMail 名称硬编码。
- 验证：新增纯函数回归测试覆盖 desktop ID 大小写匹配、已有 PNG 扩展名保留及 `1024x1024` 尺寸表；并重新核对 `src/x11.zig`、`src/worker.zig` 和 `build.zig` 的调用/测试入口。当前连接器会话没有可用的 Zig 本地编译环境，因此仅完成静态检查，不宣称本地测试或 GUI 实机验证通过；BlueMail 最终显示仍待实机确认。
- Actions：未修改 workflow；按仓库约定不手动触发、重跑或监控 GitHub Actions。
- 上游核查：`LBognanni/fasttab` main 仍为 `e8aceb726c45dbf8d491e4a7eac79ec1cd97e363`；本次修改前本仓库相对上游为 `ahead 130 / behind 0`，merge base 为该上游 HEAD，无新提交需要采用。

### 补齐 alttab 的 WM_CLASS 直接图标匹配

- 状态：待实机确认。
- 修改文件：`src/desktop_icon.zig`、`CHANGELOG.md`。
- 原始现象：用户实机确认上一版宿主 desktop ID / 大尺寸图标修复后，BlueMail 在 FastTab 中仍没有小图标，而同一环境中的 alttab 能正常显示；因此上一条 BlueMail 根因判断并不完整。
- 根因：重新逐行对照 `newyorkthink/linux-packaging/alttab/patches/desktop-icons.patch` 后确认，alttab 不只依赖 desktop 文件 ID 和 `StartupWMClass`：它会先把窗口 app / WM_CLASS 转成小写，直接在已扫描的宿主图标文件索引中查找同名图标，再回退到 desktop 元数据映射。FastTab 此前缺少这条“WM_CLASS → 图标文件名”的直接路径，所以即使系统已有同名 hicolor / pixmaps PNG，只要 desktop 关联不命中，仍会漏图标。
- 修改内容：保留现有 desktop 映射优先级，在每个窗口实例名 / 应用类名的 desktop 查找失败或图标加载失败后，新增与 alttab 等价的通用小写名称直接查找，复用现有 XDG hicolor / pixmaps 路径和尺寸策略；同时在精确 desktop ID 与 `StartupWMClass` 之后增加限定分隔符的 qualified desktop ID 尾段匹配，用于包名、vendor、reverse-DNS 或 sandbox 前缀的 desktop ID，不把任何具体应用名称写入运行逻辑。既有 kitty、AppImage `APPDIR` 和 `_NET_WM_ICON` 回退顺序保持不变。
- 验证：新增纯函数回归测试覆盖 WM_CLASS 小写归一化、带 `.desktop` 后缀归一化、qualified desktop ID 的 `_` / `-` / `.` 尾段匹配以及无分隔符误匹配拒绝；并完整复核 `src/desktop_icon.zig`、`src/x11.zig`、`src/worker.zig`、`build.zig` 与 alttab 两份图标补丁的调用链。当前连接器会话没有可用的 Zig 本地编译环境，因此不宣称本地测试、ReleaseSafe 构建或 GUI 实机验证通过；最终效果仍需 Linux/i3 实机确认。
- Actions：未修改 workflow；按仓库约定不手动触发、重跑或监控 GitHub Actions。
- 上游核查：`LBognanni/fasttab` main 仍为 `e8aceb726c45dbf8d491e4a7eac79ec1cd97e363`；本次修改前本仓库相对上游为 `ahead 132 / behind 0`，merge base 为该上游 HEAD，无新提交需要采用。

### 修复 GLX 重获取黑屏并补上延迟图标重试

- 状态：待实机确认。
- 修改文件：`src/app.zig`、`src/worker.zig`、`CHANGELOG.md`。
- 原始现象：用户实机确认此前预览修复仍不完整：同一 i3 工作区中 Edge 等浏览器在 FastTab 隐藏后再次打开仍会出现黑色预览，跨工作区同样可以出现；BlueMail 在 FastTab 中仍缺少小图标，而 alttab 可以显示。
- 根因：① `processReacquireQueue()` 把 GLX reacquire 成功直接当成有效实时画面，但 Chromium 类窗口可能返回可绑定却暂时全黑的 backing pixmap，导致已有正常 `cached_snapshot` 被黑色 live texture 遮住，并可能在后续隐藏时被黑帧覆盖。② 后台 worker 只在窗口首次进入跟踪列表时尝试获取图标；如果应用在首轮扫描时尚未发布 `_NET_WM_ICON` 或可用 desktop/AppImage 元数据，之后该窗口不会再次尝试，因此前面的图标路径补强仍可能无法生效。
- 修改内容：已有 `cached_snapshot` 的窗口在 GLX reacquire 成功后继续显示该缓存，不再仅凭“绑定成功”立即提升为 live；只有后续真实 XDamage 并完成 rebind 后才恢复实时预览；隐藏状态下也不再为了截图重新获取并覆盖已有缓存。没有缓存的首次窗口仍沿用原实时路径。图标 worker 新增通用延迟重试：尚未成功发布图标的已跟踪窗口最多每 1 秒重新走一次现有 desktop / AppImage / `_NET_WM_ICON` 解析，成功后停止，不增加 BlueMail 或其他应用名称硬编码。
- 验证：新增纯逻辑回归测试覆盖“存在缓存时，reacquire 不立即提升为 live”；完整复核 `src/app.zig` 与 `src/worker.zig` 的资源生命周期、缓存所有权、任务所有权和重试节流。当前连接器执行环境没有 Zig 编译器，因此不宣称本地测试、ReleaseSafe 构建或 GUI 实机验证通过；浏览器预览和 BlueMail 图标最终效果仍待 Linux/i3 实机确认。
- Actions：未修改 workflow；按仓库约定不手动触发、重跑或监控 GitHub Actions。
- 上游核查：`LBognanni/fasttab` main 仍为 `e8aceb726c45dbf8d491e4a7eac79ec1cd97e363`，没有新上游提交需要采用。

### 补齐 alttab 的 WM_HINTS 窗口图标回退

- 状态：待实机确认。
- 修改文件：`src/wm_hints_icon.zig`、`src/worker.zig`、`CHANGELOG.md`。
- 原始现象：用户实机确认前面的 desktop ID、hicolor、WM_CLASS 直接匹配和延迟重试后，BlueMail 仍没有小图标，而同机 alttab 可以显示。
- 根因：再次对照 `sagb/alttab` 的实际 `src/win.c` 后确认，上游 alttab 的窗口图标来源并不止 `_NET_WM_ICON` 和文件图标：`addWindowInfo()` 会先尝试 `_NET_WM_ICON`，失败后调用 `addIconFromHints()` 读取 ICCCM `WM_HINTS` 的 `IconPixmapHint` / `IconMaskHint`。FastTab 此前完全缺少这条 X11 原生回退，因此继续扩大 desktop 文件匹配无法覆盖只通过 WM_HINTS 提供图标的客户端。
- 修改内容：新增通用、应用无关的 XCB `WM_HINTS` 图标读取模块；只在现有 desktop/AppImage/`_NET_WM_ICON` 全部失败后读取 `IconPixmapHint`，可选读取 `IconMaskHint` 生成透明度，通过 `xcb-image` 读取 pixmap，并按 root TrueColor visual mask 转换成 FastTab 现有 ARGB 图标格式。worker 继续复用上一版每秒一次的延迟重试，成功后停止；kitty 已实机确认的 desktop/AppImage 路径和既有优先级不变。
- 验证：新增纯逻辑测试覆盖 WM_HINTS flags / pixmap / mask 解析和 TrueColor channel mask 缩放；静态核对 XCB pixmap 尺寸限制、像素数量上限、mask 生命周期及 worker 图标缓存所有权。当前执行环境没有 Zig 编译器，因此不宣称本地测试、ReleaseSafe 构建或 GUI 实机验证通过；BlueMail 最终显示仍待 Linux/i3 实机确认。
- Actions：未修改 workflow；未手动触发、重跑或监控 GitHub Actions。
- 上游核查：`LBognanni/fasttab` main 仍为 `e8aceb726c45dbf8d491e4a7eac79ec1cd97e363`；本次没有上游新提交需要采用。

### 固化已确认基线并补充 RunImage / 容器进程根图标回退

- 状态：kitty、BlueMail、Edge 小图标已由真实 Linux 环境确认正常；Zen Browser 小图标本次修复待实机确认。父提交 `1123b5d0f3b7d71dca85f18e76860737b0c672fc` 的 Actions #214 已成功。
- 修改文件：`src/desktop_icon.zig`、`AGENTS.md`、`README.md`、`README.zh-CN.md`、`CHANGELOG.md`。
- 当前现象：同一个 browser RunImage 中 Edge 已能显示小图标，但 Zen Browser 在 FastTab 中没有小图标；同机 alttab 也没有 Zen Browser 小图标。当前截图中浏览器窗口预览已经可见，因此本次不改 `src/app.zig`、GLX 生命周期、缓存截图、XDamage 或窗口排序逻辑。
- 根因：browser RunImage 把浏览器及其 desktop/icon 安装在容器内；`RIM_SHARE_ICONS=1` 是把宿主图标共享进容器，并不能让宿主 FastTab 的 XDG desktop/icon 扫描自动看到容器内部文件。现有 FastTab 在宿主 desktop/icon、AppImage `APPDIR` 之后直接进入 `_NET_WM_ICON` / `WM_HINTS`，缺少“只读取目标窗口进程自身容器根目录”的通用路径。alttab 同样缺失 Zen 图标，因此本次不再以 alttab 是否显示作为继续修改既有 WM_HINTS 路径的依据。
- 修改内容：保留已经生效的宿主 desktop/icon、AppImage、`_NET_WM_ICON`、`WM_HINTS` 顺序和实现不变，仅在 AppImage 回退失败后新增目标 PID 的 `/proc/<pid>/root` 回退；在该进程根目录中复用现有 desktop 文件 ID、`StartupWMClass`、qualified desktop ID、WM_CLASS 直接图标名、hicolor 尺寸和 pixmaps 规则。容器内绝对图标符号链接按目标进程根目录语义解析，不错误跳回宿主绝对路径。运行逻辑不包含 Zen、Edge、BlueMail、kitty 等应用名称，也不遍历其他进程。
- 基线固化：`AGENTS.md` 明确记录已确认的浏览器黑帧缓存保护，以及 kitty、BlueMail、Edge 图标属于不得无故回退的稳定行为；图标优先级固定为“宿主 desktop/icon → AppImage `APPDIR` → 目标 PID 进程根 desktop/icon → `_NET_WM_ICON` → `WM_HINTS`”。
- 验证：新增纯逻辑文件系统测试，用通用容器应用名构造目标根目录、desktop、hicolor 图标和指向容器 `/opt/...` 的绝对符号链接，覆盖进程根解析的关键路径；同时完整复核 `src/desktop_icon.zig`、`src/x11.zig`、`src/worker.zig` 的调用顺序。当前连接器执行环境没有 Zig 编译器，因此不宣称本次新代码已经本地构建或实机验证通过；未修改 workflow，也不手动触发、重跑或监控 Actions。
- 上游核查：`LBognanni/fasttab` main 仍为 `e8aceb726c45dbf8d491e4a7eac79ec1cd97e363`；父提交相对上游为 `ahead 139 / behind 0`，merge base 为该上游 HEAD，没有新上游提交需要采用。

### 最终状态整理：保留已生效修复，Zen Browser 图标标记未解决

- 状态：文档整理完成；Zen Browser 小图标未解决。
- 修改文件：`README.md`、`README.zh-CN.md`、`CHANGELOG.md`；本次不修改任何源码、workflow、打包脚本或 Release 配置。
- 实机结论：kitty、BlueMail、Microsoft Edge 小图标已经在真实 Linux 环境确认正常；Zen Browser 在当前 browser RunImage 中仍没有小图标，且同机 alttab 也没有该图标。提交 `6d68624cffeb401d8ca6fb584fefd048ae5e5152` 新增的目标 PID `/proc/<pid>/root` 通用回退未解决 Zen Browser 图标，因此该问题明确标记为 `未解决`，不再继续扩大图标解析链路。
- 稳定基线：继续保留宿主 desktop/icon、AppImage `APPDIR`、目标 PID 进程根、`_NET_WM_ICON`、`WM_HINTS` 的现有优先级；不得为了 Zen Browser 重写或删减已经让 kitty、BlueMail、Edge 正常工作的路径。
- 浏览器预览：继续保留已有 `cached_snapshot`、XDamage、viewable/workspace 保护；README 仍把浏览器偶发黑屏列为已知兼容性问题，不把当前缓解逻辑描述成已经彻底解决所有浏览器黑屏。
- 后续处理：除非拿到新的可核实线索，例如 Zen Browser 实际 `WM_CLASS`、desktop 文件内容、容器内图标真实路径或 X11 图标属性，否则不再针对 Zen Browser 做猜测性代码修改。
- 验证：本次仅整理文档，没有代码行为变化，因此不需要新增构建验证；未手动触发、重跑或监控 GitHub Actions。


## 2026-09-12

### 补齐 damage 重获取缓存保护与容器图标目录链接解析

- 状态：待实机确认。
- 修改文件：`src/app.zig`、`src/desktop_icon.zig`、`CHANGELOG.md`。
- 原因：核查 `ded83ef` 发现 damage 处理中的 rebind 失败后，reacquire 成功仍会立即标记 live，绕过已有缓存保护；进程根图标解析仅处理最终文件的符号链接，父目录为绝对符号链接时会错误返回宿主路径，已在独立副本复现。
- 修改内容：失败的 rebind 不再尝试从失效纹理覆盖缓存；重新获取后有缓存则继续显示缓存，后续 damage 成功 rebind 才恢复 live。图标路径逐组件解析目录和文件符号链接，绝对链接从目标进程根开始，相对链接从所在目录开始；在展开链接后处理 `..` 并限制在目标根，循环链接仍有深度上限。
- 验证：本地 84 项测试与 ReleaseSafe 构建通过；新增回归覆盖失败 rebind 的缓存保留、后续恢复、绝对目录链接、相对链接、链接后父目录解析、根边界及循环链接。
- 限制：本次仅修复核查中确认的通用遗漏，不宣称彻底解决浏览器黑屏或 Zen Browser 图标；现有图标优先级、工作区排序及灰色占位保持原样。
- Actions：按用户要求由用户自行执行；提交使用 `[skip ci]` 避免 push 自动触发，不修改 workflow、不监控 Actions。
- 上游核查：`LBognanni/fasttab` main 仍为 `e8aceb726c45dbf8d491e4a7eac79ec1cd97e363`；修改前 `ahead 141 / behind 0`，无新上游提交需要采用。

### 修复共享 WM_CLASS instance 导致的浏览器图标串用

- 状态：待实机确认。
- 修改文件：`src/x11.zig`、`src/worker.zig`、`CHANGELOG.md`。
- 根因：只读检查实际窗口属性发现 Firefox 为 `Navigator / firefox`，Zen 为 `Navigator / zen`；旧缓存仅使用第一段 `Navigator`，导致 Zen 复用 Firefox 已缓存、已发布的图标，跳过自身图标解析。
- 修改内容：通用缓存键同时包含 WM_CLASS instance 与 class，以 NUL 分隔；worker 缓存、发布去重和传递给主线程的图标 ID 使用同一完整身份。现有图标来源优先级、已确认应用图标路径、预览和工作区排序不变，没有运行时应用名称特判。
- 验证：本地 86 项测试与 ReleaseSafe 构建通过；新增回归验证相同 instance 的不同应用图标独立缓存、同一完整身份继续复用。实际 GUI 显示仍待用户确认，不据此宣称所有 Zen 缺图标问题已解决。
- Actions：提交使用 `[skip ci]`，由用户自行执行，不触发或监控。
- 上游核查：`LBognanni/fasttab` main 为 `e8aceb726c45dbf8d491e4a7eac79ec1cd97e363`；修改前 `ahead 142 / behind 0`，无新上游提交需要采用。

### 撤销无效缓存修改并明确将 Zen 小图标留空

- 状态：撤销与文档整理完成；Zen 图标来源识别仍未解决，留空策略待实机确认。
- 修改文件：`src/x11.zig`、`src/worker.zig`、`README.md`、`README.zh-CN.md`、`AGENTS.md`、`CHANGELOG.md`。
- 用户反馈：`032fd5957b85b59a5189964377fc7f8a8737bf2b` 后 Zen 仍显示 Firefox 图标，前条缓存冲突说明不足以解释全部原因，不再宣称该方案有效。
- 修改内容：撤销该提交的复合缓存键、相关测试和注释，恢复此前缓存机制；仅撤销不能保证留空，因此按用户明确要求，对应用类名 `zen` / `zen-browser` 使用空图标 ID，跳过加载、缓存复用和重试，保留标题、预览及窗口切换。新增中文注释说明这是明确的留空策略，不是新的图标识别尝试。
- 保留基线：kitty、BlueMail、Edge 已确认图标路径，以及 `3e62ac8` 的 damage 缓存保护和容器目录链接解析均保留；工作区分组、组内最近使用顺序、半透明灰色占位、CLI 和 Release 规则不变。两份 README 同步整理当前功能和已知问题，AGENTS 记录用户要求的留空例外。
- 验证：本地 86 项测试与 ReleaseSafe 构建通过；完整检查 diff、空 ID 的缓存隔离和停止重试路径，两份 README 内容一致。未运行桌面程序，未安装软件，不宣称 GUI 实机验证通过。
- Actions：使用 `[skip ci]` 提交并推送 main，由用户自行执行，不触发或监控；保留历史提交及历史变更记录。
- 上游核查：`LBognanni/fasttab` main 仍为 `e8aceb726c45dbf8d491e4a7eac79ec1cd97e363`；修改前 `ahead 143 / behind 0`，没有新上游提交需要采用。

### 用户确认浏览器预览修复，移除过时已知问题

- 状态：实机确认（依据用户反馈）；文档整理完成。
- 修改文件：`README.md`、`README.zh-CN.md`、`AGENTS.md`、`CHANGELOG.md`。
- 修改内容：用户确认此前浏览器窗口预览黑屏问题已经修复，两份 README 删除仍将其列为已知问题的旧说明；AGENTS 固化当前缓存与 XDamage 恢复保护，禁止无故改动已验证代码。
- 保留内容：全部源码及注释、Zen 图标留空策略和其他已修复功能保持不变；历史变更记录保留，以本条用户确认更新当前状态。
- 验证：检查完整文档 diff，两份 README 内容一致；仅文档变更，不重复运行编译或测试。提交使用 `[skip ci]`，不触发或监控 Actions。

### 补齐 Zen 已有图标的显示端清除

- 状态：待实机确认；用户确认新版仍显示 Firefox 图标，上一版留空处理不完整。
- 修改文件：`src/app.zig`、`CHANGELOG.md`。
- 核查：当前窗口属性仍为 `Navigator / zen`。代码中留空判断只在 worker 首次发现窗口时执行，后续不会重新检查或清除已经分配的图标；首次扫描时的属性时序尚未实机捕获，不能将其描述为已经复现的唯一原因。
- 修改内容：主线程每次显示前重新检查窗口类名，可见期间最多每秒复查一次；识别到 Zen 时清除已有图标引用并将图标 ID 置空，阻止后续 Navigator 缓存通知重新赋值。同步当前工作区视图的图标 ID；不释放其他窗口仍使用的共享纹理，不修改窗口预览、XDamage、排序或其他应用图标解析。
- 验证：本地 87 项测试与 ReleaseSafe 构建通过；新增回归覆盖已有图标清除、共享键脱离、重复清除及标题和预览状态保留。未安装软件、未替换或重启用户正在运行的程序；实际 GUI 效果仍待确认。
- Actions：使用 `[skip ci]` 提交推送，不触发或监控。
- 上游核查：`LBognanni/fasttab` main 仍为 `e8aceb726c45dbf8d491e4a7eac79ec1cd97e363`，修改前 `ahead 145 / behind 0`，无新上游提交需要采用。

### 固化 Public 仓库自动 Actions 提交规则

- 状态：完成。
- 修改文件：`AGENTS.md`、`CHANGELOG.md`。
- 原因：Public 仓库现有 `ci.yml` 已配置 `push` 到 `main` 自动触发，后续提交不应通过提交信息绕过自动 CI，也不需要 AI 在推送后持续查询运行状态。
- 修改内容：`AGENTS.md` 明确要求所有提交到 `main` 的 commit message 不得包含任何跳过 CI / GitHub Actions 的标记或等价写法；正常 push 后由现有 workflow 自动运行。除非用户明确要求，不手动触发、重跑、查询、轮询、监控或等待 Actions。
- 验证：完整读取当前 `AGENTS.md`、`CHANGELOG.md` 和 `.github/workflows/ci.yml`；确认本次不修改 workflow，不改动源码、README、打包或 Release 逻辑。本次提交信息不包含任何跳过 CI / Actions 的标记，push 后不主动监控自动运行结果。

### 按已验证 AltTab 顺序修复 Zen/Firefox 图标来源与缓存隔离

- 状态：待实机确认。
- 修改文件：`src/window_icon.zig`、`src/x11.zig`、`src/worker.zig`、`src/app.zig`、`README.md`、`README.zh-CN.md`、`AGENTS.md`、`CHANGELOG.md`。
- 新依据：用户确认当前同机 AltTab 已能正确显示 Zen Browser 图标；重新核对 `newyorkthink/linux-packaging` 的 AltTab 稳定补丁与 `sagb/alttab` 源码后，确认其默认 `ISRC_FALLBACK` 顺序为 `_NET_WM_ICON` → `WM_HINTS` → 文件图标。FastTab 此前仍是文件图标优先，并且当前代码还主动将 `zen` / `zen-browser` 图标清空，因此无法复用该已验证行为。
- 根因补充：`032fd5957b85b59a5189964377fc7f8a8737bf2b` 只解决了共享 `WM_CLASS` instance 的缓存冲突，但当时仍先用 `Navigator` 走 desktop/icon 文件映射；该阶段若已经得到 Firefox 图标，完整缓存 key 也只能把“错误来源”隔离缓存，不能纠正图标来源本身。上一轮随后加入的 Zen 强制留空只是规避错误显示，不是图标识别修复。
- 修改内容：恢复并保留完整 `WM_CLASS` instance + class 缓存身份；移除 worker 与主线程的 Zen 专用留空/清除逻辑；新增通用窗口图标入口，默认先读取 `_NET_WM_ICON`，再读取 ICCCM `WM_HINTS`，两者都失败后才进入现有宿主 desktop/icon、AppImage `APPDIR` 和目标进程根文件图标链路。既有 desktop/AppImage/进程根解析实现本身不删除、不改写，预览、XDamage、工作区排序与 CLI 不变。
- 检查：新增纯逻辑回归测试覆盖 `_NET_WM_ICON` 多尺寸选择和截断数据拒绝；完整 diff 只涉及图标路径及同步文档，没有修改 workflow、Release、GLX 预览或窗口切换语义。由于当前连接器执行环境无法下载仓库依赖并运行 Zig，本条不声称本地 `zig build test` / ReleaseSafe 构建已经完成；push 后由现有 Public CI 自动运行，最终 Zen GUI 显示仍需真实 Linux/i3 环境确认。
- 上游核查：`LBognanni/fasttab` main 仍为 `e8aceb726c45dbf8d491e4a7eac79ec1cd97e363`；当前仓库相对上游为 `ahead 147 / behind 0`，没有新的上游提交需要采用。此次图标顺序依据来自用户当前已验证的 `newyorkthink/linux-packaging` AltTab 打包补丁和对应 `sagb/alttab` 图标调用链，不整体合并上游 FastTab。

### 最终核对并固化 Zen/Firefox 图标稳定基线

- 状态：实机确认，CI 通过。
- 修改文件：`README.md`、`README.zh-CN.md`、`AGENTS.md`、`CHANGELOG.md`、`src/wm_hints_icon.zig`、`src/thumbnail.zig`。
- 实机确认：提交 `852866cd4c04308bd2846cd164322d4feba060f9` 后，真实 Linux/i3 环境确认 Zen Browser 与 Firefox 均显示各自正确图标；系统完整重启后再次确认仍正常，没有再出现共享 `Navigator` instance 导致的串图。
- CI / Release：该提交对应 Actions #227 的测试、ReleaseSafe 构建、AppImage 构建和 Latest 发布均成功；Latest 仍只包含 `fasttab.AppImage`。因此 `_NET_WM_ICON` → `WM_HINTS` → 文件图标链路以及完整 `WM_CLASS` instance + class 缓存身份正式固化为稳定基线。
- 最终审计：完整复核当前 `AGENTS.md`、CHANGELOG、两份 README、全部核心 Zig 调用链、现有测试、`build.zig`、`ci.yml`、安装/打包脚本、desktop 元数据、Release 合约及历史 `spec.md` 定位；未发现需要再次修改的运行时代码问题。为避免破坏已实机确认行为，本次不改 X11/GLX、预览、窗口排序、输入、CLI、打包或 workflow 逻辑，只同步最终实机状态并修正两处已经过时的图标来源注释。
- 文档一致性：`README.md` 与 `README.zh-CN.md` 保持相同内容；AGENTS 明确记录 Zen/Firefox 重启后仍正常，并禁止恢复 Zen 专用留空逻辑或无依据改动已确认图标链路。
- 上游核查：`LBognanni/fasttab` `main` HEAD 仍为 `e8aceb726c45dbf8d491e4a7eac79ec1cd97e363`；本次审计前本仓库相对上游为 `ahead 148 / behind 0`，merge base 为上游 HEAD，没有新提交需要采用。
