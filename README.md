# CalcEngine

HarmonyOS NEXT 数学渲染引擎家族 —— 从表达式解析到 Canvas 渲染的全栈开源引擎。

本仓（`graph-math-engine`）是 CalcEngine 的源码仓库，包含两个子引擎与其共享底座：

- **表达式渲染引擎**（`calcengine-exp`）：字符串 → VST（视觉语法树）→ Box 布局树 → Canvas 像素
- **图象引擎**（`calcengine-graph`）：表达式分类 → 求值 → 采样 → 四模式渲染 → 全局分析

## 特性

- **四模式图形渲染**：显函数 `y=f(x)`、隐函数 `F(x,y)=0`、不等式 `y>x²`、二元方程 `x²+y²=4`
- **完整表达式渲染管线**：字符串 → Token → VST（视觉语法树）→ Box 布局树 → Canvas 像素
- **自适应采样算法**：显函数自适应采样 + 隐函数网格采样（GridSampleEngine2D）+ AMR 自适应网格细化
- **分帧可中断提取**：等值线提取受行数/求值次数/墙钟三重预算约束，高频振荡函数（如 `sin(x·y)`）不会阻塞 UI
- **全局函数分析**：零点、极值、渐近线、周期性、对称性、凹凸性
- **模块化设计**：4 个 HAR 模块，依赖链清晰（`calcengine-core → calcengine-exp → calcengine-graph → calcengine-graph-ui`）
- **零 App 耦合**：剥离键盘 UI、分享、持久化、Pro 门控等私有依赖，可独立集成

## 模块结构

```
graph-math-engine/
├── calcengine-core/       # 共享底座：Tokenizer + ConstantLib + Logger
├── calcengine-exp/        # 表达式渲染引擎：VST → Box → Canvas（零内部依赖）
├── calcengine-graph/      # 图象引擎：分类 → 求值 → 采样 → 四模式渲染（纯逻辑，零 UI）
├── calcengine-graph-ui/   # Canvas 组件参考实现：GraphCanvas + 分析坞 + GraphViewModel
└── demo/                  # 演示 HAP：单页输入 + 实时绘图
```

**依赖链**：`calcengine-graph-ui → calcengine-graph → calcengine-core`、`calcengine-graph-ui → calcengine-exp`

两个子引擎可独立取用：`calcengine-exp` 零内部依赖；`calcengine-graph` 只依赖 `calcengine-core`，**不会**把表达式排版库一起带来。

`calcengine-graph-ui` 是参考实现，**未经生产验证**（本仓作者的应用使用自己的 UI 层，与本模块无关）。它可作为集成样例，能力出口（分享 / 缩略图持久化）通过适配器接口注入，见 `support/GraphAdapters.ets`。

## 安装

### ohpm 依赖（推荐）

按需声明，不必全部引入：

```json5
{
  "dependencies": {
    // 只要表达式渲染
    "calcengine-exp": "^0.2.0",
    // 只要图象引擎（自动带入 calcengine-core）
    "calcengine-graph": "^0.2.0",
    // 想要开箱即用的 Canvas 参考实现（自动带入上面全部）
    "calcengine-graph-ui": "^0.2.0"
  }
}
```

### 本地开发（file: 依赖）

在本仓内联动调试时，用相对路径直连各模块，改动即时生效：

```json5
{
  "dependencies": {
    "calcengine-core": "file:./calcengine-core",
    "calcengine-exp": "file:./calcengine-exp",
    "calcengine-graph": "file:./calcengine-graph",
    "calcengine-graph-ui": "file:./calcengine-graph-ui"
  }
}
```

注意：`ohpm publish` 的 `--disallow_nested_package` 会拒绝相对路径嵌套依赖，**发布前必须切换为版本区间**。见 `scripts/prepare-publish.ps1`。

### Git 子模块

```bash
git submodule add https://github.com/JeeFH/graph-math-engine.git
```

## 快速开始（5 分钟）

### 1. 基础表达式渲染

```typescript
import { parseLinear, serializeLinear, MathField } from 'calcengine-exp';

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
import { GraphViewModel, GraphCanvas } from 'calcengine-graph-ui';
import { ExprClassifier, RenderMode } from 'calcengine-graph';

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

若已有自己的 UI 层，只依赖 `calcengine-graph` 即可。渲染回调通过 `RenderDispatcher.extractAll()` 拿到世界坐标的线段/多边形，`extractVisible` 是纯查询、不做求值；提取由宿主用 `RenderDispatcher.pumpExtractions(budget, vp)` 在帧间推进，预算用 `ExtractionBudget.gesture()` / `ExtractionBudget.idle()` 选档。

### 3. 函数分析

```typescript
import { GlobalAnalyzer } from 'calcengine-graph';

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

## 构建与测试

本仓**不含** `hvigorw` 包装脚本，请使用 DevEco Studio 自带的 hvigor（或直接用 DevEco GUI 的 Build / Run）：

```powershell
# DevEco Studio 6.1.1 默认安装路径；请按实际安装位置调整
$env:DEVECO_SDK_HOME = "D:\Deveco Studio\6.1.1\DevEco Studio\sdk"
$hvigor = "D:\Deveco Studio\6.1.1\DevEco Studio\tools\hvigor\bin\hvigorw.bat"
$ohpm   = "D:\Deveco Studio\6.1.1\DevEco Studio\tools\ohpm\bin\ohpm.bat"

cd graph-math-engine
& $ohpm install
& $hvigor --sync
```

`DEVECO_SDK_HOME` 必须指向 `<DevEco 安装目录>\sdk`（注意 `DevEco Studio` 这一层目录不能少），否则会报 `Invalid value of 'DEVECO_SDK_HOME'`。

运行单元测试与构建 HAR（`-p module=` 取模块名，非包名）：

```powershell
& $hvigor test -p module=calcenginecore -p coverage=false
& $hvigor test -p module=calcengineexp -p coverage=false
& $hvigor test -p module=calcenginegraph -p coverage=false

& $hvigor assembleHar -p product=default
```

测试覆盖：
- **calcengine-core**：Tokenizer 分词边界（科学计数法、常量符号、隐式乘法）
- **calcengine-exp**：parseLinear ↔ serializeLinear 往返幂等、simplify 规则、TreeCursor 导航
- **calcengine-graph**：ExprClassifier 四类分类、FunctionEvaluator 求值精度、GlobalAnalyzer 分析、表达式归一化与预算化提取的回归用例（`src/test/EngineFixes.test.ets`）

另有 `scripts/check-exports.ps1`，静态校验跨包导入的每个符号都在目标包 `Index.ets` 的导出面内，且每个被导入的包都在 `oh-package.json5` 中直接声明：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check-exports.ps1
```

## 贡献

欢迎贡献！详见 [CONTRIBUTING.md](./CONTRIBUTING.md)

## 许可证

MIT License - 详见 [LICENSE](./LICENSE)

## 相关链接

- [架构图](./ARCHITECTURE.md)
- [API 文档](./API.md)
- [更新日志](./CHANGELOG.md)
- [行为准则](./CODE_OF_CONDUCT.md)
