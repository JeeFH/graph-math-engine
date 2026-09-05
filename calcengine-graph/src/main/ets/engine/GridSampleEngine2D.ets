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
// calcengine-graph/src/main/ets/engine/GridSampleEngine2D.ets
/**
 * 二维网格采样引擎
 *
 * 对 F(x,y) 在固定世界坐标网格上均匀采样，生成 GridCache2D。
 * 供隐函数（Marching Squares 等值线）、不等式（区域填充）、二元方程共用。
 *
 * 核心设计（与 SampleEngine 1D 对齐）：
 * - 采样基准为世界坐标，与视图无关
 * - 可视窗口 + 向外扩展缓冲区间（默认 50% 扩展）
 * - 平移时仅补算新增行/列条带（增量扩展）
 * - 缩放时按需构建精细叠加层
 * - 总格数上限兜底（防止极端缩放导致内存爆炸）
 */

import { BivariateEvaluator } from './BivariateEvaluator';
import { GridCache2D } from './GridCache2D';

/** 单方向最大网格节点数（总格数上限 = MAX_GRID_NODE^2） */
const MAX_GRID_NODE: number = 500;
/** 缓冲扩展比例（可视范围向外扩展 50%） */
const BUFFER_RATIO: number = 0.5;
/** 增量扩展时的最小条带宽度（世界单位），防止过窄条带导致频繁触发 */
const MIN_EXTEND_WIDTH: number = 1e-6;
/** 奇点中心探针吹起倍率：|中心探针值| > maxC × 此倍率 → 判定奇点（sim4 扫描验证零误伤） */
const POLE_CENTER_FACTOR: number = 2.0;
/** 奇点边探针吹起倍率：|边探针值| > 该边两角最大 × 此倍率 → 判定奇点（sim4 扫描验证零误伤） */
const POLE_EDGE_FACTOR: number = 1.0;

/**
 * 网格增量扩展结果。
 *
 * 渲染器需要知道「哪些单元格是新增的」，才能只对新增条带做等值线提取，
 * 而不是在每次平移后重提取整个网格（后者正是平移卡顿的根因之一）。
 */
export interface GridExtendResult {
  /** 是否真的扩展了（false = 无需扩展，或超节点上限被放弃） */
  extended: boolean;
  /** 扩展前的列数 */
  oldCols: number;
  /** 扩展前的行数 */
  oldRows: number;
  /** 左侧新增列数 */
  leftCols: number;
  /** 右侧新增列数 */
  rightCols: number;
  /** 底部新增行数 */
  bottomRows: number;
  /** 顶部新增行数 */
  topRows: number;
}

export class GridSampleEngine2D {

  /**
   * 全量构建二维网格缓存。
   *
   * @param ev 双变量求值器
   * @param fnId 函数稳定 id
   * @param exprHash 表达式哈希（用于失效判定）
   * @param vpXMin 视口 xMin
   * @param vpXMax 视口 xMax
   * @param vpYMin 视口 yMin
   * @param vpYMax 视口 yMax
   * @param targetCellSize 目标网格间距（世界单位），由 pixelWorldDx 决定
   * @returns 构建完成的 GridCache2D
   */
  static buildCache(ev: BivariateEvaluator, fnId: number, exprHash: string,
    vpXMin: number, vpXMax: number, vpYMin: number, vpYMax: number,
    targetCellSize: number): GridCache2D {

    // 可视范围 + 缓冲扩展
    const xRange: number = vpXMax - vpXMin;
    const yRange: number = vpYMax - vpYMin;
    const xBuffer: number = xRange * BUFFER_RATIO;
    const yBuffer: number = yRange * BUFFER_RATIO;
    const xMin: number = vpXMin - xBuffer;
    const xMax: number = vpXMax + xBuffer;
    const yMin: number = vpYMin - yBuffer;
    const yMax: number = vpYMax + yBuffer;

    return GridSampleEngine2D.buildGrid(ev, fnId, exprHash,
      xMin, xMax, yMin, yMax, targetCellSize);
  }

  /**
   * 分块构建第一阶段：计算网格维度并创建空缓存（values = []，filledRows = 0）。
   * 不执行任何求值，快速返回。随后用 fillGridChunk 逐行填充。
   * 范围与 buildCache 一致（可视范围 + 缓冲扩展）。
   */
  static beginCache(fnId: number, exprHash: string,
    vpXMin: number, vpXMax: number, vpYMin: number, vpYMax: number,
    targetCellSize: number): GridCache2D {

    const xRange: number = vpXMax - vpXMin;
    const yRange: number = vpYMax - vpYMin;
    const xBuffer: number = xRange * BUFFER_RATIO;
    const yBuffer: number = yRange * BUFFER_RATIO;
    const xMin: number = vpXMin - xBuffer;
    const xMax: number = vpXMax + xBuffer;
    const yMin: number = vpYMin - yBuffer;
    const yMax: number = vpYMax + yBuffer;

    return GridSampleEngine2D.beginGrid(fnId, exprHash,
      xMin, xMax, yMin, yMax, targetCellSize);
  }

  /**
   * 分块构建第二阶段：填充接下来的 maxNodeRows 个节点行。
   * 从 cache.filledRows 处继续，填充后更新 filledRows。
   *
   * @param cache beginGrid 创建的空缓存
   * @param ev 双变量求值器
   * @param maxNodeRows 本次最多填充的节点行数（控制单帧耗时）
   * @returns true 表示网格已全部填充完成
   */
  static fillGridChunk(cache: GridCache2D, ev: BivariateEvaluator,
    maxNodeRows: number): boolean {

    if (cache.values === null) return true;
    const values: Float64Array = cache.values;
    const stride: number = cache.cols + 1;
    const totalNodeRows: number = cache.rows + 1;
    const startRow: number = cache.filledRows;
    const endRow: number = Math.min(startRow + maxNodeRows, totalNodeRows);

    for (let j: number = startRow; j < endRow; j++) {
      const wy: number = cache.yMin + j * cache.dy;
      const rowOff: number = j * stride;
      for (let i: number = 0; i <= cache.cols; i++) {
        const wx: number = cache.xMin + i * cache.dx;
        values[rowOff + i] = GridSampleEngine2D.safeEval(ev, wx, wy);
      }
    }
    cache.filledRows = endRow;

    // 增量奇点检测：单元格行 j 需要节点行 j 与 j+1，本批填完节点行
    // [startRow, endRow) 后，单元格行 [max(0, startRow-1), endRow-2] 首次可检测。
    // 开销分摊到各分块，避免构建完成时单次全量检测卡顿。
    const firstCellRow: number = Math.max(0, startRow - 1);
    const lastCellRow: number = endRow - 2;
    for (let j: number = firstCellRow; j <= lastCellRow; j++) {
      GridSampleEngine2D.detectPolesForRow(cache, ev, j, 0, cache.cols);
    }

    return cache.filledRows >= totalNodeRows;
  }

  /**
   * 创建空网格缓存（计算维度 + 分配，不求值）。
   * buildGrid 与分块构建共用的底层。
   */
  static beginGrid(fnId: number, exprHash: string,
    xMin: number, xMax: number, yMin: number, yMax: number,
    targetCellSize: number): GridCache2D {

    // 计算网格维度
    let cols: number = Math.ceil((xMax - xMin) / targetCellSize);
    let rows: number = Math.ceil((yMax - yMin) / targetCellSize);

    // 上限兜底
    if (cols > MAX_GRID_NODE) cols = MAX_GRID_NODE;
    if (rows > MAX_GRID_NODE) rows = MAX_GRID_NODE;
    if (cols < 2) cols = 2;
    if (rows < 2) rows = 2;

    // 实际间距（按兜底后的维度重算）
    const dx: number = (xMax - xMin) / cols;
    const dy: number = (yMax - yMin) / rows;

    const cache: GridCache2D = new GridCache2D(
      fnId, exprHash, xMin, xMax, yMin, yMax, dx, dy, cols, rows);
    // 扁平化存储：一次性分配连续内存，分块填充时直接写入偏移
    cache.values = new Float64Array((rows + 1) * (cols + 1));
    cache.filledRows = 0;
    cache.poleFlags = new Array<number>(cols * rows).fill(0);
    return cache;
  }

  /**
   * 在指定世界坐标范围内构建网格。
   */
  static buildGrid(ev: BivariateEvaluator, fnId: number, exprHash: string,
    xMin: number, xMax: number, yMin: number, yMax: number,
    targetCellSize: number): GridCache2D {

    // 复用分块构建底层：一次性填充所有行（同步全量构建）
    const cache: GridCache2D = GridSampleEngine2D.beginGrid(fnId, exprHash,
      xMin, xMax, yMin, yMax, targetCellSize);
    GridSampleEngine2D.fillGridChunk(cache, ev, cache.rows + 1);
    return cache;
  }

  /**
   * 增量扩展缓存：视口平移超出缓存范围时，补算缺失的行/列条带并合并。
   * 原地修改 cache。
   *
   * 策略（扁平化存储优化）：
   * - 新分配更大的 Float64Array，用 .set() 块拷贝旧数据（memcpy 级）
   * - 仅对新增条带求值（底部/顶部行 + 左/右列）
   * - 奇点检测仅针对含新数据的区域（拷贝旧标记 + 检测新区域），
   *   避免全网格重检测的 O(总格数) 开销
   */
  static extendCache(cache: GridCache2D, ev: BivariateEvaluator,
    newXMin: number, newXMax: number, newYMin: number, newYMax: number): GridExtendResult {
  
    const noop: GridExtendResult = {
      extended: false, oldCols: cache.cols, oldRows: cache.rows,
      leftCols: 0, rightCols: 0, bottomRows: 0, topRows: 0
    };
    if (cache.values === null) return noop;
    
    const dx: number = cache.dx;
    const dy: number = cache.dy;
    
    // 计算需要扩展的格数（四个方向）
    let leftCols: number = 0;
    let rightCols: number = 0;
    let bottomRows: number = 0;
    let topRows: number = 0;
    
    if (newXMin < cache.xMin - MIN_EXTEND_WIDTH) {
      leftCols = Math.ceil((cache.xMin - newXMin) / dx);
    }
    if (newXMax > cache.xMax + MIN_EXTEND_WIDTH) {
      rightCols = Math.ceil((newXMax - cache.xMax) / dx);
    }
    if (newYMin < cache.yMin - MIN_EXTEND_WIDTH) {
      bottomRows = Math.ceil((cache.yMin - newYMin) / dy);
    }
    if (newYMax > cache.yMax + MIN_EXTEND_WIDTH) {
      topRows = Math.ceil((newYMax - cache.yMax) / dy);
    }
    
    // 无需扩展
    if (leftCols === 0 && rightCols === 0 && bottomRows === 0 && topRows === 0) {
      return noop;
    }
    
    // 上限兜底
    const oldCols: number = cache.cols;
    const oldRows: number = cache.rows;
    const newTotalCols: number = oldCols + leftCols + rightCols;
    const newTotalRows: number = oldRows + bottomRows + topRows;
    if (newTotalCols > MAX_GRID_NODE || newTotalRows > MAX_GRID_NODE) {
      // 超出上限 → 放弃增量扩展，由调用方决定全量重建
      return noop;
    }
  
    const oldValues: Float64Array = cache.values;
    const oldStride: number = oldCols + 1;
    const newStride: number = newTotalCols + 1;
    const newValues: Float64Array = new Float64Array((newTotalRows + 1) * newStride);
  
    // 旧数据在新数组中的偏移
    const offI: number = leftCols;
    const offJ: number = bottomRows;
  
    // 新的范围
    const actualXMin: number = cache.xMin - leftCols * dx;
    const actualYMin: number = cache.yMin - bottomRows * dy;
  
    // 1) 块拷贝旧数据行（memcpy 级，无逐元素 push）
    for (let j: number = 0; j <= oldRows; j++) {
      const srcOff: number = j * oldStride;
      const dstOff: number = (j + offJ) * newStride + offI;
      newValues.set(oldValues.subarray(srcOff, srcOff + oldStride), dstOff);
    }
  
    // 2) 底部新增行（全宽）
    for (let j: number = 0; j < bottomRows; j++) {
      const wy: number = actualYMin + j * dy;
      const rowOff: number = j * newStride;
      for (let i: number = 0; i <= newTotalCols; i++) {
        newValues[rowOff + i] = GridSampleEngine2D.safeEval(ev, actualXMin + i * dx, wy);
      }
    }
  
    // 3) 顶部新增行（全宽）
    for (let j: number = offJ + oldRows + 1; j <= newTotalRows; j++) {
      const wy: number = actualYMin + j * dy;
      const rowOff: number = j * newStride;
      for (let i: number = 0; i <= newTotalCols; i++) {
        newValues[rowOff + i] = GridSampleEngine2D.safeEval(ev, actualXMin + i * dx, wy);
      }
    }
  
    // 4) 中间行（旧节点行）的左/右新增列
    for (let j: number = offJ; j <= offJ + oldRows; j++) {
      const wy: number = actualYMin + j * dy;
      const rowOff: number = j * newStride;
      for (let i: number = 0; i < leftCols; i++) {
        newValues[rowOff + i] = GridSampleEngine2D.safeEval(ev, actualXMin + i * dx, wy);
      }
      for (let i: number = offI + oldCols + 1; i <= newTotalCols; i++) {
        newValues[rowOff + i] = GridSampleEngine2D.safeEval(ev, actualXMin + i * dx, wy);
      }
    }
  
    // 5) 奇点标记迁移：拷贝旧标记（带偏移）+ 仅检测含新数据的区域
    const oldFlags: number[] | null = cache.poleFlags;
    const newFlags: number[] = new Array<number>(newTotalCols * newTotalRows).fill(0);
    if (oldFlags !== null) {
      for (let j: number = 0; j < oldRows; j++) {
        const srcRow: number = j * oldCols;
        const dstRow: number = (j + offJ) * newTotalCols + offI;
        for (let i: number = 0; i < oldCols; i++) {
          if (oldFlags[srcRow + i] === 1) {
            newFlags[dstRow + i] = 1;
          }
        }
      }
    }
  
    // 更新缓存（先更新维度，detectPolesForRow 依赖新维度读取新数组）
    cache.values = newValues;
    cache.xMin = actualXMin;
    cache.xMax = cache.xMax + rightCols * dx;
    cache.yMin = actualYMin;
    cache.yMax = cache.yMax + topRows * dy;
    cache.cols = newTotalCols;
    cache.rows = newTotalRows;
    cache.poleFlags = newFlags;
    // 精细层失效
    cache.clearRefined();
  
    // 6) 增量奇点检测（仅新区域）
    if (leftCols > 0 || rightCols > 0) {
      // 水平扩展：所有单元格行的新列需要检测
      for (let j: number = 0; j < newTotalRows; j++) {
        if (leftCols > 0) {
          GridSampleEngine2D.detectPolesForRow(cache, ev, j, 0, leftCols);
        }
        if (rightCols > 0) {
          GridSampleEngine2D.detectPolesForRow(cache, ev, j, offI + oldCols, newTotalCols);
        }
      }
      // 底部/顶部条带行的中间列段（左右列已在上方覆盖）
      for (let j: number = 0; j < bottomRows; j++) {
        GridSampleEngine2D.detectPolesForRow(cache, ev, j, offI, offI + oldCols);
      }
      for (let j: number = offJ + oldRows; j < newTotalRows; j++) {
        GridSampleEngine2D.detectPolesForRow(cache, ev, j, offI, offI + oldCols);
      }
    } else {
      // 纯垂直扩展：仅检测新行条带
      for (let j: number = 0; j < bottomRows; j++) {
        GridSampleEngine2D.detectPolesForRow(cache, ev, j, 0, newTotalCols);
      }
      for (let j: number = offJ + oldRows; j < newTotalRows; j++) {
        GridSampleEngine2D.detectPolesForRow(cache, ev, j, 0, newTotalCols);
      }
    }

    const result: GridExtendResult = {
      extended: true, oldCols: oldCols, oldRows: oldRows,
      leftCols: leftCols, rightCols: rightCols,
      bottomRows: bottomRows, topRows: topRows
    };
    return result;
  }

  /**
   * 精细层构建：对可见区域以更小间距重新采样。
   * 结果存入 cache.refinedValues。
   */
  static refineCache(cache: GridCache2D, ev: BivariateEvaluator,
    vxMin: number, vxMax: number, vyMin: number, vyMax: number,
    targetCellSize: number): void {

    // 精细范围：可见区域 + 小缓冲
    const xBuf: number = (vxMax - vxMin) * 0.1;
    const yBuf: number = (vyMax - vyMin) * 0.1;
    const xMin: number = vxMin - xBuf;
    const xMax: number = vxMax + xBuf;
    const yMin: number = vyMin - yBuf;
    const yMax: number = vyMax + yBuf;

    let cols: number = Math.ceil((xMax - xMin) / targetCellSize);
    let rows: number = Math.ceil((yMax - yMin) / targetCellSize);
    if (cols > MAX_GRID_NODE) cols = MAX_GRID_NODE;
    if (rows > MAX_GRID_NODE) rows = MAX_GRID_NODE;
    if (cols < 2) cols = 2;
    if (rows < 2) rows = 2;

    const dx: number = (xMax - xMin) / cols;
    const dy: number = (yMax - yMin) / rows;

    const values: number[][] = [];
    for (let j: number = 0; j <= rows; j++) {
      const row: number[] = [];
      const wy: number = yMin + j * dy;
      for (let i: number = 0; i <= cols; i++) {
        const wx: number = xMin + i * dx;
        row.push(GridSampleEngine2D.safeEval(ev, wx, wy));
      }
      values.push(row);
    }

    cache.refinedValues = values;
    cache.refinedXMin = xMin;
    cache.refinedXMax = xMax;
    cache.refinedYMin = yMin;
    cache.refinedYMax = yMax;
    cache.refinedDx = dx;
    cache.refinedDy = dy;
    cache.refinedCols = cols;
    cache.refinedRows = rows;
  }

  /**
   * 计算合适的网格间距。
   * @param vpRange 视口范围（世界单位）
   * @param pixelWorldDx 单像素对应的世界坐标间距
   * @returns 建议的网格间距
   */
  static suggestCellSize(vpRange: number, pixelWorldDx: number): number {
    // 基础层：约 200 个格子覆盖视口范围
    const coarse: number = vpRange / 200;
    // 不低于像素精度的 4 倍（避免过密）
    const minCell: number = pixelWorldDx * 4;
    return Math.max(coarse, minCell);
  }

  /** 安全求值：捕获异常返回 NaN */
  private static safeEval(ev: BivariateEvaluator, x: number, y: number): number {
    try {
      return ev.evaluate(x, y);
    } catch (e) {
      return NaN;
    }
  }

  /**
   * 公开的安全求值（供渲染器 AMR 探针使用）。
   * evaluate 承诺不抛异常，此处保留 try-catch 兖底。
   */
  static safeEvalPub(ev: BivariateEvaluator, x: number, y: number): number {
    try {
      return ev.evaluate(x, y);
    } catch (e) {
      return NaN;
    }
  }

  /**
   * 检测单元格行 j 的指定列范围内所有单元格奇点，写入 cache.poleFlags。
   * 单元格行 j 使用节点行 j 与 j+1。仅处理候选单元格（四角有限且变号），
   * 其余（全满足/全不满足/含 NaN）直接跳过，零开销。
   *
   * @param cache 网格缓存（维度已更新）
   * @param ev 求值器（探针检测用）
   * @param j 单元格行索引
   * @param iStart 起始列（含）
   * @param iEnd 结束列（不含，上限 cache.cols）
   */
  private static detectPolesForRow(cache: GridCache2D, ev: BivariateEvaluator,
    j: number, iStart: number, iEnd: number): void {
    const values: Float64Array | null = cache.values;
    const flags: number[] | null = cache.poleFlags;
    if (values === null || flags === null) return;
    if (j < 0 || j + 1 > cache.rows) return;
    const stride: number = cache.cols + 1;
    const end: number = Math.min(iEnd, cache.cols);
    const row0Off: number = j * stride;
    const row1Off: number = (j + 1) * stride;
    for (let i: number = Math.max(0, iStart); i < end; i++) {
      const v00: number = values[row0Off + i];
      const v10: number = values[row0Off + i + 1];
      const v11: number = values[row1Off + i + 1];
      const v01: number = values[row1Off + i];
      if (!isFinite(v00) || !isFinite(v10) || !isFinite(v11) || !isFinite(v01)) {
        continue;
      }
      // 候选单元格：四角不全同号（否则 MS 不产生等值线，无需检测）
      const allPos: boolean = v00 >= 0 && v10 >= 0 && v11 >= 0 && v01 >= 0;
      const allNeg: boolean = v00 < 0 && v10 < 0 && v11 < 0 && v01 < 0;
      if (allPos || allNeg) continue;
      const x0: number = cache.xMin + i * cache.dx;
      const y0: number = cache.yMin + j * cache.dy;
      if (GridSampleEngine2D.cellHasPole(ev, x0, y0, x0 + cache.dx, y0 + cache.dy,
        v00, v10, v11, v01)) {
        flags[j * cache.cols + i] = 1;
      }
    }
  }

  /**
   * 检测单个网格单元是否包含奇点（极点/无穷间断）。
   *
   * 原理：对 MS 会产生等值线的候选单元格（四角有限且变号），若函数在
   * 单元格内探针点的值显著超出四角最大值（吹起）或非有限，说明单元格内
   * 存在极点——变号是 +∞/-∞ 跳跃而非真实过零，MS 会画出跨越渐近线的
   * 贯穿伪影线段，须标记跳过。
   *
   * 多探针策略（sim4 阈值扫描定稿：零误伤 + 82.3% 伪影清除率）：
   * - 单元格中心探针：|fc| > POLE_CENTER_FACTOR × maxC → 奇点
   * - 每条符号变化边的 25%/50%/75% 三点探针：
   *   |f| > POLE_EDGE_FACTOR × max(该边两角) → 奇点
   *   （三分点探针使极点偏离边中点时仍有探针落在吹起区；sim4 证实
   *   lerp 穿越点探针与中点探针重叠、无增益，不采用）
   *
   * @returns true 表示单元格含奇点，等值线提取应跳过
   */
  private static cellHasPole(ev: BivariateEvaluator,
    x0: number, y0: number, x1: number, y1: number,
    v00: number, v10: number, v11: number, v01: number): boolean {

    // 任一角非有限时 MS 直接跳过该格，无需检测
    if (!isFinite(v00) || !isFinite(v10) || !isFinite(v11) || !isFinite(v01)) {
      return false;
    }
    const maxC: number = Math.max(Math.abs(v00), Math.abs(v10), Math.abs(v11), Math.abs(v01));
    if (maxC <= 0) return false;

    // 中心探针
    const fc: number = GridSampleEngine2D.safeEval(ev, (x0 + x1) * 0.5, (y0 + y1) * 0.5);
    if (!isFinite(fc) || Math.abs(fc) > POLE_CENTER_FACTOR * maxC) {
      return true;
    }

    // 四条边：边 0 底(v00→v10)、边 1 右(v10→v11)、边 2 顶(v01→v11)、边 3 左(v00→v01)
    const edgeAX: number[] = [x0, x1, x0, x0];
    const edgeAY: number[] = [y0, y0, y1, y0];
    const edgeAV: number[] = [v00, v10, v01, v00];
    const edgeBX: number[] = [x1, x1, x1, x0];
    const edgeBY: number[] = [y0, y1, y1, y1];
    const edgeBV: number[] = [v10, v11, v11, v01];
    // 边内探针位置：25%/50%/75% 三分点
    const probeTs: number[] = [0.25, 0.5, 0.75];
    for (let e: number = 0; e < 4; e++) {
      const av: number = edgeAV[e];
      const bv: number = edgeBV[e];
      // 仅探针符号变化边（等值线穿越边）
      if ((av >= 0) === (bv >= 0)) continue;
      const ax: number = edgeAX[e];
      const ay: number = edgeAY[e];
      const bx: number = edgeBX[e];
      const by: number = edgeBY[e];
      const edgeMax: number = Math.max(Math.abs(av), Math.abs(bv));
      for (let p: number = 0; p < probeTs.length; p++) {
        const t: number = probeTs[p];
        const fp: number = GridSampleEngine2D.safeEval(ev,
          ax + t * (bx - ax), ay + t * (by - ay));
        // 真实过零时 F≈0；极点附近 F 吹起（或非有限）
        if (!isFinite(fp) || Math.abs(fp) > POLE_EDGE_FACTOR * edgeMax) {
          return true;
        }
      }
    }
    return false;
  }
}
