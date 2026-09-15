# 架构文档

> CalcEngine 模块短名：`core` = `calcengine-core`，`exp` = `calcengine-exp`，
> `graph` = `calcengine-graph`，`graph-ui` = `calcengine-graph-ui`。

## 全栈渲染管线

```
┌─────────────────────────────────────────────────────────────────┐
│                        表达式渲染管线                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  字符串输入                                                      │
│     ↓                                                           │
│  ┌──────────────┐                                               │
│  │  Tokenizer   │  词法分析：字符串 → Token 序列                  │
│  │    (core)    │  - 一元负号 / 二元减号                         │
│  │              │  - 科学计数法（1.2e3）                         │
│  │              │  - 常量符号（π、e）                            │
│  └──────┬───────┘                                               │
│         ↓                                                       │
│  ┌──────────────┐                                               │
│  │  parseLinear │  语法分析：Token → VST（视觉语法树）            │
│  │    (exp)     │  - VstRow / VstFrac / VstPow / VstFunc ...   │
│  │              │  - 分支结构（分子/分母/底数/指数）              │
│  └──────┬───────┘                                               │
│         ↓                                                       │
│  ┌──────────────┐                                               │
│  │ExprRenderer  │  翻译层：VST → Box 布局树                      │
│  │    (exp)     │  - HBox / VBox / FracBox / PowerBox ...      │
│  │              │  - TeX 度量规则（NUM1, DENOM1, SUP_DROP ...） │
│  └──────┬───────┘                                               │
│         ↓                                                       │
│  ┌──────────────┐                                               │
│  │  Canvas 2D   │  渲染层：Box 树 → Canvas 像素                  │
│  │   (视图)     │  - 字形绘制 / 分数线的 / 根号覆盖              │
│  │              │  - 光标定位 / 选中高亮                         │
│  └──────────────┘                                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

注意 `exp` 自带递归下降解析器（`parser/ExprParser.ets`），**不复用** `core` 的 `Tokenizer`。原因：`Tokenizer` 只产出扁平 `string[]`，无法表达分数分子分母、n 次根指数、上下标等二维结构，而排版必须保留结构信息。两者是不同层次的工具，不是重复实现。

## 图形四模式分类

```
┌─────────────────────────────────────────────────────────────────┐
│                    ExprClassifier.classify()                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  输入：原始表达式（可能含 y=, >, <, = 等关系符）                  │
│  前置：ExprNormalizer.normalize()                                │
│    - Unicode 乘除号族（· ∙ ⋅ • ∗ → *）、全角标点/数字 → ASCII    │
│    - root(n,b) 改写为一元形式：n=2 → sqrt、n=3 → cbrt、其余 → 幂 │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ Step 1: 检测关系运算符                                    │  │
│  │   - 有 >, <, >=, <= → INEQUALITY（不等式）               │  │
│  │   - 有 = 且含 x,y → BIVARIATE_EQ（二元方程）             │  │
│  │   - 有 = 仅含 x   → IMPLICIT（隐函数兜底）               │  │
│  └──────────────────────────────────────────────────────────┘  │
│         ↓                                                       │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ Step 2: 无关系运算符 → 检查变量                           │  │
│  │   - 含 x 和 y      → IMPLICIT（隐函数 F(x,y)=0）         │  │
│  │   - 仅含 x         → EXPLICIT（显函数 y=f(x)）           │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│  输出：ClassifyResult { mode, rawExpr, normalizedExpr, ... }   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## 采样与等值线提取

### 显函数自适应采样（SampleEngine）

```
1. 初始均匀采样（N 个点）
2. 检测相邻点斜率变化
3. 斜率变化剧烈区域 → 递归细分
4. 不连续点检测（y 值跳变 / NaN）→ 断开线段
5. 输出：LineSegment[]（连续线段片段）
```

### 隐函数网格采样与提取（GridSampleEngine2D + ImplicitRenderer）

网格采样与等值线提取**拆成两个阶段**，因为后者成本远高于前者且必须可中断：

```
阶段一：网格构建（分块，逐行填充）
1. 按视口范围 + 50% 缓冲构建均匀网格
2. 逐节点行求值 F(x,y)（fillGridChunk，每次填 maxNodeRows 行）
3. 增量奇点检测（detectPolesForRow）标记极点单元格
4. 填满后原子替换 gridCache（构建期间旧网格继续渲染）

阶段二：等值线提取（分帧可中断，pumpExtraction）
5. 对符号变化单元格做 AMR 递归（4 路细分，5 个共享探针）
6. 叶子层 Marching Squares 线性插值出线段
7. 约束：行数 / 探针求值次数 / 墙钟三重预算
        + 段数软上限（降 AMR 深度）与硬上限（截断）
        + 振荡早退（4 个子格全含穿越即停止细分）
8. 产物按单元格行分桶，供帧期 O(可见段数) 查询
```

**关键契约**：`extractVisible(vp)` 是**纯查询**——不求值、不做 MS 迭代、不触发提取。提取一律由宿主调用 `RenderDispatcher.pumpExtractions(budget, vp)` 在帧间推进，预算用 `ExtractionBudget.gesture()`（手势期让帧优先）或 `ExtractionBudget.idle()`（空闲期尽快补全）选档。这样最坏耗时由预算常数决定，与被积函数的振荡密度解耦。

## 全局函数分析（GlobalAnalyzer）

```
analyzeGlobal(expr, isDeg) → GlobalAnalysisResult | null

分析内容：
├── 定义域（DomainInterval[]）：连续有定义区间 + 开闭端点
├── 值域（DomainInterval[]）：基于极值 + 端点极限
├── 零点（GraphPoint[]）：f(x) ≈ 0 的点
├── 极值（Extremum[]）：极大/极小点（kind: 'max' | 'min'）
├── 渐近线（Asymptotes）：
│   ├── 垂直渐近线（vertical: number[]）
│   ├── 水平渐近线（horizontal: {xDir, y}[]）
│   └── 斜渐近线（oblique: {xDir, k, b}[]）
├── 凹凸性（Concavity）：
│   ├── 拐点（inflections: GraphPoint[]）
│   ├── 凹区间（concaveUp: DomainInterval[]）
│   └── 凸区间（concaveDown: DomainInterval[]）
├── 对称性（SymmetryKind）：'even' | 'odd' | 'none'
├── 周期性（period: number | null）：最小正周期
├── 最大曲率（maxCurvature: GraphPoint | null）
└── 增长阶（GrowthClass）：'constant' | 'linear' | 'polynomial' | 'exponential' | ...
```

## 模块依赖关系

依赖图**不是**线性链：`calcengine-graph` 只依赖 `calcengine-core`，与 `calcengine-exp` 完全解耦。

```
        ┌──────────────────────────────────────────────────────────┐
        │                 calcengine-graph-ui                      │
        │  Canvas 组件参考实现（未经生产验证，视作实验性模块）       │
        │  - GraphCanvas / GraphDisplayArea / AnalysisDock         │
        │  - GraphViewModel / GraphImageExporter / GraphExportService│
        └───────┬────────────────────────────────┬─────────────────┘
                │ depends on                     │ depends on
                ↓                                ↓
     ┌────────────────────────┐      ┌────────────────────────┐
     │   calcengine-graph     │      │    calcengine-exp      │
     │   图象引擎（纯逻辑）    │      │   表达式渲染引擎        │
     │   零 UI 依赖            │      │   零内部依赖            │
     │  - ExprClassifier      │      │  - VST 节点模型         │
     │  - FunctionEvaluator   │      │  - Box 布局树           │
     │  - SampleEngine        │      │  - parseLinear          │
     │  - RenderDispatcher    │      │  - serializeLinear      │
     │  - GlobalAnalyzer      │      │  - MathField            │
     └───────────┬────────────┘      └────────────────────────┘
                 │ depends on
                 ↓
     ┌────────────────────────┐
     │    calcengine-core     │
     │   共享底座              │
     │   零内部依赖            │
     │  - Tokenizer           │
     │  - ConstantLib         │
     │  - MathLogger          │
     └────────────────────────┘
```

设计意图：`calcengine-exp` 与 `calcengine-graph` 互为独立子引擎，只共享最底层的 `calcengine-core`。只要表达式排版不会带入图象引擎，只要图象引擎也不会带入排版库。

> 已知待收敛项：`calcengine-exp` 的 `ExprParser.FUNC_NAME_LIST` 与 `calcengine-graph` 的 `EngineFunctions` 函数词表**双向不一致**（排版层认 `csc`/`sec`/`cot`，求值层认 `cbrt`/`exp`/`round`/`sign`/`factorial`）。治理方向是把函数词表下沉到 `calcengine-core` 单点维护。

## 解耦设计

开源版剥离所有 App 私有耦合，通过注入接口实现可扩展：

### 主题

```typescript
// 不绑定 AppStorage，由宿主传入
@Prop isDark: boolean = false;
```

### 分享

```typescript
// 可选适配器，默认空实现（分享入口在 UI 上自动隐藏）
export interface GraphShareAdapter {
  shareImage(jpegBuffer: ArrayBuffer, pixelMap: image.PixelMap): Promise<void>;
}

// 宿主注入
GraphCanvas({ shareAdapter: myShareAdapter, ... })
```

### 存储

```typescript
// 可选适配器，默认仅返回空字符串不落地
export interface GraphStorageAdapter {
  saveThumbnail(jpegBuffer: ArrayBuffer): Promise<string>;
}
```

### 品牌信息

```typescript
// 水印合成的品牌名与 logo 由宿主注入，均可选
GraphImageExporter.composeWatermark(..., logoResId, brandName);
```

### 日志

```typescript
// 轻量 Logger 接口，默认 console
import { setMathLogger } from 'calcengine-core';
setMathLogger(myCustomLogger);
```

## 文件组织

```
graph-math-engine/
├── calcengine-core/
│   ├── Index.ets                    # 模块入口
│   ├── oh-package.json5
│   └── src/
│       ├── main/ets/math/
│       │   ├── Tokenizer.ets        # 词法分词器
│       │   ├── ConstantLib.ets      # 常量库（π、e、φ ...）
│       │   └── MathLogger.ets       # 日志抽象
│       └── test/                    # 单元测试
│
├── calcengine-exp/                  # 零内部依赖
│   ├── Index.ets
│   └── src/main/ets/
│       ├── vst/                     # VST 节点模型
│       │   ├── VstNodes.ets         # VstRow/VstFrac/VstPow ...
│       │   ├── VstEditor.ets        # MathField 命令式编辑
│       │   ├── VstSerializer.ets    # VST → 字符串
│       │   ├── ExpressionSimplifier.ets  # 完成态化简（含数字因子折叠）
│       │   ├── GraphKeyMap.ets      # 排版图键
│       │   └── TreeCursor.ets       # 分支导航
│       ├── parser/
│       │   └── ExprParser.ets       # 字符串 → VST（自带递归下降）
│       ├── engine/
│       │   ├── ExprRender.ets       # VST → Box
│       │   └── LayoutMap.ets        # 布局映射
│       ├── box/                     # Box 布局树
│       │   ├── Box.ets              # 基类
│       │   ├── FracBox.ets          # 分数
│       │   ├── PowerBox.ets         # 幂
│       │   └── ...
│       ├── font/                    # TeX 度量
│       │   ├── TeXMetrics.ets
│       │   └── MathSpacing.ets
│       └── view/                    # 视图组件
│           ├── ExprView.ets
│           └── MathFieldView.ets
│
├── calcengine-graph/                # 只依赖 calcengine-core
│   ├── Index.ets
│   └── src/
│       ├── main/ets/
│       │   ├── engine/              # 核心引擎（纯逻辑，零 UI）
│       │   │   ├── ExprNormalizer.ets    # 词法前置归一化 + root 模板改写
│       │   │   ├── EngineFunctions.ets   # 函数名表与实现单点定义
│       │   │   ├── ExprClassifier.ets    # 四模式分类
│       │   │   ├── FunctionEvaluator.ets # RPN 求值器（显函数）
│       │   │   ├── BivariateEvaluator.ets# 二元求值器
│       │   │   ├── ExplicitRenderer.ets  # 显函数渲染器
│       │   │   ├── ImplicitRenderer.ets  # 隐函数/方程渲染器
│       │   │   ├── InequalityRenderer.ets# 不等式渲染器
│       │   │   ├── BivariateEqRenderer.ets # 二元方程渲染器
│       │   │   ├── IRenderer.ets         # 渲染器接口与共享类型
│       │   │   ├── ExtractionBudget.ets  # 分帧提取预算与段数上限
│       │   │   ├── RenderDispatcher.ets  # 渲染调度与提取泵
│       │   │   ├── SampleEngine.ets      # 显函数采样
│       │   │   ├── SampleCache.ets       # 显函数样本缓存
│       │   │   ├── GridSampleEngine2D.ets# 隐函数网格采样
│       │   │   ├── GridCache2D.ets       # 网格缓存
│       │   │   ├── GlobalAnalyzer.ets    # 全局分析
│       │   │   └── GraphAnalyzer.ets     # 视口内分析
│       │   ├── types/
│       │   │   └── GraphTypes.ets        # GraphFunction/调色板/线型
│       │   ├── math/
│       │   │   └── GraphMath.ets         # 坐标变换/视口
│       │   └── utils/
│       │       └── AnalysisTextFormatter.ets  # 分析结果文本格式化
│       └── test/
│           ├── LocalUnit.test.ets        # 分类/求值/分析
│           └── EngineFixes.test.ets      # 归一化/实数域根/预算提取回归
│
├── calcengine-graph-ui/             # 参考实现，未经生产验证
│   ├── Index.ets
│   └── src/main/ets/
│       ├── components/
│       │   ├── GraphCanvas.ets      # 主画布组件
│       │   ├── GraphCanvasController.ets # 命令式控制器
│       │   ├── GraphDisplayArea.ets # 显示区域
│       │   └── AnalysisDock.ets     # 分析坞
│       ├── viewmodel/
│       │   └── GraphViewModel.ets   # 状态管理（依赖 calcengine-exp）
│       ├── paint/                   # 绘制逻辑
│       │   ├── GridAxisPainter.ets  # 网格/轴
│       │   └── GraphCurvePainter.ets# 曲线/填充
│       ├── gesture/
│       │   └── GraphGestureMath.ets # 命中检测几何
│       ├── support/                 # 适配器/工具
│       │   ├── GraphAdapters.ets    # ShareAdapter/StorageAdapter
│       │   ├── CompatUtils.ets
│       │   ├── ModeTag.ets
│       │   └── UiMotion.ets
│       └── export/
│           ├── GraphExportService.ets # 导出服务
│           └── GraphImageExporter.ets # 水印合成 + JPEG 打包
│
├── demo/                            # 演示 HAP
│   └── src/main/ets/
│       ├── entryability/EntryAbility.ets
│       └── pages/Index.ets
│
└── scripts/
    ├── check-exports.ps1            # 跨包导出面静态校验
    └── prepare-publish.ps1          # 发布前依赖形态切换
```

## 设计原则

1. **纯逻辑与 UI 分离**：`calcengine-graph` 零 UI 依赖，可独立测试；`calcengine-graph-ui` 是可选参考实现
2. **子引擎互相独立**：`calcengine-exp` 与 `calcengine-graph` 不互相依赖，只共享 `calcengine-core`
3. **接口注入**：主题/分享/存储/日志/品牌信息均通过接口或参数注入，默认空实现
4. **类型安全**：ArkTS 严格模式，零 any/unknown
5. **帧路径不可阻塞**：`extractVisible` 等帧期 API 是纯查询；一切重计算走预算化的帧间泵
6. **静默失败不可接受**：表达式结构非法在解析期显式报错（`validateStructure`），而非解析成功却处处 NaN
7. **可扩展常量库**：ConstantLib 支持运行时注册新常量
8. **中文注释**：与现有代码风格一致，README 提供英文摘要
