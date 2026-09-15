# 贡献指南

感谢你对 Graph Math Engine 的关注！我们欢迎各种形式的贡献。

## 行为准则

本项目采用 [Contributor Covenant](./CODE_OF_CONDUCT.md) 行为准则。参与贡献即表示你同意遵守该准则。

## 如何贡献

### 报告 Bug

1. 在 GitHub Issues 中搜索是否已有相关 issue
2. 如果没有，点击 "New Issue" 创建新 issue
3. 使用 Bug 报告模板，填写以下信息：
   - 环境信息（HarmonyOS 版本、DevEco Studio 版本）
   - 复现步骤
   - 期望行为 vs 实际行为
   - 截图或日志（如有）

### 提出新功能

1. 先在 Issues 中讨论该功能的可行性
2. 确认方向后，提交 Feature Request issue
3. 描述使用场景、预期效果、实现思路

### 提交代码

1. Fork 本仓库
2. 创建特性分支：`git checkout -b feature/your-feature-name`
3. 编写代码并添加测试
4. 确保所有测试通过
5. 提交代码：`git commit -m "feat: add your feature"`
6. 推送分支：`git push origin feature/your-feature-name`
7. 创建 Pull Request

### 改进文档

文档同样重要！如果你发现文档有误或不清晰，欢迎提交 PR。

## 开发环境

### 前置要求

- DevEco Studio 6.0+
- HarmonyOS NEXT SDK（本仓 `build-profile.json5` 目标 6.1.0(23)）
- Node.js 16+

### 本地开发

本仓**不含** `hvigorw` / `ohpm` 包装脚本，须使用 DevEco Studio 自带的工具链（或直接用 GUI 的 Sync / Build / Run）：

```powershell
# 先克隆、再安装依赖
#   git clone https://github.com/JeeFH/graph-math-engine.git
#   cd graph-math-engine

# DevEco Studio 默认安装路径；请按实际安装位置调整
$env:DEVECO_SDK_HOME = "D:\Deveco Studio\6.1.1\DevEco Studio\sdk"
$hvigor = "D:\Deveco Studio\6.1.1\DevEco Studio\tools\hvigor\bin\hvigorw.bat"
$ohpm   = "D:\Deveco Studio\6.1.1\DevEco Studio\tools\ohpm\bin\ohpm.bat"

& $ohpm install
& $hvigor --sync

# 构建全部 HAR 产物
& $hvigor assembleHar -p product=default

# 运行测试（-p module= 取模块名，非包名）
& $hvigor test -p module=calcenginecore -p coverage=false
& $hvigor test -p module=calcengineexp -p coverage=false
& $hvigor test -p module=calcenginegraph -p coverage=false
```

`DEVECO_SDK_HOME` 必须指向 `<DevEco 安装目录>\sdk`（`DevEco Studio` 这一层目录不能省略），否则会报 `Invalid value of 'DEVECO_SDK_HOME'`。

> 模块名与包名不同：`module.json5` / `build-profile.json5` 的模块名不含连字符（`calcenginecore`），而 `oh-package.json5` 的包名含连字符（`calcengine-core`）。这是 HarmonyOS 的约束。

## 代码规范

### ArkTS 严格模式

本项目启用 ArkTS 严格模式，请确保：

- 不使用 `any`、`unknown` 类型
- 所有变量显式声明类型
- 不使用隐式类型转换

### 注释规范

- 公共 API 使用 JSDoc 注释（中文为主）
- 文件头部包含 MIT License 注释
- 复杂算法添加行内注释说明

### 提交信息格式

遵循 [Conventional Commits](https://www.conventionalcommits.org/)：

```
feat: 新功能
fix: 修复 Bug
docs: 文档更新
style: 代码格式（不影响逻辑）
refactor: 重构（非新功能、非修复）
test: 添加测试
chore: 构建/工具变更
```

示例：

```
feat(graph): 添加斜渐近线检测
fix(calcengine-exp): 修复分数盒宽度计算错误
docs: 更新 ARCHITECTURE.md 采样算法说明
```

## 测试

### 单元测试

每个模块的测试位于 `src/test/` 目录：

- `calcengine-core/src/test/LocalUnit.test.ets`：Tokenizer 分词边界
- `calcengine-exp/src/test/LocalUnit.test.ets`：VST 往返幂等、化简规则
- `calcengine-graph/src/test/LocalUnit.test.ets`：分类、求值、分析
- `calcengine-graph/src/test/EngineFixes.test.ets`：表达式归一化、实数域根、静默失败显式化、分帧提取的预算回归

### 运行测试

```powershell
# 单模块测试
& $hvigor test -p module=calcenginecore -p coverage=false

# 指定测试用例
& $hvigor test -p module=calcenginecore -p scope=TokenizerTest#scientific_notation
```

### 提交前自检

```powershell
# 校验跨包导入的符号均在目标包 Index.ets 导出面内、且依赖已直接声明
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check-exports.ps1
```

## 发布流程

1. 更新 `CHANGELOG.md`
2. 更新各模块 `oh-package.json5` 版本号（语义化版本）
3. 用 `scripts/prepare-publish.ps1` 把 `file:` 依赖切为版本区间并构建 HAR
4. 按依赖顺序发布到 ohpm：`calcengine-core` → `calcengine-exp` → `calcengine-graph` → `calcengine-graph-ui`
5. 创建 Release PR
6. 合并后打 tag：`git tag v0.x.0`
7. 推送 tag：`git push --tags`

> `ohpm publish` 会拒绝相对路径嵌套依赖（`--disallow_nested_package`），因此**开发态的 `file:` 依赖不能直接发布**，必须先切换为 `^版本` 形式。

## 许可证

贡献的代码将采用 MIT 许可证发布。

## 问题与支持

- 使用问题：GitHub Discussions
- Bug 报告：GitHub Issues
- 安全漏洞：请私信维护者

感谢你的贡献！
