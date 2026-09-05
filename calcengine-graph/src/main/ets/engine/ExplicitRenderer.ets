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
// calcengine-graph/src/main/ets/engine/ExplicitRenderer.ets
/**
 * 显函数渲染器（模式 A: y = f(x)）
 *
 * 封装现有的 FunctionEvaluator + SampleEngine + FunctionSampleCache 1D 管线，
 * 实现 IRenderer 统一接口。
 *
 * 核心逻辑不变：一维逐点采样 + 自适应加密 + 通用间断点检测。
 * 这是性能最优的渲染模式，不启用二维网格。
 */

import { Viewport } from '../math/GraphMath';
import { FunctionEvaluator } from './FunctionEvaluator';
import { FunctionSampleCache, WorldSample } from './SampleCache';
import { SampleEngine } from './SampleEngine';
import { IRenderer, RenderData, RenderMode } from './IRenderer';

/** 缓冲扩展比例（可视范围向外扩展 50%） */
const BUFFER_RATIO: number = 0.5;

export class ExplicitRenderer implements IRenderer {
  readonly mode: RenderMode = RenderMode.EXPLICIT;

  private readonly fnId: number;
  private readonly expr: string;
  private evaluator: FunctionEvaluator | null = null;
  private cache: FunctionSampleCache | null = null;

  constructor(fnId: number, expr: string, isDegMode: boolean) {
    this.fnId = fnId;
    this.expr = expr;
    try {
      this.evaluator = new FunctionEvaluator(expr, isDegMode);
    } catch (e) {
      this.evaluator = null;
    }
  }

  buildCache(vp: Viewport, pixelWorldDx: number): void {
    if (this.evaluator === null || !this.evaluator.isValid) return;

    const xRange: number = vp.xMax - vp.xMin;
    const xBuffer: number = xRange * BUFFER_RATIO;
    const xMin: number = vp.xMin - xBuffer;
    const xMax: number = vp.xMax + xBuffer;

    // 基础采样间距：视口宽度 W 内约 2000 个点（与旧管线 buildSampleCache 的
    // baseDx = range/2000 完全对齐，保证 Task 2.3 采样点坐标一致）。
    // 注意：不能用缓冲后宽度 (xMax-xMin)=2W 除以 2000，否则密度减半。
    const dx: number = xRange / 2000;
    const exprHash: string = this.expr;

    this.cache = SampleEngine.buildCache(this.evaluator, this.fnId, exprHash,
      xMin, xMax, dx);
  }

  extendCache(newVp: Viewport): void {
    if (this.cache === null || this.evaluator === null || !this.evaluator.isValid) return;

    const xRange: number = newVp.xMax - newVp.xMin;
    const xBuffer: number = xRange * BUFFER_RATIO;
    const newXMin: number = newVp.xMin - xBuffer;
    const newXMax: number = newVp.xMax + xBuffer;

    if (newXMin < this.cache.xMin || newXMax > this.cache.xMax) {
      SampleEngine.extendCache(this.cache, this.evaluator, newXMin, newXMax);
    }
  }

  extractVisible(vp: Viewport): RenderData {
    const visibleSamples: WorldSample[] = this.cache !== null
      ? this.cache.getVisibleSamples(vp.xMin, vp.xMax)
      : [];

    // 检查是否需要细化（深度缩放）
    if (this.cache !== null && this.evaluator !== null && this.cache.needsRefine(
      (vp.xMax - vp.xMin) / 1000)) {
      const refineDx: number = (vp.xMax - vp.xMin) / 1000;
      if (!this.cache.refineValid(vp.xMin, vp.xMax, refineDx)) {
        SampleEngine.refineCache(this.cache, this.evaluator,
          vp.xMin, vp.xMax, refineDx);
      }
      // 使用细化层数据
      const refinedVisible: WorldSample[] = this.cache.getVisibleSamples(vp.xMin, vp.xMax);
      return {
        mode: RenderMode.EXPLICIT,
        fnId: this.fnId,
        color: '',
        lineWidth: 2,
        lineStyle: 'solid',
        expr: this.expr,
        samples1D: refinedVisible,
        cacheValid: true
      };
    }

    return {
      mode: RenderMode.EXPLICIT,
      fnId: this.fnId,
      color: '',
      lineWidth: 2,
      lineStyle: 'solid',
      expr: this.expr,
      samples1D: visibleSamples,
      cacheValid: this.cache !== null
    };
  }

  dispose(): void {
    if (this.cache !== null) {
      this.cache.samples = [];
      this.cache.refinedSamples = null;
      this.cache = null;
    }
    this.evaluator = null;
  }

  cacheCovers(vp: Viewport): boolean {
    if (this.cache === null) return false;
    const xRange: number = vp.xMax - vp.xMin;
    const xBuffer: number = xRange * BUFFER_RATIO;
    return this.cache.covers(vp.xMin - xBuffer, vp.xMax + xBuffer);
  }
}
