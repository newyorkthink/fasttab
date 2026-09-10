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
