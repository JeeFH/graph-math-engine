# calcengine-exp

CalcEngine 的**表达式渲染引擎**：字符串 → VST（视觉语法树）→ Box 布局树 → Canvas 像素。零内部依赖，可独立取用——只要表达式排版不会带入图象引擎。

## 安装

```json5
{
  "dependencies": {
    "calcengine-exp": "^0.2.0"
  }
}
```

## 快速开始

### 解析与序列化

```typescript
import { parseLinear, serializeLinear, simplify } from 'calcengine-exp';

const vst = parseLinear('sin(x) + x^2');
const str: string = serializeLinear(vst);     // 'sin(x)+x^2'
const short = simplify(parseLinear('x*x'));   // → x^2
```

`simplify(root, foldNumericProducts?)` 的第二个参数默认 `false`，保持历史行为逐字节不变；传 `true` 时折叠同一乘积项内的数字因子（`2*3*x → 6x`），并在数字乘积带二进制浮点尾数时（如 `0.1*0.2`）放弃折叠、原样保留。

### 命令式编辑

```typescript
import { MathField } from 'calcengine-exp';

const field = new MathField();
field.execute('insertVar', 'x');
field.execute('insertOp', '+');
field.execute('insertText', '1');
console.log(field.serialize());   // 'x+1'
```

### 组件（ArkUI）

```typescript
import { ExprView, MathFieldView } from 'calcengine-exp';

ExprView({ /* 只读表达式展示 */ });
MathFieldView({ /* 可编辑表达式输入 */ });
```

### 离屏渲染

不依赖组件即可把表达式渲染到离屏 Canvas，例如合成到图片水印中：

```typescript
import { parseLinear, simplify, ExprRenderer, measureAndRelayout } from 'calcengine-exp';

const renderer = new ExprRenderer();
const root = measureAndRelayout(simplify(parseLinear(expr)), metrics);
renderer.render(ctx, root, style);
```

### 分支导航

```typescript
import { resolveRow, resolveBranch, BRANCH_NUM, BRANCH_DEN } from 'calcengine-exp';

const numNodes = resolveBranch(fracNode, BRANCH_NUM);   // 进入分子
const nodes = resolveRow(root, [0, BRANCH_NUM]);        // 按路径导航
```

VST 节点类型（`VstRow` `VstNum` `VstVar` `VstConst` `VstOp` `VstFrac` `VstPow` `VstSqrt` `VstRoot` `VstParen` `VstFunc` `VstCeil` `VstFloor` `VstNeg` `VstLog`）、TeX 度量常数（`NUM1` `DENOM1` `SUP_DROP` ...）、间距工具与主题色解析（`resolveColor`）均从包根导出。完整清单见仓库 [API.md](../API.md)。

## 词表边界

`parseLinear` 认识 `root`（n 次根）与 `csc` / `sec` / `cot`，而 [`calcengine-graph`](../calcengine-graph) 的求值器函数表目前不含后三者。跨层词表差异见仓库 CHANGELOG 的 Known Issues。

## 许可证

MIT License - 详见 [LICENSE](./LICENSE)
