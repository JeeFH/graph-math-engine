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
 * GraphGestureMath - 手势命中检测数学层（GraphGestureLayer 的计算部分）
 *
 * 从 GraphCanvas 拆分出的纯几何计算：单指轻点时判定命中哪条曲线。
 * - Pass 1：显函数沿 x 扫描线采样，点到线段距离判定（任意斜率无死区）
 * - Pass 1b：y 轴扫描线兜底（近垂直陡峭曲线的弦段偏离修正）
 * - Pass 2：隐函数 / 不等式 / 二元方程走渲染器线段图元命中
 *
 * 与组件状态无关，全部输入经 HitTestEnv 传入，可独立测试。
 */

import {
  GraphMath, Viewport, FunctionEvaluator, GraphFunction,
  RenderDispatcher, RenderData, RenderMode, LineSegment
} from 'graph';

/** 命中检测环境：GraphCanvas 每次轻点时组装传入 */
export interface HitTestEnv {
  /** 函数列表 */
  functions: GraphFunction[];
  /** 当前视口 */
  viewport: Viewport;
  /** 画布尺寸（vp） */
  canvasW: number;
  canvasH: number;
  /** 渲染调度器（非显函数线段数据源） */
  renderDispatcher: RenderDispatcher;
  /** 预构建的 FunctionEvaluator 缓存（按函数 id） */
  evaluatorCache: Map<number, FunctionEvaluator>;
}

export class GraphGestureMath {
  /**
   * 命中检测：返回距点击点最近且在阈值内的函数 id（无命中返回 -1）。
   * @param env 命中检测环境
   * @param px 点击点 x（Canvas 坐标系，vp）
   * @param py 点击点 y（Canvas 坐标系，vp）
   */
  static hitTest(env: HitTestEnv, px: number, py: number): number {
    const w: number = env.canvasW;
    const h: number = env.canvasH;
    if (w <= 0 || h <= 0) {
      return -1;
    }
    const threshold: number = 32; // vp：点击偏离曲线多少像素内算命中
    const win: number = 64; // 搜索窗口半宽（px）
    const step: number = 2; // 采样步长（px）
    const x0: number = Math.max(0, px - win);
    const x1: number = Math.min(w, px + win);
    let bestId: number = -1;
    let bestDist: number = threshold;

    // ── Pass 1: EXPLICIT 模式（y = f(x)，FunctionEvaluator 采样） ──
    // 点到线段距离：将相邻有效采样点连成线段（与渲染折线模型一致）。
    // 陡峭函数（如 y=999x）相邻采样点屏幕间距可达数百 px，若仅计算点到
    // 离散采样点距离会产生「命中死区」；改为点到线段距离后任意斜率均可命中。
    for (let i = 0; i < env.functions.length; i++) {
      const fn: GraphFunction = env.functions[i];
      if (!fn.enabled) {
        continue;
      }
      const mode: RenderMode | null = env.renderDispatcher.getMode(fn.id);
      if (mode !== null && mode !== RenderMode.EXPLICIT) {
        continue; // 非显函数跳过，由 Pass 2 处理
      }
      const ev: FunctionEvaluator | undefined = env.evaluatorCache.get(fn.id);
      if (ev == undefined || !ev.isValid) {
        continue;
      }
      let minD: number = threshold;
      let prevSx: number = NaN;
      let prevSy: number = NaN;
      for (let sx = x0; sx <= x1; sx += step) {
        const wx: number = GraphMath.screenToWorldX(sx, env.viewport, w);
        let y: number;
        try {
          y = ev.evaluate(wx);
        } catch (e) {
          prevSx = NaN; // 求值失败：断开线段，避免跨越无定义区间误连
          continue;
        }
        if (!isFinite(y)) {
          prevSx = NaN; // 无穷值（极点 / 定义域边界）：同样断开线段
          continue;
        }
        const sy: number = GraphMath.worldToScreenY(y, env.viewport, h);
        if (!Number.isNaN(prevSx)) {
          const d: number = GraphGestureMath.pointToSegDist(px, py, prevSx, prevSy, sx, sy);
          if (d < minD) {
            minD = d;
          }
        }
        prevSx = sx;
        prevSy = sy;
      }
      if (minD < bestDist) {
        bestDist = minD;
        bestId = fn.id;
      }
    }

    // ── Pass 1b: y 轴扫描线兜底（近垂直陡峭曲线） ──
    // 极端陡峭的非线性函数（如 y=kx³ 在 k 极大时）Pass 1 的 2px 步长弦段
    // 在屏幕空间曲率过大仍可能偏离真实曲线；此处沿 py 邻域逐行步进，对每行
    // 在 [x0,x1] 内用相邻采样符号变化 + 线性插值求曲线交点，以交点距离判定命中。
    for (let i = 0; i < env.functions.length; i++) {
      const fn: GraphFunction = env.functions[i];
      if (!fn.enabled) {
        continue;
      }
      const mode: RenderMode | null = env.renderDispatcher.getMode(fn.id);
      if (mode !== null && mode !== RenderMode.EXPLICIT) {
        continue;
      }
      const ev: FunctionEvaluator | undefined = env.evaluatorCache.get(fn.id);
      if (ev == undefined || !ev.isValid) {
        continue;
      }
      let minD: number = threshold;
      const y0: number = Math.max(0, py - win);
      const y1: number = Math.min(h, py + win);
      for (let sy = y0; sy <= y1; sy += step) {
        const wy: number = GraphMath.screenToWorldY(sy, env.viewport, h);
        let prevX: number = NaN;
        let prevVal: number = NaN;
        for (let sx = x0; sx <= x1; sx += step) {
          const wx: number = GraphMath.screenToWorldX(sx, env.viewport, w);
          let val: number;
          try {
            val = ev.evaluate(wx) - wy;
          } catch (e) {
            prevVal = NaN;
            continue;
          }
          if (!isFinite(val)) {
            prevVal = NaN;
            continue;
          }
          // 符号变化（含零点接触）：曲线在 prevX 与 sx 之间穿过水平线 y=wy
          if (!Number.isNaN(prevVal) &&
            ((prevVal <= 0 && val >= 0) || (prevVal >= 0 && val <= 0))) {
            const denom: number = prevVal - val;
            const t: number = denom !== 0 ? prevVal / denom : 0.5;
            const crossSx: number = prevX + t * (sx - prevX);
            const d: number = Math.hypot(crossSx - px, sy - py);
            if (d < minD) {
              minD = d;
            }
          }
          prevX = sx;
          prevVal = val;
        }
      }
      if (minD < bestDist) {
        bestDist = minD;
        bestId = fn.id;
      }
    }

    // ── Pass 2: 非显函数（隐函数 / 不等式 / 二元方程）──
    // 利用渲染调度器产出的线段图元做点到线段距离检测
    let hasNonExplicit: boolean = false;
    for (let i = 0; i < env.functions.length; i++) {
      const fn: GraphFunction = env.functions[i];
      if (!fn.enabled) {
        continue;
      }
      const mode: RenderMode | null = env.renderDispatcher.getMode(fn.id);
      if (mode === RenderMode.IMPLICIT || mode === RenderMode.BIVARIATE_EQ || mode === RenderMode.INEQUALITY) {
        hasNonExplicit = true;
        break;
      }
    }
    if (hasNonExplicit) {
      const vp: Viewport = env.viewport;
      const styleMap: Map<number, GraphFunction> = new Map();
      for (let i = 0; i < env.functions.length; i++) {
        styleMap.set(env.functions[i].id, env.functions[i]);
      }
      const allRenderData: RenderData[] = env.renderDispatcher.extractAll(vp, styleMap);
      for (let i = 0; i < env.functions.length; i++) {
        const fn: GraphFunction = env.functions[i];
        if (!fn.enabled) {
          continue;
        }
        const mode: RenderMode | null = env.renderDispatcher.getMode(fn.id);
        if (mode === null || mode === RenderMode.EXPLICIT) {
          continue;
        }
        // 查找该函数的 RenderData
        let rd: RenderData | null = null;
        for (let k = 0; k < allRenderData.length; k++) {
          if (allRenderData[k].fnId === fn.id) {
            rd = allRenderData[k];
            break;
          }
        }
        if (rd == null) {
          continue;
        }
        let minD: number = threshold;
        // IMPLICIT / BIVARIATE_EQ：使用 contourSegments
        if ((mode === RenderMode.IMPLICIT || mode === RenderMode.BIVARIATE_EQ) && rd.contourSegments != null) {
          minD = GraphGestureMath.hitTestSegments(px, py, vp, w, h, rd.contourSegments);
        }
        // INEQUALITY：使用 boundarySegments
        if (mode === RenderMode.INEQUALITY && rd.boundarySegments != null) {
          const bd: number = GraphGestureMath.hitTestSegments(px, py, vp, w, h, rd.boundarySegments);
          if (bd < minD) {
            minD = bd;
          }
        }
        if (minD < bestDist) {
          bestDist = minD;
          bestId = fn.id;
        }
      }
    }

    return bestId;
  }

  /**
   * 点到线段集合的最近距离（屏幕空间）
   * 遍历所有线段，将世界坐标端点投影到屏幕坐标后计算点到线段距离，取最小值。
   */
  static hitTestSegments(px: number, py: number, vp: Viewport,
    w: number, h: number, segments: LineSegment[]): number {
    let minD: number = Infinity;
    for (let i = 0; i < segments.length; i++) {
      const seg: LineSegment = segments[i];
      const sx1: number = GraphMath.worldToScreenX(seg.x1, vp, w);
      const sy1: number = GraphMath.worldToScreenY(seg.y1, vp, h);
      const sx2: number = GraphMath.worldToScreenX(seg.x2, vp, w);
      const sy2: number = GraphMath.worldToScreenY(seg.y2, vp, h);
      const d: number = GraphGestureMath.pointToSegDist(px, py, sx1, sy1, sx2, sy2);
      if (d < minD) {
        minD = d;
      }
    }
    return minD;
  }

  /**
   * 点 (px,py) 到线段 (x1,y1)-(x2,y2) 的欧氏距离
   */
  static pointToSegDist(px: number, py: number,
    x1: number, y1: number, x2: number, y2: number): number {
    const dx: number = x2 - x1;
    const dy: number = y2 - y1;
    const lenSq: number = dx * dx + dy * dy;
    if (lenSq < 1e-12) {
      // 退化线段（两端点重合）→ 退化为点到点距离
      return Math.hypot(px - x1, py - y1);
    }
    // 投影参数 t ∈ [0,1]，钳制到线段范围
    let t: number = ((px - x1) * dx + (py - y1) * dy) / lenSq;
    if (t < 0) {
      t = 0;
    } else if (t > 1) {
      t = 1;
    }
    const closestX: number = x1 + t * dx;
    const closestY: number = y1 + t * dy;
    return Math.hypot(px - closestX, py - closestY);
  }
}
