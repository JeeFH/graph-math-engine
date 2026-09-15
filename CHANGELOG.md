# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-09-05

品牌统一为 **CalcEngine**，模块与包名全面重整；同时修复三类渲染缺陷。

### Changed（含破坏性变更）

- **模块与包重命名**（目录名、`oh-package.json5` 的 `name`、`module.json5` 的 `name`）：
  | 原 | 新（目录 / 包名） | 新（模块名） |
  |---|---|---|
  | `mathkit` | `calcengine-core` / `calcengine-core` | `calcenginecore` |
  | `exprrender` | `calcengine-exp` / `calcengine-exp` | `calcengineexp` |
  | `graph` | `calcengine-graph` / `calcengine-graph` | `calcenginegraph` |
  | `graph-ui` | `calcengine-graph-ui` / `calcengine-graph-ui` | `calcenginegraphui` |

  模块名去连字符是 HarmonyOS 的约束（`module.json5` 的 `name` 不接受 `-`），与既有惯例一致（原 `graph-ui` 包对应的模块名即 `graphui`）。

- **`GraphViewModel` 与 `GraphImageExporter` 从 `calcengine-graph` 移至 `calcengine-graph-ui`**。
  前者依赖 `calcengine-exp` 的 `MathField`，后者属图片后处理（水印合成 + JPEG 打包），均不属于纯引擎职责。
- **`calcengine-graph` 不再依赖 `calcengine-exp`**，依赖收敛为仅 `calcengine-core`。至此两个子引擎可真正独立取用：只要表达式渲染不会带入图象引擎，只要图象引擎不会带入排版库。
- `calcengine-graph-ui` 新增对 `calcengine-core` 的直接依赖（`GraphViewModel` 取 `getMathLogger`）。
- `calcengine-graph/Index.ets` 新增导出 `ExtractionBudget`，供宿主驱动分帧提取时选档；移出上述两个符号。
- 各包版本 0.1.0 → 0.2.0；补 `repository` / `homepage` 发布元数据。
- 修正源码首行路径注释（此前 19 个文件指向宿主应用的 `features/graph/src/main/ets/...`，与开源仓实际位置不符）。
- 修正 README 与 CHANGELOG 中指向 `github.com/graph-math-engine/graph-math-engine` 的错误链接，实际远端为 `github.com/JeeFH/graph-math-engine`。

### Fixed

- **`x^(1/3)` 等负底数奇分母有理指数在 `x < 0` 时恒为 NaN**，导致立方根曲线左半平面整片空白。
  原实现以 `a < 0 && b % 1 !== 0` 一刀切，杀掉了奇分母有理指数在负实数域的确定实值。现用连分数在分母 ≤1024 内重构 `p ≈ p/q`，`q` 为奇数时返回 `(-1)^p · |a|^b`；`q` 为偶数或无逼近则维持 NaN。仅作用于原本就失败的分支，正常路径零额外开销。
- **`2·3x` 无法解析与渲染**：中间点 `·`（U+00B7）不在词法器运算符白名单内，落入"忽略非法字符"分支被静默丢弃，表达式退化为 `[2,3,x]`；隐式乘法不在相邻数值间补乘号，RPN 求值后栈残留 2 个元素，`evaluate` 恒返回 NaN 而 `isValid` 仍为 `true` —— 表现为画布全空且零报错。现由 `ExprNormalizer` 在词法前把乘号族（`· ∙ ⋅ • ∗`）、除号族、全角标点与不可见字符归一为 ASCII 等价形式。
- **`root(n, b)` 无法求值**：排版层（`ExprParser`）认识 `root` 并如实序列化，而求值器的 `func` 节点只弹 1 个操作数，不支持二元函数。现由 `ExprNormalizer` 在词法前改写为一元形式：`n=2 → sqrt(b)`、`n=3 → cbrt(b)`、其余 → `(b)^(1/(n))`。
- **平移结束、快照运镜、点击曲线切焦点时的卡顿**：全网格等值线提取原先挂在 `extractVisible` 的脏标记分支上，而 `extractVisible` 由手势回调里的 `draw()` 调用，等价于在 UI 线程上同步跑完整个网格的 AMR 递归。现提取改由 `pumpExtraction` 在帧间推进，`extractVisible` 变为纯查询。
- `FunctionEvaluator` 求值热路径不再抛异常（原先抛 `[GRAPH_DOMAIN]`/`[GRAPH_OVERFLOW]` 会触发完整栈追踪构建），统一返回 NaN，与 `BivariateEvaluator` 既有契约对齐。
- `ExpressionSimplifier` 开启数字因子折叠后，`2·3x` 归一为 `6x`；`VstSerializer` 把 `·` 归一为 `*`，从产出端消除"自身产出下游词法器读不懂的 token"这一整类问题。

### Added

- `calcengine-core`（原 mathkit）：
  - 无新增 API；`MathLogger` / `ConstantLib` / `Tokenizer` 保持不变。
- `calcengine-graph`：
  - `ExprNormalizer`：词法前置归一化（Unicode 乘除号族、全角标点/数字/字母、不可见字符 + `root(n,b)` 模板改写）。幂等。
  - `EngineFunctions`：函数名表与实现的**单点定义**（原先在 `FunctionEvaluator`、`BivariateEvaluator`、`ExprClassifier` 三处各有一份且逐处遗漏）。新增 `cbrt`；`powReal` 提供实数域幂语义；`toRational` 提供连分数有理重构。
  - `ExtractionBudget`：分帧提取的三重预算（单元格行数 / 探针求值次数 / 墙钟），含 `gesture()` 与 `idle()` 两档；配套 `SEGMENT_SOFT_CAP`（降 AMR 深度）与 `SEGMENT_HARD_CAP`（截断）。
  - `IRenderer` 的 `IChunkedGridRenderer` 扩展 `isGridReady` / `hasPendingExtraction` / `pumpExtraction` / `refreshExtraction` / `commitPendingPrecision`。
  - `RenderDispatcher` 新增 `pumpExtractions(budget, vp)` 与 `hasPendingExtraction()`；`onViewportChange` 改为只登记目标精度，避免运镜动画每帧重置提取游标。
  - `GridSampleEngine2D.extendCache` 改为返回 `GridExtendResult`（回报四向新增格数），使视口平移后只提取新增条带。
  - 求值器新增 `validateStructure`：把"相邻两个数值"「RPN 栈残留」等在解析期判为非法并给出可读原因，取代此前"解析成功但处处 NaN"的静默失败。
  - `FunctionEvaluator` 新增预分配求值栈缓冲（零分配热路径）。
  - `ExpressionSimplifier.simplify(root, foldNumericProducts)` 可选参数（默认 `false`，历史调用方行为逐字节不变）。
- `calcengine-exp`：`ExpressionSimplifier.simplify` 新增可选参数；`VstSerializer` 乘号族归一。
- 测试：`calcengine-graph/src/test/EngineFixes.test.ets`（5 组 / 20 例），覆盖归一化、函数表、实数域根、静默失败显式化、以及 `extractVisible` 不触发提取、高频表达式提取有界这两条关键回归。
- 工具：`scripts/check-exports.ps1` —— 静态校验跨包导入的每个符号都在目标包 `Index.ets` 导出面内，且每个被导入的包都已直接声明。

### Known Issues

- **`sin(x·y)` 仍可能长时间阻塞**。已修复的提取路径不再阻塞 UI，但**网格构建期的奇点检测**（`cellHasPole`，每候选格最多 13 次探针求值）成本未纳入任何预算，仅由 `CHUNK_ROWS` 间接控制；对振荡函数"四角变号"的候选格占比极高，成本随格数放大。待诊断后修复（下次补丁版）。
- 函数词表在排版层与求值层**双向不一致**：
  - 排版层认识而求值层不认识：`csc` `sec` `cot`（`root` 已由 `ExprNormalizer` 在求值侧补齐）
  - 求值层认识而排版层不认识：`cbrt` `exp` `round` `sign` `factorial`
  后果：输入 `csc(x)` 会被正常排版但画布空白。治理方向是把函数词表下沉到 `calcengine-core` 单点维护。
- 本仓 `.gitignore` 缺 `**/.test` 条目，自 v0.1.0 起误跟踪了约 80 个构建缓存（`.msgpack` / `.protoBin` / `modules.abc` / `sourceMaps.map` 等）。这些缓存内部仍以旧模块名为键，0.2.0 改名后已失效。计划后续补充忽略规则并取消跟踪。
- `calcengine-graph-ui` 是参考实现，**未经生产验证**，视为实验性模块。

### Notes

- v0.1.0 已发布并公开 `graph-ui`（26 文件）与 `demo`（14 文件），本版按既定决策**保留**二者开源。
- 本次未执行 ohpm 发布；发布需按 `calcengine-core → calcengine-exp → calcengine-graph → calcengine-graph-ui` 顺序，且发布前须用 `scripts/prepare-publish.ps1` 把 `file:` 依赖切为版本区间（`ohpm publish --disallow_nested_package` 会拒绝相对路径嵌套依赖）。
- `calcengine-graph-ui` 与宿主应用自有的 UI 层双份并存，二者不互相消费；收敛不在本版范围。

## [0.1.0] - 2026-08-04

首个公开版本。此处模块名沿用当时的命名，0.2.0 已重命名，对应关系见上。

### Added

- **mathkit**（0.2.0 起为 `calcengine-core`）：数学内核模块
  - `Tokenizer`：表达式词法分析器，支持 Unicode 标识符、隐式乘法、常量识别
  - `ConstantLib`：数学常量库（π、e 等），支持自定义注册
  - `MathLogger`：可替换的日志抽象层

- **exprrender**（0.2.0 起为 `calcengine-exp`）：表达式渲染引擎
  - `parseLinear`：线性表达式解析器，构建 VST（视觉语法树）
  - `serializeLinear`：VST 序列化为线性字符串
  - `simplify`：表达式化简（合并同类项、约分等）
  - `MathField`：可编辑数学公式组件（VST 编辑器）
  - `ExprRender`：VST → Box 布局树 → Canvas 渲染管线
  - 支持分数、上下标、根号、绝对值等数学排版

- **graph**（0.2.0 起为 `calcengine-graph`）：图形计算引擎
  - `ExprClassifier`：表达式四模式分类（显函数/隐函数/不等式/二元方程）
  - `FunctionEvaluator`：显函数安全求值器
  - `GlobalAnalyzer`：全局函数分析（零点、极值、渐近线、周期性、对称性、凹凸性）
  - 自适应采样算法（显函数）
  - 网格采样引擎 GridSampleEngine2D（隐函数）

- **graph-ui**（0.2.0 起为 `calcengine-graph-ui`）：图形 UI 组件库
  - `GraphCanvas`：Canvas 图形渲染组件（支持主题/品牌定制）
  - `GraphDisplayArea`：图形显示区域（含坐标轴、网格、标注）
  - `AnalysisDock`：分析结果停靠面板
  - `GraphShareAdapter` / `GraphStorageAdapter`：可注入的分享/存储适配器
  - `GraphImageExporter`：图形导出工具（0.2.0 起归入 `calcengine-graph-ui`）

- **demo**：演示应用
  - 无键盘布局演示页，支持直接输入表达式查看图形渲染效果

[0.2.0]: https://github.com/JeeFH/graph-math-engine/releases/tag/v0.2.0
[0.1.0]: https://github.com/JeeFH/graph-math-engine/releases/tag/v0.1.0
