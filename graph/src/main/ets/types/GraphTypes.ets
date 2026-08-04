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
// features/graph/src/main/ets/types/GraphTypes.ets
/**
 * 图象绘制模式共享类型定义
 *
 * GraphFunction 同时被 GraphCanvas（绘制数据源）与 GraphDisplayArea（编辑区）
 * 消费；真正的所有权在 瀹夸富缁勪欢（@Local graphFunctions），二者均为只读/写回视图。
 */

/** 线型：实线 / 虚线（#13 快捷工具条循环切换） */
export type GraphLineStyle = 'solid' | 'dashed';

/** 标记分类：零点 / 极值 / 拐点 / 渐近线（逐函数独立开关） */
export type MarkerCategory = 'zeros' | 'extrema' | 'inflections' | 'asymptotes';

/** 线型枚举（用于循环切换与取色板对齐顺序） */
export const GRAPH_LINE_STYLES: GraphLineStyle[] = ['solid', 'dashed'];

/** 单条待绘制函数 */
export interface GraphFunction {
  /** 稳定 id，用于 ForEach 键控与回调定位（不走下标，避免增删错位） */
  id: number;
  /** 表达式，如 "sin(x)"、"x^2 - 1" */
  expr: string;
  /** 曲线颜色（十六进制） */
  color: string;
  /** 是否绘制 */
  enabled: boolean;
  /** 自定义别名（可选，设置后列表标签显示别名而非 y₁/y₂…） */
  name?: string;
  /**
   * 默认标签固定序号（创建时分配，不随数组位置变化）：
   * name 为空时显示 y_{labelIndex+1}（如 0 → y₁）。
   * 删除其他函数不影响已有序号；仅在清除别名且原序号已被占用时重新分配。
   */
  labelIndex: number;
  /** 线型（实线 / 虚线） */
  lineStyle: GraphLineStyle;
  /** 线宽（像素，绘制用；菜单可选 细/中/粗 = 2/3/4.5） */
  lineWidth: number;
  /** 当前表达式的渲染模式（由 GraphViewModel 在 setExpr 时写入，RenderMode 枚举值） */
  renderMode?: number;
  /** 零点标记（红点），逐函数独立 */
  showZeros?: boolean;
  /** 极值标记（绿框），逐函数独立 */
  showExtrema?: boolean;
  /** 拐点标记（Pro，来自凹凸性分析） */
  showInflections?: boolean;
  /** 渐近线标记（Pro，垂直/水平/斜） */
  showAsymptotes?: boolean;
  /** 函数分析卡片是否显示（控制分析坞中的卡片显隐） */
  showAnalysis?: boolean;
}

/** 函数配色（按添加顺序循环取用，互不冲突） */
export const GRAPH_PALETTE: string[] = [
  '#185FA5', // 蓝
  '#D7263D', // 红
  '#2E7D32', // 绿
  '#ED6C02', // 橙
  '#6A1B9A', // 紫
  '#00838F'  // 青
];

/** 取色面板预设色（在调色板基础上补充中性色，约 12 色网格） */
export const GRAPH_COLOR_PICKER: string[] = [
  '#185FA5', '#D7263D', '#2E7D32', '#ED6C02',
  '#6A1B9A', '#00838F', '#000000', '#5D4037',
  '#9E9E9E', '#FFFFFF', '#FFC107', '#E91E63'
];

/** 默认标签序号 → 显示标签（y₁ / y₂ / … / y₉，超出用 yN） */
export function graphFunctionLabel(index: number): string {
  const sub: string[] = ['₁', '₂', '₃', '₄', '₅', '₆', '₇', '₈', '₉'];
  if (index >= 0 && index < sub.length) {
    return 'y' + sub[index];
  }
  return 'y' + (index + 1).toString();
}

/**
 * 计算下一个可用的默认标签序号（「入栈式」命名）：
 * 取当前所有默认名称函数已占用序号中的最小空闲值，而非按数组下标分配。
 * 如现有 y₁、y₃（y₂ 已删除）→ 返回 1（新函数得 y₂）；
 * 自定义名称的函数不占用序号位。
 */
export function nextFreeLabelIndex(functions: GraphFunction[]): number {
  const used: Set<number> = new Set();
  for (let i: number = 0; i < functions.length; i++) {
    const f: GraphFunction = functions[i];
    if (f.name === undefined || f.name.length === 0) {
      used.add(f.labelIndex);
    }
  }
  let idx: number = 0;
  while (used.has(idx)) {
    idx++;
  }
  return idx;
}

/** 获取函数的显示名称（自定义别名优先，否则按固定序号生成 y₁/y₂…） */
export function graphDisplayName(fn: GraphFunction): string {
  if (fn.name !== undefined && fn.name.length > 0) {
    return fn.name;
  }
  return graphFunctionLabel(fn.labelIndex);
}

/** 调色板中当前颜色的下一个（点击色点循环切换） */
export function nextGraphColor(current: string): string {
  const i: number = GRAPH_PALETTE.indexOf(current);
  return GRAPH_PALETTE[(i + 1) % GRAPH_PALETTE.length];
}

/** 线型循环（实线 ↔ 虚线） */
export function nextLineStyle(current: GraphLineStyle): GraphLineStyle {
  const i: number = GRAPH_LINE_STYLES.indexOf(current);
  return GRAPH_LINE_STYLES[(i + 1) % GRAPH_LINE_STYLES.length];
}

/**
 * 屏幕投影点：用于「世界坐标预缓存 + 视口投影 + 轻量细分」渲染管线。
 * - raw：FunctionEvaluator 的原始返回值（含 NaN / ±Inf），用于判断无定义 / 无穷。
 * - y：经钳制的屏幕 y（NaN / ±Inf / 溢出均钳到屏幕外 ±1e6）。
 * - x/wx：屏幕 x 与对应世界坐标 x（细分时反算中点用）。
 */
export interface Gpt {
  x: number;   // 屏幕 x（像素）
  y: number;   // 屏幕 y（已钳制；NaN 表示无定义）
  wx: number;  // 对应世界坐标 x
  raw: number; // 原始求值结果（用于 NaN / 无穷判定）
}
