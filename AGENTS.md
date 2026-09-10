# AGENTS.md

本文件是本仓库中所有 AI coding agents（Codex、Claude Code、Copilot、Gemini CLI 等）的仓库级操作规范。

除本文件中的稳定基线和记录要求外，用户在当前任务中的明确要求优先。任何修改都必须以当前 `main`、`README.md`、`CHANGELOG.md`、实际源码和当前 CI 为准，不得根据旧对话、旧分支、旧 Release 或旧 `spec.md` 猜测当前状态。

## 1. 仓库定位

FastTab 是 `LBognanni/fasttab` 的维护分支，主要面向 Linux X11 环境，核心使用 Zig、XCB、XComposite/GLX、Raylib 和 OpenGL。

维护目标：

- 保持窗口切换低延迟、实时预览和稳定输入处理。
- 优先采用通用 X11 / GLX 逻辑，不为单个应用名称堆叠特殊补丁。
- 保持当前 AppImage 与 Latest Release 的简单发布模型。
- 修改必须最小、可审计、可回溯，不以反复提交和 GitHub Actions 失败作为主要试错手段。

`spec.md` 是历史设计与架构参考，不是当前行为的最高事实来源。若它与当前源码、README、CHANGELOG 或 CI 冲突，以当前已经存在并确认的实现为准。

## 2. 当前稳定基线

修改前必须先确认以下基线是否仍成立；如果仓库已经发生后续变化，以 `CHANGELOG.md` 和当前代码为准。

### 窗口切换

- `Alt+Tab`：显示所有已跟踪窗口。
- `Win+Tab`：只显示当前工作区窗口。
- 当前工作区只有一个窗口时，仍保留可视切换界面。
- 方向键以及 `h`、`j`、`k`、`l` 用于网格导航。
- 松开 `Alt` 或 `Super`、按 `Enter`、按 `Esc` 的既有行为不得无故改变。
- 单实例锁和守护进程启动流程属于稳定基线。

### 实时预览

- 所有 X11 客户端共用一套通用 GLX 实时预览路径。
- 不应重新加入 Firefox、Edge、Remmina、root framebuffer 等基于应用名称的专用捕获规则，除非用户明确要求且有可核实的技术原因。
- FastTab 隐藏时释放 XComposite/GLX 绑定，再次显示时重新获取最新 backing pixmap。
- 缓存截图只作为跨工作区或窗口暂时未映射时的兜底，不应取代正常实时预览。

### 应用图标

- 优先使用宿主系统 `.desktop` / icon 解析。
- 宿主图标解析失败后，可以从运行中的 AppImage `APPDIR`、`.desktop`、`StartupWMClass`、`.DirIcon` 或 AppImage 内置图标做通用回退。
- 当前 AppImage 图标回退是泛化机制，不得改成 kitty 或其他单个应用专用判断。

### CLI

当前 CLI 只保留：

```text
fasttab
fasttab daemon
fasttab --daemon
fasttab help
fasttab -h
fasttab --help
```

已经删除：

```text
fasttab version
fasttab -v
fasttab -V
fasttab --version
```

不得因为仓库仍存在 `VERSION` 文件而恢复程序版本显示。`VERSION` 当前只服务于现有打包流程内部的包元数据和中间产物命名。

### GitHub Actions 与 Release

- `.github/workflows/` 当前只保留 `ci.yml`。
- 不得为了一个临时问题新增第二套 workflow、测试 workflow 或重复发布 workflow。
- 正常、必要的构建和测试可以使用现有 CI；本仓库是 Public 仓库，不需要为了节省 Actions 分钟牺牲正确性，但仍要避免无意义重复运行。
- Release 使用固定 `latest` tag。
- Release 标题固定为 `FastTab`。
- Release 正文保持为空，详细说明放在 README / CHANGELOG。
- 对外 Release 只保留一个 x86_64 资产：`fasttab.AppImage`。
- 不得重新发布带版本号文件名、DEB、RPM、SHA256、zsync、ARM64 等资产，除非用户明确要求改变当前发布策略。
- `build_packages.sh` 中仍可能保留历史 native package 构建逻辑；当前 Release 不使用它们。不要因为未发布就顺手删除，也不要擅自重新启用。

### README

- `README.md` 与 `README.zh-CN.md` 当前保持相同内容。
- 修改其中一份时必须同步检查另一份，避免长期不一致。
- 公开说明以中文为主；命令、文件名、协议字段、API 名称、技术专有名词保持原名，不做会破坏含义的翻译。

## 3. 修改前必须完整读取

任何代码、workflow、打包或文档修改开始前，必须先完整理解实际范围。

至少按任务需要读取：

1. `AGENTS.md`。
2. `CHANGELOG.md`。
3. `README.md` 与 `README.zh-CN.md` 中与任务相关的部分。
4. 本次直接修改的完整文件，而不是只看局部片段。
5. 与修改路径直接相关的调用方、依赖方和测试。
6. 涉及 CI / Release 时必须完整读取 `.github/workflows/ci.yml`。
7. 涉及 AppImage 时必须检查 `build_appimage.sh`、`build_packages.sh`、`packaging/` 和当前 Release 合约。
8. 涉及窗口预览、输入、图标、工作区或布局时必须检查对应源码链路，不得只改 UI 表象。

修改前要先确认：

- 当前故障或需求是什么。
- 哪些内容已经确认有效，属于稳定基线。
- 实际需要修改哪些文件。
- 哪些文件不应该碰。
- 是否会影响 CLI、窗口切换、实时预览、图标、CI、AppImage、Release 或 README。

禁止只改一处后再靠多次失败逐步发现其他问题。

## 4. 上游同步规则

上游仓库固定为：

```text
LBognanni/fasttab
```

涉及核心功能、准备同步上游或用户明确要求检查上游时，必须先重新核查上游 `main`，不能依赖上一次结果。

标准处理顺序：

1. 获取上游当前 `main` HEAD。
2. 比较 `LBognanni:main...main` 或等价 Git 历史关系。
3. 确认本仓库相对上游的 `ahead` / `behind` 状态和 merge base。
4. 如果 `behind = 0`，说明没有待同步的上游新提交，不得为了“同步”重新合并旧代码。
5. 如果上游出现新提交，逐个阅读 commit 与 diff，判断是否解决本仓库仍存在的问题或提供明显更好的通用实现。
6. 只移植真正需要且与本地稳定基线兼容的部分；不得直接用上游文件覆盖本地大量定制修改。
7. 与本地现有行为冲突时，默认保留本地已确认基线，除非用户明确要求改回上游行为。
8. 每次上游核查结果必须写入 `CHANGELOG.md`，包括上游 HEAD、对比结果和“采用 / 不采用”的理由。

禁止把“上游更新了”自动等同于“必须合并”。

## 5. 变更记录：每次提交都必须更新

`CHANGELOG.md` 是后续维护者和 AI 判断当前状态的必读文件。

### 强制要求

- **任何实际提交到 `main` 的修改，都必须在同一次任务中同步更新 `CHANGELOG.md`。**
- 代码、workflow、README、打包、Release、CLI、依赖、图标、布局、兼容性、测试和纯文档规则调整都属于需要记录的修改。
- 仅修正 `CHANGELOG.md` 自身的错字、标点或排版时，可以不递归新增一条“修改了变更记录”的记录。
- 记录必须追加，不得覆盖、删除或改写已经确认的历史。
- 如果旧记录后来被证明不完整或状态发生变化，应追加新条目说明，不直接篡改旧结论。

### 每条记录至少包含

- 日期。
- 状态：`完成`、`CI 通过`、`实机确认`、`待实机确认` 或 `未解决`。
- 修改文件。
- 修改原因 / 原始现象。
- 实际修改内容。
- 已知结果与仍存在的限制。
- 已知历史 commit SHA；如果记录的就是当前尚未生成 SHA 的提交，不要为了回填 SHA 再制造第二次提交，以该记录所在 Git commit 为准。
- 涉及上游时记录上游 commit 和采用 / 未采用理由。

### 状态必须真实

- 只有 CI 确实完成成功，才能写“CI 通过”。
- 只有用户真实环境反馈有效，才能写“实机确认”。
- 仅完成代码修改但尚未获得真实 GUI 反馈时，必须写“待实机确认”。
- 问题仍存在时必须明确写“未解决”，不得用模糊措辞让后续 AI 误以为已经修复。
- 用户明确确认某个行为有效后，应把该行为视为新的稳定基线；后续不得无理由回退。

## 6. 修改范围必须最小化

- 只修改完成当前任务所必需的文件。
- 不得顺手重构、批量格式化、重命名、清理或删除无关内容。
- 不得为了“统一风格”改动已经正常工作的 X11/GLX、输入、布局、AppImage 或 CI 逻辑。
- 如果某条已存在命令、脚本、配置或代码路径已经被确认有效，后续修改必须建立在该基线上，不得擅自换成未经验证的等价写法。
- 修复一个应用兼容问题时优先做通用能力增强，不按窗口标题、应用名称或特定用户环境硬编码。
- 任何删除、覆盖、历史重写或 Release 清理都属于高影响操作，必须先明确实际影响并确认范围。

## 7. Zig / X11 / GLX 修改要求

### Zig

- 遵循现有 Zig 风格和 `zig fmt` 结果。
- 保持显式 allocator 传递和现有内存生命周期。
- 使用 `defer` / `errdefer` 保证资源释放。
- 不得静默吞掉本应传播或记录的关键错误。
- 不要为了局部需求引入新的大型依赖。

### X11 / XCB

- 修改 key grab、modifier、workspace、active window、WM_CLASS、desktop property 前必须读取完整调用链。
- 必须考虑 NumLock / CapsLock 等已有 modifier 变体，不得只修单一路径。
- 不得把 `Alt+Tab` 与 `Win+Tab` 的路由语义混在一起。
- 不能因为某个窗口管理器的个别行为就破坏 EWMH / XCB 的通用处理。

### XComposite / GLX

- Pixmap、GLXPixmap、texture binding 和窗口隐藏 / 显示生命周期属于高风险区域。
- 修改绑定和释放顺序前必须确认资源所有权、释放顺序和重新获取路径。
- 不得用 CPU 截图或静态缓存替代当前正常零拷贝 / 实时路径，除非用户明确改变架构目标。
- 应优先修通用 renderer / texture lifecycle，而不是按应用名称分叉实现。

## 8. 图标处理要求

图标解析优先级必须保持清晰：

1. 宿主系统 desktop / icon。
2. 通用 AppImage `APPDIR` 回退。
3. 如果仍无法解析，再根据真实缺失原因设计新的通用回退。

要求：

- 不得写 `if app_name == "kitty"`、`firefox`、`edge` 等应用专用补丁作为默认解决方案。
- 新增图标路径时必须考虑绝对路径、相对路径、desktop `Icon=`、`StartupWMClass` 和 AppImage `.DirIcon` 的实际语义。
- 不得扫描或读取与图标解析无关的用户私有文件。

## 9. AppImage 与打包规则

- 当前对外资产名固定为 `fasttab.AppImage`，README 命令必须与此一致。
- AppImage 内部需要的 desktop、icon、README、LICENSE 必须保持完整。
- `quick-sharun` 是当前 AppImage 构建路线的一部分；没有明确技术原因和用户要求时不要替换整套打包工具。
- `VERSION` 可以继续作为内部包元数据来源，但不得重新进入 CLI / Release 标题 / Release 资产名等用户展示路径。
- 不得把个人 HOME、主机名、用户名、临时构建目录或其他本机私有路径写入最终 AppImage。
- 修改 `AppRun.sh` 注入逻辑时必须保留当前默认进入 `daemon` 的启动行为，除非任务明确要求改变。

## 10. 测试与 CI

本仓库已经存在 Zig 测试和 CI，不适用“禁止测试”的规则。

- 优先复用和更新现有测试，不要为一个小问题无意义复制大量测试文件。
- 代码行为发生变化时，应检查现有测试是否需要同步更新。
- GUI / X11 / GLX 的最终实机效果不能仅靠 CI 代替；CI 成功只能证明构建与现有自动测试通过。
- 不得声称“实机验证通过”，除非确实获得真实 Linux 环境运行结果。
- 不得靠连续 push 多个猜测修复来使用 Actions 试错。

修改 `.github/workflows/ci.yml` 前必须完整检查：

- YAML 结构。
- `permissions`。
- `push` / `pull_request` / `workflow_dispatch` 触发条件。
- Job 依赖关系。
- 构建依赖。
- 路径与文件名。
- Release 权限。
- `latest` tag 更新。
- 最终 Release 只包含 `fasttab.AppImage` 的断言。

## 11. Git 提交要求

- 不创建测试分支。
- 完整检查后直接提交并推送 `main`。
- 一次任务尽量只产生一个有意义提交，不得把同一个问题拆成无意义的多次小提交。
- 提交前必须检查完整 diff，确认没有遗漏、误改或无关文件。
- 如果写入过程中产生了临时或不完整提交，最终交付前必须整理掉，不得把试错历史留在 `main`。
- Commit message 应准确描述最终修改，不写与实际内容不符的泛化标题。
- 不得通过 GitHub Actions 的失败结果来替代提交前静态检查。

## 12. README 与公开文档

本仓库是 Public 仓库。

- 不得把对话中获得的用户个人主机、用户名、HOME 路径、设备型号、网络环境、账号、密钥或其他个人信息写入 README、AGENTS、CHANGELOG、注释或 Release。
- 实机结果使用“真实 Linux 环境”“Linux 实机验证”等中性表述。
- README 中命令必须可直接执行，不写用户机器专属绝对路径。
- 端口、路径、设备名等会因环境变化的示例参数应使用明确占位符，除非它本身就是项目固定值。
- README 只描述当前使用方式；历史修改和已完成事项放入 `CHANGELOG.md`，不要重新把 Release 页面堆成长篇更新说明。

## 13. 当前项目结构

修改前应按任务核对实际目录；以下仅作为当前主结构参考：

```text
fasttab/
├── src/
│   ├── main.zig
│   ├── app.zig
│   ├── x11.zig
│   ├── ui.zig
│   ├── desktop_icon.zig
│   ├── window_scanner.zig
│   ├── thumbnail.zig
│   ├── worker.zig
│   ├── layout.zig
│   ├── navigation.zig
│   ├── shaders/
│   └── tests/
├── packaging/
├── .github/
│   ├── workflows/ci.yml
│   └── scripts/
├── build.zig
├── setup.sh
├── build_appimage.sh
├── build_packages.sh
├── VERSION
├── README.md
├── README.zh-CN.md
├── CHANGELOG.md
├── spec.md
└── LICENSE.md
```

不要把这份目录说明当成不可变事实；文件增删后应同步更新本节和 CHANGELOG。

## 14. 标准任务流程

每次任务按以下顺序执行：

1. 读取 `AGENTS.md`。
2. 读取 `CHANGELOG.md`，确认已经完成和仍待处理的事项。
3. 读取当前 README 与相关完整源码 / workflow。
4. 如涉及核心代码或上游，重新核查 `LBognanni/fasttab`。
5. 明确稳定基线、修改范围和禁止改动内容。
6. 一次性完成所有必要修改。
7. 同步更新 README（如当前行为说明受影响）。
8. 同步追加 `CHANGELOG.md`。
9. 检查完整 diff、语法、路径、参数、资源生命周期和 CI / Release 影响。
10. 直接提交 `main`，避免多次试错提交。
11. 查看必要 CI 结果，不把 CI 成功夸大为 GUI 实机验证。
12. 最终回复只说明最终状态：修改了哪些文件、解决了什么、仍有什么未验证、最终 commit 和 CI 状态。

## 15. 最终交付前检查

完成任务前必须确认：

- 没有擅自改动稳定基线。
- 没有遗漏与代码变更对应的 README / CHANGELOG 更新。
- 没有恢复已删除的版本 CLI 或旧 Release 模型。
- 没有新增多余 workflow。
- 没有把单应用 workaround 写成核心逻辑。
- 没有泄露用户个人环境。
- 没有无关文件变化。
- 完整 diff 与实际需求一致。
- 如果涉及上游，已经记录上游核查结论。
- 对“完成”“CI 通过”“实机确认”的表述均有对应事实依据。
