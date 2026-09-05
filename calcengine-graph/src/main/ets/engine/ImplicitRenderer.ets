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
// calcengine-graph/src/main/ets/engine/ImplicitRenderer.ets
/**
 * 隐函数 / 方程渲染器（模式 B: F(x,y) = 0）
 *
 * 底层使用 GridSampleEngine2D 进行二维网格采样，
 * 通过 Marching Squares 算法提取 F(x,y) = 0 的等值线。
 *
 * 性能架构（分帧提取 + 帧期纯查询）：
 * - 等值线是世界坐标、视图无关的数学实体，提取一次即可跨帧复用
 * - 提取由 pumpExtraction 在帧间分批推进，严格遵守行数/求值/墙钟三重预算
 * - extractVisible（帧期）只做行分桶查询 + 包围盒裁剪，零求值、零 MS 迭代
 *
 * 历史缺陷（已修正）：提取原先挂在 extractVisible 的脏标记分支上，而 extractVisible
 * 由手势回调里的 draw() 同步调用，于是「平移结束的一次重绘」= 「在 UI 线程上跑完
 * 整个网格的 AMR 递归」。配合 AMR 无全局上界，sin(x·y) 这类高频函数会触发千万级
 * 求值与百万级线段分配，实测 THREAD_BLOCK_6S、Rss 420MB、设备级卡死。
 *
 * AMR（Adaptive Mesh Refinement）自适应网格细化：
 * - 仅对曲线穿过的单元格（通常 <10% 网格）递归细分
 * - 每级求值边中点 + 中心共 5 个探针，子格共享父格探针值（无重复求值）
 * - 曲线附近有效分辨率提升 2^AMR_MAX_DEPTH 倍，高曲率区域
 *   （心形线尖端、抛物线极值）自动获得像素级线段密度
 *
 * 成本约束（与被积函数的振荡密度解耦）：
 * - 振荡早退：depth ≥ 1 时若 4 个子格全部含穿越，说明零集在本尺度已不可解析，
 *   直接在当前深度出 MS 线段。这对光滑曲线无影响（穿越子格通常为 2 个），
 *   但把 sin(x·y) 这类函数的单格成本从 ~425 次求值压到 ~25 次。
 * - 段数软上限 → AMR 深度降级；段数硬上限 → 截断并标记 truncated。
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
import { GridSampleEngine2D, GridExtendResult } from './GridSampleEngine2D';
import { IChunkedGridRenderer, RenderData, RenderMode, LineSegment } from './IRenderer';
import { ExtractionBudget, SEGMENT_SOFT_CAP, SEGMENT_HARD_CAP } from './ExtractionBudget';

/** 缓冲扩展比例 */
const BUFFER_RATIO: number = 0.5;
/** AMR 最大细分深度（曲线附近有效分辨率 = 基础网格 × 2^深度） */
const AMR_MAX_DEPTH: number = 4;
/** 段数越过软上限后的降级深度：保留一层细分以维持曲线连续性，放弃更高密度 */
const AMR_DEGRADED_DEPTH: number = 1;
/** AMR 细分终止屏幕尺寸（单元格屏幕宽度 ≤ 此值时不再细分，直接出线段） */
const AMR_MIN_CELL_PX: number = 1.5;

/**
 * 待提取的单元格矩形（行列均为半开区间 [i0,i1) × [j0,j1)）。
 *
 * 全量提取时只有一个覆盖整网格的矩形；增量扩展时是四条新增条带，
 * 使平移后只需提取新增区域，而不是重跑整个网格。
 */
interface ExtractRect {
  i0: number;
  j0: number;
  i1: number;
  j1: number;
}

export class ImplicitRenderer implements IChunkedGridRenderer {
  readonly mode: RenderMode = RenderMode.IMPLICIT;

  protected readonly fnId: number;
  protected readonly expr: string;
  protected evaluator: BivariateEvaluator | null = null;
  protected gridCache: GridCache2D | null = null;
  /** 分块构建中的新网格（未填满前不对外生效，填满后原子替换 gridCache） */
  protected pendingGrid: GridCache2D | null = null;

  // ── 提取产物：按单元格行分桶 ──
  /**
   * rowBuckets[j] = 基础单元格行 j 产出的全部线段。
   *
   * 行分桶使帧期可见性查询只需触碰视口覆盖的行，复杂度从
   * O(缓存总段数) 降到 O(可见段数)——缓存范围是视口 +50% 边距（面积 2.25×），
   * 旧实现每帧要白扫 1.25× 的段。分桶同时让增量提取可以 O(1) 追加。
   *
   * AMR 的所有子格都落在其基础单元格内，故线段 y 范围严格属于该行，分桶精确无泄漏。
   */
  protected rowBuckets: LineSegment[][] = [];
  /** 已提取线段总数（软/硬上限判定用） */
  protected segmentCount: number = 0;
  /** 是否因触及段数硬上限而截断 */
  protected truncated: boolean = false;

  // ── 提取流水线游标 ──
  /** 待提取矩形队列 */
  protected pendingRects: ExtractRect[] = [];
  /** 当前正在处理的矩形 */
  protected curRect: ExtractRect | null = null;
  /** 当前矩形的行遍历序（按距视口中心由近及远） */
  protected curRowOrder: Int32Array = new Int32Array(0);
  /** curRowOrder 中的下一个下标 */
  protected curRowPos: number = 0;
  /** 当前行内下一个待处理的列（行内可中断续跑） */
  protected curCol: number = 0;
  /** 是否有未完成的提取 */
  protected extractionActive: boolean = false;

  /** 构建时的像素世界间距（AMR 终止条件依赖此精度） */
  protected buildPixelDx: number = 0;
  /** 已完成提取所使用的像素世界间距 */
  protected extractPixelDx: number = 0;
  /** 待生效的目标精度（缩放/运镜期间只记录，结束后一次性提交） */
  protected targetPixelDx: number = 0;
  /** 行遍历序的排序中心（视口 y 中心） */
  protected extractCenterY: number = 0;

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
    this.buildPixelDx = pixelWorldDx;
    this.extractCenterY = (vp.yMin + vp.yMax) * 0.5;
    // 只登记提取任务，不同步执行：调用方需随后驱动 pumpExtraction
    this.beginFullExtraction();
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
    this.extractCenterY = (vp.yMin + vp.yMax) * 0.5;
  }

  /**
   * 分块构建第二阶段：填充接下来的 maxNodeRows 个节点行。
   * 填满后原子替换 gridCache（dispose 旧网格）并登记全量提取任务，返回 true。
   * 构建期间 extractVisible 继续用旧网格 + 旧线段渲染，不中断显示。
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
      // 网格替换完成 → 登记提取任务（实际提取由 pumpExtraction 分帧推进）
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
      // 扩展失败（超节点上限）→ 由调用方触发围绕当前视口的分块重建
      return;
    }
    this.extractCenterY = (newVp.yMin + newVp.yMax) * 0.5;
    this.enqueueExtendedStrips(res);
  }

  /**
   * 登记扩展后需要提取的单元格条带。
   *
   * 提取已完成时是纯增量：旧行桶按底部新增行数整体上移（线段是世界坐标，
   * 无需平移），只提取四条新增条带。
   * 提取尚未完成时游标与行序都基于旧网格坐标，无法安全续跑，
   * 改为对整个新网格重提取（仍受预算与上限约束，不会阻塞主线程）。
   */
  protected enqueueExtendedStrips(res: GridExtendResult): void {
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

    // 行桶整体上移 offJ 行；新增行与超出旧范围的行为空桶
    const shifted: LineSegment[][] = [];
    for (let j: number = 0; j < newRows; j++) {
      const oldJ: number = j - offJ;
      if (oldJ >= 0 && oldJ < this.rowBuckets.length) {
        shifted.push(this.rowBuckets[oldJ]);
      } else {
        shifted.push([]);
      }
    }
    this.rowBuckets = shifted;

    this.pendingRects = [];
    this.curRect = null;
    this.curRowOrder = new Int32Array(0);
    this.curRowPos = 0;
    this.curCol = 0;
    // 上下条带取全宽；左右条带只取旧行区间，避免与上下条带重复提取
    this.pushRect(0, 0, newCols, offJ);
    this.pushRect(0, offJ + res.oldRows, newCols, newRows);
    this.pushRect(0, offJ, offI, offJ + res.oldRows);
    this.pushRect(offI + res.oldCols, offJ, newCols, offJ + res.oldRows);
    this.extractionActive = this.pendingRects.length > 0;
  }

  /**
   * 刷新提取精度：缩放导致当前缓存线段密度不足时记录目标精度。
   *
   * 不在此立即重置提取游标：本方法在缩放/运镜动画期间每帧都会被调用，
   * 若每帧都归零游标，提取将永远无法完成（这正是「快照运镜卡顿」的成因之一）。
   * 由 commitPendingPrecision 在动画结束后一次性提交。
   */
  refreshExtraction(pixelWorldDx: number): void {
    if (this.gridCache === null || this.gridCache.values === null) return;
    // 仅当精度显著提升（>10%）时才需要重提取，避免冗余工作
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
   * 帧期查询：行分桶 + 包围盒裁剪。
   *
   * 契约：本方法绝不做求值、绝不做 MS 迭代、绝不触发提取。
   * 提取未完成的帧返回已提取部分（曲线渐进长出），由 pumpExtraction 续跑。
   */
  extractVisible(vp: Viewport): RenderData {
    const cache: GridCache2D | null = this.gridCache;
    const visible: LineSegment[] = [];

    if (cache !== null && cache.rows > 0 && cache.dy > 0 && this.rowBuckets.length > 0) {
      let jMin: number = Math.floor((vp.yMin - cache.yMin) / cache.dy);
      let jMax: number = Math.floor((vp.yMax - cache.yMin) / cache.dy);
      if (jMin < 0) jMin = 0;
      if (jMax > cache.rows - 1) jMax = cache.rows - 1;
      const bucketLimit: number = Math.min(jMax, this.rowBuckets.length - 1);
      for (let j: number = jMin; j <= bucketLimit; j++) {
        const bucket: LineSegment[] = this.rowBuckets[j];
        for (let k: number = 0; k < bucket.length; k++) {
          const s: LineSegment = bucket[k];
          const segXMin: number = Math.min(s.x1, s.x2);
          const segXMax: number = Math.max(s.x1, s.x2);
          if (segXMax < vp.xMin || segXMin > vp.xMax) {
            continue;
          }
          visible.push(s);
        }
      }
    }

    return {
      mode: RenderMode.IMPLICIT,
      fnId: this.fnId,
      color: '',
      lineWidth: 2,
      lineStyle: 'solid',
      expr: this.expr,
      contourSegments: visible,
      cacheValid: cache !== null && cache.values !== null
    };
  }

  // ==================== 分帧提取流水线 ====================

  /** 登记一次覆盖整个网格的全量提取（丢弃已有产物） */
  protected beginFullExtraction(): void {
    this.rowBuckets = [];
    this.segmentCount = 0;
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

  /** 入队一个待提取矩形（空矩形自动忽略） */
  protected pushRect(i0: number, j0: number, i1: number, j1: number): void {
    if (i1 <= i0 || j1 <= j0) return;
    const r: ExtractRect = { i0: i0, j0: j0, i1: i1, j1: j1 };
    this.pendingRects.push(r);
  }

  /**
   * 推进一步提取，严格遵守预算后返回。
   *
   * 可中断粒度：行内可断（curCol 记录断点），行间可断（curRowPos 记录断点），
   * 矩形间可断（pendingRects 队列）。任何时刻返回都已产出一批可渲染的线段。
   *
   * 预算窗口由调度方（RenderDispatcher.pumpExtractions）统一 begin，
   * 本方法不自行 begin，以便多个渲染器共享同一窗口、形成全局每帧上限。
   *
   * @returns true 表示提取已完成（或已因硬上限截断）
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

    this.extractCenterY = (vp.yMin + vp.yMax) * 0.5;
    // 预算已被前面的渲染器耗尽 → 本轮不做工，下一轮重新 begin 后续跑
    if (budget.shouldStop()) return false;
    const pwDx: number = this.buildPixelDx > 0 ?
      this.buildPixelDx : (vp.xMax - vp.xMin) / 400;
    // 段数越过软上限 → 降低 AMR 深度，用密度换覆盖面（曲线仍连续，无断裂伪影）
    const maxDepth: number = (this.segmentCount >= SEGMENT_SOFT_CAP) ?
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
      const bucket: LineSegment[] = this.bucketFor(j);
      const before: number = bucket.length;
      const rowOff: number = j * stride;

      let i: number = this.curCol;
      while (i < rect.i1) {
        this.extractCellAt(bucket, values, stride, poleFlags, cache,
          i, j, rowOff, pwDx, maxDepth, budget);
        i++;
        this.curCol = i;
        // 求值配额耗尽 → 行内断点续跑（不做墙钟检查，Date.now() 只在行边界调用）
        if (budget.evalsExhausted()) break;
      }
      this.segmentCount += bucket.length - before;

      if (this.curCol >= rect.i1) {
        this.curRowPos++;
        this.curCol = rect.i0;
        budget.countRow();
      }

      // 硬上限：内存有界优先于画面完整
      if (this.segmentCount >= SEGMENT_HARD_CAP) {
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

  /**
   * 生成矩形内的行遍历序：从最接近视口中心的行向两侧交替展开。
   *
   * 使「部分完成」的中间态总是先覆盖用户正在看的区域，而不是从网格底边
   * 逐行长上来——这是渐进精修在观感上成立的关键。O(n) 双端填充，无需排序。
   */
  protected buildRowOrder(rect: ExtractRect, cache: GridCache2D): Int32Array {
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

  /** 取（并按需创建）单元格行 j 的线段桶 */
  protected bucketFor(j: number): LineSegment[] {
    while (this.rowBuckets.length <= j) {
      const empty: LineSegment[] = [];
      this.rowBuckets.push(empty);
    }
    return this.rowBuckets[j];
  }

  /** 处理单个基础单元格：读四角、跳过无效格、交给 AMR */
  protected extractCellAt(bucket: LineSegment[], values: Float64Array,
    stride: number, poleFlags: number[] | null, cache: GridCache2D,
    i: number, j: number, rowOff: number,
    pixelWorldDx: number, maxDepth: number, budget: ExtractionBudget): void {

    const off: number = rowOff + i;
    const v00: number = values[off];
    const v10: number = values[off + 1];
    const v11: number = values[off + stride + 1];
    const v01: number = values[off + stride];

    // 跳过含 NaN 的格子
    if (!isFinite(v00) || !isFinite(v10) || !isFinite(v11) || !isFinite(v01)) {
      return;
    }
    // case 0（全负）和 case 15（全正）→ 无等值线穿越
    if (!cellCrossesZero(v00, v10, v11, v01)) {
      return;
    }
    // 跳过奇点单元格（极点/无穷间断）
    if (poleFlags !== null && poleFlags[j * cache.cols + i] === 1) {
      return;
    }

    const x0: number = cache.xMin + i * cache.dx;
    const y0: number = cache.yMin + j * cache.dy;
    this.extractCellAMR(bucket, x0, y0, x0 + cache.dx, y0 + cache.dy,
      v00, v10, v11, v01, 0, maxDepth, pixelWorldDx, budget);
  }

  /**
   * AMR 递归提取：对单个单元格判定细分或出线段。
   *
   * 细分策略：求值边中点 + 中心共 5 个探针，将单元格分为 4 个子格，
   * 对含曲线的子格递归处理。子格的四角值全部来自父格角点或探针值，
   * 同一父格的 4 个子格共享 5 个探针值，无重复求值。
   */
  protected extractCellAMR(bucket: LineSegment[],
    x0: number, y0: number, x1: number, y1: number,
    v00: number, v10: number, v11: number, v01: number,
    depth: number, maxDepth: number, pixelWorldDx: number,
    budget: ExtractionBudget): void {

    const cellPx: number = (x1 - x0) / pixelWorldDx;

    // 终止条件：深度上限 或 单元格已足够小 → 标准 MS 出线段
    if (depth >= maxDepth || cellPx <= AMR_MIN_CELL_PX) {
      this.extractCellMS(bucket, x0, y0, x1, y1, v00, v10, v11, v01);
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

    // 任一探针非有限 → 回退到基础 MS（避免 NaN 传播导致曲线断裂）
    if (!isFinite(vB) || !isFinite(vR) || !isFinite(vT) || !isFinite(vL) || !isFinite(vC)) {
      this.extractCellMS(bucket, x0, y0, x1, y1, v00, v10, v11, v01);
      return;
    }

    // 振荡早退：4 个子格全部含穿越 → 零集在本尺度下已不可解析。
    // 继续细分只会产出亚像素级的无意义线段，是 sin(x·y) 卡死的直接成本来源。
    // 对光滑曲线无影响：一条简单曲线穿过单元格时通常只占据 2 个（至多 3 个）子格；
    // 保留 depth 0 一层细分，使心形线尖端等真实高曲率特征仍能获得加密。
    if (depth >= 1) {
      let crossings: number = 0;
      if (cellCrossesZero(v00, vB, vC, vL)) crossings++;
      if (cellCrossesZero(vB, v10, vR, vC)) crossings++;
      if (cellCrossesZero(vL, vC, vT, v01)) crossings++;
      if (cellCrossesZero(vC, vR, v11, vT)) crossings++;
      if (crossings === 4) {
        this.extractCellMS(bucket, x0, y0, x1, y1, v00, v10, v11, v01);
        return;
      }
    }

    // 4 个子格递归（角点值全部复用，零额外求值）
    this.processSubCell(bucket, x0, y0, mx, my, v00, vB, vC, vL,
      depth, maxDepth, pixelWorldDx, budget);   // 左下
    this.processSubCell(bucket, mx, y0, x1, my, vB, v10, vR, vC,
      depth, maxDepth, pixelWorldDx, budget);   // 右下
    this.processSubCell(bucket, x0, my, mx, y1, vL, vC, vT, v01,
      depth, maxDepth, pixelWorldDx, budget);   // 左上
    this.processSubCell(bucket, mx, my, x1, y1, vC, vR, v11, vT,
      depth, maxDepth, pixelWorldDx, budget);   // 右上
  }

  /**
   * 处理子格：无穿越 → 跳过；有穿越 → 递归 AMR。
   */
  protected processSubCell(bucket: LineSegment[],
    x0: number, y0: number, x1: number, y1: number,
    v00: number, v10: number, v11: number, v01: number,
    depth: number, maxDepth: number, pixelWorldDx: number,
    budget: ExtractionBudget): void {
    if (!cellCrossesZero(v00, v10, v11, v01)) return;
    this.extractCellAMR(bucket, x0, y0, x1, y1, v00, v10, v11, v01,
      depth + 1, maxDepth, pixelWorldDx, budget);
  }

  /**
   * 标准 Marching Squares 单元格出线段（叶子操作）。
   * 零中间分配：仅在穿越边对需要时计算插值点坐标。
   */
  protected extractCellMS(bucket: LineSegment[],
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
      bucket.push({ x1: ax, y1: ay, x2: bx, y2: by });
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
    this.rowBuckets = [];
    this.segmentCount = 0;
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

/** 四角是否变号（即等值线是否可能穿越本单元格） */
function cellCrossesZero(v00: number, v10: number, v11: number, v01: number): boolean {
  const allPos: boolean = v00 >= 0 && v10 >= 0 && v11 >= 0 && v01 >= 0;
  const allNeg: boolean = v00 < 0 && v10 < 0 && v11 < 0 && v01 < 0;
  return !allPos && !allNeg;
}

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
