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
