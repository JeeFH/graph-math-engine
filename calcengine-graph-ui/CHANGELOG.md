# Changelog

本包是 CalcEngine 图象引擎的 **Canvas 组件参考实现**，未经生产验证，视为实验性模块。跨包的家族级变更见仓库根 [CHANGELOG.md](../CHANGELOG.md)。

## [0.2.0] - 2026-09-05

### Changed

- 包由 `graph-ui` 重命名为 `calcengine-graph-ui`（目录名、包名、模块名同步调整）。
- 新增对 `calcengine-core` 的直接依赖（`GraphViewModel` 使用 `getMathLogger`）。依赖为 `calcengine-graph` + `calcengine-exp` + `calcengine-core`。
- 补 `repository` / `homepage` 发布元数据，以及包内 `LICENSE` 与 `README.md`。

### Added

- `GraphViewModel` 由 `calcengine-graph` 移入本包。它依赖 `calcengine-exp` 的 `MathField` 与序列化能力，属 UI 状态层，不属于纯引擎职责。
- `GraphImageExporter` 由 `calcengine-graph` 移入本包。它属图片后处理（水印合成 + JPEG 打包），同样不属于纯引擎职责。
- `Index.ets` 相应新增上述两个符号的导出。

### Notes

- 本包与宿主应用自有的 UI 层双份并存，二者互不消费。收敛为独立课题，不在本版范围。
- `calcengine-graph` 在本版移出 `GraphViewModel` / `GraphImageExporter` 后不再依赖 `calcengine-exp`，因此仅需图象引擎的使用方可以不引入本包。

## [0.1.0] - 2026-08-04

### Added

- `GraphCanvas`：Canvas 图形渲染组件（支持主题/品牌定制）
- `GraphCanvasController`：命令式控制器（宿主无需持有组件实例即可下发命令）
- `GraphDisplayArea`：图形显示区域（含坐标轴、网格、标注）
- `AnalysisDock`：分析结果停靠面板
- `GraphShareAdapter` / `GraphStorageAdapter` 与 `NoopShareAdapter` / `NoopStorageAdapter`：可注入的分享/存储适配器（未注入时功能自动降级）
- `GraphExportService` / `GraphImageExporter`：图形导出与水印合成
- `ModeTag` / `MODE_STYLES` / `MODE_STYLES_DARK`、`UiMotion`
