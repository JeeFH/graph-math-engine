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
 * GraphCurvePainter - 曲线 / 等值线 / 填充区域 / 特殊点标记绘制器
 *
 * 从 GraphCanvas 拆分出的四大渲染模式绘制逻辑：
 * - 显函数：世界坐标预缓存投影 + 屏幕空间自适应细分（含渐近线端点延伸）
 * - 隐函数 / 二元方程：等值线段批量描边（虚线走链式路径保证花纹连续）
 * - 不等式：区域填充（单一 path + globalAlpha）+ 边界线
 * - 特殊点标记：零点 / 极值 / 拐点 / 渐近线（周期函数按周期复制）
 *
 * 绘制所需的全部外部状态经 CurvePaintEnv 传入，与组件解耦，可独立测试。
 */

import {
  GraphMath, Viewport, FunctionEvaluator, FunctionSampleCache, WorldSample,
  GraphFunction, Gpt, GraphPoint, Extremum,
  GlobalAnalysisResult, HorizontalAsymptote, ObliqueAsymptote,
  RenderDispatcher, RenderData, RenderMode, LineSegment, Polygon
} from 'calcengine-graph';
import { GridAxisPainter } from './GridAxisPainter';

/** 1D 曲线递归细分预算（跨线段共享，避免单帧评估过多导致卡顿） */
interface SubdivBudget {
  evalCount: number;
  subdivCount: number;
  maxEval: number;
  maxSubdiv: number;
}

/** 曲线绘制环境：GraphCanvas 每帧组装传入（全部为引用传递，无深拷贝） */
export interface CurvePaintEnv {
  /** 待绘制函数列表 */
  functions: GraphFunction[];
  /** 当前选中函数 id（叠加光晕高亮） */
  activeId: number;
  /** 手势进行中（降质渲染：粗采样 + 跳细分） */
  isGesturing: boolean;
  /** 暗色模式（标记标签配色） */
  isDark: boolean;
  /** 统一渲染调度器（隐函数 / 不等式 / 二元方程数据源） */
  renderDispatcher: RenderDispatcher;
  /** 预构建的 FunctionEvaluator 缓存（按函数 id） */
  evaluatorCache: Map<number, FunctionEvaluator>;
  /** 世界坐标采样缓存（按函数 id） */
  sampleCaches: Map<number, FunctionSampleCache>;
  /** 读取某函数的标记分析结果（缓存未命中返回 null） */
  getMarkerAnalysis: (fn: GraphFunction) => GlobalAnalysisResult | null;
}

export class GraphCurvePainter {
  /** 轮廓链单槽缓存：线段数组引用（渲染器 cachedSegments 跨帧引用稳定，避免手势期每帧重链） */
  private chainSegsRef: LineSegment[] | null = null;
  private chainResult: number[][] = [];

  /**
   * 函数曲线渲染（世界坐标预缓存 + 视口投影 + 轻量细分）。
   *
   * 核心架构：
   * - 函数加载时由 SampleEngine 一次性预计算世界坐标采样点并标记所有间断点。
   * - 渲染时仅做「世界→屏幕」坐标投影 + 按间断标记分割 + 描边。
   * - 视图变化（缩放/平移）不触发重新求值，仅重新投影。
   * - 间断点检测基于数学第一性原理（介值定理推论），与视图无关，全函数通用。
   */
  drawCurves(ctx: CanvasRenderingContext2D, vp: Viewport, w: number, h: number,
    env: CurvePaintEnv): void {
    const TOL: number = 0.5;
    const MAX_SUBDIV: number = 2000;
    const MAX_EVAL: number = 500; // 每帧 evaluate 调用上限（防止卡顿）
    const HUGE_SCREEN: number = 1e6;

    // 一次性提取所有非显函数的渲染数据（避免循环内重复提取）
    let allRenderData: RenderData[] | null = null;
    const hasNonExplicit: boolean = env.functions.some((fn: GraphFunction): boolean => {
      if (!fn.enabled) return false;
      const mode: RenderMode | null = env.renderDispatcher.getMode(fn.id);
      return mode === RenderMode.IMPLICIT || mode === RenderMode.BIVARIATE_EQ || mode === RenderMode.INEQUALITY;
    });
    if (hasNonExplicit) {
      allRenderData = env.renderDispatcher.extractAll(vp, GraphCurvePainter.buildFnStyleMap(env.functions));
    }

    for (let i = 0; i < env.functions.length; i++) {
      const fn: GraphFunction = env.functions[i];
      if (!fn.enabled) {
        continue;
      }

      // 查询渲染调度器判定模式
      const mode: RenderMode | null = env.renderDispatcher.getMode(fn.id);

      if (mode === RenderMode.IMPLICIT || mode === RenderMode.BIVARIATE_EQ) {
        // ── 隐函数 / 二元方程：等值线渲染 ──
        if (allRenderData != null) {
          for (let k = 0; k < allRenderData.length; k++) {
            const rd: RenderData = allRenderData[k];
            if (rd.fnId === fn.id && rd.contourSegments != null) {
              this.drawContourSegments(ctx, vp, w, h, fn, rd.contourSegments, env);
            }
          }
        }
        continue;
      }

      if (mode === RenderMode.INEQUALITY) {
        // ── 不等式：区域填充 + 边界线 ──
        if (allRenderData != null) {
          for (let k = 0; k < allRenderData.length; k++) {
            const rd: RenderData = allRenderData[k];
            if (rd.fnId === fn.id) {
              if (rd.fillRegions != null) {
                GraphCurvePainter.drawFillRegions(ctx, vp, w, h, fn, rd.fillRegions);
              }
              if (rd.boundarySegments != null) {
                this.drawContourSegments(ctx, vp, w, h, fn, rd.boundarySegments, env);
              }
            }
          }
        }
        continue;
      }

      // ── 显函数（默认）：现有 1D 管线 ──
      const ev: FunctionEvaluator | undefined = env.evaluatorCache.get(fn.id);
      if (ev == undefined) {
        continue;
      }

      const cache: FunctionSampleCache | undefined = env.sampleCaches.get(fn.id);
      if (cache != undefined && cache.samples.length > 0) {
        // ── 主路径：缓存渲染（无 evaluate 调用） ──
        this.drawFromCache(ctx, vp, w, h, fn, cache, ev, TOL, MAX_SUBDIV, MAX_EVAL, HUGE_SCREEN, env);
      } else if (!env.isGesturing) {
        // ── 回退路径：缓存未就绪时直接 evaluator 渲染（仅首帧或缓存构建中） ──
        GraphCurvePainter.drawFallback(ctx, vp, w, h, fn, ev, MAX_EVAL, HUGE_SCREEN, env);
      }
    }
  }

  /**
   * 主渲染路径：从世界坐标缓存投影到屏幕。
   * 此路径不调用 evaluate（除非轻量细分需要），性能 O(可见点数)。
   */
  private drawFromCache(ctx: CanvasRenderingContext2D, vp: Viewport, w: number, h: number,
    fn: GraphFunction, cache: FunctionSampleCache, ev: FunctionEvaluator,
    TOL: number, MAX_SUBDIV: number, MAX_EVAL: number, HUGE_SCREEN: number,
    env: CurvePaintEnv): void {
    // 1) 获取可见样本
    const visible: WorldSample[] = cache.getVisibleSamples(vp.xMin, vp.xMax);
    if (visible.length < 2) {
      return;
    }

    // 2) 世界坐标 → 屏幕坐标投影
    const pts: Gpt[] = [];
    for (let k: number = 0; k < visible.length; k++) {
      const s: WorldSample = visible[k];
      const sx: number = GraphMath.worldToScreenX(s.x, vp, w);
      let sy: number;
      if (Number.isNaN(s.y)) {
        sy = NaN;
      } else if (s.y === Infinity) {
        sy = -HUGE_SCREEN;
      } else if (s.y === -Infinity) {
        sy = h + HUGE_SCREEN;
      } else {
        sy = GraphMath.worldToScreenY(s.y, vp, h);
        if (!isFinite(sy)) {
          sy = s.y > vp.yMax ? -HUGE_SCREEN : h + HUGE_SCREEN;
        }
      }
      pts.push({ x: sx, y: sy, wx: s.x, raw: s.y });
    }

    // 3) 按 disc 标记 + NaN 分割
    // ±Inf 采样点是垂直渐近线点（如 ln(x) 在 x=0 处趋向 -∞），第 2 步已将其
    // 投影到画布外（±HUGE_SCREEN）。此处须作为"画布外端点"延伸相邻折线，
    // 使曲线朝渐近线方向画出画布；若像普通 disc 点一样丢弃，曲线会在最后
    // 一个有限采样点处截断，无法呈现趋向无穷的渐近线特性。
    const runs: Gpt[][] = [];
    let cur: Gpt[] = [];
    let pendingAsymptote: Gpt | null = null;
    for (let k: number = 0; k < pts.length; k++) {
      const p: Gpt = pts[k];
      const ws: WorldSample = visible[k];
      if (Number.isNaN(p.raw)) {
        // 无定义点：断开折线并清除渐近线挂起点
        if (cur.length > 0) {
          runs.push(cur);
          cur = [];
        }
        pendingAsymptote = null;
        continue;
      }
      if (p.raw === Infinity || p.raw === -Infinity) {
        // 垂直渐近线点：作为画布外端点追加到当前折线（若有）后断开；
        // 同时挂起，供其后的有限折线从该点出发延伸出画布。
        if (cur.length > 0) {
          cur.push(p);
          runs.push(cur);
          cur = [];
        }
        pendingAsymptote = p;
        continue;
      }
      if (ws.disc) {
        // 常规间断标记（极点/跳跃等）：断开折线
        if (cur.length > 0) {
          runs.push(cur);
          cur = [];
        }
        pendingAsymptote = null;
        continue;
      }
      // 有限且非间断的正常采样点
      if (cur.length === 0 && pendingAsymptote !== null) {
        // 折线从渐近线画布外端点起始（曲线自渐近线方向陡降/陡升而来）
        cur.push(pendingAsymptote);
        pendingAsymptote = null;
      }
      cur.push(p);
    }
    if (cur.length > 0) {
      runs.push(cur);
    }

    // 4) 轻量屏幕空间自适应细分（有评估预算限制，避免卡顿）
    let subdivCount: number = 0;
    let evalCount: number = 0;
    const refinedRuns: Gpt[][] = [];
    for (let r: number = 0; r < runs.length; r++) {
      const run: Gpt[] = runs[r];
      if (run.length < 2) {
        refinedRuns.push(run);
        continue;
      }
      if (env.isGesturing) {
        refinedRuns.push(run);
        continue;
      }
      const out: Gpt[] = [run[0]];
      const budget: SubdivBudget = {
        evalCount: evalCount, subdivCount: subdivCount,
        maxEval: MAX_EVAL, maxSubdiv: MAX_SUBDIV
      };
      for (let k: number = 1; k < run.length; k++) {
        const a: Gpt = run[k - 1];
        const b: Gpt = run[k];
        // Y 方向裁剪：两端屏幕 Y 均远超画布（不可见）时跳过细分评估，节省 evalCount 预算
        const offscreen: boolean = (a.y < -h && b.y < -h) || (a.y > 2 * h && b.y > 2 * h);
        if (!offscreen && budget.subdivCount < budget.maxSubdiv) {
          GraphCurvePainter.subdivideSegment(out, a, b, 0, vp, w, h, ev, TOL, budget);
        }
        out.push(b);
      }
      evalCount = budget.evalCount;
      subdivCount = budget.subdivCount;
      refinedRuns.push(out);
    }

    // 5) 描边
    GraphCurvePainter.strokeRuns(ctx, fn, refinedRuns, env);
  }

  /**
   * 递归自适应细分：在相邻采样点间插入中点，修正凹形曲线极值点处的阶梯感。
   *
   * 原理：计算线段中点的真实函数值与线性插值的屏幕偏差，
   * 偏差超过 TOL 时插入中点并对左右两半递归（深度 ≤ 4），
   * 直到偏差足够小或预算耗尽。共享全局评估预算，避免卡顿。
   */
  private static subdivideSegment(out: Gpt[], a: Gpt, b: Gpt, depth: number,
    vp: Viewport, w: number, h: number, ev: FunctionEvaluator,
    TOL: number, budget: SubdivBudget): void {
    // 深度上限 4（最细间隔 = 原始间距 / 16）或预算耗尽 → 停止
    if (depth >= 4 || budget.evalCount >= budget.maxEval ||
      budget.subdivCount >= budget.maxSubdiv) {
      return;
    }
    if (!Number.isFinite(a.raw) || !Number.isFinite(b.raw)) {
      return;
    }
    const mx: number = (a.wx + b.wx) * 0.5;
    let midRaw: number;
    try {
      midRaw = ev.evaluate(mx);
      budget.evalCount++;
    } catch (e) {
      midRaw = NaN;
    }
    if (!Number.isFinite(midRaw)) {
      return;
    }
    const midSy: number = GraphMath.worldToScreenY(midRaw, vp, h);
    const interpSy: number = (a.y + b.y) * 0.5;
    const dev: number = Math.abs(midSy - interpSy);
    if (dev <= TOL) {
      return; // 偏差足够小，无需细分
    }
    const midSx: number = GraphMath.worldToScreenX(mx, vp, w);
    const mid: Gpt = { x: midSx, y: midSy, wx: mx, raw: midRaw };
    budget.subdivCount++;
    // 先递归左半（中点插入位置在 a 与 b 之间），再递归右半
    GraphCurvePainter.subdivideSegment(out, a, mid, depth + 1, vp, w, h, ev, TOL, budget);
    out.push(mid);
    GraphCurvePainter.subdivideSegment(out, mid, b, depth + 1, vp, w, h, ev, TOL, budget);
  }

  /**
   * 回退渲染路径：缓存未就绪时直接 evaluator 渲染。
   * 仅在首帧或缓存构建中使用，步长 2px + 简单 NaN/Inf 分割。
   */
  private static drawFallback(ctx: CanvasRenderingContext2D, vp: Viewport, w: number, h: number,
    fn: GraphFunction, ev: FunctionEvaluator, MAX_EVAL: number, HUGE_SCREEN: number,
    env: CurvePaintEnv): void {
    let evalCount: number = 0;
    const stepPx: number = 2;
    const N: number = Math.max(1, Math.floor(w / stepPx));
    const cols: Gpt[] = [];
    for (let c: number = 0; c <= N && evalCount < MAX_EVAL; c++) {
      const sx: number = (c / N) * w;
      const wx: number = GraphMath.screenToWorldX(sx, vp, w);
      let y: number;
      try {
        y = ev.evaluate(wx);
        evalCount++;
      } catch (e) {
        y = NaN;
      }
      let sy: number;
      if (Number.isNaN(y)) {
        sy = NaN;
      } else if (y === Infinity) {
        sy = -HUGE_SCREEN;
      } else if (y === -Infinity) {
        sy = h + HUGE_SCREEN;
      } else {
        sy = GraphMath.worldToScreenY(y, vp, h);
        if (!isFinite(sy)) {
          sy = y > vp.yMax ? -HUGE_SCREEN : h + HUGE_SCREEN;
        }
      }
      cols.push({ x: sx, y: sy, wx: wx, raw: y });
    }

    // 简单 NaN/Inf 分割
    const runs: Gpt[][] = [];
    let cur: Gpt[] = [];
    for (let c: number = 0; c < cols.length; c++) {
      const p: Gpt = cols[c];
      if (Number.isNaN(p.raw) || !Number.isFinite(p.raw)) {
        if (cur.length > 0) {
          runs.push(cur);
          cur = [];
        }
        continue;
      }
      cur.push(p);
    }
    if (cur.length > 0) {
      runs.push(cur);
    }
    GraphCurvePainter.strokeRuns(ctx, fn, runs, env);
  }

  /** 通用描边：线型设置 + 光晕 + 主描边 */
  private static strokeRuns(ctx: CanvasRenderingContext2D, fn: GraphFunction, runs: Gpt[][],
    env: CurvePaintEnv): void {
    ctx.setLineDash(fn.lineStyle === 'dashed' ? [8, 6] : []);
    ctx.strokeStyle = fn.color;
    ctx.lineWidth = fn.lineWidth ?? 3;
    ctx.lineJoin = 'round';
    ctx.lineCap = 'round';

    // 选中态光晕
    if (fn.id === env.activeId && !env.isGesturing) {
      ctx.save();
      ctx.globalAlpha = 0.28;
      ctx.strokeStyle = fn.color;
      ctx.lineWidth = Math.max(10, (fn.lineWidth ?? 3) * 3.5);
      ctx.lineJoin = 'round';
      ctx.lineCap = 'round';
      for (let r = 0; r < runs.length; r++) {
        const run: Gpt[] = runs[r];
        if (run.length < 2) {
          continue;
        }
        ctx.beginPath();
        ctx.moveTo(run[0].x, run[0].y);
        for (let p = 1; p < run.length; p++) {
          ctx.lineTo(run[p].x, run[p].y);
        }
        ctx.stroke();
      }
      ctx.restore();
    }

    // 主描边
    for (let r = 0; r < runs.length; r++) {
      const run: Gpt[] = runs[r];
      if (run.length < 2) {
        continue;
      }
      ctx.beginPath();
      ctx.moveTo(run[0].x, run[0].y);
      for (let p = 1; p < run.length; p++) {
        ctx.lineTo(run[p].x, run[p].y);
      }
      ctx.stroke();
    }

    ctx.setLineDash([]);
  }

  // ==================== 多模式绘制方法 ====================

  /**
   * 构建函数样式 Map（供 RenderDispatcher.extractAll 使用）
   */
  static buildFnStyleMap(functions: GraphFunction[]): Map<number, GraphFunction> {
    const m: Map<number, GraphFunction> = new Map();
    for (let i = 0; i < functions.length; i++) {
      const fn: GraphFunction = functions[i];
      m.set(fn.id, fn);
    }
    return m;
  }

  /**
   * 绘制等值线段集合（隐函数 / 二元方程 / 不等式边界）。
   * 将世界坐标线段投影到屏幕坐标并描边。
   *
   * 性能优化：所有线段合并到单一 path 后一次 stroke，
   * 避免逐段 beginPath/stroke（数千段时 Canvas 状态机开销巨大，平移/缩放卡顿）。
   */
  private drawContourSegments(ctx: CanvasRenderingContext2D, vp: Viewport,
    w: number, h: number, fn: GraphFunction, segments: LineSegment[],
    env: CurvePaintEnv): void {
    if (segments.length === 0) return;

    ctx.save();
    ctx.strokeStyle = fn.color;
    ctx.lineWidth = fn.lineWidth ?? 3;
    ctx.lineJoin = 'round';
    ctx.lineCap = 'round';
    const dashed: boolean = fn.lineStyle === 'dashed';
    ctx.setLineDash(dashed ? [8, 6] : []);

    if (dashed) {
      // 虚线：先把共享端点的线段链接成连续折线再描边。
      // Canvas 虚线花纹在每个子路径起点重置—— MS 线段仅 2~5px，
      // 逐条独立描边会使 [8,6] 花纹退化为实线；链接后花纹沿曲线连续流动。
      const chains: number[][] = this.getContourChains(segments);

      // 选中态光晕（同样走链式路径）
      if (fn.id === env.activeId && !env.isGesturing) {
        ctx.save();
        ctx.globalAlpha = 0.28;
        ctx.lineWidth = Math.max(10, (fn.lineWidth ?? 3) * 3.5);
        GraphCurvePainter.strokeChains(ctx, chains, vp, w, h);
        ctx.restore();
      }

      // 主描边
      GraphCurvePainter.strokeChains(ctx, chains, vp, w, h);
    } else {
      // 实线：保持批量路径（数千子路径一次 stroke，无虚线花纹重置问题）
      // 选中态光晕（同样合并为单一 path）
      if (fn.id === env.activeId && !env.isGesturing) {
        ctx.save();
        ctx.globalAlpha = 0.28;
        ctx.lineWidth = Math.max(10, (fn.lineWidth ?? 3) * 3.5);
        ctx.beginPath();
        for (let i = 0; i < segments.length; i++) {
          const seg: LineSegment = segments[i];
          ctx.moveTo(GraphMath.worldToScreenX(seg.x1, vp, w),
            GraphMath.worldToScreenY(seg.y1, vp, h));
          ctx.lineTo(GraphMath.worldToScreenX(seg.x2, vp, w),
            GraphMath.worldToScreenY(seg.y2, vp, h));
        }
        ctx.stroke();
        ctx.restore();
      }

      // 主描边：单一 path 一次 stroke
      ctx.beginPath();
      for (let i = 0; i < segments.length; i++) {
        const seg: LineSegment = segments[i];
        ctx.moveTo(GraphMath.worldToScreenX(seg.x1, vp, w),
          GraphMath.worldToScreenY(seg.y1, vp, h));
        ctx.lineTo(GraphMath.worldToScreenX(seg.x2, vp, w),
          GraphMath.worldToScreenY(seg.y2, vp, h));
      }
      ctx.stroke();
    }

    ctx.setLineDash([]);
    ctx.restore();
  }

  // ── 虚线轮廓链式描边辅助 ──

  /** 获取轮廓链（引用命中返回缓存，否则重链后回填） */
  private getContourChains(segments: LineSegment[]): number[][] {
    if (this.chainSegsRef === segments) {
      return this.chainResult;
    }
    const chains: number[][] = GraphCurvePainter.chainContours(segments);
    this.chainSegsRef = segments;
    this.chainResult = chains;
    return chains;
  }

  /**
   * 将轮廓线段链接成连续折线（供虚线描边）。
   * 返回扁平坐标数组列表，每条链为 [x0,y0,x1,y1,...]。
   *
   * 相邻网格单元共享边的交点由相同插值输入算出（位级相等），
   * 用量化端点键建邻接表即可可靠链接；链仅在曲线端点处断开，
   * 闭合回路自然成链（末点与首点重合）。复杂度 O(n)。
   */
  private static chainContours(segments: LineSegment[]): number[][] {
    const n: number = segments.length;
    const chains: number[][] = [];
    if (n === 0) {
      return chains;
    }
    // 端点键 → 触及该点的线段索引列表
    const adj: Map<string, number[]> = new Map();
    const visited: boolean[] = new Array<boolean>(n).fill(false);
    for (let i = 0; i < n; i++) {
      const seg: LineSegment = segments[i];
      const k1: string = GraphCurvePainter.contourKey(seg.x1, seg.y1);
      let l1: number[] | undefined = adj.get(k1);
      if (l1 === undefined) {
        l1 = [];
        adj.set(k1, l1);
      }
      l1.push(i);
      const k2: string = GraphCurvePainter.contourKey(seg.x2, seg.y2);
      if (k2 !== k1) {
        let l2: number[] | undefined = adj.get(k2);
        if (l2 === undefined) {
          l2 = [];
          adj.set(k2, l2);
        }
        l2.push(i);
      }
    }
    for (let i = 0; i < n; i++) {
      if (visited[i]) {
        continue;
      }
      visited[i] = true;
      const seg0: LineSegment = segments[i];
      const front: number[] = [seg0.x1, seg0.y1, seg0.x2, seg0.y2];
      // 向前扩展（从 seg0 尾端出发，追加另一端坐标）
      let curKey: string = GraphCurvePainter.contourKey(seg0.x2, seg0.y2);
      for (;;) {
        const j: number = GraphCurvePainter.nextUnvisitedAt(adj, visited, curKey);
        if (j < 0) {
          break;
        }
        visited[j] = true;
        const seg: LineSegment = segments[j];
        if (GraphCurvePainter.contourKey(seg.x1, seg.y1) === curKey) {
          front.push(seg.x2, seg.y2);
          curKey = GraphCurvePainter.contourKey(seg.x2, seg.y2);
        } else {
          front.push(seg.x1, seg.y1);
          curKey = GraphCurvePainter.contourKey(seg.x1, seg.y1);
        }
      }
      // 向后扩展（从 seg0 头端出发，新头点收集到 back，最后按点对逆序合并到链首）
      const back: number[] = [];
      curKey = GraphCurvePainter.contourKey(seg0.x1, seg0.y1);
      for (;;) {
        const j: number = GraphCurvePainter.nextUnvisitedAt(adj, visited, curKey);
        if (j < 0) {
          break;
        }
        visited[j] = true;
        const seg: LineSegment = segments[j];
        if (GraphCurvePainter.contourKey(seg.x1, seg.y1) === curKey) {
          back.push(seg.x2, seg.y2);
          curKey = GraphCurvePainter.contourKey(seg.x2, seg.y2);
        } else {
          back.push(seg.x1, seg.y1);
          curKey = GraphCurvePainter.contourKey(seg.x1, seg.y1);
        }
      }
      const chain: number[] = [];
      for (let p: number = back.length - 2; p >= 0; p -= 2) {
        chain.push(back[p], back[p + 1]);
      }
      for (let p: number = 0; p < front.length; p++) {
        chain.push(front[p]);
      }
      chains.push(chain);
    }
    return chains;
  }

  /** 邻接表中该键下首个未访问线段索引（无则 -1） */
  private static nextUnvisitedAt(adj: Map<string, number[]>, visited: boolean[], key: string): number {
    const list: number[] | undefined = adj.get(key);
    if (list === undefined) {
      return -1;
    }
    for (let k = 0; k < list.length; k++) {
      if (!visited[list[k]]) {
        return list[k];
      }
    }
    return -1;
  }

  /** 轮廓端点量化键（相邻单元共享端点位级相等，量化仅为保险） */
  private static contourKey(x: number, y: number): string {
    return Math.round(x * 1000000) + ',' + Math.round(y * 1000000);
  }

  /** 描边折线链：单一 beginPath，每条链为一个子路径（虚线花纹沿链连续），一次 stroke */
  private static strokeChains(ctx: CanvasRenderingContext2D, chains: number[][],
    vp: Viewport, w: number, h: number): void {
    ctx.beginPath();
    for (let c = 0; c < chains.length; c++) {
      const pts: number[] = chains[c];
      if (pts.length < 4) {
        continue; // 退化链（不足两点）跳过
      }
      ctx.moveTo(GraphMath.worldToScreenX(pts[0], vp, w),
        GraphMath.worldToScreenY(pts[1], vp, h));
      for (let i = 2; i < pts.length; i += 2) {
        ctx.lineTo(GraphMath.worldToScreenX(pts[i], vp, w),
          GraphMath.worldToScreenY(pts[i + 1], vp, h));
      }
    }
    ctx.stroke();
  }

  /**
   * 绘制填充区域多边形（不等式模式）。
   * 将世界坐标多边形投影到屏幕坐标并填充（半透明）。
   *
   * 性能优化：所有多边形合并到单一 path 后一次 fill，
   * 避免逐块 beginPath/fill（不等式区域可达数万个子路径，逐个 fill 会严重卡顿）。
   */
  private static drawFillRegions(ctx: CanvasRenderingContext2D, vp: Viewport,
    w: number, h: number, fn: GraphFunction, regions: Polygon[]): void {
    if (regions.length === 0) return;

    ctx.save();
    // 填充色：曲线原色 + globalAlpha 25% 真透明（Canvas 支持 globalAlpha，
    // 光晕路径已验证）。预合成到背景色的方案会得到不透明填充、完全遮盖下层曲线。
    // 单一 path + nonzero winding 一次 fill 保证重叠子路径不叠加变暗，透明度均匀。
    ctx.globalAlpha = 0.25;
    ctx.fillStyle = fn.color;

    // 单一 path 汇总所有多边形子路径，最后一次 fill
    ctx.beginPath();
    for (let i = 0; i < regions.length; i++) {
      const poly: Polygon = regions[i];
      if (poly.points.length < 3) continue;

      ctx.moveTo(GraphMath.worldToScreenX(poly.points[0].x, vp, w),
        GraphMath.worldToScreenY(poly.points[0].y, vp, h));
      for (let k = 1; k < poly.points.length; k++) {
        ctx.lineTo(GraphMath.worldToScreenX(poly.points[k].x, vp, w),
          GraphMath.worldToScreenY(poly.points[k].y, vp, h));
      }
      ctx.closePath();
    }
    ctx.fill();

    ctx.restore();
  }

  // ==================== 特殊点标记 ====================

  /**
   * 特殊点标记：为启用标记的函数绘制零点/极值/拐点/渐近线。
   * 数据来自视口无关的全局分析缓存（经 env.getMarkerAnalysis 读取），
   * 绘制时按视口过滤；周期函数按周期复制。
   * 与分析面板（showAnalysis）、图像可见性（enabled）均解耦，叠加于图像之上。
   */
  drawAnalysis(ctx: CanvasRenderingContext2D, vp: Viewport, w: number, h: number,
    env: CurvePaintEnv): void {
    ctx.font = '10vp sans-serif';
    for (let i = 0; i < env.functions.length; i++) {
      const fn: GraphFunction = env.functions[i];
      const showZ: boolean = fn.showZeros === true;
      const showE: boolean = fn.showExtrema === true;
      const showI: boolean = fn.showInflections === true;
      const showA: boolean = fn.showAsymptotes === true;
      if (!showZ && !showE && !showI && !showA) {
        continue;
      }
      const a: GlobalAnalysisResult | null = env.getMarkerAnalysis(fn);
      if (a == null) {
        continue; // 缓存未构建（异步构建完成后会触发重绘）
      }
      // 零点（红点，y=0）
      if (showZ) {
        for (let j = 0; j < a.zeros.length; j++) {
          const rxs: number[] = GraphCurvePainter.markerReplicas(a.zeros[j].x, a.period, vp);
          for (let k = 0; k < rxs.length; k++) {
            GraphCurvePainter.drawZeroDot(ctx, vp, w, h, rxs[k], env.isDark);
          }
        }
      }
      // 极值（绿框）
      if (showE) {
        for (let j = 0; j < a.extrema.length; j++) {
          const ex: Extremum = a.extrema[j];
          const rxs: number[] = GraphCurvePainter.markerReplicas(ex.x, a.period, vp);
          for (let k = 0; k < rxs.length; k++) {
            GraphCurvePainter.drawExtremumBox(ctx, vp, w, h, rxs[k], ex.y, ex.kind, env.isDark);
          }
        }
      }
      // 拐点（蓝色菱形 + "拐" 标签）
      if (showI && a.concavity.inflections.length > 0) {
        for (let j = 0; j < a.concavity.inflections.length; j++) {
          const ip: GraphPoint = a.concavity.inflections[j];
          const rxs: number[] = GraphCurvePainter.markerReplicas(ip.x, a.period, vp);
          for (let k = 0; k < rxs.length; k++) {
            GraphCurvePainter.drawInflectionDot(ctx, vp, w, h, rxs[k], ip.y, env.isDark);
          }
        }
      }
      // 渐近线（紫色虚线）
      if (showA) {
        GraphCurvePainter.drawAsymptotes(ctx, vp, w, h, a);
      }
    }
  }

  /** 标记在视口内的全部副本 x：非周期返回自身（若在视口内）；周期函数按周期复制（过密时返回空） */
  private static markerReplicas(x0: number, period: number | null, vp: Viewport): number[] {
    const out: number[] = [];
    if (period == null) {
      if (x0 >= vp.xMin && x0 <= vp.xMax) {
        out.push(x0);
      }
      return out;
    }
    const nLo: number = Math.ceil((vp.xMin - x0) / period);
    const nHi: number = Math.floor((vp.xMax - x0) / period);
    if (nHi - nLo > 400) {
      return out; // 过密（缩放过度），放弃绘制避免性能问题
    }
    for (let n = nLo; n <= nHi; n++) {
      out.push(x0 + n * period);
    }
    return out;
  }

  /** 零点标记：(x, 0) 处红点 + x 值标签 */
  private static drawZeroDot(ctx: CanvasRenderingContext2D, vp: Viewport, w: number, h: number,
    x: number, isDark: boolean): void {
    const sx: number = GraphMath.worldToScreenX(x, vp, w);
    const sy: number = GraphMath.worldToScreenY(0, vp, h);
    ctx.fillStyle = '#D7263D';
    ctx.beginPath();
    ctx.arc(sx, sy, 4, 0, Math.PI * 2);
    ctx.fill();
    ctx.fillStyle = GridAxisPainter.labelColor(isDark);
    ctx.textAlign = 'center';
    ctx.textBaseline = 'bottom';
    ctx.fillText('x=' + GridAxisPainter.fmtSmart(x), sx, sy - 6);
  }

  /** 极值标记：(x, y) 处绿色方框 + 极值标签 */
  private static drawExtremumBox(ctx: CanvasRenderingContext2D, vp: Viewport, w: number, h: number,
    x: number, y: number, kind: 'max' | 'min', isDark: boolean): void {
    const sx: number = GraphMath.worldToScreenX(x, vp, w);
    const sy: number = GraphMath.worldToScreenY(y, vp, h);
    ctx.strokeStyle = '#2E7D32';
    ctx.lineWidth = 2;
    ctx.strokeRect(sx - 4, sy - 4, 8, 8);
    ctx.fillStyle = GridAxisPainter.labelColor(isDark);
    ctx.textAlign = 'center';
    ctx.textBaseline = 'bottom';
    ctx.fillText((kind === 'max' ? '极大 ' : '极小 ') + 'f=' + GridAxisPainter.fmtSmart(y), sx, sy - 6);
  }

  /** 拐点标记：(x, y) 处蓝色菱形 + "拐" 标签 */
  private static drawInflectionDot(ctx: CanvasRenderingContext2D, vp: Viewport, w: number, h: number,
    x: number, y: number, isDark: boolean): void {
    const sx: number = GraphMath.worldToScreenX(x, vp, w);
    const sy: number = GraphMath.worldToScreenY(y, vp, h);
    ctx.fillStyle = '#1565C0';
    ctx.beginPath();
    ctx.moveTo(sx, sy - 5);
    ctx.lineTo(sx + 4, sy);
    ctx.lineTo(sx, sy + 5);
    ctx.lineTo(sx - 4, sy);
    ctx.closePath();
    ctx.fill();
    ctx.fillStyle = GridAxisPainter.labelColor(isDark);
    ctx.textAlign = 'center';
    ctx.textBaseline = 'bottom';
    ctx.fillText('拐(' + GridAxisPainter.fmtSmart(x) + ',' + GridAxisPainter.fmtSmart(y) + ')', sx, sy - 7);
  }

  /** 渐近线：垂直/水平/斜渐近线（紫色虚线，仅绘制视口内可见者） */
  private static drawAsymptotes(ctx: CanvasRenderingContext2D, vp: Viewport, w: number, h: number,
    a: GlobalAnalysisResult): void {
    ctx.save();
    ctx.strokeStyle = '#7B1FA2';
    ctx.lineWidth = 1;
    ctx.setLineDash([6, 4]);
    // 垂直渐近线 x = c
    for (let i = 0; i < a.asymptotes.vertical.length; i++) {
      const c: number = a.asymptotes.vertical[i];
      if (c >= vp.xMin && c <= vp.xMax) {
        const sx: number = GraphMath.worldToScreenX(c, vp, w);
        ctx.beginPath();
        ctx.moveTo(sx, 0);
        ctx.lineTo(sx, h);
        ctx.stroke();
        ctx.fillStyle = '#7B1FA2';
        ctx.textAlign = 'left';
        ctx.textBaseline = 'top';
        ctx.fillText('x=' + GridAxisPainter.fmtSmart(c), sx + 3, 4);
      }
    }
    // 水平渐近线 y = c
    for (let i = 0; i < a.asymptotes.horizontal.length; i++) {
      const ha: HorizontalAsymptote = a.asymptotes.horizontal[i];
      if (ha.y >= vp.yMin && ha.y <= vp.yMax) {
        const sy: number = GraphMath.worldToScreenY(ha.y, vp, h);
        ctx.beginPath();
        ctx.moveTo(0, sy);
        ctx.lineTo(w, sy);
        ctx.stroke();
        ctx.fillStyle = '#7B1FA2';
        ctx.textAlign = 'left';
        ctx.textBaseline = 'bottom';
        ctx.fillText('y=' + GridAxisPainter.fmtSmart(ha.y), 4, sy - 3);
      }
    }
    // 斜渐近线 y = kx + b
    for (let i = 0; i < a.asymptotes.oblique.length; i++) {
      const oa: ObliqueAsymptote = a.asymptotes.oblique[i];
      const yAtLeft: number = oa.k * vp.xMin + oa.b;
      const yAtRight: number = oa.k * vp.xMax + oa.b;
      const sx1: number = GraphMath.worldToScreenX(vp.xMin, vp, w);
      const sy1: number = GraphMath.worldToScreenY(yAtLeft, vp, h);
      const sx2: number = GraphMath.worldToScreenX(vp.xMax, vp, w);
      const sy2: number = GraphMath.worldToScreenY(yAtRight, vp, h);
      ctx.beginPath();
      ctx.moveTo(sx1, sy1);
      ctx.lineTo(sx2, sy2);
      ctx.stroke();
    }
    ctx.restore();
  }
}
