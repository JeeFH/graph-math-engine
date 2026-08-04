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
// features/graph/src/main/ets/engine/SampleCache.ets
/**
 * 函数世界坐标预缓存数据结构
 *
 * 核心设计原则：函数图像是客观存在的数学实体，采样数据与视图（缩放/平移）完全无关。
 * 一次性在固定世界坐标间距上预计算采样点并标记间断点，
 * 渲染时仅做「世界→屏幕」坐标投影，无需重新求值。
 */

/** 世界坐标采样点（视图无关） */
export interface WorldSample {
  x: number;      // 世界坐标 x
  y: number;      // f(x) 原始值（NaN=无定义, ±Inf=趋向无穷）
  disc: boolean;  // 此点为间断标记（不连线，仅分割用）
}

/** 单函数的世界坐标预缓存 */
export class FunctionSampleCache {
  fnId: number;
  exprHash: string;           // 表达式+角度模式哈希（失效判定）
  samples: WorldSample[];     // 按 x 升序排列
  xMin: number;               // 缓存覆盖范围（世界坐标）
  xMax: number;
  baseDx: number;             // 基准采样间距（世界单位）
  builtAt: number;            // 构建时间戳（ms）
  /** 细化叠加层：深度缩放时对可见区间加密采样的结果（按 x 升序） */
  refinedSamples: WorldSample[] | null;
  refinedXMin: number;        // 细化层覆盖范围
  refinedXMax: number;
  refinedDx: number;          // 细化层间距

  constructor(fnId: number, exprHash: string, samples: WorldSample[],
    xMin: number, xMax: number, baseDx: number) {
    this.fnId = fnId;
    this.exprHash = exprHash;
    this.samples = samples;
    this.xMin = xMin;
    this.xMax = xMax;
    this.baseDx = baseDx;
    this.builtAt = Date.now();
    this.refinedSamples = null;
    this.refinedXMin = 0;
    this.refinedXMax = 0;
    this.refinedDx = 0;
  }

  /**
   * 二分查找：返回 samples[] 中第一个 x >= target 的索引。
   * 用于快速定位视口可见范围的起始样本。
   */
  lowerBound(target: number): number {
    let lo: number = 0;
    let hi: number = this.samples.length;
    while (lo < hi) {
      const mid: number = (lo + hi) >> 1;
      if (this.samples[mid].x < target) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /**
   * 二分查找：返回 samples[] 中最后一个 x <= target 的索引 + 1。
   * 用于快速定位视口可见范围的结束样本。
   */
  upperBound(target: number): number {
    let lo: number = 0;
    let hi: number = this.samples.length;
    while (lo < hi) {
      const mid: number = (lo + hi) >> 1;
      if (this.samples[mid].x <= target) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /**
   * 获取视口 [vxMin, vxMax] 内的可见样本子数组（含前后各 1 个边界外样本用于连线）。
   * 若存在细化层且覆盖当前视口，优先使用细化层。
   */
  getVisibleSamples(vxMin: number, vxMax: number): WorldSample[] {
    // 检查细化层是否覆盖当前视口
    if (this.refinedSamples != null && this.refinedSamples.length > 0 &&
      vxMin >= this.refinedXMin && vxMax <= this.refinedXMax) {
      return this.getVisibleFrom(this.refinedSamples, vxMin, vxMax);
    }
    return this.getVisibleFrom(this.samples, vxMin, vxMax);
  }

  private getVisibleFrom(arr: WorldSample[], vxMin: number, vxMax: number): WorldSample[] {
    if (arr.length === 0) {
      return [];
    }
    let start: number = this.lowerBoundIn(arr, vxMin);
    let end: number = this.upperBoundIn(arr, vxMax);
    // 前后各扩展 1 个样本（确保边界连线完整）
    if (start > 0) {
      start--;
    }
    if (end < arr.length) {
      end++;
    }
    return arr.slice(start, end);
  }

  private lowerBoundIn(arr: WorldSample[], target: number): number {
    let lo: number = 0;
    let hi: number = arr.length;
    while (lo < hi) {
      const mid: number = (lo + hi) >> 1;
      if (arr[mid].x < target) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  private upperBoundIn(arr: WorldSample[], target: number): number {
    let lo: number = 0;
    let hi: number = arr.length;
    while (lo < hi) {
      const mid: number = (lo + hi) >> 1;
      if (arr[mid].x <= target) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /** 判断视口是否在缓存覆盖范围内 */
  covers(vxMin: number, vxMax: number): boolean {
    return vxMin >= this.xMin && vxMax <= this.xMax;
  }

  /** 判断当前缩放是否需要细化（样本间距 > 2px 对应的世界距离） */
  needsRefine(pixelWorldDx: number): boolean {
    return this.baseDx > pixelWorldDx * 2;
  }

  /** 判断细化层是否仍然有效（覆盖当前视口且精度足够） */
  refineValid(vxMin: number, vxMax: number, pixelWorldDx: number): boolean {
    if (this.refinedSamples == null || this.refinedSamples.length === 0) {
      return false;
    }
    return vxMin >= this.refinedXMin && vxMax <= this.refinedXMax &&
      this.refinedDx <= pixelWorldDx * 2;
  }

  /**
   * 缓冲窗口淘汰：裁切 samples[] 仅保留 [newXMin, newXMax] 范围内的样本。
   * 用于滑动窗口机制——视图平移后淘汰远离可视区域的旧采样点，控制内存恒定。
   */
  shrinkTo(newXMin: number, newXMax: number): void {
    const start: number = this.lowerBound(newXMin);
    const end: number = this.upperBound(newXMax);
    if (start > 0 || end < this.samples.length) {
      this.samples = this.samples.slice(start, end);
    }
    this.xMin = newXMin;
    this.xMax = newXMax;
    // 细化层同步失效（范围已变）
    this.refinedSamples = null;
  }
}
