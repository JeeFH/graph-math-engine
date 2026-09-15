# Changelog

本包是 CalcEngine 家族的图象引擎（纯逻辑、零 UI 依赖，只依赖 `calcengine-core`）。跨包的家族级变更与完整的缺陷分析见仓库根 [CHANGELOG.md](../CHANGELOG.md)。

## [0.2.0] - 2026-09-05

### Changed（含破坏性变更）

- 包由 `graph` 重命名为 `calcengine-graph`（目录名、包名、模块名同步调整）。
- **不再依赖表达式排版库**。原先依赖 `exprrender`，现依赖收敛为仅 `calcengine-core`；`GraphViewModel` 与 `GraphImageExporter` 移入 `calcengine-graph-ui`。至此两个子引擎可真正独立取用。
- `Index.ets` 新增导出 `ExtractionBudget` / `SegmentCaps` / `SEGMENT_SOFT_CAP` / `SEGMENT_HARD_CAP`（宿主驱动分帧提取时使用）；移出上述两个符号。
- 补 `repository` / `homepage` 发布元数据，以及包内 `LICENSE` 与 `README.md`。

### Fixed

- **`x^(1/3)` 等负底数奇分母有理指数在 `x < 0` 时恒为 NaN**，导致立方根曲线左半平面整片空白。现用连分数在分母 <=1024 内重构 `p ≈ p/q`，`q` 为奇数时返回 `(-1)^p · |a|^b`；`q` 为偶数或无逼近则维持 NaN。仅作用于原本就失败的分支，正常路径零额外开销。
- **`2·3x` 无法解析与渲染**：中间点 `·`（U+00B7）不在词法器白名单内，被静默丢弃，表达式退化后 RPN 求值恒返回 NaN 而 `isValid` 仍为 `true` —— 表现为画布全空且零报错。现由 `ExprNormalizer` 在词法前把乘号族、除号族、全角标点与不可见字符归一为 ASCII 等价形式。
- **`root(n, b)` 无法求值**：求值器的函数节点只弹 1 个操作数，不支持二元函数。现由 `ExprNormalizer` 在词法前改写为一元形式：`n=2 -> sqrt(b)`、`n=3 -> cbrt(b)`、其余 -> `(b)^(1/(1/(n)))` 的等价幂形式。
- **平移结束、快照运镜、点击曲线切焦点时的卡顿**：全网格等值线提取原先挂在 `extractVisible` 的脏标记分支上，而该方法是帧回调 `draw()` 的一部分，等价于在 UI 线程同步跑完整个网格的 AMR 递归。现提取改由 `pumpExtraction` 在帧间推进，`extractVisible` 变为纯查询。
- **段数上限改为按画布像素推导**，取代固定常数 200000。实测振荡函数在 400x400 网格下段数稳定顶到 200000，而 1080px 画布无法分辨该量级；后果是每轮泵入后的 `draw()` 都要重绘全部累积段，且大量线段对象常驻。现由 `SegmentCaps.of(pixelWorldDx, worldWidth)` 推导（16 段/像素，下限 2048）。
- 求值热路径不再抛异常，统一返回 NaN（原先抛异常会触发完整栈追踪构建，在热循环中足以阻塞主线程）。

### Added

- `ExprNormalizer`：词法前置归一化（Unicode 乘除号族、全角标点/数字/字母、不可见字符 + `root(n,b)` 模板改写）。幂等。
- `EngineFunctions`：函数名表与实现的单点定义（原先在三处各有一份且逐处遗漏）。新增 `cbrt`；`powReal` 提供实数域幂语义；`toRational` 提供连分数有理重构。
- `ExtractionBudget`：分帧提取的三重预算（单元格行数 / 探针求值次数 / 墙钟），含 `gesture()` 与 `idle()` 两档。
- `SegmentCaps`：由视口与像素尺度推导的段数软/硬上限。
- 求值器结构校验：相邻两个数值、运算符缺操作数、RPN 栈残留等在解析期判为非法并给出可读原因，取代此前"解析成功但处处 NaN"的静默失败。
- 自适应网格细化（AMR）提取、行分桶空间索引、可见性优先行序、振荡早退，以及 `GridExtendResult`（视口平移后只提取新增条带）。

### Known Issues

- 高频振荡函数（如 `sin(x·y)`）在视口放大到零集无法被网格分辨时，部分真实曲线会被奇点检测误判为极点而跳过，表现为曲线稀疏。误判率的定量数据与被否决的替代方案见仓库根 CHANGELOG。
- 函数词表与 `calcengine-exp` 存在双向不一致（`csc`/`sec`/`cot` 仅排版层支持；`cbrt`/`exp`/`round`/`sign`/`factorial` 仅求值层支持）。

## [0.1.0] - 2026-08-04

### Added

- `ExprClassifier`：表达式四模式分类（显函数/隐函数/不等式/二元方程）
- `FunctionEvaluator` / `BivariateEvaluator`：一元与二元求值器
- `GlobalAnalyzer`：全局分析（零点、极值、渐近线、周期性、对称性、凹凸性、增长阶）
- `GraphAnalyzer`：视口内分析；`SampleEngine` 显函数自适应采样；`GridSampleEngine2D` 网格采样
- `RenderDispatcher` 与四模式渲染器
- `GraphMath` / `GraphTypes`（`GraphFunction` / 调色板 / 线型 / 标签）
