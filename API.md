# API 参考

## mathkit

最小数学内核：表达式分词 + 常数库 + 日志抽象。

### Tokenizer

```typescript
import { Tokenizer } from 'mathkit';

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

### ConstantLib

```typescript
import { ConstantLib } from 'mathkit';

// 查询常量值
const pi: number = ConstantLib.lookup('π'); // 3.14159...

// 注册自定义常量
ConstantLib.register('α', 0.5);
```

### MathLogger

```typescript
import { setMathLogger, getMathLogger } from 'mathkit';

// 自定义日志实现
setMathLogger({
  info: (msg: string) => console.log('[INFO]', msg),
  warn: (msg: string) => console.warn('[WARN]', msg),
  error: (msg: string) => console.error('[ERROR]', msg)
});
```

---

## exprrender

表达式渲染引擎：VST（视觉语法树）→ Box 布局树 → Canvas 像素。

### 解析与序列化

```typescript
import { parseLinear, serializeLinear } from 'exprrender';

// 字符串 → VST
const vst: VstRow = parseLinear('x^2 + sin(x)');

// VST → 字符串
const str: string = serializeLinear(vst); // 'x^2+sin(x)'
```

### VST 节点类型

```typescript
import {
  VstRow, VstNum, VstVar, VstConst, VstOp,
  VstFrac, VstPow, VstSqrt, VstRoot, VstParen,
  VstFunc, VstCeil, VstFloor, VstNeg, VstLog
} from 'exprrender';

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
import { resolveRow, resolveBranch, BRANCH_NUM, BRANCH_DEN } from 'exprrender';

// 导航到分数的分子
const numNodes: VstNode[] | undefined = resolveBranch(fracNode, BRANCH_NUM);

// 通过路径导航
const nodes: VstNode[] = resolveRow(root, [0, BRANCH_NUM]);
```

### MathField 命令式编辑

```typescript
import { MathField } from 'exprrender';

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
import { simplify, parseLinear, serializeLinear } from 'exprrender';

const vst = parseLinear('x*x');
const simplified = simplify(vst);
serializeLinear(simplified); // 'x^2'
```

---

## graph

图形引擎：分类 → 求值 → 采样 → 四模式渲染 → 全局分析。

### ExprClassifier

```typescript
import { ExprClassifier, RenderMode } from 'graph';
import type { ClassifyResult } from 'graph';

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

### FunctionEvaluator

```typescript
import { FunctionEvaluator } from 'graph';

// 弧度模式（默认）
const ev = new FunctionEvaluator('sin(x)');
const y: number = ev.evaluate(Math.PI / 2); // ≈ 1

// 角度模式
const evDeg = new FunctionEvaluator('sin(x)', true);
const yDeg: number = evDeg.evaluate(90); // ≈ 1
```

### GlobalAnalyzer

```typescript
import { GlobalAnalyzer } from 'graph';
import type { GlobalAnalysisResult } from 'graph';

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

### GraphViewModel

```typescript
import { GraphViewModel } from 'graph';

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

### GraphFunction 类型

```typescript
import type { GraphFunction, MarkerCategory, GraphLineStyle } from 'graph';

interface GraphFunction {
  id: number;
  rawExpr: string;           // 原始表达式
  normalizedExpr: string;    // 标准化表达式
  mode: RenderMode;          // 渲染模式
  color: string;             // 颜色
  lineStyle: GraphLineStyle; // 线型
  visible: boolean;          // 是否可见
  markers: Set<MarkerCategory>; // 标记类别
  // ...
}
```

---

## graph-ui

Canvas 组件参考实现。

### GraphCanvas

```typescript
import { GraphCanvas, GraphCanvasController } from 'graph-ui';

// 控制器
const controller = new GraphCanvasController();

// 组件
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
  
  // 可选适配器
  shareAdapter: myShareAdapter,
  storageAdapter: myStorageAdapter,
  
  // 高级分析门控
  advancedAnalysisEnabled: true
});
```

### GraphDisplayArea

```typescript
import { GraphDisplayArea } from 'graph-ui';

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
import { AnalysisDock } from 'graph-ui';

AnalysisDock({
  functions: vm.functions,
  activeId: vm.activeId,
  isDark: false
});
```

### 适配器接口

```typescript
import type { GraphShareAdapter, GraphStorageAdapter } from 'graph-ui';

// 分享适配器
interface GraphShareAdapter {
  share(pixelMap: image.PixelMap, expr: string): Promise<void>;
}

// 存储适配器
interface GraphStorageAdapter {
  saveThumbnail(buf: ArrayBuffer): Promise<string>;
}
```

---

## 错误码

引擎使用字符串错误码：

- `[GRAPH_FUNC_INVALID]`：函数表达式无效
- `[GRAPH_FUNC_EVAL]`：函数求值错误
- `[GRAPH_DIVIDE_BY_ZERO]`：除零
- `[GRAPH_DOMAIN]`：定义域错误
- `[GRAPH_OVERFLOW]`：溢出

---

## 类型导出

各模块导出的类型：

### mathkit

```typescript
export { Tokenizer, ConstantLib, setMathLogger, getMathLogger };
export type { TokenPosition, IdentifierPosition, MathLogger, ConstantEntry };
```

### exprrender

```typescript
export { parseLinear, serializeLinear, simplify, MathField, resolveRow, resolveBranch };
export { VstNode, VstRow, VstNum, VstVar, VstConst, VstOp, VstFrac, VstPow, ... };
export { BRANCH_NUM, BRANCH_DEN, BRANCH_BODY, BRANCH_BASE, BRANCH_EXP, ... };
export type { ExprStyle, ExprMetrics, DebugMask, GraphKeySpec };
```

### graph

```typescript
export { ExprClassifier, FunctionEvaluator, BivariateEvaluator, GlobalAnalyzer, GraphAnalyzer };
export { RenderMode, RenderDispatcher, SampleEngine, GridSampleEngine2D };
export { GraphViewModel, fmt, fmtPi, formatIntervals, GraphImageExporter };
export type { ClassifyResult, RenderData, LineSegment, Polygon, GlobalAnalysisResult };
export type { GraphFunction, GraphLineStyle, MarkerCategory };
```

### graph-ui

```typescript
export { GraphCanvas, GraphCanvasController, GraphDisplayArea, AnalysisDock };
export { GraphExportService, ModeTag, UiMotion };
export type { AnalysisCardData, GraphShareAdapter, GraphStorageAdapter, ModeTagStyle };
```
