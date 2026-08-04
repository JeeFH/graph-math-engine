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
// features/graph/src/main/ets/engine/GridCache2D.ets
/**
 * 二维网格预缓存数据结构
 *
 * 存储 F(x,y) 在固定世界坐标网格上的采样值。
 * 供隐函数（等值线提取）、不等式（区域填充）、二元方程共用。
 *
 * 设计原则（与 FunctionSampleCache 对齐）：
 * - 网格数据与视图（缩放/平移）无关，仅与世界坐标范围有关
 * - 一次性预渲染远超可视窗口的大范围网格，视图变化时仅增量扩展
 * - 支持 LOD 分层：基础层（粗网格）+ 精细层（细网格，仅覆盖可见区域）
 */

/** 二维网格缓存 */
export class GridCache2D {
  fnId: number;
  exprHash: string;

  /**
   * 网格值矩阵（扁平化存储）：
   * values[j * (cols+1) + i] = F(xMin + i * dx, yMin + j * dy)
   * 总长度 = (rows+1) * (cols+1)，行优先连续存储。
   *
   * 性能设计：单个 Float64Array 替代 number[][]（行数组的数组），
   * 缓存局部性显著提升（连续内存布局），GC 对象从 500+ 行数组降为 1 个
   * TypedArray，网格遍历 2-3x 加速。
   */
  values: Float64Array | null;

  /** 网格覆盖范围（世界坐标） */
  xMin: number;
  xMax: number;
  yMin: number;
  yMax: number;

  /** 网格间距（世界单位） */
  dx: number;
  dy: number;

  /** 网格维度（格子数，节点数 = 格子数 + 1） */
  cols: number;
  rows: number;

  /**
   * 已填充的节点行数（0..rows+1）。
   * 用于分块构建（chunked build）：网格不必一次性填满，
   * 可以逐行分片填充并在帧间让出主线程。filledRows >= rows+1 表示构建完成。
   */
  filledRows: number;

  /** 构建时间戳（ms） */
  builtAt: number;

  /**
   * 奇点（极点/无穷间断）单元格标记。
   * 扁平数组，长度 cols*rows，行优先：poleFlags[j*cols+i] === 1 表示
   * 单元格 (i,j)（四角 [i,j]~[i+1,j+1]）内检测到奇点。
   * Marching Squares 提取时跳过这些单元格，避免画出跨越渐近线的贯穿伪影。
   * 与 1D SampleEngine 「构建期一次检测、渲染期只读标记」模式一致。
   */
  poleFlags: number[] | null;

  /** 精细叠加层（深度缩放时使用） */
  refinedValues: number[][] | null;
  refinedXMin: number;
  refinedXMax: number;
  refinedYMin: number;
  refinedYMax: number;
  refinedDx: number;
  refinedDy: number;
  refinedCols: number;
  refinedRows: number;

  constructor(fnId: number, exprHash: string,
    xMin: number, xMax: number, yMin: number, yMax: number,
    dx: number, dy: number, cols: number, rows: number) {
    this.fnId = fnId;
    this.exprHash = exprHash;
    this.values = null;
    this.xMin = xMin;
    this.xMax = xMax;
    this.yMin = yMin;
    this.yMax = yMax;
    this.dx = dx;
    this.dy = dy;
    this.cols = cols;
    this.rows = rows;
    this.filledRows = 0;
    this.builtAt = Date.now();
    this.poleFlags = null;
    this.refinedValues = null;
    this.refinedXMin = 0;
    this.refinedXMax = 0;
    this.refinedYMin = 0;
    this.refinedYMax = 0;
    this.refinedDx = 0;
    this.refinedDy = 0;
    this.refinedCols = 0;
    this.refinedRows = 0;
  }

  /**
   * 获取网格节点值。
   * @param i 列索引（0..cols）
   * @param j 行索引（0..rows）
   * @returns F(x,y) 值，越界返回 NaN
   */
  getValue(i: number, j: number): number {
    if (this.values === null) return NaN;
    if (j < 0 || j > this.rows || i < 0 || i > this.cols) return NaN;
    return this.values[j * (this.cols + 1) + i];
  }

  /**
   * 设置网格节点值（分块构建 / 增量扩展时使用）。
   * @param i 列索引（0..cols）
   * @param j 行索引（0..rows）
   * @param v F(x,y) 值
   */
  setValue(i: number, j: number, v: number): void {
    if (this.values === null) return;
    if (j < 0 || j > this.rows || i < 0 || i > this.cols) return;
    this.values[j * (this.cols + 1) + i] = v;
  }

  /** 扁平索引：节点 (i, j) 在 values 中的偏移 */
  nodeOffset(i: number, j: number): number {
    return j * (this.cols + 1) + i;
  }

  /**
   * 获取网格节点的世界坐标。
   * @param i 列索引
   * @param j 行索引
   * @returns [worldX, worldY]
   */
  getWorldCoord(i: number, j: number): [number, number] {
    return [this.xMin + i * this.dx, this.yMin + j * this.dy];
  }

  /**
   * 判断缓存是否完全覆盖给定范围
   */
  covers(vxMin: number, vxMax: number, vyMin: number, vyMax: number): boolean {
    return vxMin >= this.xMin && vxMax <= this.xMax &&
      vyMin >= this.yMin && vyMax <= this.yMax;
  }

  /**
   * 判断精细层是否有效且覆盖给定范围
   * @deprecated AMR 自适应网格细化方案已取代精细层职责，此方法保留仅为兼容。
   */
  refineValid(vxMin: number, vxMax: number, vyMin: number, vyMax: number,
    pixelWorldDx: number): boolean {
    if (this.refinedValues === null || this.refinedValues.length === 0) {
      return false;
    }
    return vxMin >= this.refinedXMin && vxMax <= this.refinedXMax &&
      vyMin >= this.refinedYMin && vyMax <= this.refinedYMax &&
      this.refinedDx <= pixelWorldDx * 2 && this.refinedDy <= pixelWorldDx * 2;
  }

  /**
   * 判断基础层是否需要精细化
   * @deprecated AMR 自适应网格细化方案已取代精细层职责，此方法保留仅为兼容。
   */
  needsRefine(pixelWorldDx: number): boolean {
    return this.dx > pixelWorldDx * 2 || this.dy > pixelWorldDx * 2;
  }

  /**
   * 释放精细层资源（缩放变化时调用）
   */
  clearRefined(): void {
    this.refinedValues = null;
    this.refinedXMin = 0;
    this.refinedXMax = 0;
    this.refinedYMin = 0;
    this.refinedYMax = 0;
    this.refinedDx = 0;
    this.refinedDy = 0;
    this.refinedCols = 0;
    this.refinedRows = 0;
  }

  /**
   * 释放全部资源（dispose 时调用）
   */
  dispose(): void {
    this.values = null;
    this.poleFlags = null;
    this.clearRefined();
  }
}
