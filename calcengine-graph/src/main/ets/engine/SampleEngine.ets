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
// calcengine-graph/src/main/ets/engine/SampleEngine.ets
/**
 * 函数采样引擎：世界坐标固定采样 + 通用间断点检测
 *
 * 核心设计原则（数学第一性原理）：
 * - 函数图像是客观数学实体，采样与视图（缩放/平移/像素密度）完全无关。
 * - 间断点（极点、跳跃、无定义）是函数的内禀性质，一次检测永久有效。
 * - 通用判据适配所有函数，无需针对特定函数的补丁代码。
 *
 * 间断点检测数学原理：
 * - 介值定理推论：连续函数中点值受两端约束，不可能远超两端。
 * - 若 |f(mid)| >> max(|f(a)|, |f(b)|) → 函数在 [a,b] 不连续 → 必有极点。
 * - 连续函数中点值严格介于两端之间；若中点=端点 → 函数单侧恒定 → 跳跃间断。
 */

import { FunctionEvaluator } from './FunctionEvaluator';
import { FunctionSampleCache, WorldSample } from './SampleCache';

/** 自适应加密最大深度 */
const REFINE_DEPTH: number = 4;
/** 单函数基础层最大样本数 */
const MAX_BASE_SAMPLES: number = 10000;
/** 单函数细化层最大样本数 */
const MAX_REFINED_SAMPLES: number = 5000;
/** 幅值爆炸判据倍数 K */
const K_MAG: number = 3;
/** 跳跃间断最小显著幅度：端点差小于此值的"跳跃"无视觉意义，视为连续 */
const JUMP_EPS: number = 1e-9;
/** 跳跃间断中点贴合相对容差：中点到端点距离占跳跃幅度比例低于此值才判定"贴合"。
 *  真实跳跃（floor/ceil/step 等分段恒定函数）该比例为 0；连续函数由介值定理约为 0.5，
 *  故 1e-6 可严格区分，且与函数幅值无关（缩放不变）。 */
const JUMP_STICK_REL: number = 1e-6;
/** 符号+幅值联合判据阈值（两端绝对值之和超过此值才考虑） */
const SIGN_MAG_THRESHOLD: number = 10;
/** 极点穿越检测阈值：端点最小幅值超过此值才判定为极点穿越而非正常过零点 */
const POLE_CROSS_THRESHOLD: number = 3;
/** 渐近线探针位置：距非有限端 1/1024 区间宽度处 */
const ASYMPTOTE_PROBE_RATIO: number = 1 / 1024;
/** 渐近线探针陡降判定阈值：探针值超出有限端值至少 2 个单位才确认为渐近线 */
const ASYMPTOTE_PROBE_DIVE: number = 2;
/** 渐近线加密步长比：每步向非有限端推进 16 倍 */
const ASYMPTOTE_STEP_RATIO: number = 16;
/** 渐近线加密下探深度：函数值超出有限端值 150 个单位即停止（充分远离视口） */
const ASYMPTOTE_DIVE_DEPTH: number = 150;
/** 渐近线加密单边界最大插入点数 */
const ASYMPTOTE_MAX_SAMPLES: number = 80;

export class SampleEngine {

  /**
   * 全量构建缓存：在 [xMin, xMax] 范围内以 dx 为基准间距采样，
   * 自适应加密高频区域，检测并标记所有间断点。
   */
  static buildCache(ev: FunctionEvaluator, fnId: number, exprHash: string,
    xMin: number, xMax: number, dx: number): FunctionSampleCache {
    const samples: WorldSample[] = SampleEngine.sampleRange(ev, xMin, xMax, dx);
    return new FunctionSampleCache(fnId, exprHash, samples, xMin, xMax, dx);
  }

  /**
   * 增量扩展：视口平移超出缓存范围时，补算缺失段并合并。
   * 返回更新后的缓存（原地修改）。
   */
  static extendCache(cache: FunctionSampleCache, ev: FunctionEvaluator,
    newXMin: number, newXMax: number): void {
    const dx: number = cache.baseDx;
    let leftSamples: WorldSample[] = [];
    let rightSamples: WorldSample[] = [];

    if (newXMin < cache.xMin) {
      // 左侧补算
      leftSamples = SampleEngine.sampleRange(ev, newXMin, cache.xMin - dx * 0.5, dx);
    }
    if (newXMax > cache.xMax) {
      // 右侧补算
      rightSamples = SampleEngine.sampleRange(ev, cache.xMax + dx * 0.5, newXMax, dx);
    }

    if (leftSamples.length > 0 || rightSamples.length > 0) {
      const merged: WorldSample[] = [];
      for (let i: number = 0; i < leftSamples.length; i++) {
        merged.push(leftSamples[i]);
      }
      for (let i: number = 0; i < cache.samples.length; i++) {
        merged.push(cache.samples[i]);
      }
      for (let i: number = 0; i < rightSamples.length; i++) {
        merged.push(rightSamples[i]);
      }
      cache.samples = merged;
      if (newXMin < cache.xMin) {
        cache.xMin = newXMin;
      }
      if (newXMax > cache.xMax) {
        cache.xMax = newXMax;
      }
      // 细化层失效
      cache.refinedSamples = null;
    }
  }

  /**
   * 可见区细化：深度缩放时对 [xMin, xMax] 以更小间距 dx 重新采样。
   * 结果存入 cache.refinedSamples（叠加层，不修改基础层）。
   */
  static refineCache(cache: FunctionSampleCache, ev: FunctionEvaluator,
    xMin: number, xMax: number, dx: number): void {
    // 确保细化层点数不超过上限
    let effectiveDx: number = dx;
    const estimatedN: number = Math.ceil((xMax - xMin) / dx);
    if (estimatedN > MAX_REFINED_SAMPLES) {
      effectiveDx = (xMax - xMin) / MAX_REFINED_SAMPLES;
    }
    const samples: WorldSample[] = SampleEngine.sampleRange(ev, xMin, xMax, effectiveDx);
    cache.refinedSamples = samples;
    cache.refinedXMin = xMin;
    cache.refinedXMax = xMax;
    cache.refinedDx = effectiveDx;
  }

  /**
   * 核心采样流程：均匀采样 + 自适应加密 + 间断点检测。
   * 公开以供缓冲窗口机制对缺口区间独立采样。
   */
  static sampleRange(ev: FunctionEvaluator, xMin: number, xMax: number,
    dx: number): WorldSample[] {
    if (xMax <= xMin || dx <= 0) {
      return [];
    }
    // 限制总点数
    let n: number = Math.ceil((xMax - xMin) / dx);
    if (n > MAX_BASE_SAMPLES) {
      n = MAX_BASE_SAMPLES;
      dx = (xMax - xMin) / n;
    }

    // 第一阶段：均匀采样
    const raw: WorldSample[] = [];
    for (let i: number = 0; i <= n; i++) {
      const x: number = xMin + i * dx;
      const y: number = SampleEngine.safeEval(ev, x);
      raw.push({ x: x, y: y, disc: false });
    }

    // 第二阶段：自适应加密（高频区域插入中间点）
    const enriched: WorldSample[] = SampleEngine.adaptiveRefine(ev, raw, dx);

    // 第二点五阶段：渐近线边界加密（定义域边界处趋向无穷的陡降/陡升）
    const asymptoted: WorldSample[] = SampleEngine.refineAsymptoteBoundaries(ev, enriched);

    // 第三阶段：通用间断点检测
    SampleEngine.detectDiscontinuities(ev, asymptoted);

    return asymptoted;
  }

  /**
   * 自适应加密：对相邻样本 y 变化剧烈的区间，递归二分插入中间点。
   * 深度上限 REFINE_DEPTH，总点数上限 MAX_BASE_SAMPLES。
   */
  private static adaptiveRefine(ev: FunctionEvaluator, raw: WorldSample[],
    baseDx: number): WorldSample[] {
    const result: WorldSample[] = [];
    const minDx: number = baseDx / Math.pow(2, REFINE_DEPTH);

    for (let i: number = 0; i < raw.length; i++) {
      result.push(raw[i]);
      if (i < raw.length - 1 && result.length < MAX_BASE_SAMPLES) {
        const a: WorldSample = raw[i];
        const b: WorldSample = raw[i + 1];
        // 仅当两端都有定义时才考虑加密
        if (Number.isFinite(a.y) && Number.isFinite(b.y)) {
          const dy: number = Math.abs(b.y - a.y);
          const scale: number = Math.max(Math.abs(a.y), Math.abs(b.y), 1);
          // 相对变化率 > 1（即变化量超过函数值本身）→ 需要加密
          if (dy > scale) {
            SampleEngine.collectMidpoints(ev, result, a, b, 0, minDx);
          }
        }
      }
    }
    // 加密后按 x 升序排列（中点插入顺序不保证有序）
    result.sort((a: WorldSample, b: WorldSample): number => a.x - b.x);
    return result;
  }

  /**
   * 递归收集中点（推入 result 数组，最后统一排序）
   */
  private static collectMidpoints(ev: FunctionEvaluator, result: WorldSample[],
    a: WorldSample, b: WorldSample, depth: number, minDx: number): void {
    if (depth >= REFINE_DEPTH || (b.x - a.x) < minDx) {
      return;
    }
    const mx: number = (a.x + b.x) / 2;
    const my: number = SampleEngine.safeEval(ev, mx);
    const mid: WorldSample = { x: mx, y: my, disc: false };
    result.push(mid);

    // 递归检查左半和右半是否仍需加密
    if (Number.isFinite(a.y) && Number.isFinite(my)) {
      const dyL: number = Math.abs(my - a.y);
      const scaleL: number = Math.max(Math.abs(a.y), Math.abs(my), 1);
      if (dyL > scaleL) {
        SampleEngine.collectMidpoints(ev, result, a, mid, depth + 1, minDx);
      }
    }
    if (Number.isFinite(my) && Number.isFinite(b.y)) {
      const dyR: number = Math.abs(b.y - my);
      const scaleR: number = Math.max(Math.abs(my), Math.abs(b.y), 1);
      if (dyR > scaleR) {
        SampleEngine.collectMidpoints(ev, result, mid, b, depth + 1, minDx);
      }
    }
  }

  /**
   * 渐近线边界加密：补全定义域边界处趋向无穷的陡降/陡升曲线。
   *
   * 问题背景：ln(x) 在 x→0⁺ 时趋向 -∞，但基础均匀采样在边界区间
   * [0, dx] 内无任何采样点（0 处为 -Inf，dx 处为有限值），且自适应
   * 加密因端点非有限而跳过该区间，导致曲线在最后一个有限采样点处
   * 截断，无法呈现沿渐近线陡降的数学特性。
   *
   * 算法：识别「一端非有限（NaN/±Inf）、另一端有限」的边界区间，
   * 先用探针（距非有限端 1/1024 区间宽度）判定是否为真实渐近线
   * （探针值须显著超出有限端值），避免对 sqrt(x)（边界取有限值 0）、
   * asin(x) 等无渐近线函数误加密；确认后从有限端向非有限端按几何
   * 级数（每步推进 16 倍）插入采样点，直至函数值超出有限端值
   * ASYMPTOTE_DIVE_DEPTH 个单位或达到点数上限。
   *
   * 数学客观性：判定与加密完全基于世界坐标的函数值性质，与视图无关。
   */
  private static refineAsymptoteBoundaries(ev: FunctionEvaluator,
    samples: WorldSample[]): WorldSample[] {
    const result: WorldSample[] = [];
    for (let i: number = 0; i < samples.length; i++) {
      const s: WorldSample = samples[i];
      result.push(s);
      if (i >= samples.length - 1) {
        continue;
      }
      const next: WorldSample = samples[i + 1];
      const sFinite: boolean = Number.isFinite(s.y);
      const nextFinite: boolean = Number.isFinite(next.y);
      // 仅处理「一端非有限、另一端有限」的边界区间
      if (sFinite === nextFinite) {
        continue;
      }
      const nonFiniteX: number = sFinite ? next.x : s.x;
      const finiteX: number = sFinite ? s.x : next.x;
      const finiteY: number = sFinite ? s.y : next.y;
      // 探针判定：是否为真实渐近线陡降/陡升
      const probeX: number = nonFiniteX + (finiteX - nonFiniteX) * ASYMPTOTE_PROBE_RATIO;
      const probeY: number = SampleEngine.safeEval(ev, probeX);
      const divingDown: boolean = Number.isFinite(probeY) && probeY < finiteY - ASYMPTOTE_PROBE_DIVE;
      const divingUp: boolean = Number.isFinite(probeY) && probeY > finiteY + ASYMPTOTE_PROBE_DIVE;
      if (!divingDown && !divingUp) {
        continue;
      }
      // 确认渐近线：从有限端向非有限端几何级数插入采样点
      const span: number = finiteX - nonFiniteX;
      const inserted: WorldSample[] = [];
      let ratio: number = 1;
      for (let k: number = 0; k < ASYMPTOTE_MAX_SAMPLES; k++) {
        ratio = ratio / ASYMPTOTE_STEP_RATIO;
        const x: number = nonFiniteX + span * ratio;
        const y: number = SampleEngine.safeEval(ev, x);
        if (!Number.isFinite(y)) {
          break;
        }
        inserted.push({ x: x, y: y, disc: false });
        // 已充分远离有限端值（陡降/陡升足够深），停止
        if (divingDown && y < finiteY - ASYMPTOTE_DIVE_DEPTH) {
          break;
        }
        if (divingUp && y > finiteY + ASYMPTOTE_DIVE_DEPTH) {
          break;
        }
      }
      // 插入点聚于非有限端附近，按 x 升序并入以保证整体有序
      inserted.sort((a: WorldSample, b: WorldSample): number => a.x - b.x);
      for (let m: number = 0; m < inserted.length; m++) {
        result.push(inserted[m]);
      }
    }
    return result;
  }

  /**
   * 通用间断点检测（核心算法，数学第一性原理）
   *
   * 对每对相邻采样点检测间断性，在间断位置标记 disc=true。
   * 判据完全基于世界坐标数学性质，与屏幕/视图无关：
   *
   * 判据 1（无定义）：f(a)=NaN 或 f(b)=NaN
   * 判据 2（无穷极点）：中点 f(m) 非有限
   * 判据 3（幅值爆炸）：|f(m)| > K * max(|f(a)|, |f(b)|, eps)
   * 判据 4（跳跃间断）：f(m)≈f(a) 或 f(m)≈f(b) 且 f(a)≠f(b)
   * 判据 5（符号+幅值+1/4,3/4验证）：异号且幅值大 → 1/4、3/4 点用 minEnd 对比
   * 判据 6（极点穿越检测）：异号且 min(|fa|,|fb|) > 阈值 → 4 等分点验证
   *
   * 关键设计决策：
   * - 判据 5 使用 minEnd 替代 maxEnd：原 maxEnd 在极点靠近区间一端时被极大值主导，
   *   导致验证失效。用 minEnd（正常侧）能得到合理的验证阈值。
   * - 判据 6 解决「极点正好落在两个中点之间」：4 等分点能发现细粒度穿越迹象。
   */
  private static detectDiscontinuities(ev: FunctionEvaluator, samples: WorldSample[]): void {
    for (let i: number = 0; i < samples.length - 1; i++) {
      const a: WorldSample = samples[i];
      const b: WorldSample = samples[i + 1];

      // 判据 1：无定义
      if (Number.isNaN(a.y) || Number.isNaN(b.y)) {
        if (Number.isNaN(a.y)) {
          a.disc = true;
        }
        if (Number.isNaN(b.y)) {
          b.disc = true;
        }
        continue;
      }

      // 如果任一端已标记为间断，跳过
      if (a.disc || b.disc) {
        continue;
      }

      // 两端有限检测
      if (!Number.isFinite(a.y) || !Number.isFinite(b.y)) {
        if (!Number.isFinite(a.y)) {
          a.disc = true;
        }
        if (!Number.isFinite(b.y)) {
          b.disc = true;
        }
        continue;
      }

      const absFa: number = Math.abs(a.y);
      const absFb: number = Math.abs(b.y);
      const maxEnd: number = Math.max(absFa, absFb, 1e-10);
      const minEnd: number = Math.min(absFa, absFb);

      // 取中点
      const mx: number = (a.x + b.x) / 2;
      const my: number = SampleEngine.safeEval(ev, mx);

      // 判据 2：中点非有限 → 确定有极点
      if (!Number.isFinite(my)) {
        samples.splice(i + 1, 0, { x: mx, y: NaN, disc: true });
        i++;
        continue;
      }

      // 判据 3：幅值爆炸（|mid| >> max(|fa|,|fb|)）→ 确定有极点
      if (Math.abs(my) > K_MAG * maxEnd) {
        samples.splice(i + 1, 0, { x: mx, y: my, disc: true });
        i++;
        continue;
      }

      // 判据 4：跳跃间断（中点值贴合某端值 → 函数单侧恒定）
      // 修复（e^x 负向断裂）：贴合判定改为相对于跳跃幅度 jumpGap 而非绝对容差。
      // 旧版用绝对容差 JUMP_EPS 判定 |my - a.y|，当 e^x 处于 x∈(-21,-16)
      // （值域 1e-9~1e-7）时，中点天然落在端点 1e-9 以内，被误判为跳跃间断，
      // 整段曲线被切割为散点，出现可见断裂。
      // 数学依据：真实跳跃（分段恒定函数）中点与某端点严格重合（stick≈0）；
      // 连续函数由介值定理中点严格介于两端之间，stick 约为 jumpGap 的一半。
      // 故用 stick/jumpGap 相对比例可严格区分，且与函数整体幅值无关（缩放不变）。
      const jumpGap: number = Math.abs(b.y - a.y);
      if (jumpGap > JUMP_EPS) {
        const stickA: number = Math.abs(my - a.y);
        const stickB: number = Math.abs(my - b.y);
        if (stickA <= jumpGap * JUMP_STICK_REL || stickB <= jumpGap * JUMP_STICK_REL) {
          samples.splice(i + 1, 0, { x: mx, y: my, disc: true });
          i++;
          continue;
        }
      }

      // 判据 5：符号+幅值+多点验证（修复：用 minEnd 替代 maxEnd）
      // 当符号变化且幅值较大时，取 1/4、3/4 点验证是否为极点。
      // 旧版用 maxEnd 导致极点靠近区间一端时验证失效（maxEnd被极大值主导），
      // 改用 minEnd：正常侧的值能给出合理的验证阈值。
      if (a.y * b.y < 0 && (absFa + absFb) > SIGN_MAG_THRESHOLD && minEnd > 0) {
        const q1x: number = a.x + (b.x - a.x) * 0.25;
        const q3x: number = a.x + (b.x - a.x) * 0.75;
        const q1y: number = SampleEngine.safeEval(ev, q1x);
        const q3y: number = SampleEngine.safeEval(ev, q3x);
        const checkEnd: number = Math.max(minEnd, 1e-10);
        const confirmed: boolean = !Number.isFinite(q1y) || !Number.isFinite(q3y) ||
          Math.abs(q1y) > K_MAG * checkEnd || Math.abs(q3y) > K_MAG * checkEnd;
        if (confirmed) {
          samples.splice(i + 1, 0, { x: mx, y: NaN, disc: true });
          i++;
          continue;
        }
      }

      // 判据 6：极点穿越检测（解决极点落在区间中部但中点不穿越的问题）
      // 当 f(a)·f(b) < 0 且 min(|fa|,|fb|) > 阈值时，
      // 在区间内取 4 个等分点，检查是否存在任意相邻等分点异号且幅值显著。
      // 这能检测到「极点不在中点附近而在区间其他位置」的情况。
      if (a.y * b.y < 0 && minEnd > POLE_CROSS_THRESHOLD) {
        const nCheck: number = 4;
        const checkDx: number = (b.x - a.x) / (nCheck + 1);
        let prevY: number = a.y;
        let poleFound: boolean = false;
        for (let k: number = 1; k <= nCheck; k++) {
          const cx: number = a.x + k * checkDx;
          const cy: number = SampleEngine.safeEval(ev, cx);
          if (!Number.isFinite(cy)) {
            poleFound = true;
            break;
          }
          if (prevY * cy < 0 && Math.min(Math.abs(prevY), Math.abs(cy)) > POLE_CROSS_THRESHOLD) {
            poleFound = true;
            break;
          }
          prevY = cy;
        }
        if (!poleFound && prevY * b.y < 0 &&
          Math.min(Math.abs(prevY), Math.abs(b.y)) > POLE_CROSS_THRESHOLD) {
          poleFound = true;
        }
        if (poleFound) {
          samples.splice(i + 1, 0, { x: mx, y: NaN, disc: true });
          i++;
          continue;
        }
      }
    }
  }

  /** 安全求值：捕获异常返回 NaN */
  private static safeEval(ev: FunctionEvaluator, x: number): number {
    try {
      return ev.evaluate(x);
    } catch (e) {
      return NaN;
    }
  }
}
