# calcengine-graph

CalcEngine 的**图象引擎**：表达式分类 → 求值 → 采样 → 四模式渲染 → 全局分析。

**纯逻辑、零 UI 依赖**，只依赖 [`calcengine-core`](../calcengine-core)——不会把表达式排版库一起带来。四模式：显函数 `y=f(x)`、隐函数 `F(x,y)=0`、不等式、二元方程。

## 安装

```json5
{
  "dependencies": {
    "calcengine-graph": "^0.2.0"
  }
}
```

## 快速开始

### 分类

```typescript
import { ExprClassifier, RenderMode } from 'calcengine-graph';
import type { ClassifyResult } from 'calcengine-graph';

const r: ClassifyResult = ExprClassifier.classify('y=x^2');
// { mode: RenderMode.EXPLICIT, rawExpr: 'y=x^2', normalizedExpr: 'x^2', hasX: true, hasY: false }
```

分类入口会先做词法归一化（对调用方透明）：Unicode 乘号族 `· ∙ ⋅ • ∗`、除号族、全角标点与数字、不可见字符一律归一为 ASCII 等价形式；`root(n,b)` 改写为一元形式（`n=2→sqrt`、`n=3→cbrt`、其余→`(b)^(1/(n))`）。因此 `normalizedExpr` 总是求值器可直接消费的形式。

### 求值

```typescript
import { FunctionEvaluator, BivariateEvaluator } from 'calcengine-graph';

const ev = new FunctionEvaluator('sin(x)');
const y: number = ev.evaluate(Math.PI / 2);   // ≈ 1

// 二元（隐函数/不等式/方程）
const bev = new BivariateEvaluator('x^2+y^2-4', false);
const z: number = bev.evaluate(1, 1);
```

**求值契约**：`evaluate` 是采样热路径，**绝不抛异常**。所有运行时错误（域错误、除零、溢出、RPN 栈异常）一律返回 `NaN`；调用方用 `isValid` / `error` 判断解析是否成功，用 `isFinite` / `Number.isNaN` 判定求值结果即可，无需 try/catch。

**实数域幂语义**：负底数配奇分母有理指数返回实根（`(-8)^(1/3) = -2`、`(-8)^(2/3) = 4`）；偶分母与无理指数维持 `NaN`。

### 渲染调度（自带 UI 层时只需这些）

```typescript
import { RenderDispatcher, ExtractionBudget, SegmentCaps } from 'calcengine-graph';
import type { RenderData } from 'calcengine-graph';

const dispatcher = new RenderDispatcher();
dispatcher.syncFunctions(functions, isDegMode);

// 分块建网格：先取需要重建的 fnId，再逐块填充直到返回 true
const targets: number[] = dispatcher.getRebuildTargets(vp);
// …beginBuildFor(fnId, vp, pixelWorldDx) → buildChunkFor(fnId, maxNodeRows) 直到 true

// 帧期查询：纯投影，零求值、零等值线迭代
const all: RenderData[] = dispatcher.extractAll(vp, fnStyleMap);

// 帧间推进提取：绝不能在一帧内跑完
const budget = isGesturing ? ExtractionBudget.gesture() : ExtractionBudget.idle();
const done: boolean = dispatcher.pumpExtractions(budget, vp);
```

**关键契约**：

- `extractVisible`（经 `extractAll`）**不触发提取**。提取未完成的帧返回已提取部分，曲线渐进长出。
- `pumpExtractions` 内部统一 `budget.begin()`，多个渲染器共享同一预算窗口，形成全局每帧上限。
- 预算含行数 / 探针求值次数 / 墙钟三重上限。段数上限由 `SegmentCaps.of(pixelWorldDx, worldWidth)` 按画布像素推导（16 段/像素，下限 2048），超软上限降 AMR 深度、超硬上限截断并置 `truncated`——即**最坏耗时由常数与画布尺寸决定，与被积函数的振荡密度解耦**。
- `ExtractionBudget.gesture()` 取 8 行 / 4 万次 / 6ms；`idle()` 取 32 行 / 20 万次 / 12ms。

### 全局分析

```typescript
import { GlobalAnalyzer } from 'calcengine-graph';
import type { GlobalAnalysisResult } from 'calcengine-graph';

const r: GlobalAnalysisResult | null = GlobalAnalyzer.analyzeGlobal('x^2-1', false);
// r.zeros / r.extrema / r.domain / r.range / r.asymptotes / r.symmetry
// r.period / r.concavity / r.maxCurvature / r.growthClass
```

### 文本格式化

`fmt` `fmtPi` `formatIntervals` `domainTextOf` `rangeTextOf` `symmetryTextOf` `periodTextOf` `growthTextOf`——把分析结果转成可直接展示的文案。

## 已知限制

- **高频振荡函数**（如 `sin(x·y)`）在视口放大到零集无法被网格分辨时，部分真实曲线会被奇点检测误判为极点而跳过，表现为曲线稀疏。定量数据与已否决的替代方案见仓库 CHANGELOG 的 Known Issues。
- 函数词表与 `calcengine-exp` 存在双向不一致（`csc`/`sec`/`cot` 仅排版层支持；`cbrt`/`exp`/`round`/`sign`/`factorial` 仅求值层支持）。

## 许可证

MIT License - 详见 [LICENSE](./LICENSE)
