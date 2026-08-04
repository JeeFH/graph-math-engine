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
// features/graph/src/main/ets/math/GraphMath.ets
/**
 * 图象绘制数学工具
 * - 视口 (Viewport) 定义可见域
 * - world ↔ screen 坐标变换（screen 单位 vp，与 ArkUI 一致）
 * - 「漂亮刻度」算法（1/2/5 × 10^k），让网格线对齐、标签不挤
 */

/** 视口：当前可见的坐标范围 */
export interface Viewport {
  xMin: number;
  xMax: number;
  yMin: number;
  yMax: number;
}

export class GraphMath {
  /** 世界坐标 X → 屏幕水平像素（vp） */
  static worldToScreenX(x: number, vp: Viewport, width: number): number {
    return (x - vp.xMin) / (vp.xMax - vp.xMin) * width;
  }

  /** 世界坐标 Y → 屏幕垂直像素（vp，Y 轴向下） */
  static worldToScreenY(y: number, vp: Viewport, height: number): number {
    return height - (y - vp.yMin) / (vp.yMax - vp.yMin) * height;
  }

  /** 屏幕水平像素 → 世界坐标 X */
  static screenToWorldX(px: number, vp: Viewport, width: number): number {
    return vp.xMin + (px / width) * (vp.xMax - vp.xMin);
  }

  /** 屏幕垂直像素 → 世界坐标 Y */
  static screenToWorldY(py: number, vp: Viewport, height: number): number {
    return vp.yMin + ((height - py) / height) * (vp.yMax - vp.yMin);
  }

  /**
   * 计算「漂亮」刻度步长：取 1 / 2 / 5 × 10^k 中最贴近 target 的一档。
   * range：坐标轴可见跨度；targetTicks：期望的刻度数量。
   */
  static niceStep(range: number, targetTicks: number): number {
    if (range <= 0 || !(targetTicks > 0)) {
      return 1;
    }
    const raw: number = range / targetTicks;
    const mag: number = Math.pow(10, Math.floor(Math.log10(raw)));
    const norm: number = raw / mag; // 归一化到 1..10
    let step: number;
    if (norm < 1.5) {
      step = 1;
    } else if (norm < 3) {
      step = 2;
    } else if (norm < 7) {
      step = 5;
    } else {
      step = 10;
    }
    return step * mag;
  }

  /** 在 [min, max] 内按 step 生成刻度值（消除浮点累积误差） */
  static ticks(min: number, max: number, step: number): number[] {
    if (!(step > 0)) {
      return [];
    }
    const decimals: number = GraphMath.decimalPlaces(step);
    const out: number[] = [];
    const start: number = Math.ceil(min / step) * step;
    for (let v: number = start; v <= max + step * 1e-9; v += step) {
      // 按步长整数倍回正，避免 0.1+0.2 这类误差
      const idx: number = Math.round(v / step);
      // 二次消除浮点累积误差（如 0.2*3 = 0.6000000000000001）
      const val: number = Number((idx * step).toFixed(decimals));
      out.push(val);
    }
    return out;
  }

  /** 计算步长的小数位数（用于刻度值精度截断，避免 0.6000000000000001 这类尾巴） */
  private static decimalPlaces(step: number): number {
    if (Math.floor(step) === step) {
      return 0;
    }
    const s: string = step.toString();
    const dot: number = s.indexOf('.');
    if (dot < 0) {
      // 科学计数法（如 1e-7）→ 按数量级给足小数位
      if (s.indexOf('e') >= 0 || s.indexOf('E') >= 0) {
        return Math.max(0, -Math.floor(Math.log10(step)));
      }
      return 0;
    }
    return s.length - dot - 1;
  }

  /** 默认视口：以原点为中心、纵横比 1 的方形窗（后续可由内容自适应） */
  static defaultViewport(): Viewport {
    return { xMin: -10, xMax: 10, yMin: -10, yMax: 10 };
  }
}
