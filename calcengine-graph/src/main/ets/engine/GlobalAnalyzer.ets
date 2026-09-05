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
// calcengine-graph/src/main/ets/engine/GlobalAnalyzer.ets
/**
 * 全局函数分析引擎（视口无关）
 *
 * 与 GraphAnalyzer（视口采样、供特殊点标记渲染）职责分离：
 * 本引擎在「函数自身特征尺度」上采样，得到不随视口变化的全局性质：
 * - 定义域：区间数组 + 开闭端点（修复 1/x 误显示为 ±0.01 闭区间的问题）
 * - 值域：基于极值 + 端点极限的真实取值范围（区间数组，支持多段并集）
 * - 渐近线：垂直 / 水平 / 斜
 * - 凹凸性：凹/凸区间 + 拐点
 * - 对称性：偶 / 奇 / 无
 * - 周期性：最小正周期
 * - 曲率：最大曲率点
 * - 增长阶：x→∞ 时的增长分类
 *
 * 数值近似（非符号 CAS）：对常见初等函数精确；极窄未定义区域/超高频振荡可能遗漏。
 */

import { FunctionEvaluator } from './FunctionEvaluator';
import { GraphPoint, Extremum } from './GraphAnalyzer';

/** 带开闭标志的区间（lo/hi 可为 ±Infinity） */
export interface DomainInterval {
  lo: number;
  hi: number;
  loOpen: boolean;
  hiOpen: boolean;
}

/** 水平渐近线 y = y（xDir: +1 = x→+∞，-1 = x→-∞） */
export interface HorizontalAsymptote {
  xDir: number;
  y: number;
}

/** 斜渐近线 y = kx + b */
export interface ObliqueAsymptote {
  xDir: number;
  k: number;
  b: number;
}

/** 渐近线集合 */
export interface Asymptotes {
  vertical: number[];
  horizontal: HorizontalAsymptote[];
  oblique: ObliqueAsymptote[];
}

/** 凹凸性分析结果 */
export interface Concavity {
  /** 拐点 */
  inflections: GraphPoint[];
  /** f'' > 0（凹，开口向上） */
  concaveUp: DomainInterval[];
  /** f'' < 0（凸，开口向下） */
  concaveDown: DomainInterval[];
}

/** 对称性 */
export type SymmetryKind = 'even' | 'odd' | 'none';

/** 增长阶分类码 */
export type GrowthClass = 'constant' | 'bounded' | 'logarithmic' | 'linear' | 'polynomial' | 'exponential' | 'unknown';

/** 全局分析结果 */
export interface GlobalAnalysisResult {
  domain: DomainInterval[];
  range: DomainInterval[];
  zeros: GraphPoint[];
  extrema: Extremum[];
  asymptotes: Asymptotes;
  concavity: Concavity;
  symmetry: SymmetryKind;
  /** 最小正周期；非周期为 null */
  period: number | null;
  /** 周期函数：一个周期内的无定义点（定义域 = ℝ 去掉 {p + kT}）；非周期为空数组 */
  periodHoles: number[];
  maxCurvature: GraphPoint | null;
  /** 最大曲率点处的曲率值 κ = |f''| / (1 + f'²)^1.5（maxCurvature 为 null 时为 0） */
  maxCurvatureKappa: number;
  growthClass: GrowthClass;
}

/** 定义域扫描中间结果（含极点位置，供垂直渐近线复用） */
interface DomainScan {
  intervals: DomainInterval[];
  poles: number[];
}

/** 曲率检测内部结果（最大曲率点 + 该点曲率值 κ） */
interface CurvatureResult {
  point: GraphPoint | null;
  kappa: number;
}

export class GlobalAnalyzer {
  /** 非周期函数的分析窗口半宽 */
  private static readonly WINDOW: number = 100;
  /** 非周期函数采样点数 */
  private static readonly N_APERIODIC: number = 10000;
  /** 周期函数单周期采样点数 */
  private static readonly N_PERIODIC: number = 4000;

  /**
   * 全局分析入口。
   * @returns 分析结果；解析失败或全段无定义返回 null
   */
  static analyzeGlobal(expr: string, isDeg: boolean): GlobalAnalysisResult | null {
    let ev: FunctionEvaluator;
    try {
      ev = new FunctionEvaluator(expr, isDeg);
    } catch (e) {
      return null;
    }
    if (!ev.isValid) {
      return null;
    }

    // 1. 周期性检测 → 决定分析窗口
    const period: number | null = GlobalAnalyzer.detectPeriod(ev);
    let w0: number;
    let w1: number;
    let n: number;
    if (period != null) {
      const win: number[] = GlobalAnalyzer.choosePeriodicWindow(ev, period);
      w0 = win[0];
      w1 = win[1];
      n = GlobalAnalyzer.N_PERIODIC;
    } else {
      w0 = -GlobalAnalyzer.WINDOW;
      w1 = GlobalAnalyzer.WINDOW;
      n = GlobalAnalyzer.N_APERIODIC;
    }

    // 2. 稠密采样
    const xs: number[] = new Array<number>(n + 1);
    const ys: number[] = new Array<number>(n + 1);
    let anyFinite: boolean = false;
    for (let i = 0; i <= n; i++) {
      const x: number = w0 + (i / n) * (w1 - w0);
      xs[i] = x;
      const y: number = GlobalAnalyzer.feval(ev, x);
      ys[i] = y;
      if (isFinite(y)) {
        anyFinite = true;
      }
    }
    if (!anyFinite) {
      return null;
    }
    const scale: number = GlobalAnalyzer.typicalScale(ys);

    // 3. 定义域（含极点）
    const scan: DomainScan = GlobalAnalyzer.detectDomain(ev, xs, ys, scale, period != null);
    const domain: DomainInterval[] = scan.intervals;

    // 3.5 周期函数：收集一个周期内的无定义点（定义域区间的内部边界），
    //     用于把定义域表达为 ℝ（无洞）或 x ≠ p + kT（有洞），而非局限在单周期窗口。
    let periodHoles: number[] = [];
    if (period != null) {
      const holeEps: number = (w1 - w0) * 1e-6;
      const rawHoles: number[] = [];
      for (let k = 0; k < domain.length; k++) {
        const d: DomainInterval = domain[k];
        if (isFinite(d.lo) && d.lo > w0 + holeEps && d.lo < w1 - holeEps) {
          rawHoles.push(d.lo);
        }
        if (isFinite(d.hi) && d.hi > w0 + holeEps && d.hi < w1 - holeEps) {
          rawHoles.push(d.hi);
        }
      }
      rawHoles.sort((a: number, b: number): number => a - b);
      for (let k = 0; k < rawHoles.length; k++) {
        if (periodHoles.length === 0 ||
          Math.abs(periodHoles[periodHoles.length - 1] - rawHoles[k]) > 1e-9) {
          periodHoles.push(rawHoles[k]);
        }
      }
    }

    // 4. 零点 / 极值（分析窗口内）
    const zeros: GraphPoint[] = GlobalAnalyzer.detectZeros(ev, xs, ys, scale);
    const extrema: Extremum[] = GlobalAnalyzer.detectExtrema(ev, xs, ys, scale);

    // 5. 值域
    const range: DomainInterval[] = GlobalAnalyzer.detectRange(ev, domain, extrema);

    // 6. 渐近线
    const asymptotes: Asymptotes = GlobalAnalyzer.detectAsymptotes(ev, domain, scan.poles, period != null);

    // 7. 凹凸性
    const concavity: Concavity = GlobalAnalyzer.detectConcavity(ev, xs, ys);

    // 8. 对称性
    const symmetry: SymmetryKind = GlobalAnalyzer.detectSymmetry(ev, scale);

    // 9. 曲率
    const curv: CurvatureResult = GlobalAnalyzer.detectCurvature(ev, xs, ys);

    // 10. 增长阶
    const growthClass: GrowthClass = GlobalAnalyzer.detectGrowth(ev);

    return {
      domain,
      range,
      zeros,
      extrema,
      asymptotes,
      concavity,
      symmetry,
      period,
      periodHoles,
      maxCurvature: curv.point,
      maxCurvatureKappa: curv.kappa,
      growthClass
    };
  }

  // ================= 基础工具 =================

  /** 安全求值（异常 → NaN） */
  private static feval(ev: FunctionEvaluator, x: number): number {
    try {
      return ev.evaluate(x);
    } catch (e) {
      return NaN;
    }
  }

  /** 典型幅度：|y| 的中位数（用于各类门控） */
  private static typicalScale(ys: number[]): number {
    const finiteAbs: number[] = [];
    for (let i = 0; i < ys.length; i++) {
      if (isFinite(ys[i])) {
        finiteAbs.push(Math.abs(ys[i]));
      }
    }
    if (finiteAbs.length === 0) {
      return 1e-6;
    }
    finiteAbs.sort((a: number, b: number): number => a - b);
    return Math.max(finiteAbs[Math.floor(finiteAbs.length / 2)], 1e-6);
  }

  /**
   * 把接近「漂亮数值」的边界吸附过去（整数 / π/12 的整数倍），
   * 以便在精确点求值判定开闭、并得到干净的显示值。
   */
  private static snapValue(c: number): number | null {
    const tol: number = 1e-6;
    const ni: number = Math.round(c);
    if (Math.abs(c - ni) < tol) {
      return ni;
    }
    const step: number = Math.PI / 12;
    const k: number = Math.round(c / step);
    const cand: number = k * step;
    if (Math.abs(c - cand) < tol) {
      return cand;
    }
    return null;
  }

  // ================= 周期性 =================

  /**
   * 自相关检测最小正周期。
   * 采样 [-40,40]，截断大幅值（抗渐近线），均值中心化后求归一化自相关，
   * 取第一个 R>0.9 的局部峰为候选周期，再做 f(x+T)≈f(x) 直接验证。
   */
  private static detectPeriod(ev: FunctionEvaluator): number | null {
    const half: number = 40;
    const dx: number = 0.02;
    const n: number = Math.floor(2 * half / dx);
    const raw: number[] = new Array<number>(n + 1);
    let anyFin: boolean = false;
    for (let i = 0; i <= n; i++) {
      const y: number = GlobalAnalyzer.feval(ev, -half + i * dx);
      raw[i] = y;
      if (isFinite(y)) {
        anyFin = true;
      }
    }
    if (!anyFin) {
      return null;
    }
    const scale: number = GlobalAnalyzer.typicalScale(raw);
    const cap: number = 10 * scale;

    // 截断 + 均值中心化（非有限值置 0，能量低不影响主周期判定）
    const y: number[] = new Array<number>(n + 1);
    let mean: number = 0;
    let cnt: number = 0;
    for (let i = 0; i <= n; i++) {
      let v: number = raw[i];
      if (!isFinite(v)) {
        v = 0;
      } else {
        if (v > cap) {
          v = cap;
        }
        if (v < -cap) {
          v = -cap;
        }
      }
      y[i] = v;
      mean += v;
      cnt++;
    }
    mean = mean / cnt;
    let energy: number = 0;
    for (let i = 0; i <= n; i++) {
      y[i] = y[i] - mean;
      energy += y[i] * y[i];
    }
    if (energy < 1e-12) {
      return null; // 常函数
    }

    // 自相关：先离开 lag≈0 的平凡高相关区，再找第一个 R>0.9 的局部峰
    const lMax: number = Math.floor(n / 3);
    const r: number[] = new Array<number>(lMax + 1);
    r[0] = 1;
    for (let lag = 1; lag <= lMax; lag++) {
      let s: number = 0;
      for (let i = 0; i + lag <= n; i++) {
        s += y[i] * y[i + lag];
      }
      r[lag] = s / energy;
    }
    // 平凡区结束：第一个 R<0.9 的 lag（单调/常函数会一直高相关或衰减无峰）
    let lagDrop: number = -1;
    for (let lag = 1; lag <= lMax; lag++) {
      if (r[lag] < 0.9) {
        lagDrop = lag;
        break;
      }
    }
    if (lagDrop < 0) {
      return null;
    }
    // 平凡区之后第一个 R>0.9 的局部峰 → 最小正周期
    let bestLag: number = -1;
    for (let lag = Math.max(lagDrop, 2); lag < lMax; lag++) {
      if (r[lag] > 0.9 && r[lag] >= r[lag - 1] && r[lag] > r[lag + 1]) {
        bestLag = lag;
        break;
      }
    }
    if (bestLag < 0) {
      return null;
    }
    let tCand: number = bestLag * dx;

    // 直接验证 f(x+T) ≈ f(x)
    let ok: number = 0;
    let total: number = 0;
    const tol: number = 1e-2 * scale + 1e-9;
    for (let i = 0; i <= 200; i++) {
      const x: number = -half + (i / 200) * (2 * half - tCand);
      const a: number = GlobalAnalyzer.feval(ev, x);
      const b: number = GlobalAnalyzer.feval(ev, x + tCand);
      if (isFinite(a) && isFinite(b)) {
        total++;
        if (Math.abs(a - b) <= tol + 1e-6 * Math.abs(a)) {
          ok++;
        }
      }
    }
    if (total < 20 || ok / total < 0.9) {
      return null;
    }
    // 周期吸附到漂亮值（整数 / π/12 倍，容差为一个采样步长）
    const tSnap: number | null = GlobalAnalyzer.snapPeriod(tCand, dx);
    return tSnap != null ? tSnap : tCand;
  }

  /** 周期吸附（容差较边界吸附更宽，约一个采样步长） */
  private static snapPeriod(t: number, tol: number): number | null {
    const ni: number = Math.round(t);
    if (Math.abs(t - ni) < tol && ni > 0) {
      return ni;
    }
    const step: number = Math.PI / 12;
    const k: number = Math.round(t / step);
    const cand: number = k * step;
    if (Math.abs(t - cand) < tol && cand > 0) {
      return cand;
    }
    return null;
  }

  /**
   * 为周期函数选取单周期窗口 [x0, x0+T]：
   * 优先 [0, T]；若窗口端点恰好落在极点（|f| 巨大/非有限），平移 T/2 重试。
   */
  private static choosePeriodicWindow(ev: FunctionEvaluator, period: number): number[] {
    const poleMag: number = 1e6;
    const edgeBad = (x: number): boolean => {
      const v: number = GlobalAnalyzer.feval(ev, x);
      return !isFinite(v) || Math.abs(v) > poleMag;
    };
    if (!edgeBad(0) && !edgeBad(period)) {
      return [0, period];
    }
    const s: number = period / 2;
    if (!edgeBad(s) && !edgeBad(s + period)) {
      return [s, s + period];
    }
    // 仍不理想：退回 [0, T]（端点极点将由定义域扫描处理）
    return [0, period];
  }

  // ================= 定义域 =================

  /**
   * 定义域扫描：
   * - 样本非有限 → 未定义点；
   * - 相邻有限样本异号且幅值巨大 → 极点穿越（如 1/x、tan）；
   * - 收集「连续有定义」最大区间，边界二分细化 + 开闭分类；
   * - 非周期函数最外侧区间延伸至 ±∞。
   */
  private static detectDomain(ev: FunctionEvaluator, xs: number[], ys: number[],
    scale: number, isPeriodic: boolean): DomainScan {
    const n: number = xs.length - 1;
    const crossGate: number = 20 * scale;

    // 相邻样本间的极点穿越标志
    const poleCross: boolean[] = new Array<boolean>(n).fill(false);
    for (let i = 0; i < n; i++) {
      const y0: number = ys[i];
      const y1: number = ys[i + 1];
      if (isFinite(y0) && isFinite(y1) && y0 * y1 < 0 &&
        Math.max(Math.abs(y0), Math.abs(y1)) > crossGate) {
        poleCross[i] = true;
      }
    }

    // 收集连续有定义区间（样本下标 [si, ei]）
    const idxIntervals: Array<[number, number]> = [];
    let curStart: number = -1;
    for (let i = 0; i <= n; i++) {
      if (!isFinite(ys[i])) {
        if (curStart >= 0) {
          idxIntervals.push([curStart, i - 1]);
          curStart = -1;
        }
      } else {
        if (curStart < 0) {
          curStart = i;
        }
        if (i < n && poleCross[i]) {
          idxIntervals.push([curStart, i]);
          curStart = -1;
        }
      }
    }
    if (curStart >= 0) {
      idxIntervals.push([curStart, n]);
    }

    const intervals: DomainInterval[] = [];
    const poles: number[] = [];

    for (let k = 0; k < idxIntervals.length; k++) {
      const si: number = idxIntervals[k][0];
      const ei: number = idxIntervals[k][1];

      // 左边界
      let lo: number;
      let loOpen: boolean;
      if (si === 0) {
        if (isPeriodic) {
          lo = xs[0];
          loOpen = false;
        } else {
          lo = -Infinity;
          loOpen = true;
        }
      } else {
        const r: number[] = GlobalAnalyzer.refineBoundary(ev, xs[si - 1], xs[si], poleCross[si - 1]);
        lo = r[0];
        loOpen = r[1] === 1;
        if (poleCross[si - 1]) {
          poles.push(lo);
        }
      }

      // 右边界
      let hi: number;
      let hiOpen: boolean;
      if (ei === n) {
        if (isPeriodic) {
          hi = xs[n];
          hiOpen = false;
        } else {
          hi = Infinity;
          hiOpen = true;
        }
      } else {
        const r: number[] = GlobalAnalyzer.refineBoundary(ev, xs[ei], xs[ei + 1], poleCross[ei]);
        hi = r[0];
        hiOpen = r[1] === 1;
        if (poleCross[ei]) {
          poles.push(hi);
        }
      }

      intervals.push({ lo, hi, loOpen, hiOpen });
    }

    // 去重极点（同一边界可能被左右两个区间各记一次）
    poles.sort((a: number, b: number): number => a - b);
    const uniqPoles: number[] = [];
    for (let i = 0; i < poles.length; i++) {
      if (uniqPoles.length === 0 || Math.abs(uniqPoles[uniqPoles.length - 1] - poles[i]) > 1e-9) {
        uniqPoles.push(poles[i]);
      }
    }

    return { intervals, poles: uniqPoles };
  }

  /**
   * 细化相邻样本 [xA, xB] 之间的间断点。
   * isPole=true：两侧均有定义但异号巨大（极点穿越）→ 符号二分，开区间。
   * isPole=false：一侧非有限 → 二分逼近边界，吸附漂亮值后精确判定开闭，否则趋势判定。
   * @returns [间断点 x, 开=1/闭=0]
   */
  private static refineBoundary(ev: FunctionEvaluator, xA: number, xB: number, isPole: boolean): number[] {
    if (isPole) {
      return [GlobalAnalyzer.refinePole(ev, xA, xB), 1];
    }
    return GlobalAnalyzer.refineEdge(ev, xA, xB);
  }

  /** 极点定位：符号二分（f(a) 与 f(b) 异号且巨大），收敛到极点；命中非有限点直接返回 */
  private static refinePole(ev: FunctionEvaluator, a: number, b: number): number {
    let fa: number = GlobalAnalyzer.feval(ev, a);
    for (let it = 0; it < 80; it++) {
      const m: number = (a + b) / 2;
      const fm: number = GlobalAnalyzer.feval(ev, m);
      if (!isFinite(fm)) {
        const snapped: number | null = GlobalAnalyzer.snapValue(m);
        return snapped != null ? snapped : m;
      }
      if (fa * fm < 0) {
        b = m;
      } else {
        a = m;
        fa = fm;
      }
      if (Math.abs(b - a) < 1e-12 * Math.max(1, Math.abs(a))) {
        break;
      }
    }
    const c: number = (a + b) / 2;
    const snapped: number | null = GlobalAnalyzer.snapValue(c);
    return snapped != null ? snapped : c;
  }

  /**
   * 有限/非有限边界细化：二分逼近后，
   * 1) 吸附漂亮值并精确求值判定开闭；
   * 2) 否则从有定义侧做趋势测试（趋近时 |f| 显著增大 → 发散 → 开）。
   * @returns [边界 x, 开=1/闭=0]
   */
  private static refineEdge(ev: FunctionEvaluator, xA: number, xB: number): number[] {
    let a: number = xA;
    let b: number = xB;
    if (!isFinite(GlobalAnalyzer.feval(ev, a))) {
      const t: number = a;
      a = b;
      b = t;
    }
    // 此时 f(a) 有限，f(b) 非有限
    for (let it = 0; it < 80; it++) {
      const m: number = (a + b) / 2;
      const fm: number = GlobalAnalyzer.feval(ev, m);
      if (isFinite(fm)) {
        a = m;
      } else {
        b = m;
      }
      if (Math.abs(b - a) < 1e-12 * Math.max(1, Math.abs(a))) {
        break;
      }
    }
    const c: number = (a + b) / 2;
    const snapped: number | null = GlobalAnalyzer.snapValue(c);
    if (snapped != null) {
      return [snapped, isFinite(GlobalAnalyzer.feval(ev, snapped)) ? 0 : 1];
    }
    // 趋势测试：从有定义侧（a 所在侧）趋近边界
    const dir: number = a >= c ? 1 : -1;
    const eps: number = 1e-6 * Math.max(1, Math.abs(c));
    const f1: number = GlobalAnalyzer.feval(ev, c + dir * eps);
    const f2: number = GlobalAnalyzer.feval(ev, c + dir * eps / 1000);
    let open: boolean;
    if (!isFinite(f2)) {
      open = true;
    } else if (isFinite(f1)) {
      open = Math.abs(f2) > Math.abs(f1) * 1.3 && Math.abs(f2) > Math.abs(f1) + 1e-6;
    } else {
      open = true;
    }
    return [c, open ? 1 : 0];
  }

  // ================= 零点 / 极值 =================

  /** 零点：符号变化 + 幅值门控（滤除渐近线穿越）+ 二分细化 */
  private static detectZeros(ev: FunctionEvaluator, xs: number[], ys: number[], scale: number): GraphPoint[] {
    const n: number = xs.length - 1;
    const gate: number = 20 * scale;
    const zeros: GraphPoint[] = [];
    for (let i = 0; i < n; i++) {
      const y0: number = ys[i];
      const y1: number = ys[i + 1];
      if (!isFinite(y0) || !isFinite(y1)) {
        continue;
      }
      if (Math.abs(y0) <= gate && Math.abs(y1) <= gate && y0 * y1 < 0) {
        let a: number = xs[i];
        let b: number = xs[i + 1];
        let fa: number = y0;
        for (let k = 0; k < 60; k++) {
          const m: number = (a + b) / 2;
          const fm: number = GlobalAnalyzer.feval(ev, m);
          if (!isFinite(fm)) {
            break;
          }
          if (fa * fm <= 0) {
            b = m;
          } else {
            a = m;
            fa = fm;
          }
          if (Math.abs(b - a) < (xs[n] - xs[0]) / n * 1e-3) {
            break;
          }
        }
        const root: number = (a + b) / 2;
        const fmid: number = GlobalAnalyzer.feval(ev, root);
        if (isFinite(fmid) && Math.abs(fmid) < 1e-2 * scale + 1e-6) {
          if (zeros.length === 0 || Math.abs(zeros[zeros.length - 1].x - root) > 1e-9) {
            zeros.push({ x: root, y: 0 });
          }
        }
      }
    }
    return zeros;
  }

  /** 极值：中心差分导数变号 + 幅值门控 + 邻域细化 */
  private static detectExtrema(ev: FunctionEvaluator, xs: number[], ys: number[], scale: number): Extremum[] {
    const n: number = xs.length - 1;
    const gate: number = 50 * scale;
    const extrema: Extremum[] = [];
    for (let i = 1; i < n; i++) {
      const yp: number = ys[i - 1];
      const yc: number = ys[i];
      const yn: number = ys[i + 1];
      if (!isFinite(yp) || !isFinite(yc) || !isFinite(yn)) {
        continue;
      }
      const d1: number = (yc - yp) / (xs[i] - xs[i - 1]);
      const d2: number = (yn - yc) / (xs[i + 1] - xs[i]);
      if (d1 * d2 >= 0) {
        continue;
      }
      if (Math.abs(yc) > gate) {
        continue;
      }
      let kind: 'max' | 'min';
      if (d1 > 0 && d2 < 0) {
        kind = 'max';
      } else if (d1 < 0 && d2 > 0) {
        kind = 'min';
      } else {
        continue;
      }
      const lo: number = xs[i - 1];
      const hi: number = xs[i + 1];
      let bestX: number = xs[i];
      let bestY: number = yc;
      for (let r = 0; r <= 24; r++) {
        const rx: number = lo + (r / 24) * (hi - lo);
        const ry: number = GlobalAnalyzer.feval(ev, rx);
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
    return extrema;
  }

  // ================= 值域 =================

  /**
   * 值域：对每个定义域片段（连续区间），收集极值点函数值 + 端点值/极限，
   * 取最值并按「是否可达」定开闭，最后跨片段合并。
   */
  private static detectRange(ev: FunctionEvaluator, domain: DomainInterval[],
    extrema: Extremum[]): DomainInterval[] {
    const pieces: DomainInterval[] = [];
    for (let k = 0; k < domain.length; k++) {
      const d: DomainInterval = domain[k];
      const piece: DomainInterval | null = GlobalAnalyzer.rangeOfPiece(ev, d, extrema);
      if (piece != null) {
        pieces.push(piece);
      }
    }
    // 周期函数单片段的值域即全局值域；非周期跨片段合并 —— 统一由 mergeIntervals 处理
    return GlobalAnalyzer.mergeIntervals(pieces);
  }

  /** 单个定义域片段的值域（连续函数在区间上的最值 = 极值/端点） */
  private static rangeOfPiece(ev: FunctionEvaluator, d: DomainInterval, extrema: Extremum[]): DomainInterval | null {
    // 候选值：[值, 是否可达(1/0)]
    const candVals: number[] = [];
    const candAch: boolean[] = [];

    // 区间内极值
    for (let i = 0; i < extrema.length; i++) {
      const ex: Extremum = extrema[i];
      if (ex.x > d.lo && ex.x < d.hi) {
        candVals.push(ex.y);
        candAch.push(true);
      }
    }

    // 左端点
    if (d.lo === -Infinity) {
      const lim: number[] = GlobalAnalyzer.limitAtInfinity(ev, -1);
      if (lim[0] === 1) {
        candVals.push(lim[1]);
        candAch.push(false);
      } else if (lim[0] === 2) {
        candVals.push(Infinity);
        candAch.push(false);
      } else if (lim[0] === 3) {
        candVals.push(-Infinity);
        candAch.push(false);
      }
    } else if (!d.loOpen) {
      const v: number = GlobalAnalyzer.feval(ev, d.lo);
      if (isFinite(v)) {
        candVals.push(v);
        candAch.push(true);
      }
    } else {
      const lim: number[] = GlobalAnalyzer.limitAtPoint(ev, d.lo, 1);
      if (lim[0] === 1) {
        candVals.push(lim[1]);
        candAch.push(false);
      } else if (lim[0] === 2) {
        candVals.push(Infinity);
        candAch.push(false);
      } else if (lim[0] === 3) {
        candVals.push(-Infinity);
        candAch.push(false);
      }
    }

    // 右端点
    if (d.hi === Infinity) {
      const lim: number[] = GlobalAnalyzer.limitAtInfinity(ev, 1);
      if (lim[0] === 1) {
        candVals.push(lim[1]);
        candAch.push(false);
      } else if (lim[0] === 2) {
        candVals.push(Infinity);
        candAch.push(false);
      } else if (lim[0] === 3) {
        candVals.push(-Infinity);
        candAch.push(false);
      }
    } else if (!d.hiOpen) {
      const v: number = GlobalAnalyzer.feval(ev, d.hi);
      if (isFinite(v)) {
        candVals.push(v);
        candAch.push(true);
      }
    } else {
      const lim: number[] = GlobalAnalyzer.limitAtPoint(ev, d.hi, -1);
      if (lim[0] === 1) {
        candVals.push(lim[1]);
        candAch.push(false);
      } else if (lim[0] === 2) {
        candVals.push(Infinity);
        candAch.push(false);
      } else if (lim[0] === 3) {
        candVals.push(-Infinity);
        candAch.push(false);
      }
    }

    if (candVals.length === 0) {
      return null;
    }

    let rMin: number = Infinity;
    let rMax: number = -Infinity;
    let minAch: boolean = false;
    let maxAch: boolean = false;
    for (let i = 0; i < candVals.length; i++) {
      const v: number = candVals[i];
      if (v < rMin) {
        rMin = v;
        minAch = candAch[i];
      } else if (v === rMin && candAch[i]) {
        minAch = true;
      }
      if (v > rMax) {
        rMax = v;
        maxAch = candAch[i];
      } else if (v === rMax && candAch[i]) {
        maxAch = true;
      }
    }
    if (rMin === Infinity || rMax === -Infinity) {
      return null;
    }
    // 数值噪声吸附（如 tan(π)≈-1e-16 → 0），保证相邻片段在相同点正确合并
    const snapLo: number | null = GlobalAnalyzer.snapValue(rMin);
    if (snapLo != null) {
      rMin = snapLo;
    }
    const snapHi: number | null = GlobalAnalyzer.snapValue(rMax);
    if (snapHi != null) {
      rMax = snapHi;
    }
    return {
      lo: rMin,
      hi: rMax,
      loOpen: rMin === -Infinity || !minAch,
      hiOpen: rMax === Infinity || !maxAch
    };
  }

  /**
   * x → s·∞ 时的极限。
   * @returns [类型码(1=有限/2=+∞/3=-∞/0=无极限或有界振荡), 有限时的极限值]
   */
  private static limitAtInfinity(ev: FunctionEvaluator, s: number): number[] {
    const probes: number[] = [1e2, 1e3, 1e4, 1e5, 1e6];
    const vals: number[] = [];
    for (let i = 0; i < probes.length; i++) {
      vals.push(GlobalAnalyzer.feval(ev, s * probes[i]));
    }
    // 发散判定：是否出现 ±∞
    let sawInf: number = 0; // +1 / -1
    for (let i = 0; i < vals.length; i++) {
      const v: number = vals[i];
      if (v === Infinity) {
        sawInf = 1;
      } else if (v === -Infinity) {
        sawInf = -1;
      }
    }
    if (sawInf === 1) {
      return [2, 0];
    }
    if (sawInf === -1) {
      return [3, 0];
    }
    // 全有限：检查收敛
    let allFinite: boolean = true;
    for (let i = 0; i < vals.length; i++) {
      if (!isFinite(vals[i])) {
        allFinite = false;
      }
    }
    if (!allFinite) {
      return [0, 0]; // NaN（如 sqrt(-∞)）→ 无定义
    }
    const d1: number = Math.abs(vals[4] - vals[3]);
    const d2: number = Math.abs(vals[3] - vals[2]);
    const mag: number = Math.abs(vals[4]);
    // 末两步差值相对很小 → 收敛
    const tolConv: number = 1e-3 * Math.max(1, mag);
    if (d1 < tolConv && d2 < tolConv * 10) {
      return [1, vals[4]];
    }
    // 发散：幅值单调持续增长（覆盖 x² 等快发散与 ln/sqrt 等慢发散）
    const m1: number = Math.abs(vals[1]);
    const m2: number = Math.abs(vals[2]);
    const m3: number = Math.abs(vals[3]);
    if (mag > m3 && m3 > m2 && m2 > m1 && mag > 10 && mag > 1.5 * m1) {
      return vals[4] > 0 ? [2, 0] : [3, 0];
    }
    // 有界振荡（如 sin）→ 无单极限
    return [0, 0];
  }

  /**
   * x → c（从 dir 侧趋近）的极限。用于开区间端点（极点/可去间断）。
   * @returns [类型码(1=有限/2=+∞/3=-∞/0=未知), 有限时的极限值]
   */
  private static limitAtPoint(ev: FunctionEvaluator, c: number, dir: number): number[] {
    const base: number = 1e-3 * Math.max(1, Math.abs(c));
    const deltas: number[] = [base, base / 10, base / 100, base / 1000, base / 10000];
    const vals: number[] = [];
    for (let i = 0; i < deltas.length; i++) {
      vals.push(GlobalAnalyzer.feval(ev, c + dir * deltas[i]));
    }
    const last: number = vals[4];
    if (last === Infinity) {
      return [2, 0];
    }
    if (last === -Infinity) {
      return [3, 0];
    }
    if (!isFinite(last)) {
      return [0, 0];
    }
    // 幅值持续增大 → 发散
    if (Math.abs(vals[4]) > Math.abs(vals[3]) && Math.abs(vals[3]) > Math.abs(vals[2]) && Math.abs(vals[4]) > 1e6) {
      return vals[4] > 0 ? [2, 0] : [3, 0];
    }
    // 收敛
    const d1: number = Math.abs(vals[4] - vals[3]);
    const tol: number = 1e-3 * Math.max(1, Math.abs(last));
    if (d1 < tol) {
      return [1, last];
    }
    // 缓慢发散（如 ln）：仍在增大但幅度不巨大 → 视最末值符号判定发散
    if (Math.abs(vals[4]) > Math.abs(vals[2]) * 1.3) {
      return vals[4] > 0 ? [2, 0] : [3, 0];
    }
    return [1, last];
  }

  /** 合并重叠/相邻的值域区间（相邻但双开于同一点 → 保留间隙，如 (-∞,0)∪(0,∞)） */
  private static mergeIntervals(intervals: DomainInterval[]): DomainInterval[] {
    if (intervals.length <= 1) {
      return intervals;
    }
    const sorted: DomainInterval[] = intervals.slice().sort((a: DomainInterval, b: DomainInterval): number => a.lo - b.lo);
    const merged: DomainInterval[] = [sorted[0]];
    for (let i = 1; i < sorted.length; i++) {
      const cur: DomainInterval = sorted[i];
      const last: DomainInterval = merged[merged.length - 1];
      const overlap: boolean = cur.lo < last.hi ||
        (cur.lo === last.hi && !(cur.loOpen && last.hiOpen));
      if (overlap) {
        if (cur.hi > last.hi) {
          last.hi = cur.hi;
          last.hiOpen = cur.hiOpen;
        } else if (cur.hi === last.hi) {
          last.hiOpen = last.hiOpen && cur.hiOpen;
        }
      } else {
        merged.push(cur);
      }
    }
    return merged;
  }

  // ================= 渐近线 =================

  /**
   * 渐近线：
   * - 垂直：定义域扫描得到的极点（f→±∞ 的有限 x）；
   * - 水平：x→±∞ 的有限极限；
   * - 斜：k = lim f/x（有限且非 0），b = lim (f − kx)。
   */
  private static detectAsymptotes(ev: FunctionEvaluator, domain: DomainInterval[],
    poles: number[], isPeriodic: boolean): Asymptotes {
    const vertical: number[] = poles.slice();
    const horizontal: HorizontalAsymptote[] = [];
    const oblique: ObliqueAsymptote[] = [];

    // 周期函数在 ±∞ 处无极限（振荡/重复），不产生水平/斜渐近线
    if (!isPeriodic) {
      const dirs: number[] = [-1, 1];
      for (let di = 0; di < dirs.length; di++) {
        const s: number = dirs[di];
        // 仅当定义域确实延伸到该方向无穷时才检测
        let extendsInf: boolean = false;
        for (let k = 0; k < domain.length; k++) {
          if ((s === -1 && domain[k].lo === -Infinity) || (s === 1 && domain[k].hi === Infinity)) {
            extendsInf = true;
          }
        }
        if (!extendsInf) {
          continue;
        }
        const lim: number[] = GlobalAnalyzer.limitAtInfinity(ev, s);
        if (lim[0] === 1) {
          horizontal.push({ xDir: s, y: lim[1] });
        } else if (lim[0] === 2 || lim[0] === 0) {
          // 发散或振荡：尝试斜渐近线 k = lim f(x)/x
          const kLim: number[] = GlobalAnalyzer.limitRatio(ev, s);
          if (kLim[0] === 1 && Math.abs(kLim[1]) > 1e-9) {
            const k: number = kLim[1];
            const bLim: number[] = GlobalAnalyzer.limitShifted(ev, s, k);
            if (bLim[0] === 1) {
              oblique.push({ xDir: s, k, b: bLim[1] });
            }
          }
        }
      }
    }

    return { vertical, horizontal, oblique };
  }

  /** k = lim_{x→s·∞} f(x)/x */
  private static limitRatio(ev: FunctionEvaluator, s: number): number[] {
    const probes: number[] = [1e2, 1e3, 1e4, 1e5];
    const vals: number[] = [];
    for (let i = 0; i < probes.length; i++) {
      const x: number = s * probes[i];
      const v: number = GlobalAnalyzer.feval(ev, x);
      vals.push(v / x);
    }
    let allFin: boolean = true;
    for (let i = 0; i < vals.length; i++) {
      if (!isFinite(vals[i])) {
        allFin = false;
      }
    }
    if (!allFin) {
      return [0, 0];
    }
    const d: number = Math.abs(vals[3] - vals[2]);
    if (d < 1e-2 * Math.max(1, Math.abs(vals[3]))) {
      return [1, vals[3]];
    }
    return [0, 0];
  }

  /** b = lim_{x→s·∞} (f(x) − kx) */
  private static limitShifted(ev: FunctionEvaluator, s: number, k: number): number[] {
    const probes: number[] = [1e2, 1e3, 1e4];
    const vals: number[] = [];
    for (let i = 0; i < probes.length; i++) {
      const x: number = s * probes[i];
      vals.push(GlobalAnalyzer.feval(ev, x) - k * x);
    }
    let allFin: boolean = true;
    for (let i = 0; i < vals.length; i++) {
      if (!isFinite(vals[i])) {
        allFin = false;
      }
    }
    if (!allFin) {
      return [0, 0];
    }
    const d: number = Math.abs(vals[2] - vals[1]);
    if (d < 1e-2 * Math.max(1, Math.abs(vals[2]))) {
      return [1, vals[2]];
    }
    return [0, 0];
  }

  // ================= 凹凸性 =================

  /**
   * 凹凸性：中心差分二阶导 f''，变号点二分细化为拐点；
   * 按 f'' 符号收集凹（f''>0）/凸（f''<0）区间。
   */
  private static detectConcavity(ev: FunctionEvaluator, xs: number[], ys: number[]): Concavity {
    const n: number = xs.length - 1;
    const h: number = (xs[n] - xs[0]) / n;
    // 二阶导样本
    const d2: number[] = new Array<number>(n + 1).fill(NaN);
    for (let i = 1; i < n; i++) {
      const yp: number = ys[i - 1];
      const yc: number = ys[i];
      const yn: number = ys[i + 1];
      if (isFinite(yp) && isFinite(yc) && isFinite(yn)) {
        d2[i] = (yn - 2 * yc + yp) / (h * h);
      }
    }

    const inflections: GraphPoint[] = [];
    const concaveUp: DomainInterval[] = [];
    const concaveDown: DomainInterval[] = [];

    // 噪声底：基于函数尺度的绝对阈值，替代失效的相对门控
    // 验证：一次函数 f=2x+1 → d2Noise≈2.5e-3 ≫ 浮点噪声 1e-10 → 全间隙（正确）
    //       x² (f''=2) → d2Noise≈0.0625 < 2 → 正常检出；sin → d2Noise≈2e-3 < 1 → 正常
    const yScale: number = GlobalAnalyzer.typicalScale(ys);
    const d2Noise: number = Math.max(1e-8 * yScale / (h * h), 1e-12);

    // 拐点：d2 变号（且两侧幅值均显著超过噪声底，排除渐近线附近抖动与近线性函数噪声）
    const d2Scale: number = GlobalAnalyzer.typicalScale(d2);
    const infGate: number = 100 * d2Scale;
    for (let i = 1; i < n; i++) {
      const a: number = d2[i];
      const b: number = d2[i + 1];
      if (!isFinite(a) || !isFinite(b)) {
        continue;
      }
      if (a * b < 0 && Math.max(Math.abs(a), Math.abs(b)) < infGate
        && Math.abs(a) > d2Noise && Math.abs(b) > d2Noise) {
        // 二分细化 f'' 的零点
        let lo: number = xs[i];
        let hi: number = xs[i + 1];
        let flo: number = a;
        for (let k = 0; k < 50; k++) {
          const m: number = (lo + hi) / 2;
          const fm: number = GlobalAnalyzer.secondDeriv(ev, m, h / 10);
          if (!isFinite(fm)) {
            break;
          }
          if (flo * fm <= 0) {
            hi = m;
          } else {
            lo = m;
            flo = fm;
          }
        }
        const xi: number = (lo + hi) / 2;
        const yi: number = GlobalAnalyzer.feval(ev, xi);
        if (isFinite(yi)) {
          if (inflections.length === 0 || Math.abs(inflections[inflections.length - 1].x - xi) > 1e-6) {
            inflections.push({ x: xi, y: yi });
          }
        }
      }
    }

    // 凹/凸区间：按 d2 符号收集连续段，用噪声底替代原 1e-9*d2Scale 间隙门控
    // 新增：丢弃跨采样数 < 3 的噪声碎段
    let curSign: number = 0; // +1 凹 / -1 凸
    let curLo: number = NaN;
    let curHi: number = NaN;
    let curStartIdx: number = 0;
    for (let i = 1; i < n; i++) {
      const v: number = d2[i];
      const isGap: boolean = !isFinite(v) || Math.abs(v) < d2Noise;
      const sg: number = isGap ? 0 : (v > 0 ? 1 : -1);
      if (sg !== curSign) {
        // 结束上一段（仅当段长度 ≥ 3 个采样时才收入）
        if (curSign !== 0 && !isNaN(curLo) && (i - curStartIdx) >= 3) {
          const iv: DomainInterval = { lo: curLo, hi: curHi, loOpen: true, hiOpen: true };
          if (curSign > 0) {
            concaveUp.push(iv);
          } else {
            concaveDown.push(iv);
          }
        }
        curSign = sg;
        if (sg !== 0) {
          curLo = xs[i];
          curHi = xs[i];
          curStartIdx = i;
        } else {
          curLo = NaN;
          curHi = NaN;
          curStartIdx = 0;
        }
      } else if (sg !== 0) {
        curHi = xs[i];
      }
    }
    // 收尾最后一段（同样丢弃碎段）
    if (curSign !== 0 && !isNaN(curLo) && (n - curStartIdx) >= 3) {
      const iv: DomainInterval = { lo: curLo, hi: curHi, loOpen: true, hiOpen: true };
      if (curSign > 0) {
        concaveUp.push(iv);
      } else {
        concaveDown.push(iv);
      }
    }

    return { inflections, concaveUp, concaveDown };
  }

  /** 二阶导（中心差分，步长 h） */
  private static secondDeriv(ev: FunctionEvaluator, x: number, h: number): number {
    const yp: number = GlobalAnalyzer.feval(ev, x - h);
    const yc: number = GlobalAnalyzer.feval(ev, x);
    const yn: number = GlobalAnalyzer.feval(ev, x + h);
    if (!isFinite(yp) || !isFinite(yc) || !isFinite(yn)) {
      return NaN;
    }
    return (yn - 2 * yc + yp) / (h * h);
  }

  // ================= 对称性 =================

  /** 对称性：在采样点上验证 f(−x)≈f(x)（偶）/ f(−x)≈−f(x)（奇） */
  private static detectSymmetry(ev: FunctionEvaluator, scale: number): SymmetryKind {
    const tol: number = 1e-3 * scale + 1e-9;
    let evenOk: number = 0;
    let oddOk: number = 0;
    let total: number = 0;
    for (let i = 1; i <= 100; i++) {
      const x: number = i * 0.37; // 无理步长避免恰好落在特殊点
      const fp: number = GlobalAnalyzer.feval(ev, x);
      const fm: number = GlobalAnalyzer.feval(ev, -x);
      if (!isFinite(fp) || !isFinite(fm)) {
        continue;
      }
      total++;
      if (Math.abs(fm - fp) <= tol + 1e-6 * Math.abs(fp)) {
        evenOk++;
      }
      if (Math.abs(fm + fp) <= tol + 1e-6 * Math.abs(fp)) {
        oddOk++;
      }
    }
    if (total < 10) {
      return 'none';
    }
    if (evenOk / total > 0.95) {
      return 'even';
    }
    if (oddOk / total > 0.95) {
      return 'odd';
    }
    return 'none';
  }

  // ================= 曲率 =================

  /** 最大曲率点：κ = |f''| / (1 + f'²)^1.5，同时返回该点曲率值 κ */
  private static detectCurvature(ev: FunctionEvaluator, xs: number[], ys: number[]): CurvatureResult {
    const n: number = xs.length - 1;
    const h: number = (xs[n] - xs[0]) / n;
    let bestK: number = -1;
    let bestX: number = NaN;
    let bestY: number = NaN;
    for (let i = 1; i < n; i++) {
      const yp: number = ys[i - 1];
      const yc: number = ys[i];
      const yn: number = ys[i + 1];
      if (!isFinite(yp) || !isFinite(yc) || !isFinite(yn)) {
        continue;
      }
      const d1: number = (yn - yp) / (2 * h);
      const d2v: number = (yn - 2 * yc + yp) / (h * h);
      const kappa: number = Math.abs(d2v) / Math.pow(1 + d1 * d1, 1.5);
      if (isFinite(kappa) && kappa > bestK) {
        bestK = kappa;
        bestX = xs[i];
        bestY = yc;
      }
    }
    if (bestK < 0 || isNaN(bestX)) {
      const empty: CurvatureResult = { point: null, kappa: 0 };
      return empty;
    }
    const point: GraphPoint = { x: bestX, y: bestY };
    const result: CurvatureResult = { point: point, kappa: bestK };
    return result;
  }

  // ================= 增长阶 =================

  /** 增长阶：x→+∞ 时与参照函数比较（f(10x)/f(x) 的比值特征） */
  private static detectGrowth(ev: FunctionEvaluator): GrowthClass {
    const lim: number[] = GlobalAnalyzer.limitAtInfinity(ev, 1);
    if (lim[0] === 1) {
      // 收敛到有限值
      const f0: number = GlobalAnalyzer.feval(ev, 1);
      if (isFinite(f0) && Math.abs(lim[1] - f0) < 1e-6 * Math.max(1, Math.abs(lim[1]))) {
        return 'constant';
      }
      return 'bounded';
    }
    if (lim[0] === 3) {
      return 'bounded'; // → -∞ 视为有下界发散（增长阶关注幅值，简化处理）
    }
    if (lim[0] === 0) {
      return 'unknown'; // 振荡
    }
    // 发散到 +∞：用「比值 f(10x)/f(x) 是否自身增长」区分指数与幂函数
    const f10: number = GlobalAnalyzer.feval(ev, 10);
    const f100: number = GlobalAnalyzer.feval(ev, 100);
    const f1000: number = GlobalAnalyzer.feval(ev, 1000);
    // f(1000) 溢出而 f(100) 有限 → 增长极快 → 指数
    if (!isFinite(f1000) && isFinite(f100)) {
      return 'exponential';
    }
    if (!isFinite(f10) || !isFinite(f100) || !isFinite(f1000) ||
      Math.abs(f10) < 1e-12 || Math.abs(f100) < 1e-12) {
      return 'unknown';
    }
    const r1: number = Math.abs(f100) / Math.abs(f10);
    const r2: number = Math.abs(f1000) / Math.abs(f100);
    // 幂函数比值恒为 10^k；指数函数比值随 x 急剧增大
    if (r2 > r1 * 100) {
      return 'exponential';
    }
    if (r1 > 50) {
      return 'polynomial';
    }
    if (r1 > 5) {
      return 'linear';
    }
    return 'logarithmic';
  }
}
