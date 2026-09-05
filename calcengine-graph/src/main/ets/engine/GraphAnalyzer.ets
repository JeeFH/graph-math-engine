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
// calcengine-graph/src/main/ets/engine/GraphAnalyzer.ets
/**
 * 函数分析引擎（#13）
 *
 * 在给定视口内对单条函数做数值分析：
 * - 零点：采样相邻符号变化 → 二分细化；要求两侧采样值相对函数典型幅度足够小，
 *   以滤除 tan / 1/x 等渐近线穿越造成的“伪零点”。
 * - 极值：中心差分数值导数，导数变号且函数值有限处为候选；按导数符号变化
 *   分类极大/极小，并在微小邻域内细采样精确定位。
 * - 定义域：扫描采样点，收集“连续有限（有定义）”的最大区间（断点/渐近线处断开）。
 * - 值域：在所有“有定义”采样点中取 y 的最小/最大值。
 *
 * 所有结果均为“世界坐标”，与视口无关 → 平移/缩放时只需重新映射，无需重算。
 */

import { FunctionEvaluator } from './FunctionEvaluator';
import { Viewport } from '../math/GraphMath';

/** 世界坐标点 */
export interface GraphPoint {
  x: number;
  y: number;
}

/** 极值点（含类型） */
export interface Extremum extends GraphPoint {
  kind: 'max' | 'min';
}

/** 单条函数的分析结果 */
export interface AnalysisResult {
  /** 零点（y≈0） */
  zeros: GraphPoint[];
  /** 极值点 */
  extrema: Extremum[];
  /** 定义域：连续“有定义（有限实数）”区间（世界坐标 [lo, hi]），超出视口端以 ±∞ 表示 */
  domain: Array<[number, number]>;
  /** 值域：所有有限 y 的最小/最大值（世界坐标） */
  range: [number, number];
}

export class GraphAnalyzer {
  /**
   * 分析函数。
   * @param expr 表达式
   * @param vp 当前视口（决定采样 x 范围与最值范围）
   * @param isDeg 角度模式
   * @param steps 采样点数（越大越精确，默认 2000）
   * @returns 分析结果；解析失败或全段非有限时返回 null
   */
  static analyze(expr: string, vp: Viewport, isDeg: boolean, steps: number = 2000): AnalysisResult | null {
    let ev: FunctionEvaluator;
    try {
      ev = new FunctionEvaluator(expr, isDeg);
    } catch (e) {
      return null;
    }
    if (!ev.isValid) {
      return null;
    }

    const n: number = Math.max(2, Math.floor(steps));
    const xs: number[] = new Array<number>(n + 1);
    const ys: number[] = new Array<number>(n + 1);
    let anyFinite: boolean = false;
    for (let i = 0; i <= n; i++) {
      const x: number = vp.xMin + (i / n) * (vp.xMax - vp.xMin);
      xs[i] = x;
      let y: number;
      try {
        y = ev.evaluate(x);
      } catch (e) {
        y = NaN;
      }
      ys[i] = y;
      if (isFinite(y)) {
        anyFinite = true;
      }
    }
    if (!anyFinite) {
      return null;
    }

    // 典型幅度（|y| 的中位数），用于区分“真实零点（两侧值小）”与“渐近线穿越（两侧值大）”
    const finiteAbs: number[] = [];
    for (let i = 0; i <= n; i++) {
      if (isFinite(ys[i])) {
        finiteAbs.push(Math.abs(ys[i]));
      }
    }
    finiteAbs.sort((a: number, b: number): number => a - b);
    const scale: number = finiteAbs.length > 0
      ? Math.max(finiteAbs[Math.floor(finiteAbs.length / 2)], 1e-6)
      : 1e-6;
    // 两侧采样值均明显小于典型幅度，才视为“穿过零点附近”，否则多半是渐近线
    const ZERO_GATE: number = 20 * scale;

    const zeros: GraphPoint[] = [];
    const extrema: Extremum[] = [];

    // ── 零点 ──
    for (let i = 0; i < n; i++) {
      const y0: number = ys[i];
      const y1: number = ys[i + 1];
      if (!isFinite(y0) || !isFinite(y1)) {
        continue;
      }
      if (Math.abs(y0) <= ZERO_GATE && Math.abs(y1) <= ZERO_GATE && y0 * y1 < 0) {
        // 二分细化根
        let a: number = xs[i];
        let b: number = xs[i + 1];
        let fa: number = y0;
        let fb: number = y1;
        for (let k = 0; k < 60; k++) {
          const m: number = (a + b) / 2;
          let fm: number;
          try {
            fm = ev.evaluate(m);
          } catch (e) {
            fm = NaN;
          }
          if (!isFinite(fm)) {
            break;
          }
          if (fa * fm <= 0) {
            b = m;
            fb = fm;
          } else {
            a = m;
            fa = fm;
          }
          if (Math.abs(b - a) < (vp.xMax - vp.xMin) / n * 1e-3) {
            break;
          }
        }
        const root: number = (a + b) / 2;
        let fmid: number;
        try {
          fmid = ev.evaluate(root);
        } catch (e) {
          fmid = NaN;
        }
        // 真实零点：根处函数值有限且足够接近 0（相对典型幅度）
        if (isFinite(fmid) && Math.abs(fmid) < 1e-2 * scale + 1e-6) {
          if (zeros.length === 0 || Math.abs(zeros[zeros.length - 1].x - root) > 1e-9) {
            zeros.push({ x: root, y: 0 });
          }
        }
      }
    }

    // ── 极值（导数变号）──
    const EXT_GATE: number = 50 * scale;
    for (let i = 1; i < n; i++) {
      const yp: number = ys[i - 1];
      const yc: number = ys[i];
      const yn: number = ys[i + 1];
      if (!isFinite(yp) || !isFinite(yc) || !isFinite(yn)) {
        continue;
      }
      const d1: number = (yc - yp) / (xs[i] - xs[i - 1]);
      const d2: number = (yn - yc) / (xs[i + 1] - xs[i]);
      if (d1 * d2 < 0) {
        // 候选极值点：函数在候选处幅值不应过大（排除渐近线附近的导数符号抖动）
        if (Math.abs(yc) > EXT_GATE) {
          continue;
        }
        let kind: 'max' | 'min';
        if (d1 > 0 && d2 < 0) {
          kind = 'max'; // 增 → 减
        } else if (d1 < 0 && d2 > 0) {
          kind = 'min'; // 减 → 增
        } else {
          continue;
        }
        // 在微小邻域内细采样精确定位极值（取最值点）
        const lo: number = xs[i - 1];
        const hi: number = xs[i + 1];
        const refine: number = 24;
        let bestX: number = xs[i];
        let bestY: number = yc;
        for (let r = 0; r <= refine; r++) {
          const rx: number = lo + (r / refine) * (hi - lo);
          let ry: number;
          try {
            ry = ev.evaluate(rx);
          } catch (e) {
            ry = NaN;
          }
          if (!isFinite(ry)) {
            continue;
          }
          if (kind === 'max' ? ry > bestY : ry < bestY) {
            bestY = ry;
            bestX = rx;
          }
        }
        if (extrema.length === 0 || Math.abs(extrema[extrema.length - 1].x - bestX) > 1e-6) {
          extrema.push({ x: bestX, y: bestY, kind });
        }
      }
    }

    // ── 定义域 / 值域 ──
    // 定义域：扫描采样点，收集“连续有限（有定义）”的最大区间
    const domains: Array<[number, number]> = [];
    let curLo: number = NaN;
    let curHi: number = NaN;
    for (let i = 0; i <= n; i++) {
      if (isFinite(ys[i])) {
        if (isNaN(curLo)) {
          curLo = xs[i];
          curHi = xs[i];
        } else {
          curHi = xs[i];
        }
      } else if (!isNaN(curLo)) {
        domains.push([curLo, curHi]);
        curLo = NaN;
        curHi = NaN;
      }
    }
    if (!isNaN(curLo)) {
      domains.push([curLo, curHi]);
    }

    // 值域：在所有“有定义”采样点中取 y 的最小 / 最大值
    let rMin: number = Infinity;
    let rMax: number = -Infinity;
    for (let i = 0; i <= n; i++) {
      if (isFinite(ys[i])) {
        if (ys[i] < rMin) {
          rMin = ys[i];
        }
        if (ys[i] > rMax) {
          rMax = ys[i];
        }
      }
    }
    if (!isFinite(rMin)) {
      rMin = 0;
      rMax = 0;
    }

    return {
      zeros,
      extrema,
      domain: domains,
      range: [rMin, rMax]
    };
  }
}
