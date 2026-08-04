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
// features/graph/src/main/ets/engine/ImplicitRenderer.ets
/**
 * 隐函数 / 方程渲染器（模式 B: F(x,y) = 0）
 *
 * 底层使用 GridSampleEngine2D 进行二维网格采样，
 * 通过 Marching Squares 算法提取 F(x,y) = 0 的等值线。
 *
 * 性能架构（构建期提取 + 帧期纯投影）：
 * - 等值线提取结果是世界坐标、视图无关的数学实体
 * - 网格构建完成时一次性执行全网格 AMR 提取，缓存线段集合
 * - extractVisible（帧期）仅做视口裁剪过滤，零求值、零 MS 迭代
 *
 * AMR（Adaptive Mesh Refinement）自适应网格细化：
 * - 仅对曲线穿过的单元格（通常 <10% 网格）递归细分
 * - 每级求值边中点 + 中心共 5 个探针，子格共享父格探针值（无重复求值）
 * - 曲线附近有效分辨率提升 2^AMR_MAX_DEPTH 倍，高曲率区域
 *   （心形线尖端、抛物线极值）自动获得像素级线段密度
 *
 * Marching Squares 原理：
 * - 对每个 2×2 网格单元，根据四角符号组合（正/负）得到 16 种情况
 * - 查表确定等值线穿越哪些边
 * - 在穿越边上用线性插值定位精确穿越点
 * - 连接相邻穿越点形成线段
 */

import { Viewport } from '../math/GraphMath';
import { BivariateEvaluator } from './BivariateEvaluator';
import { GridCache2D } from './GridCache2D';
import { GridSampleEngine2D } from './GridSampleEngine2D';
import { IChunkedGridRenderer, RenderData, RenderMode, LineSegment } from './IRenderer';

/** 缓冲扩展比例 */
const BUFFER_RATIO: number = 0.5;
/** AMR 最大细分深度（曲线附近有效分辨率 = 基础网格 × 2^深度） */
const AMR_MAX_DEPTH: number = 4;
/** AMR 细分终止屏幕尺寸（单元格屏幕宽度 ≤ 此值时不再细分，直接出线段） */
const AMR_MIN_CELL_PX: number = 1.5;

export class ImplicitRenderer implements IChunkedGridRenderer {
  readonly mode: RenderMode = RenderMode.IMPLICIT;

  protected readonly fnId: number;
  protected readonly expr: string;
  protected evaluator: BivariateEvaluator | null = null;
  protected gridCache: GridCache2D | null = null;
  /** 分块构建中的新网格（未填满前不对外生效，填满后原子替换 gridCache） */
  protected pendingGrid: GridCache2D | null = null;

  // ── 构建期提取 + 线段缓存（消除帧期 Marching Squares 重算） ──
  /** 缓存的等值线段集合（世界坐标，视图无关，网格构建完成时一次性提取） */
  protected cachedSegments: LineSegment[] = [];
  /** 线段缓存脏标记：网格变更（扩展/替换）后置 true，下次 extractVisible 惰性重提取 */
  protected segmentsDirty: boolean = true;
  /** 构建时的像素世界间距（AMR 终止条件依赖此精度） */
  protected buildPixelDx: number = 0;
  /** 上次提取使用的像素世界间距（避免冗余重提取） */
  protected extractPixelDx: number = 0;

  constructor(fnId: number, expr: string, isDegMode: boolean) {
    this.fnId = fnId;
    this.expr = expr;
    try {
      this.evaluator = new BivariateEvaluator(expr, isDegMode);
    } catch (e) {
      this.evaluator = null;
    }
  }

  buildCache(vp: Viewport, pixelWorldDx: number): void {
    if (this.evaluator === null || !this.evaluator.isValid) return;

    const vpRange: number = Math.max(vp.xMax - vp.xMin, vp.yMax - vp.yMin);
    const cellSize: number = GridSampleEngine2D.suggestCellSize(vpRange, pixelWorldDx);

    this.gridCache = GridSampleEngine2D.buildCache(
      this.evaluator, this.fnId, this.expr,
      vp.xMin, vp.xMax, vp.yMin, vp.yMax, cellSize);
    // 构建完成 → 立即执行全网格 AMR 等值线提取（一次性，后续帧期零 MS 开销）
    this.buildPixelDx = pixelWorldDx;
    this.rebuildSegmentCache(pixelWorldDx);
  }

  /**
   * 分块构建第一阶段：创建空网格（不求值，快速返回）。
   * 丢弃任何未完成的旧 pendingGrid。
   */
  beginBuild(vp: Viewport, pixelWorldDx: number): void {
    if (this.evaluator === null || !this.evaluator.isValid) return;

    const vpRange: number = Math.max(vp.xMax - vp.xMin, vp.yMax - vp.yMin);
    const cellSize: number = GridSampleEngine2D.suggestCellSize(vpRange, pixelWorldDx);

    if (this.pendingGrid !== null) {
      this.pendingGrid.dispose();
      this.pendingGrid = null;
    }
    this.pendingGrid = GridSampleEngine2D.beginCache(
      this.fnId, this.expr,
      vp.xMin, vp.xMax, vp.yMin, vp.yMax, cellSize);
    this.buildPixelDx = pixelWorldDx;
  }

  /**
   * 分块构建第二阶段：填充接下来的 maxNodeRows 个节点行。
   * 填满后原子替换 gridCache（dispose 旧网格）并执行全网格 AMR 提取，返回 true。
   * 构建期间 extractVisible 继续用旧 gridCache + 旧线段渲染，不中断显示。
   */
  buildChunk(maxNodeRows: number): boolean {
    if (this.pendingGrid === null || this.evaluator === null) return true;

    const done: boolean = GridSampleEngine2D.fillGridChunk(
      this.pendingGrid, this.evaluator, maxNodeRows);
    if (done) {
      if (this.gridCache !== null) {
        this.gridCache.dispose();
      }
      this.gridCache = this.pendingGrid;
      this.pendingGrid = null;
      // 网格替换完成 → 一次性全网格 AMR 提取，填充线段缓存
      this.rebuildSegmentCache(this.buildPixelDx);
    }
    return done;
  }

  extendCache(newVp: Viewport): void {
    if (this.gridCache === null || this.evaluator === null || !this.evaluator.isValid) return;

    const xRange: number = newVp.xMax - newVp.xMin;
    const yRange: number = newVp.yMax - newVp.yMin;
    const xBuffer: number = xRange * BUFFER_RATIO;
    const yBuffer: number = yRange * BUFFER_RATIO;
    const newXMin: number = newVp.xMin - xBuffer;
    const newXMax: number = newVp.xMax + xBuffer;
    const newYMin: number = newVp.yMin - yBuffer;
    const newYMax: number = newVp.yMax + yBuffer;

    if (!this.gridCache.covers(newXMin, newXMax, newYMin, newYMax)) {
      GridSampleEngine2D.extendCache(this.gridCache, this.evaluator,
        newXMin, newXMax, newYMin, newYMax);
      // 网格已变更（或扩展失败待重建）→ 标记线段缓存失效，惰性重提取
      this.segmentsDirty = true;
    }
  }

  /**
   * 刷新提取精度：缩放导致当前缓存线段密度不足时，
   * 标记以更精细的 AMR 终止条件重新提取（不重建网格，仅重提取等值线）。
   * 由 RenderDispatcher.onViewportChange 在视口变化时调用。
   */
  refreshExtraction(pixelWorldDx: number): void {
    if (this.gridCache === null || this.gridCache.values === null) return;
    // 仅当精度显著提升（>10%）时才标记重提取，避免冗余工作
    if (this.extractPixelDx > 0 && pixelWorldDx >= this.extractPixelDx * 0.9) return;
    this.buildPixelDx = pixelWorldDx;
    this.segmentsDirty = true;
  }

  extractVisible(vp: Viewport): RenderData {
    // 惰性重提取（网格扩展 / 精度刷新后的首次帧）
    if (this.segmentsDirty) {
      const pwDx: number = this.buildPixelDx > 0 ? this.buildPixelDx :
        (vp.xMax - vp.xMin) / 400;
      this.rebuildSegmentCache(pwDx);
    }

    // 帧期：线性扫描缓存线段，包围盒快速裁剪（零求值、零 MS 迭代）
    const visible: LineSegment[] = [];
    const segs: LineSegment[] = this.cachedSegments;
    for (let i: number = 0; i < segs.length; i++) {
      const s: LineSegment = segs[i];
      const segXMin: number = Math.min(s.x1, s.x2);
      const segXMax: number = Math.max(s.x1, s.x2);
      const segYMin: number = Math.min(s.y1, s.y2);
      const segYMax: number = Math.max(s.y1, s.y2);
      if (segXMax < vp.xMin || segXMin > vp.xMax ||
        segYMax < vp.yMin || segYMin > vp.yMax) {
        continue;
      }
      visible.push(s);
    }

    return {
      mode: RenderMode.IMPLICIT,
      fnId: this.fnId,
      color: '',
      lineWidth: 2,
      lineStyle: 'solid',
      expr: this.expr,
      contourSegments: visible,
      cacheValid: this.gridCache !== null && this.gridCache.values !== null
    };
  }

  // ==================== 构建期 AMR 等值线提取 ====================

  /**
   * 全网格 AMR 等值线提取（网格构建完成 / 扩展后执行一次，结果缓存）。
   *
   * 遍历全部网格单元，对符号变化单元格：
   * - 单元格屏幕尺寸 > AMR_MIN_CELL_PX 且深度未达上限 → 递归细分提取
   * - 否则 → 标准 Marching Squares 线性插值出线段
   *
   * 仅曲线穿过的单元格被细分（通常 <10% 网格），开销集中在构建期，
   * 帧期 extractVisible 完全不做 MS 迭代。
   */
  protected rebuildSegmentCache(pixelWorldDx: number): void {
    const cache: GridCache2D | null = this.gridCache;
    if (cache === null || cache.values === null || this.evaluator === null) {
      this.cachedSegments = [];
      this.segmentsDirty = false;
      this.extractPixelDx = pixelWorldDx;
      return;
    }

    const segments: LineSegment[] = [];
    const values: Float64Array = cache.values;
    const stride: number = cache.cols + 1;
    const poleFlags: number[] | null = cache.poleFlags;

    for (let j: number = 0; j < cache.rows; j++) {
      const rowOff: number = j * stride;
      for (let i: number = 0; i < cache.cols; i++) {
        const off: number = rowOff + i;
        const v00: number = values[off];
        const v10: number = values[off + 1];
        const v11: number = values[off + stride + 1];
        const v01: number = values[off + stride];

        // 跳过含 NaN 的格子
        if (!isFinite(v00) || !isFinite(v10) || !isFinite(v11) || !isFinite(v01)) {
          continue;
        }

        // 计算 4-bit 索引（正=1，负=0）
        let caseIndex: number = 0;
        if (v00 >= 0) caseIndex |= 1;
        if (v10 >= 0) caseIndex |= 2;
        if (v11 >= 0) caseIndex |= 4;
        if (v01 >= 0) caseIndex |= 8;

        // case 0（全负）和 case 15（全正）→ 无等值线穿越
        if (caseIndex === 0 || caseIndex === 15) continue;

        // 跳过奇点单元格（极点/无穷间断）
        if (poleFlags !== null && poleFlags[j * cache.cols + i] === 1) continue;

        const x0: number = cache.xMin + i * cache.dx;
        const y0: number = cache.yMin + j * cache.dy;
        const x1: number = x0 + cache.dx;
        const y1: number = y0 + cache.dy;

        // AMR 递归提取（自动在高曲率区域加密）
        this.extractCellAMR(segments, x0, y0, x1, y1,
          v00, v10, v11, v01, 0, pixelWorldDx);
      }
    }

    this.cachedSegments = segments;
    this.extractPixelDx = pixelWorldDx;
    this.segmentsDirty = false;
  }

  /**
   * AMR 递归提取：对单个单元格判定细分或出线段。
   *
   * 细分策略：求值边中点 + 中心共 5 个探针，将单元格分为 4 个子格，
   * 对含曲线的子格递归处理。子格的四角值全部来自父格角点或探针值，
   * 同一父格的 4 个子格共享 5 个探针值，无重复求值。
   */
  protected extractCellAMR(segments: LineSegment[],
    x0: number, y0: number, x1: number, y1: number,
    v00: number, v10: number, v11: number, v01: number,
    depth: number, pixelWorldDx: number): void {

    const cellPx: number = (x1 - x0) / pixelWorldDx;

    // 终止条件：深度上限 或 单元格已足够小 → 标准 MS 出线段
    if (depth >= AMR_MAX_DEPTH || cellPx <= AMR_MIN_CELL_PX) {
      this.extractCellMS(segments, x0, y0, x1, y1, v00, v10, v11, v01);
      return;
    }

    const ev: BivariateEvaluator | null = this.evaluator;
    if (ev === null) return;

    const mx: number = (x0 + x1) * 0.5;
    const my: number = (y0 + y1) * 0.5;

    // 5 个探针：底边中点、右边中点、顶边中点、左边中点、中心
    const vB: number = GridSampleEngine2D.safeEvalPub(ev, mx, y0);
    const vR: number = GridSampleEngine2D.safeEvalPub(ev, x1, my);
    const vT: number = GridSampleEngine2D.safeEvalPub(ev, mx, y1);
    const vL: number = GridSampleEngine2D.safeEvalPub(ev, x0, my);
    const vC: number = GridSampleEngine2D.safeEvalPub(ev, mx, my);

    // 任一探针非有限 → 回退到基础 MS（避免 NaN 传播导致曲线断裂）
    if (!isFinite(vB) || !isFinite(vR) || !isFinite(vT) || !isFinite(vL) || !isFinite(vC)) {
      this.extractCellMS(segments, x0, y0, x1, y1, v00, v10, v11, v01);
      return;
    }

    // 4 个子格递归（角点值全部复用，零额外求值）：
    // 左下：v00, vB, vC, vL
    this.processSubCell(segments, x0, y0, mx, my, v00, vB, vC, vL, depth, pixelWorldDx);
    // 右下：vB, v10, vR, vC
    this.processSubCell(segments, mx, y0, x1, my, vB, v10, vR, vC, depth, pixelWorldDx);
    // 左上：vL, vC, vT, v01
    this.processSubCell(segments, x0, my, mx, y1, vL, vC, vT, v01, depth, pixelWorldDx);
    // 右上：vC, vR, v11, vT
    this.processSubCell(segments, mx, my, x1, y1, vC, vR, v11, vT, depth, pixelWorldDx);
  }

  /**
   * 处理子格：无穿越 → 跳过；有穿越 → 递归 AMR。
   */
  private processSubCell(segments: LineSegment[],
    x0: number, y0: number, x1: number, y1: number,
    v00: number, v10: number, v11: number, v01: number,
    depth: number, pixelWorldDx: number): void {
    let caseIndex: number = 0;
    if (v00 >= 0) caseIndex |= 1;
    if (v10 >= 0) caseIndex |= 2;
    if (v11 >= 0) caseIndex |= 4;
    if (v01 >= 0) caseIndex |= 8;
    if (caseIndex === 0 || caseIndex === 15) return;
    this.extractCellAMR(segments, x0, y0, x1, y1, v00, v10, v11, v01,
      depth + 1, pixelWorldDx);
  }

  /**
   * 标准 Marching Squares 单元格出线段（叶子操作）。
   * 零中间分配：仅在穿越边对需要时计算插值点坐标。
   */
  protected extractCellMS(segments: LineSegment[],
    x0: number, y0: number, x1: number, y1: number,
    v00: number, v10: number, v11: number, v01: number): void {

    let caseIndex: number = 0;
    if (v00 >= 0) caseIndex |= 1;
    if (v10 >= 0) caseIndex |= 2;
    if (v11 >= 0) caseIndex |= 4;
    if (v01 >= 0) caseIndex |= 8;
    if (caseIndex === 0 || caseIndex === 15) return;

    const edgePairs: number[][] = MARCHING_SQUARES_TABLE[caseIndex];
    for (let p: number = 0; p < edgePairs.length; p++) {
      let ax: number = 0, ay: number = 0, bx: number = 0, by: number = 0;
      switch (edgePairs[p][0]) {
        case 0: // 底边
          ax = lerp(x0, x1, v00, v10); ay = y0;
          break;
        case 1: // 右边
          ax = x1; ay = lerp(y0, y1, v10, v11);
          break;
        case 2: // 顶边
          ax = lerp(x0, x1, v01, v11); ay = y1;
          break;
        default: // 左边
          ax = x0; ay = lerp(y0, y1, v00, v01);
          break;
      }
      switch (edgePairs[p][1]) {
        case 0:
          bx = lerp(x0, x1, v00, v10); by = y0;
          break;
        case 1:
          bx = x1; by = lerp(y0, y1, v10, v11);
          break;
        case 2:
          bx = lerp(x0, x1, v01, v11); by = y1;
          break;
        default:
          bx = x0; by = lerp(y0, y1, v00, v01);
          break;
      }
      segments.push({ x1: ax, y1: ay, x2: bx, y2: by });
    }
  }

  dispose(): void {
    if (this.gridCache !== null) {
      this.gridCache.dispose();
      this.gridCache = null;
    }
    if (this.pendingGrid !== null) {
      this.pendingGrid.dispose();
      this.pendingGrid = null;
    }
    this.cachedSegments = [];
    this.evaluator = null;
  }

  cacheCovers(vp: Viewport): boolean {
    if (this.gridCache === null) return false;
    const xRange: number = vp.xMax - vp.xMin;
    const yRange: number = vp.yMax - vp.yMin;
    const xBuffer: number = xRange * BUFFER_RATIO;
    const yBuffer: number = yRange * BUFFER_RATIO;
    return this.gridCache.covers(
      vp.xMin - xBuffer, vp.xMax + xBuffer,
      vp.yMin - yBuffer, vp.yMax + yBuffer);
  }
}

// ==================== 辅助函数 ====================

/**
 * 线性插值：在值 a 和 b 之间找到零穿越位置。
 * 返回 t ∈ [0, 1]，使得 lerp(a, b, t) ≈ 0。
 */
function lerp(x0: number, x1: number, v0: number, v1: number): number {
  // 防止除零
  if (Math.abs(v1 - v0) < 1e-15) {
    return (x0 + x1) * 0.5;
  }
  const t: number = -v0 / (v1 - v0);
  // 钳制到 [0, 1]
  const tc: number = Math.max(0, Math.min(1, t));
  return x0 + tc * (x1 - x0);
}

// ==================== Marching Squares 查找表 ====================

/**
 * Marching Squares 16 种情况的边连接表。
 *
 * 四角编号：
 *   3(i,j+1) --- 2(i+1,j+1)
 *   |                |
 *   0(i,j)     ---  1(i+1,j)
 *
 * 四条边编号：
 *   边 0: 底边 0→1
 *   边 1: 右边 1→2
 *   边 2: 顶边 3→2
 *   边 3: 左边 0→3
 *
 * case 5 和 case 10 有歧义（鞍点），这里取默认连接方式。
 */
const MARCHING_SQUARES_TABLE: number[][][] = [
  /* 0:  0000 */ [],
  /* 1:  0001 */ [[3, 0]],
  /* 2:  0010 */ [[0, 1]],
  /* 3:  0011 */ [[3, 1]],
  /* 4:  0100 */ [[1, 2]],
  /* 5:  0101 */ [[3, 0], [1, 2]],  // 鞍点：两条线段
  /* 6:  0110 */ [[0, 2]],
  /* 7:  0111 */ [[3, 2]],
  /* 8:  1000 */ [[2, 3]],
  /* 9:  1001 */ [[2, 0]],
  /* 10: 1010 */ [[0, 1], [2, 3]],  // 鞍点：两条线段
  /* 11: 1011 */ [[2, 1]],
  /* 12: 1100 */ [[1, 3]],
  /* 13: 1101 */ [[1, 0]],
  /* 14: 1110 */ [[0, 3]],
  /* 15: 1111 */ []
];
