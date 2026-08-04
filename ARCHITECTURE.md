# 架构文档

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
│  │  (mathkit)   │  - 一元负号 / 二元减号                         │
│  │              │  - 科学计数法（1.2e3）                         │
│  │              │  - 常量符号（π、e）                            │
│  └──────┬───────┘                                               │
│         ↓                                                       │
│  ┌──────────────┐                                               │
│  │  parseLinear │  语法分析：Token → VST（视觉语法树）            │
│  │ (exprrender) │  - VstRow / VstFrac / VstPow / VstFunc ...   │
│  │              │  - 分支结构（分子/分母/底数/指数）              │
│  └──────┬───────┘                                               │
│         ↓                                                       │
│  ┌──────────────┐                                               │
│  │ExprRenderer  │  翻译层：VST → Box 布局树                      │
│  │ (exprrender) │  - HBox / VBox / FracBox / PowerBox ...      │
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

## 图形四模式分类

```
┌─────────────────────────────────────────────────────────────────┐
│                    ExprClassifier.classify()                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  输入：原始表达式（可能含 y=, >, <, = 等关系符）                  │
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

## 采样算法

### 显函数自适应采样（SampleEngine）

```
1. 初始均匀采样（N 个点）
2. 检测相邻点斜率变化
3. 斜率变化剧烈区域 → 递归细分
4. 不连续点检测（y 值跳变 / NaN）→ 断开线段
5. 输出：LineSegment[]（连续线段片段）
```

### 隐函数网格采样（GridSampleEngine2D）

```
1. 构建网格（worldX, worldY → 像素坐标）
2. 对每个网格单元 (i, j)：
   - 计算四角 F(x, y) 值
   - 检测符号变化（Marching Squares 算法）
   - 线性插值求交点
3. 连接相邻单元的交点 → 等值线段
4. 输出：LineSegment[]（隐式曲线）
```

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

```
┌─────────────┐
│  graph-ui   │  Canvas 组件参考实现
│  (HAR)      │  - GraphCanvas / GraphDisplayArea / AnalysisDock
└──────┬──────┘
       │ depends on
       ↓
┌─────────────┐
│   graph     │  图形引擎（纯逻辑，零 UI）
│   (HAR)     │  - ExprClassifier / FunctionEvaluator / SampleEngine
│             │  - GlobalAnalyzer / GraphViewModel
└──────┬──────┘
       │ depends on
       ↓
┌─────────────┐
│ exprrender  │  表达式渲染引擎
│   (HAR)     │  - VST 节点模型 / Box 布局树 / TeX 度量
│             │  - parseLinear / serializeLinear / MathField
└──────┬──────┘
       │ depends on
       ↓
┌─────────────┐
│  mathkit    │  最小数学内核
│   (HAR)     │  - Tokenizer / ConstantLib / MathLogger
└─────────────┘
```

## 解耦设计

开源版剥离所有 App 私有耦合，通过注入接口实现可扩展：

### 主题

```typescript
// 不绑定 AppStorage，由宿主传入
@Prop isDark: boolean = false;
```

### 分享

```typescript
// 可选适配器，默认空实现
export interface GraphShareAdapter {
  share(pixelMap: image.PixelMap, expr: string): Promise<void>;
}

// 宿主注入
GraphCanvas({ shareAdapter: myShareAdapter, ... })
```

### 存储

```typescript
// 可选适配器，默认仅返回 PixelMap 不落地
export interface GraphStorageAdapter {
  saveThumbnail(buf: ArrayBuffer): Promise<string>;
}
```

### Pro 门控

```typescript
// 布尔属性，默认 true（全部功能开放）
@Prop advancedAnalysisEnabled: boolean = true;
```

### 日志

```typescript
// 轻量 Logger 接口，默认 console
import { setMathLogger } from 'mathkit';
setMathLogger(myCustomLogger);
```

## 文件组织

```
graph-math-engine/
├── mathkit/
│   ├── Index.ets                    # 模块入口
│   ├── oh-package.json5
│   └── src/
│       ├── main/ets/math/
│       │   ├── Tokenizer.ets        # 词法分词器
│       │   ├── ConstantLib.ets      # 常量库（π、e、φ ...）
│       │   └── MathLogger.ets       # 日志抽象
│       └── test/                    # 单元测试
│
├── exprrender/
│   ├── Index.ets
│   └── src/main/ets/
│       ├── vst/                     # VST 节点模型
│       │   ├── VstNodes.ets         # VstRow/VstFrac/VstPow ...
│       │   ├── VstEditor.ets        # MathField 命令式编辑
│       │   ├── VstSerializer.ets    # VST → 字符串
│       │   └── TreeCursor.ets       # 分支导航
│       ├── parser/
│       │   └── ExprParser.ets       # 字符串 → VST
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
├── graph/
│   ├── Index.ets
│   └── src/main/ets/
│       ├── engine/                  # 核心引擎
│       │   ├── ExprClassifier.ets   # 四模式分类
│       │   ├── FunctionEvaluator.ets# RPN 求值器
│       │   ├── BivariateEvaluator.ets# 二元求值器
│       │   ├── SampleEngine.ets     # 显函数采样
│       │   ├── GridSampleEngine2D.ets# 隐函数网格采样
│       │   ├── GlobalAnalyzer.ets   # 全局分析
│       │   ├── GraphAnalyzer.ets    # 视口内分析
│       │   └── RenderDispatcher.ets # 渲染调度
│       ├── types/
│       │   └── GraphTypes.ets       # GraphFunction/调色板/线型
│       ├── math/
│       │   └── GraphMath.ets        # 坐标变换/视口
│       ├── utils/
│       │   ├── AnalysisTextFormatter.ets
│       │   └── GraphImageExporter.ets# 截图/水印
│       └── viewmodel/
│           └── GraphViewModel.ets   # 状态管理
│
├── graph-ui/
│   ├── Index.ets
│   └── src/main/ets/
│       ├── components/
│       │   ├── GraphCanvas.ets      # 主画布组件
│       │   ├── GraphDisplayArea.ets # 显示区域
│       │   └── AnalysisDock.ets     # 分析坞
│       ├── paint/                   # 绘制逻辑
│       │   ├── GridAxisPainter.ets  # 网格/轴
│       │   └── GraphCurvePainter.ets# 曲线/填充
│       ├── gesture/
│       │   └── GraphGestureMath.ets # 手势数学
│       ├── support/                 # 适配器/工具
│       │   ├── GraphAdapters.ets    # ShareAdapter/StorageAdapter
│       │   ├── CompatUtils.ets
│       │   └── ModeTag.ets
│       └── export/
│           └── GraphExportService.ets# 导出服务
│
└── demo/                            # 演示 HAP
    └── src/main/ets/
        ├── entryability/EntryAbility.ets
        └── pages/Index.ets
```

## 设计原则

1. **纯逻辑与 UI 分离**：graph 模块零 UI 依赖，可独立测试
2. **接口注入**：主题/分享/存储/日志均通过接口注入，默认空实现
3. **类型安全**：ArkTS 严格模式，零 any/unknown
4. **数值稳定性**：采样算法处理不连续点、极点、高频振荡
5. **可扩展常量库**：ConstantLib 支持运行时注册新常量
6. **中文注释**：与现有代码风格一致，README 提供英文摘要
