# Changelog

本包是 CalcEngine 家族的表达式渲染引擎（零内部依赖）。跨包的家族级变更见仓库根 [CHANGELOG.md](../CHANGELOG.md)。

## [0.2.0] - 2026-09-05

### Changed

- 包由 `exprrender` 重命名为 `calcengine-exp`（目录名、包名、模块名同步调整）。
- 补 `repository` / `homepage` 发布元数据，以及包内 `LICENSE` 与 `README.md`。

### Added

- `simplify(root, foldNumericProducts?)` 新增可选参数。默认 `false` 保持历史行为逐字节不变；传 `true` 时折叠同一乘积项内的数字因子（`2*3*x -> 6x`），并在数字乘积带二进制浮点尾数时（如 `0.1*0.2`）放弃折叠、原样保留。

### Fixed

- `VstSerializer` 把乘号族（`·` `∙` `⋅` `•` `∗`）归一为 `*`，从产出端消除"自身产出下游词法器读不懂的 token"这一整类问题。显示字形由 `ExprRenderer.render` 的 `mulGlyph` 在绘制期决定，故此改动显示中性。

## [0.1.0] - 2026-08-04

### Added

- `parseLinear` / `serializeLinear`：线性表达式解析与序列化（VST 构建）
- `simplify`：表达式化简
- `MathField`：命令式公式编辑器；`ExprView` / `MathFieldView`：ArkUI 组件
- `ExprRenderer` + Box 布局树（`Box` / `measureAndRelayout`）：VST -> Box -> Canvas 排版管线
- `resolveRow` / `resolveBranch` 与 `BRANCH_*` 分支常量：TreeCursor 导航
- TeX 度量常数（`NUM1` `DENOM1` `SUP_DROP` 等）、间距工具、`resolveColor` 主题色解析
