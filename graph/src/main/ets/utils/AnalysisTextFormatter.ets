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
// features/graph/src/main/ets/utils/AnalysisTextFormatter.ets
/**
 * 函数分析文本格式化工具（从 GraphCanvas 提取，供 AnalysisDock 与 GraphCanvas 共用）
 *
 * 纯函数，无组件依赖，接收 GlobalAnalysisResult 返回格式化字符串。
 */

import { GlobalAnalysisResult, DomainInterval } from '../engine/GlobalAnalyzer';

/** 数值格式化（去尾零，4 位精度） */
export function fmt(v: number): string {
  if (Math.abs(v) < 1e-12) {
    return '0';
  }
  let s: string = v.toFixed(4);
  s = s.replace(/\.?0+$/, '');
  return s;
}

/** 区间数组 → 文本（如 "(-∞, 0) ∪ (0, +∞)"） */
export function formatIntervals(intervals: DomainInterval[]): string {
  if (intervals.length === 0) {
    return '∅';
  }
  const parts: string[] = [];
  for (let i = 0; i < intervals.length; i++) {
    const iv: DomainInterval = intervals[i];
    const lb: string = iv.loOpen ? '(' : '[';
    const rb: string = iv.hiOpen ? ')' : ']';
    const loS: string = iv.lo === -Infinity ? '−∞' : fmt(iv.lo);
    const hiS: string = iv.hi === Infinity ? '+∞' : fmt(iv.hi);
    parts.push(lb + loS + ', ' + hiS + rb);
  }
  return parts.join(' ∪ ');
}

/** 最大公约数 */
function gcd(a: number, b: number): number {
  a = Math.abs(a);
  b = Math.abs(b);
  while (b > 0) {
    const t: number = b;
    b = a % b;
    a = t;
  }
  return a;
}

/** π 的分数倍 pπ/q 的显示文本 */
function fmtPiFrac(p: number, q: number): string {
  if (p === 0) {
    return '0';
  }
  const g: number = gcd(Math.abs(p), q);
  const pp: number = p / g;
  const qq: number = q / g;
  const sign: string = pp < 0 ? '−' : '';
  const ap: number = Math.abs(pp);
  const num: string = ap === 1 ? 'π' : ap.toString() + 'π';
  if (qq === 1) {
    return sign + num;
  }
  return sign + num + '/' + qq;
}

/** 把数值格式化为 π 的有理倍数形式 */
export function fmtPi(v: number): string {
  const ratio: number = v / Math.PI;
  if (Math.abs(ratio) < 1e-9) {
    return '0';
  }
  const qs: number[] = [1, 2, 3, 4, 6, 12];
  for (let i = 0; i < qs.length; i++) {
    const q: number = qs[i];
    const p: number = Math.round(ratio * q);
    if (Math.abs(ratio - p / q) < 1e-6) {
      return fmtPiFrac(p, q);
    }
  }
  return fmt(ratio) + 'π';
}

/** 定义域文本 */
export function domainTextOf(g: GlobalAnalysisResult | null): string {
  if (g == null) {
    return '∅';
  }
  if (g.period != null) {
    if (g.periodHoles.length === 0) {
      return 'x ∈ ℝ';
    }
    const holeParts: string[] = [];
    for (let i = 0; i < g.periodHoles.length; i++) {
      holeParts.push(fmtPi(g.periodHoles[i]));
    }
    return 'x ≠ ' + holeParts.join(', ') + ' + kT';
  }
  return formatIntervals(g.domain);
}

/** 值域文本 */
export function rangeTextOf(g: GlobalAnalysisResult | null): string {
  if (g == null || g.range.length === 0) {
    return '∅';
  }
  return formatIntervals(g.range);
}

/** 对称性文本 */
export function symmetryTextOf(g: GlobalAnalysisResult | null): string {
  if (g == null) {
    return '∅';
  }
  if (g.symmetry === 'even') {
    return '偶函数（关于 y 轴对称）';
  }
  if (g.symmetry === 'odd') {
    return '奇函数（关于原点对称）';
  }
  return '无';
}

/** 周期性文本 */
export function periodTextOf(g: GlobalAnalysisResult | null): string {
  if (g == null) {
    return '∅';
  }
  if (g.period == null) {
    return '非周期函数';
  }
  return 'T = ' + fmtPi(g.period);
}

/** 增长阶分类码 */
type GrowthClass = 'constant' | 'bounded' | 'logarithmic' | 'linear' | 'polynomial' | 'exponential' | 'unknown';

/** 增长阶文本 */
export function growthTextOf(g: GlobalAnalysisResult | null): string {
  if (g == null) {
    return '∅';
  }
  const gc: GrowthClass = g.growthClass as GrowthClass;
  switch (gc) {
    case 'constant':
      return '常量';
    case 'bounded':
      return '有界（不趋于无穷）';
    case 'logarithmic':
      return '对数增长 ~ ln x';
    case 'linear':
      return '线性增长 ~ x';
    case 'polynomial':
      return '多项式增长 ~ xⁿ';
    case 'exponential':
      return '指数增长 ~ eˣ';
    default:
      return '未知';
  }
}
