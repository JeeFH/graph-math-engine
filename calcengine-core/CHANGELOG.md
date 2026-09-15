# Changelog

本包是 CalcEngine 家族的共享底座。跨包的家族级变更（重命名、依赖关系调整等）见仓库根 [CHANGELOG.md](../CHANGELOG.md)。

## [0.2.0] - 2026-09-05

### Changed

- 包由 `mathkit` 重命名为 `calcengine-core`（目录名、`oh-package.json5` 的 `name`、`module.json5` 的 `name` 同步调整）。模块名去连字符是 HarmonyOS 的约束（`module.json5` 的 `name` 不接受 `-`）。
- 补 `repository` / `homepage` 发布元数据，以及包内 `LICENSE` 与 `README.md`。

### Fixed

- 默认日志实现的前缀由 `[mathkit]` 改为 `[calcengine-core]`。

## [0.1.0] - 2026-08-04

### Added

- `Tokenizer`：表达式词法分词器，支持 Unicode 标识符、隐式乘法、常量识别；含 `tokenizeWithPositions` 与 `getIdentifierAtPosition`。
- `ConstantLib`：数学常量库（π、e 等），支持运行时 `register` 自定义常量。
- `MathLogger` / `setMathLogger` / `getMathLogger`：可替换的日志抽象，默认输出到 `console`。
