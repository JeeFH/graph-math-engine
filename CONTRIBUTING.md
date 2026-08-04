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
- HarmonyOS NEXT SDK
- Node.js 16+

### 本地开发

```bash
# 克隆仓库
git clone https://github.com/your-username/graph-math-engine.git
cd graph-math-engine

# 安装依赖
ohpm install

# 构建所有模块
hvigorw assembleHar

# 运行测试
hvigorw test -p module=mathkit -p coverage=false
hvigorw test -p module=exprrender -p coverage=false
hvigorw test -p module=graph -p coverage=false
```

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
fix(exprrender): 修复分数盒宽度计算错误
docs: 更新 ARCHITECTURE.md 采样算法说明
```

## 测试

### 单元测试

每个模块的测试位于 `src/test/` 目录：

- `mathkit/src/test/LocalUnit.test.ets`：Tokenizer 分词边界
- `exprrender/src/test/LocalUnit.test.ets`：VST 往返幂等、化简规则
- `graph/src/test/LocalUnit.test.ets`：分类、求值、分析

### 运行测试

```bash
# 单模块测试
hvigorw test -p module=mathkit -p coverage=false

# 指定测试用例
hvigorw test -p module=mathkit -p scope=TokenizerTest#scientific_notation
```

## 发布流程

1. 更新 `CHANGELOG.md`
2. 更新各模块 `oh-package.json5` 版本号（语义化版本）
3. 创建 Release PR
4. 合并后打 tag：`git tag v0.x.0`
5. 推送 tag：`git push --tags`

## 许可证

贡献的代码将采用 MIT 许可证发布。

## 问题与支持

- 使用问题：GitHub Discussions
- Bug 报告：GitHub Issues
- 安全漏洞：请私信维护者

感谢你的贡献！
