# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-08-04

### Added

- **mathkit**：数学内核模块
  - `Tokenizer`：表达式词法分析器，支持 Unicode 标识符、隐式乘法、常量识别
  - `ConstantLib`：数学常量库（π、e 等），支持自定义注册
  - `MathLogger`：可替换的日志抽象层

- **exprrender**：表达式渲染引擎
  - `parseLinear`：线性表达式解析器，构建 VST（视觉语法树）
  - `serializeLinear`：VST 序列化为线性字符串
  - `simplify`：表达式化简（合并同类项、约分等）
  - `MathField`：可编辑数学公式组件（VST 编辑器）
  - `ExprRender`：VST → Box 布局树 → Canvas 渲染管线
  - 支持分数、上下标、根号、绝对值等数学排版

- **graph**：图形计算引擎
  - `ExprClassifier`：表达式四模式分类（显函数/隐函数/不等式/二元方程）
  - `FunctionEvaluator`：显函数安全求值器
  - `GlobalAnalyzer`：全局函数分析（零点、极值、渐近线、周期性、对称性、凹凸性）
  - 自适应采样算法（显函数）
  - 网格采样引擎 GridSampleEngine2D（隐函数）

- **graph-ui**：图形 UI 组件库
  - `GraphCanvas`：Canvas 图形渲染组件（支持主题/品牌定制）
  - `GraphDisplayArea`：图形显示区域（含坐标轴、网格、标注）
  - `AnalysisDock`：分析结果停靠面板
  - `GraphShareAdapter` / `GraphStorageAdapter`：可注入的分享/存储适配器
  - `GraphImageExporter`：图形导出工具

- **demo**：演示应用
  - 无键盘布局演示页，支持直接输入表达式查看图形渲染效果

[0.1.0]: https://github.com/graph-math-engine/graph-math-engine/releases/tag/v0.1.0
