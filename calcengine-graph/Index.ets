/*
 * Copyright (c) 2026 graph-math-engine contributors
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

/**
 * calcengine-graph 模块入口
 * 2D 图形绘制引擎（纯逻辑，零 UI 依赖）：
 * 表达式分类 → 求值器编译 → 渲染调度 → 四模式渲染器 → 全局分析。
 * Canvas 组件参考实现位于 calcengine-graph-ui 模块。
 */

// ── 共享类型（GraphFunction / 调色板 / 标签 / 线型） ──
export { GraphFunction, MarkerCategory, GRAPH_PALETTE, GRAPH_COLOR_PICKER, Gpt, graphDisplayName, graphFunctionLabel, nextGraphColor, nextFreeLabelIndex, GraphLineStyle, nextLineStyle } from './src/main/ets/types/GraphTypes';

// ── 数学工具 ──
export { GraphMath, Viewport } from './src/main/ets/math/GraphMath';

// ── 表达式分类与求值 ──
export { ExprClassifier } from './src/main/ets/engine/ExprClassifier';
export type { ClassifyResult } from './src/main/ets/engine/ExprClassifier';
export { FunctionEvaluator } from './src/main/ets/engine/FunctionEvaluator';
export { BivariateEvaluator } from './src/main/ets/engine/BivariateEvaluator';

// ── 渲染调度与四模式渲染器 ──
export { RenderDispatcher } from './src/main/ets/engine/RenderDispatcher';
export { RenderMode, renderModeLabel } from './src/main/ets/engine/IRenderer';
export type { RenderData, LineSegment, Polygon } from './src/main/ets/engine/IRenderer';

// ── 采样引擎与缓存 ──
export { SampleEngine } from './src/main/ets/engine/SampleEngine';
export { FunctionSampleCache, WorldSample } from './src/main/ets/engine/SampleCache';
export { GridSampleEngine2D } from './src/main/ets/engine/GridSampleEngine2D';
export { GridCache2D } from './src/main/ets/engine/GridCache2D';

// ── 函数分析 ──
export { GraphAnalyzer, GraphPoint, Extremum } from './src/main/ets/engine/GraphAnalyzer';
export { GlobalAnalyzer, GlobalAnalysisResult, HorizontalAsymptote, ObliqueAsymptote } from './src/main/ets/engine/GlobalAnalyzer';

// ── 文本格式化 / 图像导出工具 ──
export { fmt, fmtPi, formatIntervals, domainTextOf, rangeTextOf, symmetryTextOf, periodTextOf, growthTextOf } from './src/main/ets/utils/AnalysisTextFormatter';
export { GraphImageExporter } from './src/main/ets/utils/GraphImageExporter';

// ── 图形模式 ViewModel（状态管理核心） ──
export { GraphViewModel } from './src/main/ets/viewmodel/GraphViewModel';
