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
// calcengine-graph/src/main/ets/engine/InequalityRenderer.ets
/**
 * 不等式渲染器（模式 C: F(x,y) > 0 / < 0 / >= / <=）
 *
 * 底层使用 GridSampleEngine2D 进行二维网格采样，
 * 对每个网格单元判定不等式满足情况，生成填充区域 + 边界等值线。
 *
 * 性能架构（分帧提取 + 帧期纯查询，与 ImplicitRenderer 对齐）：
 * - 填充区域与边界线段是世界坐标、视图无关的数学实体，提取一次即可跨帧复用
 * - 提取由 pumpExtraction 在帧间分批推进，遵守行数/求值/墙钟三重预算
 * - extractVisible（帧期）只做行分桶查询 + 包围盒裁剪，零求值、零 MS 迭代
 *
 * 历史缺陷（已修正）：提取原先挂在 extractVisible 的 regionsDirty 分支上同步执行，
 * 而 extractVisible 由手势回调里的 draw() 调用，等价于在 UI 线程上跑完整网格的
 * AMR 递归；配合无全局上界的成本，高频函数会直接冻结主线程。详见 ExtractionBudget。
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
import { GridSampleEngine2D, GridExtendResult } from './GridSampleEngine2D';
import { IChunkedGridRenderer, RenderData, RenderMode, LineSegment, Polygon, Point2D } from './IRenderer';
import { InequalityDirection } from './ExprClassifier';
import { ExtractionBudget, SegmentCaps } from './ExtractionBudget';

/** 缓冲扩展比例 */
const BUFFER_RATIO: number = 0.5;
/** AMR 最大细分深度（边界附近有效分辨率 = 基础网格 × 2^深度） */
const AMR_MAX_DEPTH: number = 4;
/** 图元数越过软上限后的降级深度 */
const AMR_DEGRADED_DEPTH: number = 1;
/** AMR 细分终止屏幕尺寸（单元格屏幕宽度 ≤ 此值时不再细分） */
const AMR_MIN_CELL_PX: number = 1.5;

/** 区域包围盒（帧期快速裁剪用，与行桶内的 regions 平行存储） */
interface RegionBound {
  xMin: number;
  yMin: number;
  xMax: number;
  yMax: number;
}

/** 待提取的单元格矩形（行列均为半开区间） */
interface ExtractRect {
  i0: number;
  j0: number;
  i1: number;
  j1: number;
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

  // ── 提取产物：按单元格行分桶（区域 / 包围盒 / 边界线段三者行号一致） ──
  private rowRegions: Polygon[][] = [];
  private rowBounds: RegionBound[][] = [];
  private rowBoundary: LineSegment[][] = [];
  /** 已提取图元总数（区域 + 边界线段），软/硬上限判定用 */
  private itemCount: number = 0;
  private truncated: boolean = false;

  // ── 提取流水线游标 ──
  private pendingRects: ExtractRect[] = [];
  private curRect: ExtractRect | null = null;
  private curRowOrder: Int32Array = new Int32Array(0);
  private curRowPos: number = 0;
  private curCol: number = 0;
  private extractionActive: boolean = false;

  private buildPixelDx: number = 0;
  private extractPixelDx: number = 0;
  private targetPixelDx: number = 0;
  private extractCenterY: number = 0;

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
    this.buildPixelDx = pixelWorldDx;
    this.extractCenterY = (vp.yMin + vp.yMax) * 0.5;
    this.beginFullExtraction();
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
    this.extractCenterY = (vp.yMin + vp.yMax) * 0.5;
  }

  /**
   * 分块构建第二阶段：填充接下来的 maxNodeRows 个节点行。
   * 填满后原子替换 gridCache 并登记全量提取任务，返回 true。
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
      this.beginFullExtraction();
    }
    return done;
  }

  isGridReady(): boolean {
    return this.pendingGrid === null &&
      this.gridCache !== null && this.gridCache.values !== null;
  }

  hasPendingExtraction(): boolean {
    return this.extractionActive;
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

    if (this.gridCache.covers(newXMin, newXMax, newYMin, newYMax)) {
      return;
    }
    const res: GridExtendResult = GridSampleEngine2D.extendCache(this.gridCache,
      this.evaluator, newXMin, newXMax, newYMin, newYMax);
    if (!res.extended) {
      return;
    }
    this.extractCenterY = (newVp.yMin + newVp.yMax) * 0.5;
    this.enqueueExtendedStrips(res);
  }

  /** 登记扩展后需要提取的条带（语义与 ImplicitRenderer.enqueueExtendedStrips 一致） */
  private enqueueExtendedStrips(res: GridExtendResult): void {
    const cache: GridCache2D | null = this.gridCache;
    if (cache === null) return;

    if (this.extractionActive) {
      this.beginFullExtraction();
      return;
    }

    const newRows: number = cache.rows;
    const newCols: number = cache.cols;
    const offI: number = res.leftCols;
    const offJ: number = res.bottomRows;

    const shiftedRegions: Polygon[][] = [];
    const shiftedBounds: RegionBound[][] = [];
    const shiftedBoundary: LineSegment[][] = [];
    for (let j: number = 0; j < newRows; j++) {
      const oldJ: number = j - offJ;
      if (oldJ >= 0 && oldJ < this.rowRegions.length) {
        shiftedRegions.push(this.rowRegions[oldJ]);
        shiftedBounds.push(this.rowBounds[oldJ]);
        shiftedBoundary.push(this.rowBoundary[oldJ]);
      } else {
        shiftedRegions.push([]);
        shiftedBounds.push([]);
        shiftedBoundary.push([]);
      }
    }
    this.rowRegions = shiftedRegions;
    this.rowBounds = shiftedBounds;
    this.rowBoundary = shiftedBoundary;

    this.pendingRects = [];
    this.curRect = null;
    this.curRowOrder = new Int32Array(0);
    this.curRowPos = 0;
    this.curCol = 0;
    this.pushRect(0, 0, newCols, offJ);
    this.pushRect(0, offJ + res.oldRows, newCols, newRows);
    this.pushRect(0, offJ, offI, offJ + res.oldRows);
    this.pushRect(offI + res.oldCols, offJ, newCols, offJ + res.oldRows);
    this.extractionActive = this.pendingRects.length > 0;
  }

  /**
   * 刷新提取精度：只记录目标精度，不立即重置游标。
   * 缩放/运镜动画期间本方法每帧都会被调用，若每帧归零游标则提取永远无法完成。
   */
  refreshExtraction(pixelWorldDx: number): void {
    if (this.gridCache === null || this.gridCache.values === null) return;
    if (this.extractPixelDx > 0 && pixelWorldDx >= this.extractPixelDx * 0.9) return;
    this.targetPixelDx = pixelWorldDx;
  }

  commitPendingPrecision(): boolean {
    if (this.targetPixelDx <= 0) return false;
    const pwDx: number = this.targetPixelDx;
    this.targetPixelDx = 0;
    if (this.gridCache === null || this.gridCache.values === null) return false;
    if (this.extractPixelDx > 0 && pwDx >= this.extractPixelDx * 0.9) return false;
    this.buildPixelDx = pwDx;
    this.beginFullExtraction();
    return true;
  }

  /**
   * 帧期查询：行分桶 + 包围盒裁剪。绝不做求值、绝不做 MS 迭代、绝不触发提取。
   */
  extractVisible(vp: Viewport): RenderData {
    const cache: GridCache2D | null = this.gridCache;
    const visibleRegions: Polygon[] = [];
    const visibleBoundary: LineSegment[] = [];

    if (cache !== null && cache.rows > 0 && cache.dy > 0 && this.rowRegions.length > 0) {
      let jMin: number = Math.floor((vp.yMin - cache.yMin) / cache.dy);
      let jMax: number = Math.floor((vp.yMax - cache.yMin) / cache.dy);
      if (jMin < 0) jMin = 0;
      if (jMax > cache.rows - 1) jMax = cache.rows - 1;
      const limit: number = Math.min(jMax, this.rowRegions.length - 1);

      for (let j: number = jMin; j <= limit; j++) {
        // 区域：包围盒裁剪（游程合并后的矩形可跨多列，故 x/y 双向判定）
        const regions: Polygon[] = this.rowRegions[j];
        const bounds: RegionBound[] = this.rowBounds[j];
        for (let r: number = 0; r < regions.length; r++) {
          const b: RegionBound = bounds[r];
          if (b.xMax < vp.xMin || b.xMin > vp.xMax ||
            b.yMax < vp.yMin || b.yMin > vp.yMax) {
            continue;
          }
          visibleRegions.push(regions[r]);
        }
        // 边界线段：y 已严格落在本行内，只需 x 方向裁剪
        const segs: LineSegment[] = this.rowBoundary[j];
        for (let k: number = 0; k < segs.length; k++) {
          const s: LineSegment = segs[k];
          const segXMin: number = Math.min(s.x1, s.x2);
          const segXMax: number = Math.max(s.x1, s.x2);
          if (segXMax < vp.xMin || segXMin > vp.xMax) {
            continue;
          }
          visibleBoundary.push(s);
        }
      }
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
      cacheValid: cache !== null && cache.values !== null
    };
  }

  // ==================== 分帧提取流水线 ====================

  private beginFullExtraction(): void {
    this.rowRegions = [];
    this.rowBounds = [];
    this.rowBoundary = [];
    this.itemCount = 0;
    this.truncated = false;
    this.pendingRects = [];
    this.curRect = null;
    this.curRowOrder = new Int32Array(0);
    this.curRowPos = 0;
    this.curCol = 0;

    const cache: GridCache2D | null = this.gridCache;
    if (cache === null || cache.values === null) {
      this.extractionActive = false;
      this.extractPixelDx = this.buildPixelDx;
      return;
    }
    this.pushRect(0, 0, cache.cols, cache.rows);
    this.extractionActive = true;
  }

  private pushRect(i0: number, j0: number, i1: number, j1: number): void {
    if (i1 <= i0 || j1 <= j0) return;
    const r: ExtractRect = { i0: i0, j0: j0, i1: i1, j1: j1 };
    this.pendingRects.push(r);
  }

  /**
   * 推进一步提取。预算窗口由调度方统一 begin（与 ImplicitRenderer 同约定），
   * 多个渲染器共享同一窗口以形成全局每帧上限。
   */
  pumpExtraction(budget: ExtractionBudget, vp: Viewport): boolean {
    if (!this.extractionActive) return true;

    const cache: GridCache2D | null = this.gridCache;
    const values: Float64Array | null = (cache !== null) ? cache.values : null;
    if (cache === null || values === null || this.evaluator === null) {
      this.extractionActive = false;
      this.extractPixelDx = this.buildPixelDx;
      return true;
    }
    // 预算已被前面的渲染器耗尽 → 本轮不做工，下一轮重新 begin 后续跑
    if (budget.shouldStop()) return false;

    this.extractCenterY = (vp.yMin + vp.yMax) * 0.5;
    const pwDx: number = this.buildPixelDx > 0 ?
      this.buildPixelDx : (vp.xMax - vp.xMin) / 400;
    // 段数上限按画布像素推导（而非固定 200000），与 ImplicitRenderer 同源策略
    const caps: SegmentCaps = SegmentCaps.of(pwDx, vp.xMax - vp.xMin);
    const maxDepth: number = (this.itemCount >= caps.soft) ?
      AMR_DEGRADED_DEPTH : AMR_MAX_DEPTH;
    const stride: number = cache.cols + 1;
    const poleFlags: number[] | null = cache.poleFlags;

    while (true) {
      if (this.curRect === null) {
        if (this.pendingRects.length === 0) {
          this.extractionActive = false;
          this.extractPixelDx = pwDx;
          return true;
        }
        const next: ExtractRect = this.pendingRects.shift()!;
        this.curRect = next;
        this.curRowOrder = this.buildRowOrder(next, cache);
        this.curRowPos = 0;
        this.curCol = next.i0;
      }
      const rect: ExtractRect = this.curRect;
      if (this.curRowPos >= this.curRowOrder.length) {
        this.curRect = null;
        continue;
      }

      const j: number = this.curRowOrder[this.curRowPos];
      const before: number = this.regionsFor(j).length + this.boundaryFor(j).length;
      this.extractRowSlice(cache, values, poleFlags, j, j * stride,
        rect.i1, pwDx, maxDepth, budget);
      const after: number = this.regionsFor(j).length + this.boundaryFor(j).length;
      this.itemCount += after - before;

      if (this.curCol >= rect.i1) {
        this.curRowPos++;
        this.curCol = rect.i0;
        budget.countRow();
      }

      if (this.itemCount >= caps.hard) {
        this.truncated = true;
        this.pendingRects = [];
        this.curRect = null;
        this.extractionActive = false;
        this.extractPixelDx = pwDx;
        return true;
      }
      if (budget.shouldStop()) {
        return false;
      }
    }
  }

  /** 行遍历序：从最接近视口中心的行向两侧交替展开（O(n) 双端填充） */
  private buildRowOrder(rect: ExtractRect, cache: GridCache2D): Int32Array {
    const n: number = rect.j1 - rect.j0;
    const order: Int32Array = new Int32Array(n > 0 ? n : 0);
    if (n <= 0) return order;

    const centerRowF: number = (this.extractCenterY - cache.yMin) / cache.dy - 0.5;
    let lo: number = Math.floor(centerRowF);
    if (lo < rect.j0) lo = rect.j0;
    if (lo > rect.j1 - 1) lo = rect.j1 - 1;
    let hi: number = lo + 1;
    let k: number = 0;
    while (k < n) {
      if (lo >= rect.j0) {
        order[k] = lo;
        k++;
        lo--;
      }
      if (k >= n) break;
      if (hi < rect.j1) {
        order[k] = hi;
        k++;
        hi++;
      }
      if (lo < rect.j0 && hi >= rect.j1) break;
    }
    return order;
  }

  private regionsFor(j: number): Polygon[] {
    while (this.rowRegions.length <= j) {
      const a: Polygon[] = [];
      const b: RegionBound[] = [];
      const c: LineSegment[] = [];
      this.rowRegions.push(a);
      this.rowBounds.push(b);
      this.rowBoundary.push(c);
    }
    return this.rowRegions[j];
  }

  private boundsFor(j: number): RegionBound[] {
    this.regionsFor(j);
    return this.rowBounds[j];
  }

  private boundaryFor(j: number): LineSegment[] {
    this.regionsFor(j);
    return this.rowBoundary[j];
  }

  /**
   * 处理行 j 中 [this.curCol, iLimit) 的单元格，并推进 this.curCol。
   * 行内可中断：求值配额耗尽即返回，下次泵入从 curCol 续跑。
   */
  private extractRowSlice(cache: GridCache2D, values: Float64Array,
    poleFlags: number[] | null, j: number, rowOff: number, iLimit: number,
    pixelWorldDx: number, maxDepth: number, budget: ExtractionBudget): void {

    const stride: number = cache.cols + 1;
    const regions: Polygon[] = this.regionsFor(j);
    const rBounds: RegionBound[] = this.boundsFor(j);
    const boundary: LineSegment[] = this.boundaryFor(j);
    const y0: number = cache.yMin + j * cache.dy;
    const y1: number = y0 + cache.dy;

    let i: number = this.curCol;
    while (i < iLimit) {
      const off: number = rowOff + i;
      const v00: number = values[off];
      const v10: number = values[off + 1];
      const v11: number = values[off + stride + 1];
      const v01: number = values[off + stride];

      // 跳过含 NaN 的格子
      if (!isFinite(v00) || !isFinite(v10) || !isFinite(v11) || !isFinite(v01)) {
        i++;
        this.curCol = i;
        if (budget.evalsExhausted()) return;
        continue;
      }

      const satCount: number = (this.satisfies(v00) ? 1 : 0) +
        (this.satisfies(v10) ? 1 : 0) + (this.satisfies(v11) ? 1 : 0) +
        (this.satisfies(v01) ? 1 : 0);

      if (satCount === 4) {
        // 全满足 → 水平游程合并：连续全满足格子合并为一个大矩形
        const iStart: number = i;
        let iEnd: number = i;
        while (iEnd + 1 < iLimit) {
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
        } else {
          const x0: number = cache.xMin + i * cache.dx;
          const x1: number = x0 + cache.dx;
          this.extractMixedCellAMR(regions, rBounds, boundary,
            x0, y0, x1, y1, v00, v10, v11, v01, 0, maxDepth, pixelWorldDx, budget);
          i++;
        }
      }
      this.curCol = i;
      if (budget.evalsExhausted()) return;
    }
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
    depth: number, maxDepth: number, pixelWorldDx: number,
    budget: ExtractionBudget): void {

    const cellPx: number = (x1 - x0) / pixelWorldDx;

    // 终止条件：深度上限 或 单元格已足够小 → 叶子级 MS 提取
    if (depth >= maxDepth || cellPx <= AMR_MIN_CELL_PX) {
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
    budget.consumeEvals(5);

    // 任一探针非有限 → 回退到叶子级 MS（避免 NaN 传播）
    if (!isFinite(vB) || !isFinite(vR) || !isFinite(vT) || !isFinite(vL) || !isFinite(vC)) {
      this.extractLeafCell(regions, rBounds, boundary, x0, y0, x1, y1,
        v00, v10, v11, v01);
      return;
    }

    // 振荡早退：4 个子格全部混合 → 边界在本尺度下已不可解析，
    // 继续细分只会产出亚像素级图元（与 ImplicitRenderer 同一约束）
    if (depth >= 1) {
      let mixed: number = 0;
      if (isMixedCell(v00, vB, vC, vL, this.direction)) mixed++;
      if (isMixedCell(vB, v10, vR, vC, this.direction)) mixed++;
      if (isMixedCell(vL, vC, vT, v01, this.direction)) mixed++;
      if (isMixedCell(vC, vR, v11, vT, this.direction)) mixed++;
      if (mixed === 4) {
        this.extractLeafCell(regions, rBounds, boundary, x0, y0, x1, y1,
          v00, v10, v11, v01);
        return;
      }
    }

    // 4 个子格分别处理（角点值全部复用，零额外求值）
    this.processSubCell(regions, rBounds, boundary,
      x0, y0, mx, my, v00, vB, vC, vL, depth, maxDepth, pixelWorldDx, budget);   // 左下
    this.processSubCell(regions, rBounds, boundary,
      mx, y0, x1, my, vB, v10, vR, vC, depth, maxDepth, pixelWorldDx, budget);   // 右下
    this.processSubCell(regions, rBounds, boundary,
      x0, my, mx, y1, vL, vC, vT, v01, depth, maxDepth, pixelWorldDx, budget);   // 左上
    this.processSubCell(regions, rBounds, boundary,
      mx, my, x1, y1, vC, vR, v11, vT, depth, maxDepth, pixelWorldDx, budget);   // 右上
  }

  /**
   * 处理子格：全满足 → 矩形填充；全不满足 → 跳过；混合 → 递归 AMR。
   */
  private processSubCell(regions: Polygon[], rBounds: RegionBound[],
    boundary: LineSegment[],
    x0: number, y0: number, x1: number, y1: number,
    v00: number, v10: number, v11: number, v01: number,
    depth: number, maxDepth: number, pixelWorldDx: number,
    budget: ExtractionBudget): void {

    const satCount: number = (this.satisfies(v00) ? 1 : 0) +
      (this.satisfies(v10) ? 1 : 0) + (this.satisfies(v11) ? 1 : 0) +
      (this.satisfies(v01) ? 1 : 0);

    if (satCount === 4) {
      // 全满足 → 精确矩形填充
      this.pushRegion(regions, rBounds, x0, y0, x1, y1, x0, y0, x1, y1);
    } else if (satCount === 0) {
      // 全不满足 → 跳过
      return;
    } else {
      // 混合 → 递归
      this.extractMixedCellAMR(regions, rBounds, boundary,
        x0, y0, x1, y1, v00, v10, v11, v01, depth + 1, maxDepth,
        pixelWorldDx, budget);
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
    this.rowRegions = [];
    this.rowBounds = [];
    this.rowBoundary = [];
    this.itemCount = 0;
    this.pendingRects = [];
    this.curRect = null;
    this.extractionActive = false;
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

/** 四角是否为混合状态（既有满足也有不满足，即边界穿过本单元格） */
function isMixedCell(v00: number, v10: number, v11: number, v01: number,
  direction: InequalityDirection): boolean {
  const sat: number = (satisfiesDir(v00, direction) ? 1 : 0) +
    (satisfiesDir(v10, direction) ? 1 : 0) +
    (satisfiesDir(v11, direction) ? 1 : 0) +
    (satisfiesDir(v01, direction) ? 1 : 0);
  return sat > 0 && sat < 4;
}

/** satisfies 的模块级等价实现（供自由函数使用） */
function satisfiesDir(value: number, direction: InequalityDirection): boolean {
  switch (direction) {
    case '>': return value > 0;
    case '<': return value < 0;
    case '>=': return value >= 0;
    case '<=': return value <= 0;
    default: return value > 0;
  }
}

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
