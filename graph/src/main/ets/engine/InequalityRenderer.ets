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
// features/graph/src/main/ets/engine/InequalityRenderer.ets
/**
 * 不等式渲染器（模式 C: F(x,y) > 0 / < 0 / >= / <=）
 *
 * 底层使用 GridSampleEngine2D 进行二维网格采样，
 * 对每个网格单元判定不等式满足情况，生成填充区域 + 边界等值线。
 *
 * 性能架构（构建期提取 + 帧期纯投影，与 ImplicitRenderer 对齐）：
 * - 填充区域与边界线段是世界坐标、视图无关的数学实体
 * - 网格构建完成时一次性执行全网格提取（含游程合并 + AMR 边界细分），缓存结果
 * - extractVisible（帧期）仅做包围盒过滤，零求值、零 MS 迭代、零对象分配
 *
 * 策略：
 * - 四角全部满足 → 水平游程合并为大矩形（大幅降低 Canvas 填充开销）
 * - 四角全不满足 → 不填充
 * - 混合情况 → AMR 递归细分：满足侧子格直接填充矩形，边界子格递归至叶子后
 *   Marching Squares 提取边界线段 + 三角化填充满足侧
 * - 边界线始终用 Marching Squares 提取 F(x,y) = 0 等值线
 */

import { Viewport } from '../math/GraphMath';
import { BivariateEvaluator } from './BivariateEvaluator';
import { GridCache2D } from './GridCache2D';
import { GridSampleEngine2D } from './GridSampleEngine2D';
import { IChunkedGridRenderer, RenderData, RenderMode, LineSegment, Polygon, Point2D } from './IRenderer';
import { InequalityDirection } from './ExprClassifier';

/** 缓冲扩展比例 */
const BUFFER_RATIO: number = 0.5;
/** AMR 最大细分深度（边界附近有效分辨率 = 基础网格 × 2^深度） */
const AMR_MAX_DEPTH: number = 4;
/** AMR 细分终止屏幕尺寸（单元格屏幕宽度 ≤ 此值时不再细分） */
const AMR_MIN_CELL_PX: number = 1.5;

/** 区域包围盒（帧期快速裁剪用，与 cachedRegions 平行存储） */
interface RegionBound {
  xMin: number;
  yMin: number;
  xMax: number;
  yMax: number;
}

/**
 * Marching Squares 查找表
 * 16 种情况 → 连接的边对
 *
 * 四角编号：
 *   3(i,j+1) --- 2(i+1,j+1)
 *   |                |
 *   0(i,j)     ---  1(i+1,j)
 *
 * 边编号：0=底(0→1), 1=右(1→2), 2=顶(3→2), 3=左(0→3)
 */
const MARCHING_SQUARES_TABLE: number[][][] = [
  /* 0:  0000 */ [],
  /* 1:  0001 */ [[3, 0]],
  /* 2:  0010 */ [[0, 1]],
  /* 3:  0011 */ [[3, 1]],
  /* 4:  0100 */ [[1, 2]],
  /* 5:  0101 */ [[3, 0], [1, 2]],
  /* 6:  0110 */ [[0, 2]],
  /* 7:  0111 */ [[3, 2]],
  /* 8:  1000 */ [[2, 3]],
  /* 9:  1001 */ [[2, 0]],
  /* 10: 1010 */ [[0, 1], [2, 3]],
  /* 11: 1011 */ [[2, 1]],
  /* 12: 1100 */ [[1, 3]],
  /* 13: 1101 */ [[1, 0]],
  /* 14: 1110 */ [[0, 3]],
  /* 15: 1111 */ []
];

export class InequalityRenderer implements IChunkedGridRenderer {
  readonly mode: RenderMode = RenderMode.INEQUALITY;

  private readonly fnId: number;
  private readonly expr: string;
  private readonly direction: InequalityDirection;
  private evaluator: BivariateEvaluator | null = null;
  private gridCache: GridCache2D | null = null;
  /** 分块构建中的新网格（未填满前不对外生效，填满后原子替换 gridCache） */
  private pendingGrid: GridCache2D | null = null;

  // ── 构建期提取 + 缓存（消除帧期重复提取的对象分配开销） ──
  /** 缓存的填充区域（世界坐标，网格构建完成时一次性提取） */
  private cachedRegions: Polygon[] = [];
  /** 区域包围盒（与 cachedRegions 一一对应，帧期快速裁剪） */
  private regionBounds: RegionBound[] = [];
  /** 缓存的边界线段（F=0 等值线，世界坐标） */
  private cachedBoundary: LineSegment[] = [];
  /** 缓存脏标记：网格变更（扩展/替换）后置 true，下次 extractVisible 惰性重提取 */
  private regionsDirty: boolean = true;
  /** 构建时的像素世界间距（AMR 终止条件依赖此精度） */
  private buildPixelDx: number = 0;
  /** 上次提取使用的像素世界间距（避免冗余重提取） */
  private extractPixelDx: number = 0;

  constructor(fnId: number, expr: string, isDegMode: boolean,
    direction: InequalityDirection) {
    this.fnId = fnId;
    this.expr = expr;
    this.direction = direction;
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
    // 构建完成 → 立即执行全网格提取（一次性，后续帧期零开销）
    this.buildPixelDx = pixelWorldDx;
    this.rebuildRegionCache(pixelWorldDx);
  }

  /**
   * 分块构建第一阶段：创建空网格（不求值，快速返回）。
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
   * 填满后原子替换 gridCache 并执行全网格提取，返回 true。
   * 构建期间 extractVisible 继续用旧缓存渲染，不中断显示。
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
      // 网格替换完成 → 一次性全网格提取，填充区域 + 边界缓存
      this.rebuildRegionCache(this.buildPixelDx);
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
      // 网格已变更 → 标记缓存失效，惰性重提取
      this.regionsDirty = true;
    }
  }

  /**
   * 刷新提取精度：缩放导致当前缓存密度不足时，
   * 标记以更精细的 AMR 终止条件重新提取（不重建网格，仅重提取）。
   * 由 RenderDispatcher.onViewportChange 在视口变化时调用。
   */
  refreshExtraction(pixelWorldDx: number): void {
    if (this.gridCache === null || this.gridCache.values === null) return;
    // 仅当精度显著提升（>10%）时才标记重提取，避免冗余工作
    if (this.extractPixelDx > 0 && pixelWorldDx >= this.extractPixelDx * 0.9) return;
    this.buildPixelDx = pixelWorldDx;
    this.regionsDirty = true;
  }

  extractVisible(vp: Viewport): RenderData {
    // 惰性重提取（网格扩展 / 精度刷新后的首次帧）
    if (this.regionsDirty) {
      const pwDx: number = this.buildPixelDx > 0 ? this.buildPixelDx :
        (vp.xMax - vp.xMin) / 400;
      this.rebuildRegionCache(pwDx);
    }

    // 帧期：包围盒快速裁剪（零求值、零对象分配）
    const visibleRegions: Polygon[] = [];
    const bounds: RegionBound[] = this.regionBounds;
    for (let i: number = 0; i < this.cachedRegions.length; i++) {
      const b: RegionBound = bounds[i];
      if (b.xMax < vp.xMin || b.xMin > vp.xMax ||
        b.yMax < vp.yMin || b.yMin > vp.yMax) {
        continue;
      }
      visibleRegions.push(this.cachedRegions[i]);
    }

    const visibleBoundary: LineSegment[] = [];
    const segs: LineSegment[] = this.cachedBoundary;
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
      visibleBoundary.push(s);
    }

    return {
      mode: RenderMode.INEQUALITY,
      fnId: this.fnId,
      color: '',
      lineWidth: 2,
      lineStyle: 'solid',
      expr: this.expr,
      fillRegions: visibleRegions,
      boundarySegments: visibleBoundary,
      cacheValid: this.gridCache !== null && this.gridCache.values !== null
    };
  }

  // ==================== 构建期全网格提取 ====================

  /**
   * 全网格提取（网格构建完成 / 扩展后执行一次，结果缓存）。
   *
   * 遍历全部网格单元：
   * - 全满足 → 水平游程合并为大矩形
   * - 全不满足 → 跳过
   * - 混合 → AMR 递归细分（满足侧子格填充矩形，边界子格递归至叶子出线段 + 填充）
   *
   * 开销集中在构建期，帧期 extractVisible 完全不做网格遍历。
   */
  private rebuildRegionCache(pixelWorldDx: number): void {
    const cache: GridCache2D | null = this.gridCache;
    if (cache === null || cache.values === null || this.evaluator === null) {
      this.cachedRegions = [];
      this.regionBounds = [];
      this.cachedBoundary = [];
      this.regionsDirty = false;
      this.extractPixelDx = pixelWorldDx;
      return;
    }

    const regions: Polygon[] = [];
    const rBounds: RegionBound[] = [];
    const boundary: LineSegment[] = [];
    const values: Float64Array = cache.values;
    const stride: number = cache.cols + 1;
    const poleFlags: number[] | null = cache.poleFlags;

    for (let j: number = 0; j < cache.rows; j++) {
      const rowOff: number = j * stride;
      const y0: number = cache.yMin + j * cache.dy;
      const y1: number = y0 + cache.dy;
      let i: number = 0;
      while (i < cache.cols) {
        const off: number = rowOff + i;
        const v00: number = values[off];
        const v10: number = values[off + 1];
        const v11: number = values[off + stride + 1];
        const v01: number = values[off + stride];

        // 跳过含 NaN 的格子
        if (!isFinite(v00) || !isFinite(v10) || !isFinite(v11) || !isFinite(v01)) {
          i++;
          continue;
        }

        const s00: boolean = this.satisfies(v00);
        const s10: boolean = this.satisfies(v10);
        const s11: boolean = this.satisfies(v11);
        const s01: boolean = this.satisfies(v01);
        const satCount: number =
          (s00 ? 1 : 0) + (s10 ? 1 : 0) + (s11 ? 1 : 0) + (s01 ? 1 : 0);

        if (satCount === 4) {
          // 全满足 → 水平游程合并：连续全满足格子合并为一个大矩形
          const iStart: number = i;
          let iEnd: number = i;
          while (iEnd + 1 < cache.cols) {
            const ni: number = iEnd + 1;
            const nOff: number = rowOff + ni;
            const nv00: number = values[nOff];
            const nv10: number = values[nOff + 1];
            const nv11: number = values[nOff + stride + 1];
            const nv01: number = values[nOff + stride];
            if (!isFinite(nv00) || !isFinite(nv10) || !isFinite(nv11) || !isFinite(nv01)) {
              break;
            }
            if (!this.satisfies(nv00) || !this.satisfies(nv10) ||
              !this.satisfies(nv11) || !this.satisfies(nv01)) {
              break;
            }
            iEnd = ni;
          }
          const rx0: number = cache.xMin + iStart * cache.dx;
          const rx1: number = cache.xMin + (iEnd + 1) * cache.dx;
          this.pushRegion(regions, rBounds, rx0, y0, rx1, y1, rx0, y0, rx1, y1);
          i = iEnd + 1;
        } else if (satCount === 0) {
          // 全不满足 → 跳过
          i++;
        } else {
          // 跳过奇点单元格（极点/无穷间断）
          if (poleFlags !== null && poleFlags[j * cache.cols + i] === 1) {
            i++;
            continue;
          }
          // 混合情况 → AMR 递归细分提取
          const x0: number = cache.xMin + i * cache.dx;
          const x1: number = x0 + cache.dx;
          this.extractMixedCellAMR(regions, rBounds, boundary,
            x0, y0, x1, y1, v00, v10, v11, v01, 0, pixelWorldDx);
          i++;
        }
      }
    }

    this.cachedRegions = regions;
    this.regionBounds = rBounds;
    this.cachedBoundary = boundary;
    this.extractPixelDx = pixelWorldDx;
    this.regionsDirty = false;
  }

  /**
   * AMR 递归提取混合单元格。
   *
   * 细分策略：求值边中点 + 中心共 5 个探针，将单元格分为 4 个子格：
   * - 全满足子格 → 直接填充矩形（精确）
   * - 全不满足子格 → 跳过
   * - 混合子格 → 递归处理（深度 +1）
   * 同一父格的 4 个子格共享 5 个探针值，无重复求值。
   */
  private extractMixedCellAMR(regions: Polygon[], rBounds: RegionBound[],
    boundary: LineSegment[],
    x0: number, y0: number, x1: number, y1: number,
    v00: number, v10: number, v11: number, v01: number,
    depth: number, pixelWorldDx: number): void {

    const cellPx: number = (x1 - x0) / pixelWorldDx;

    // 终止条件：深度上限 或 单元格已足够小 → 叶子级 MS 提取
    if (depth >= AMR_MAX_DEPTH || cellPx <= AMR_MIN_CELL_PX) {
      this.extractLeafCell(regions, rBounds, boundary, x0, y0, x1, y1,
        v00, v10, v11, v01);
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

    // 任一探针非有限 → 回退到叶子级 MS（避免 NaN 传播）
    if (!isFinite(vB) || !isFinite(vR) || !isFinite(vT) || !isFinite(vL) || !isFinite(vC)) {
      this.extractLeafCell(regions, rBounds, boundary, x0, y0, x1, y1,
        v00, v10, v11, v01);
      return;
    }

    // 4 个子格分别处理（角点值全部复用，零额外求值）
    this.processSubCell(regions, rBounds, boundary,
      x0, y0, mx, my, v00, vB, vC, vL, depth, pixelWorldDx);   // 左下
    this.processSubCell(regions, rBounds, boundary,
      mx, y0, x1, my, vB, v10, vR, vC, depth, pixelWorldDx);   // 右下
    this.processSubCell(regions, rBounds, boundary,
      x0, my, mx, y1, vL, vC, vT, v01, depth, pixelWorldDx);   // 左上
    this.processSubCell(regions, rBounds, boundary,
      mx, my, x1, y1, vC, vR, v11, vT, depth, pixelWorldDx);   // 右上
  }

  /**
   * 处理子格：全满足 → 矩形填充；全不满足 → 跳过；混合 → 递归 AMR。
   */
  private processSubCell(regions: Polygon[], rBounds: RegionBound[],
    boundary: LineSegment[],
    x0: number, y0: number, x1: number, y1: number,
    v00: number, v10: number, v11: number, v01: number,
    depth: number, pixelWorldDx: number): void {

    const s00: boolean = this.satisfies(v00);
    const s10: boolean = this.satisfies(v10);
    const s11: boolean = this.satisfies(v11);
    const s01: boolean = this.satisfies(v01);
    const satCount: number =
      (s00 ? 1 : 0) + (s10 ? 1 : 0) + (s11 ? 1 : 0) + (s01 ? 1 : 0);

    if (satCount === 4) {
      // 全满足 → 精确矩形填充
      this.pushRegion(regions, rBounds, x0, y0, x1, y1, x0, y0, x1, y1);
    } else if (satCount === 0) {
      // 全不满足 → 跳过
      return;
    } else {
      // 混合 → 递归
      this.extractMixedCellAMR(regions, rBounds, boundary,
        x0, y0, x1, y1, v00, v10, v11, v01, depth + 1, pixelWorldDx);
    }
  }

  /**
   * 叶子级提取：Marching Squares 边界线段 + 满足侧填充多边形。
   * 此时单元格已足够小（≤ AMR_MIN_CELL_PX 像素），线性插值精度足够。
   */
  private extractLeafCell(regions: Polygon[], rBounds: RegionBound[],
    boundary: LineSegment[],
    x0: number, y0: number, x1: number, y1: number,
    v00: number, v10: number, v11: number, v01: number): void {

    const s00: boolean = this.satisfies(v00);
    const s10: boolean = this.satisfies(v10);
    const s11: boolean = this.satisfies(v11);
    const s01: boolean = this.satisfies(v01);

    // case index（满足=1，不满足=0）
    let caseIndex: number = 0;
    if (s00) caseIndex |= 1;
    if (s10) caseIndex |= 2;
    if (s11) caseIndex |= 4;
    if (s01) caseIndex |= 8;
    if (caseIndex === 0 || caseIndex === 15) return;

    // 计算 4 条边的穿越点坐标
    const edgePoints: number[] = [
      lerp(x0, x1, v00, v10), y0,   // 边 0: 底边
      x1, lerp(y0, y1, v10, v11),   // 边 1: 右边
      lerp(x0, x1, v01, v11), y1,   // 边 2: 顶边
      x0, lerp(y0, y1, v00, v01)    // 边 3: 左边
    ];

    // 提取边界线段
    const edgePairs: number[][] = MARCHING_SQUARES_TABLE[caseIndex];
    for (let p: number = 0; p < edgePairs.length; p++) {
      const e0: number = edgePairs[p][0];
      const e1: number = edgePairs[p][1];
      boundary.push({
        x1: edgePoints[e0 * 2],
        y1: edgePoints[e0 * 2 + 1],
        x2: edgePoints[e1 * 2],
        y2: edgePoints[e1 * 2 + 1]
      });
    }

    // 填充满足侧多边形
    this.fillMixedCell(regions, rBounds, caseIndex, x0, y0, x1, y1, edgePoints);
  }

  /**
   * 填充混合格子：根据 case index 生成满足侧的多边形。
   * 策略：顺时针遍历四条边，收集满足角 + 穿越点，构成多边形。
   */
  private fillMixedCell(regions: Polygon[], rBounds: RegionBound[],
    caseIndex: number,
    x0: number, y0: number, x1: number, y1: number,
    edgePoints: number[]): void {

    // 四角坐标
    const corners: number[] = [
      x0, y0,  // 0: 左下
      x1, y0,  // 1: 右下
      x1, y1,  // 2: 右上
      x0, y1   // 3: 左上
    ];

    // 各角是否满足
    const sats: boolean[] = [
      (caseIndex & 1) !== 0,
      (caseIndex & 2) !== 0,
      (caseIndex & 4) !== 0,
      (caseIndex & 8) !== 0
    ];

    // 顺时针遍历四条边，收集满足侧顶点序列
    const polyPoints: number[] = [];
    for (let e: number = 0; e < 4; e++) {
      const nextE: number = (e + 1) % 4;
      const cornerStart: number = e;
      const cornerEnd: number = nextE;

      // 如果起始角满足，加入该角
      if (sats[cornerStart]) {
        polyPoints.push(corners[cornerStart * 2], corners[cornerStart * 2 + 1]);
      }

      // 检查这条边上是否有边界穿越
      const edgeCaseBits: number = (sats[cornerStart] ? 1 : 0) | (sats[cornerEnd] ? 2 : 0);
      if (edgeCaseBits === 1 || edgeCaseBits === 2) {
        // 检查这条边是否在 marching squares 的边对中
        let edgeUsed: boolean = false;
        const pairs: number[][] = MARCHING_SQUARES_TABLE[caseIndex];
        for (let p: number = 0; p < pairs.length; p++) {
          if (pairs[p][0] === e || pairs[p][1] === e) {
            edgeUsed = true;
            break;
          }
        }
        if (edgeUsed) {
          polyPoints.push(edgePoints[e * 2], edgePoints[e * 2 + 1]);
        }
      }
    }

    // 至少 3 个点才构成多边形
    if (polyPoints.length >= 6) {
      const points: Point2D[] = [];
      let bxMin: number = Infinity;
      let bxMax: number = -Infinity;
      let byMin: number = Infinity;
      let byMax: number = -Infinity;
      for (let k: number = 0; k < polyPoints.length; k += 2) {
        const px: number = polyPoints[k];
        const py: number = polyPoints[k + 1];
        const pt: Point2D = { x: px, y: py };
        points.push(pt);
        if (px < bxMin) bxMin = px;
        if (px > bxMax) bxMax = px;
        if (py < byMin) byMin = py;
        if (py > byMax) byMax = py;
      }
      const poly: Polygon = { points: points };
      regions.push(poly);
      rBounds.push({ xMin: bxMin, yMin: byMin, xMax: bxMax, yMax: byMax });
    }
  }

  /** 添加矩形填充区域（含包围盒） */
  private pushRegion(regions: Polygon[], rBounds: RegionBound[],
    x0: number, y0: number, x1: number, y1: number,
    bxMin: number, byMin: number, bxMax: number, byMax: number): void {
    const p0: Point2D = { x: x0, y: y0 };
    const p1: Point2D = { x: x1, y: y0 };
    const p2: Point2D = { x: x1, y: y1 };
    const p3: Point2D = { x: x0, y: y1 };
    const pts: Point2D[] = [p0, p1, p2, p3];
    const poly: Polygon = { points: pts };
    regions.push(poly);
    rBounds.push({ xMin: bxMin, yMin: byMin, xMax: bxMax, yMax: byMax });
  }

  /**
   * 判定值是否满足不等式方向
   */
  private satisfies(value: number): boolean {
    switch (this.direction) {
      case '>': return value > 0;
      case '<': return value < 0;
      case '>=': return value >= 0;
      case '<=': return value <= 0;
      default: return value > 0;
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
    this.cachedRegions = [];
    this.regionBounds = [];
    this.cachedBoundary = [];
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
 * 线性插值：在值 a 和 b 之间找到零穿越位置
 */
function lerp(x0: number, x1: number, v0: number, v1: number): number {
  if (Math.abs(v1 - v0) < 1e-15) {
    return (x0 + x1) * 0.5;
  }
  const t: number = -v0 / (v1 - v0);
  const tc: number = Math.max(0, Math.min(1, t));
  return x0 + tc * (x1 - x0);
}
