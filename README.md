# Graph Math Engine

HarmonyOS NEXT 图形数学引擎 —— 从表达式解析到 Canvas 渲染的全栈开源引擎。

## 特性

- **四模式图形渲染**：显函数 `y=f(x)`、隐函数 `F(x,y)=0`、不等式 `y>x²`、二元方程 `x²+y²=4`
- **完整表达式渲染管线**：字符串 → Token → VST（视觉语法树）→ Box 布局树 → Canvas 像素
- **自适应采样算法**：显函数自适应采样 + 隐函数网格采样（GridSampleEngine2D）
- **全局函数分析**：零点、极值、渐近线、周期性、对称性、凹凸性
- **模块化设计**：4 个 HAR 模块，依赖链清晰（mathkit → exprrender → graph → graph-ui）
- **零 App 耦合**：剥离键盘 UI、分享、持久化、Pro 门控等私有依赖，可独立集成

## 模块结构

```
graph-math-engine/
├── mathkit/          # 数学内核：Tokenizer + ConstantLib + Logger
├── exprrender/       # 表达式渲染引擎：VST → Box → Canvas
├── graph/            # 图形引擎：分类 → 求值 → 采样 → 四模式渲染
├── graph-ui/         # Canvas 组件参考实现：GraphCanvas + 分析坞
└── demo/             # 演示 HAP：单页输入 + 实时绘图
```

**依赖链**：`graph-ui → graph → exprrender → mathkit`

## 安装

### ohpm 依赖（推荐）

在模块的 `oh-package.json5` 中添加：

```json5
{
  "dependencies": {
    "mathkit": "file:./mathkit",
    "exprrender": "file:./exprrender",
    "graph": "file:./graph",
    "graph-ui": "file:./graph-ui"
  }
}
```

### Git 子模块

```bash
git submodule add https://github.com/your-username/graph-math-engine.git
```

## 快速开始（5 分钟）

### 1. 基础表达式渲染

```typescript
import { parseLinear, serializeLinear, MathField } from 'exprrender';

// 解析线性表达式为 VST
const vst = parseLinear('sin(x) + x^2');

// 序列化为字符串
const str = serializeLinear(vst); // 'sin(x)+x^2'

// 使用 MathField 命令式编辑
const field = new MathField();
field.execute('insertVar', 'x');
field.execute('insertOp', '+');
field.execute('insertText', '1');
console.log(field.serialize()); // 'x+1'
```

### 2. 图形渲染

```typescript
import { GraphViewModel, GraphCanvas } from 'graph-ui';
import { ExprClassifier, RenderMode } from 'graph';

// 创建 ViewModel
const vm = new GraphViewModel();

// 添加函数
vm.addFunction('sin(x)');
vm.addFunction('x^2+y^2=4'); // 隐函数（圆）
vm.addFunction('y>x^2');      // 不等式

// 在组件中使用
@Entry
@Component
struct GraphPage {
  private vm: GraphViewModel = new GraphViewModel();
  
  build() {
    Column() {
      GraphCanvas({
        functions: this.vm.functions,
        activeId: this.vm.activeId,
        isDegMode: false,
        isDark: false,
        renderDispatcher: this.vm.getRenderDispatcher()
      })
    }
  }
}
```

### 3. 函数分析

```typescript
import { GlobalAnalyzer } from 'graph';

const result = GlobalAnalyzer.analyzeGlobal('x^2 - 1', false);
if (result) {
  console.log('零点:', result.zeros);        // [{x: -1, y: 0}, {x: 1, y: 0}]
  console.log('极值:', result.extrema);      // [{x: 0, y: -1, kind: 'min'}]
  console.log('对称性:', result.symmetry);   // 'even'
  console.log('周期:', result.period);       // null（非周期）
}
```

## 架构概览

详见 [ARCHITECTURE.md](./ARCHITECTURE.md)

```
字符串 → Tokenizer → VST → ExprRenderer → Box 树 → Canvas 像素
                ↓
         ExprClassifier → FunctionEvaluator → SampleEngine → Renderer
                ↓
         GlobalAnalyzer（零点/极值/渐近线/周期/对称性）
```

## API 参考

详见 [API.md](./API.md)

## 演示工程

`demo/` 模块提供单页演示：
- 简易输入框 + GraphCanvas 实时绘图
- 支持四类表达式：`sin(x)`、`x^2+y^2=4`、`y>x`、`x^2+y^2=x`
- 不含键盘 UI（开源版剥离）

## 测试

```bash
# 运行单元测试（需要 DevEco Studio 环境）
hvigorw test -p module=mathkit -p coverage=false
hvigorw test -p module=exprrender -p coverage=false
hvigorw test -p module=graph -p coverage=false
```

测试覆盖：
- **mathkit**：Tokenizer 分词边界（科学计数法、常量符号、隐式乘法）
- **exprrender**：parseLinear ↔ serializeLinear 往返幂等、simplify 规则、TreeCursor 导航
- **graph**：ExprClassifier 四类分类、FunctionEvaluator 求值精度、GlobalAnalyzer 分析

## 贡献

欢迎贡献！详见 [CONTRIBUTING.md](./CONTRIBUTING.md)

## 许可证

MIT License - 详见 [LICENSE](./LICENSE)

## 相关链接

- [架构图](./ARCHITECTURE.md)
- [API 文档](./API.md)
- [更新日志](./CHANGELOG.md)
- [行为准则](./CODE_OF_CONDUCT.md)
