# calcengine-core

CalcEngine 的共享底座：**词法分词 + 数学常量库 + 日志抽象**。零内部依赖，是家族里最底层的一层。

## 安装

```json5
{
  "dependencies": {
    "calcengine-core": "^0.2.0"
  }
}
```

## 快速开始

### 分词

```typescript
import { Tokenizer } from 'calcengine-core';
import type { TokenPosition, IdentifierPosition } from 'calcengine-core';

// 扁平 token 序列
const tokens: string[] = Tokenizer.tokenize('sin(x) + 2π');
// ['sin', '(', 'x', ')', '+', '2', 'π']

// 带位置信息（用于光标命中判定）
const positions: TokenPosition[] = Tokenizer.tokenizeWithPositions('x+1');

// 取光标处的标识符
const hit: IdentifierPosition | null = Tokenizer.getIdentifierAtPosition('sin(x)', 1);
// {identifier: 'sin', start: 0, end: 3}
```

### 常量库

```typescript
import { ConstantLib } from 'calcengine-core';
import type { ConstantEntry } from 'calcengine-core';

const pi: number = ConstantLib.lookup('π');   // 3.14159...
ConstantLib.register('α', 0.5);               // 运行时注册自定义常量
```

### 日志

SDK 内部不直接依赖 hilog 等宿主平台设施，默认输出到 `console`；宿主可注入实现转发到自己的日志系统。

```typescript
import { setMathLogger, getMathLogger } from 'calcengine-core';
import type { MathLogger } from 'calcengine-core';

setMathLogger({
  info: (m: string) => console.log('[INFO]', m),
  warn: (m: string) => console.warn('[WARN]', m),
  error: (m: string) => console.error('[ERROR]', m)
});
```

## 边界说明

`Tokenizer` 只产出**扁平** `string[]`，不构建语法树，也无法表达分数分子/分母、n 次根指数、上下标等二维结构。需要二维排版结构时请用 [`calcengine-exp`](../calcengine-exp) 的 `parseLinear`——它自带递归下降解析器，**不复用**本包的 `Tokenizer`。两者是不同层次的工具，不是重复实现。

## 许可证

MIT License - 详见 [LICENSE](./LICENSE)
