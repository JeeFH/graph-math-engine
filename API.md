# API 参考

> 模块短名：`core` = `calcengine-core`，`exp` = `calcengine-exp`，
> `graph` = `calcengine-graph`，`graph-ui` = `calcengine-graph-ui`。

## calcengine-core

共享底座：表达式分词 + 常数库 + 日志抽象。零内部依赖。

### Tokenizer

```typescript
import { Tokenizer } from 'calcengine-core';

// 分词
const tokens: string[] = Tokenizer.tokenize('sin(x) + 2π');
// ['sin', '(', 'x', ')', '+', '2', 'π']

// 带位置信息的分词
const positions: TokenPosition[] = Tokenizer.tokenizeWithPositions('x+1');
// [{token: 'x', start: 0}, {token: '+', start: 1}, {token: '1', start: 2}]

// 获取光标位置的标识符
const hit: IdentifierPosition | null = Tokenizer.getIdentifierAtPosition('sin(x)', 1);
// {identifier: 'sin', start: 0, end: 3}
```

注意：`Tokenizer` 只产出扁平 `string[]`，不建语法树。需要二维结构（分数、n 次根指数、上下标）时请用 `calcengine-exp` 的 `parseLinear`，它自带递归下降解析器。

### ConstantLib

```typescript
import { ConstantLib } from 'calcengine-core';

// 查询常量值
const pi: number = ConstantLib.lookup('π'); // 3.14159...

// 注册自定义常量
ConstantLib.register('α', 0.5);
```

### MathLogger

```typescript
import { setMathLogger, getMathLogger } from 'calcengine-core';

// 自定义日志实现
setMathLogger({
  info: (msg: string) => console.log('[INFO]', msg),
  warn: (msg: string) => console.warn('[WARN]', msg),
  error: (msg: string) => console.error('[ERROR]', msg)
});
```

---

## calcengine-exp

表达式渲染引擎：VST（视觉语法树）→ Box 布局树 → Canvas 像素。零内部依赖。

### 解析与序列化

```typescript
import { parseLinear, serializeLinear } from 'calcengine-exp';

// 字符串 → VST
const vst: VstRow = parseLinear('x^2 + sin(x)');

// VST → 字符串
const str: string = serializeLinear(vst); // 'x^2+sin(x)'
```

`parseLinear` 认识 `root`（n 次根）与 `csc` / `sec` / `cot`，而 `calcengine-graph` 的求值器函数表目前不含后三者。已知的跨层词表差异见 CHANGELOG 的 Known Issues。

### VST 节点类型

```typescript
import {
  VstRow, VstNum, VstVar, VstConst, VstOp,
  VstFrac, VstPow, VstSqrt, VstRoot, VstParen,
  VstFunc, VstCeil, VstFloor, VstNeg, VstLog
} from 'calcengine-exp';

// 分数节点
const frac = new VstFrac();
frac.num = [new VstNum(1)];
frac.den = [new VstNum(2)];

// 幂节点
const pow = new VstPow();
pow.base = [new VstVar('x')];
pow.exp = [new VstNum(2)];
```

### TreeCursor 导航

```typescript
import { resolveRow, resolveBranch, BRANCH_NUM, BRANCH_DEN } from 'calcengine-exp';

// 导航到分数的分子
const numNodes: VstNode[] | undefined = resolveBranch(fracNode, BRANCH_NUM);

// 通过路径导航
const nodes: VstNode[] = resolveRow(root, [0, BRANCH_NUM]);
```

### MathField 命令式编辑

```typescript
import { MathField } from 'calcengine-exp';

const field = new MathField();

// 插入变量
field.execute('insertVar', 'x');

// 插入运算符
field.execute('insertOp', '+');

// 插入文本（自动解析）
field.execute('insertText', '1');

// 序列化
const expr: string = field.serialize(); // 'x+1'

// 删除
field.execute('backspace');
```

### 化简

```typescript
import { simplify, parseLinear, serializeLinear } from 'calcengine-exp';

const vst = parseLinear('x*x');
const simplified = simplify(vst);
serializeLinear(simplified); // 'x^2'
```

`simplify` 第二个参数 `foldNumericProducts` 默认 `false`，保持历史行为逐字节不变。传 `true` 时折叠同一乘积项内的数字因子（`2·3x → 6x`），并在数字乘积带二进制浮点尾数时（如 `0.1·0.2`）放弃折叠、原样保留。

```typescript
simplify(parseLinear('2*3*x'), true); // → 6x
```

---

## calcengine-graph

图象引擎：分类 → 求值 → 采样 → 四模式渲染 → 全局分析。只依赖 `calcengine-core`。

### ExprClassifier

```typescript
import { ExprClassifier, RenderMode } from 'calcengine-graph';
import type { ClassifyResult } from 'calcengine-graph';

const result: ClassifyResult = ExprClassifier.classify('y=x^2');
// {
//   mode: RenderMode.EXPLICIT,
//   rawExpr: 'y=x^2',
//   normalizedExpr: 'x^2',
//   hasX: true,
//   hasY: false
// }

// 四种模式
RenderMode.EXPLICIT;     // 0: 显函数 y=f(x)
RenderMode.IMPLICIT;     // 1: 隐函数 F(x,y)=0
RenderMode.INEQUALITY;   // 2: 不等式
RenderMode.BIVARIATE_EQ; // 3: 二元方程
```

`classify` 入口会先做词法归一化，对调用方透明：Unicode 乘号族（`· ∙ ⋅ • ∗`）、除号族、全角标点与数字、不可见字符全部归一为 ASCII 等价形式；`root(n,b)` 改写为一元形式（`n=2 → sqrt(b)`、`n=3 → cbrt(b)`、其余 → `(b)^(1/(n))`）。因此 `normalizedExpr` 总是求值器可直接消费的形式。

### FunctionEvaluator

```typescript
import { FunctionEvaluator } from 'calcengine-graph';

// 弧度模式（默认）
const ev = new FunctionEvaluator('sin(x)');
const y: number = ev.evaluate(Math.PI / 2); // ≈ 1

// 角度模式
const evDeg = new FunctionEvaluator('sin(x)', true);
const yDeg: number = evDeg.evaluate(90); // ≈ 1
```

**求值契约**：`evaluate` 是采样热路径，**绝不抛异常**。所有运行时错误（域错误、除零、溢出、RPN 栈异常）一律返回 `NaN`。

```typescript
ev.isValid;  // boolean：解析是否成功
ev.error;    // string | null：解析失败原因（可读文本）
```

解析期即显式失败的情形包括相邻两个数值、运算符缺少操作数、RPN 栈残留等——不再出现"解析成功但处处 NaN"的静默失败。

支持的函数见下表的"求值层"列。注意与排版层（`calcengine-exp`）的词表差异：

| | 函数 |
|---|---|
| 仅求值层支持 | `cbrt` `exp` `round` `sign` `factorial` |
| 仅排版层支持 | `csc` `sec` `cot`（`root` 已由归一化在求值侧补齐） |
| 两层均支持 | `sin` `cos` `tan` `asin` `acos` `atan` `sinh` `cosh` `tanh` `ln` `log` `log2` `log10` `sqrt` `abs` `floor` `ceil` |

**实数域幂语义**：负底数配奇分母有理指数返回实根，例如 `(-8)^(1/3) = -2`、`(-8)^(2/3) = 4`；偶分母（`(-4)^0.5`）与无理指数（`(-2)^π`）维持 `NaN`。

### GlobalAnalyzer

```typescript
import { GlobalAnalyzer } from 'calcengine-graph';
import type { GlobalAnalysisResult } from 'calcengine-graph';

const result: GlobalAnalysisResult | null = GlobalAnalyzer.analyzeGlobal('x^2-1', false);

if (result) {
  // 零点
  result.zeros; // GraphPoint[]: [{x: -1, y: 0}, {x: 1, y: 0}]

  // 极值
  result.extrema; // Extremum[]: [{x: 0, y: -1, kind: 'min'}]

  // 定义域
  result.domain; // DomainInterval[]

  // 值域
  result.range; // DomainInterval[]

  // 渐近线
  result.asymptotes.vertical;   // number[]
  result.asymptotes.horizontal; // {xDir, y}[]
  result.asymptotes.oblique;    // {xDir, k, b}[]

  // 对称性
  result.symmetry; // 'even' | 'odd' | 'none'

  // 周期性
  result.period; // number | null

  // 凹凸性
  result.concavity.inflections; // GraphPoint[]
  result.concavity.concaveUp;   // DomainInterval[]
  result.concavity.concaveDown; // DomainInterval[]

  // 最大曲率
  result.maxCurvature; // GraphPoint | null
  result.maxCurvatureKappa; // number

  // 增长阶
  result.growthClass; // 'constant' | 'linear' | 'polynomial' | 'exponential' | ...
}
```

### RenderDispatcher 与 ExtractionBudget

若已有自己的 UI 层，只需依赖本模块：`RenderDispatcher` 产出世界坐标的线段/多边形，绘制由宿主负责。

```typescript
import { RenderDispatcher, ExtractionBudget } from 'calcengine-graph';
import type { RenderData } from 'calcengine-graph';

// 同步函数列表（表达式变更时调用，内部按模式创建/销毁渲染器）
dispatcher.syncFunctions(functions, isDegMode);

// 按需分块构建网格（有未覆盖的渲染器时返回 fnId 列表）
const targets: number[] = dispatcher.getRebuildTargets(vp);
// …逐个 beginBuildFor(fnId, vp, pixelWorldDx) → buildChunkFor(fnId, maxNodeRows) 直到返回 true

// 帧期查询：纯投影，零求值、零 MS 迭代
const all: RenderData[] = dispatcher.extractAll(vp, fnStyleMap);
// all[i].contourSegments / fillRegions / boundarySegments 为世界坐标

// 帧间推进提取（必须在帧间调用，绝不可在单帧内跑完）
const budget = isGesturing ? ExtractionBudget.gesture() : ExtractionBudget.idle();
const done: boolean = dispatcher.pumpExtractions(budget, vp);
```

**契约**：
- `extractVisible`（经 `extractAll`）**不触发提取**，提取未完成的帧返回已提取部分（曲线渐进长出）
- `pumpExtractions` 在内部统一 `budget.begin()`，多个渲染器共享同一预算窗口，形成全局每帧上限
- 预算含行数 / 探针求值次数 / 墙钟三重上限；段数上限由 `SegmentCaps.of(pixelWorldDx, worldWidth)` 按画布像素推导（16 段/像素，下限 2048），超软上限降 AMR 深度、超硬上限截断并置 `truncated`
- `ExtractionBudget.gesture()` 取 8 行 / 4 万次 / 6ms；`idle()` 取 32 行 / 20 万次 / 12ms

段数上限的由来：早期实现用固定常数 200000，对 1080px 画布相当于每像素列 185 段，远超可分辨限度，且每次泵入后的重绘开销随累积段数线性增长。现由画布宽度决定，宿主无需自行调参；`SEGMENT_SOFT_CAP`/`SEGMENT_HARD_CAP` 仅为上钳位常数。

### GraphFunction 类型

```typescript
import type { GraphFunction, MarkerCategory, GraphLineStyle } from 'calcengine-graph';

interface GraphFunction {
  id: number;
  expr: string;              // 完成态表达式（经 simplify 回写）
  color: string;             // 颜色
  lineWidth: number;         // 线宽（vp）
  lineStyle: GraphLineStyle; // 线型
  enabled: boolean;          // 是否可见
  name?: string;             // 自定义标签
  labelIndex: number;        // 标签序号
}
```

---

## calcengine-graph-ui

Canvas 组件参考实现，**未经生产验证**，视作实验性模块。依赖 `calcengine-graph`、`calcengine-exp`、`calcengine-core`。

### GraphViewModel

`GraphViewModel` 归属本模块（它依赖 `calcengine-exp` 的 `MathField` 与序列化能力，属 UI 状态层）。

```typescript
import { GraphViewModel } from 'calcengine-graph-ui';
import type { MarkerCategory } from 'calcengine-graph';

const vm = new GraphViewModel();

// 添加函数
const id = vm.addFunction('sin(x)');

// 获取渲染调度器
const dispatcher = vm.getRenderDispatcher();

// 函数列表
vm.functions; // GraphFunction[]

// 当前选中
vm.activeId; // number

// 设置标记类别
vm.setMarkerCategory(id, MarkerCategory.ZERO);

// 切换分析
vm.toggleAnalysis(id);
```

### GraphCanvas

```typescript
import { GraphCanvas, GraphCanvasController } from 'calcengine-graph-ui';

// 控制器（宿主无需持有 GraphCanvas 实例即可下发命令，如截取缩略图）
const controller = new GraphCanvasController();

GraphCanvas({
  functions: vm.functions,
  activeId: vm.activeId,
  isDegMode: false,
  isDark: false,
  renderDispatcher: vm.getRenderDispatcher(),
  controller: controller,

  // 可选回调
  onSelect: (id: number) => { /* ... */ },
  onColorChange: (id: number, color: string) => { /* ... */ },
  onExprChange: (id: number, expr: string) => { /* ... */ },

  // 可选适配器（未注入时功能自动降级：分享入口隐藏、缩略图不落地）
  shareAdapter: myShareAdapter,
  storageAdapter: myStorageAdapter,

  // 高级分析门控
  advancedAnalysisEnabled: true
});
```

### GraphDisplayArea

```typescript
import { GraphDisplayArea } from 'calcengine-graph-ui';

GraphDisplayArea({
  functions: vm.functions,
  activeId: vm.activeId,
  isDark: false,
  isPhoneDevice: true,
  advancedAnalysisEnabled: true
});
```

### AnalysisDock

```typescript
import { AnalysisDock } from 'calcengine-graph-ui';

AnalysisDock({
  functions: vm.functions,
  activeId: vm.activeId,
  isDark: false
});
```

### GraphImageExporter

图象水印合成 + JPEG 打包。品牌信息由宿主注入，均为可选。

```typescript
import { GraphImageExporter } from 'calcengine-graph-ui';

GraphImageExporter.composeWatermark(pixelMap, fontSize, fg, logoResId, brandName, ...);
// logoResId <= 0 时跳过 logo；brandName 为空时跳过品牌文字
```

### 适配器接口

```typescript
import type { GraphShareAdapter, GraphStorageAdapter } from 'calcengine-graph-ui';

// 分享出口：GraphCanvas 完成截图、水印合成与 JPEG 打包后调用
interface GraphShareAdapter {
  shareImage(jpegBuffer: ArrayBuffer, pixelMap: image.PixelMap): Promise<void>;
}

// 缩略图持久化出口：返回存储引用（路径 / URI / 记录 id），失败返回空字符串
interface GraphStorageAdapter {
  saveThumbnail(jpegBuffer: ArrayBuffer): Promise<string>;
}
```

未注入时使用 `NoopShareAdapter` / `NoopStorageAdapter`，不执行任何落地操作。

---

## 表达式求值错误处理

自 0.2.0 起，引擎**不再使用字符串错误码，也不再在求值路径抛异常**。原 `[GRAPH_FUNC_INVALID]` / `[GRAPH_FUNC_EVAL]` / `[GRAPH_DIVIDE_BY_ZERO]` / `[GRAPH_DOMAIN]` / `[GRAPH_OVERFLOW]` 五个错误码已全部移除。

原因：求值是网格采样与 1D 采样的热路径（单次可达数十万次调用），抛异常会触发完整栈追踪构建，在热循环中足以阻塞主线程数秒。

现行契约分两层：

| 阶段 | 表现 |
|---|---|
| 解析期 | `isValid === false` + `error` 给出可读原因（相邻数值、括号不匹配、未知标识符、缺少操作数、RPN 栈残留等） |
| 求值期 | 一律返回 `NaN`（域错误、除零、溢出、栈异常），**绝不抛异常** |

因此调用方只需检查 `isValid`，之后 `evaluate` 的返回值用 `isFinite` / `Number.isNaN` 判定即可，无需 try/catch。

---

## 类型导出

各模块导出的类型：

### calcengine-core

```typescript
export { Tokenizer, ConstantLib, setMathLogger, getMathLogger };
export type { TokenPosition, IdentifierPosition, MathLogger, ConstantEntry };
```

### calcengine-exp

```typescript
export { parseLinear, serializeLinear, simplify, MathField, resolveRow, resolveBranch };
export { VstNode, VstRow, VstNum, VstVar, VstConst, VstOp, VstFrac, VstPow, ... };
export { BRANCH_NUM, BRANCH_DEN, BRANCH_BODY, BRANCH_BASE, BRANCH_EXP, ... };
export type { ExprStyle, ExprMetrics, DebugMask, GraphKeySpec };
```

### calcengine-graph

```typescript
export { ExprClassifier, FunctionEvaluator, BivariateEvaluator, GlobalAnalyzer, GraphAnalyzer };
export { RenderMode, renderModeLabel, RenderDispatcher, ExtractionBudget, SegmentCaps };
export { SampleEngine, GridSampleEngine2D, GridCache2D, FunctionSampleCache };
export { fmt, fmtPi, formatIntervals, domainTextOf, rangeTextOf, symmetryTextOf };
export type { ClassifyResult, RenderData, LineSegment, Polygon, GlobalAnalysisResult };
export type { GraphFunction, GraphLineStyle, MarkerCategory, WorldSample, Viewport };
```

注意：`GraphViewModel` 与 `GraphImageExporter` **不在本模块**，已移至 `calcengine-graph-ui`。

### calcengine-graph-ui

```typescript
export { GraphCanvas, GraphCanvasController, GraphDisplayArea, AnalysisDock };
export { GraphViewModel, GraphImageExporter, GraphExportService };
export { NoopShareAdapter, NoopStorageAdapter, ModeTag, UiMotion };
export { MODE_STYLES, MODE_STYLES_DARK };
export type { AnalysisCardData, GraphShareAdapter, GraphStorageAdapter, ModeTagStyle };
```
