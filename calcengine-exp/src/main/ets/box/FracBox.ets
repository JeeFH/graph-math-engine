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
// box/FracBox.ets
// 分数盒子：分子在上、分数线居中于本盒基线、分母在下。
// 采用文本样式间隙参数（NUM2/DENOM2，比显示样式 NUM1/DENOM1 更小），并随
// 子盒下伸/上伸收敛；盒子高度精确包裹"分子顶 → 分数线 → 分母底"。

import { Box } from './Box';
import { NUM2, DENOM2, DEFAULT_RULE_THICKNESS, AXIS_HEIGHT } from '../font/TeXMetrics';

export class FracBox extends Box {
  num: Box;
  den: Box;
  private fs: number = 0;

  /** 分子基线相对本盒基线的偏移（负，在上方）；供 LayoutMap 放置光标 */
  numBaselineOffset: number = 0;
  /** 分母基线相对本盒基线的偏移（正，在下方）；供 LayoutMap 放置光标 */
  denBaselineOffset: number = 0;
  /** 分数线相对本盒基线的上移量（= AXIS_HEIGHT * fs）；供 LayoutMap 定位 */
  fracAxisShift: number = 0;

  constructor(num: Box, den: Box, fontSize: number) {
    super();
    this.num = num;
    this.den = den;
    this.fs = fontSize;
    this.relayout();
  }

  /** 用当前分子/分母尺寸重算分数盒布局，供实测后重排调用 */
  relayout(): void {
    const ruleHalf: number = DEFAULT_RULE_THICKNESS * this.fs * 0.5;
    const minGap: number = DEFAULT_RULE_THICKNESS * this.fs * 2;
    // 分母偏移：保证分母顶部与分数线之间有 minGap 间距（收紧系数：0.7 → 0.45）
    const denShift: number = Math.max(DENOM2 * this.fs * 0.45 + this.den.height * 0.45 + ruleHalf, this.den.height + minGap);
    // 分子偏移：独立计算，保证分子底部与分数线之间有 minGap 间距（不受分母偏移影响）
    const numShift: number = this.num.depth + minGap;
    this.numBaselineOffset = -numShift;
    this.denBaselineOffset = denShift;
    this.width = Math.max(this.num.width, this.den.width);
    // 基线 = 文字基线；分数线在基线上方 AXIS_HEIGHT 处（数学轴线）
    // 保证 depth >= axisShift：使含分数的 HBox 视觉中心 = 数学轴线 = 文字视觉中心，
    // 分数与相邻项（如 -1）自然沿数学轴线居中对齐
    const axisShift: number = AXIS_HEIGHT * this.fs;
    this.fracAxisShift = axisShift;
    this.height = axisShift + numShift + this.num.height;
    this.depth = Math.max(denShift + this.den.depth - axisShift, axisShift);
  }

  draw(ctx: CanvasRenderingContext2D, x: number, y: number): void {
    if (this.background) {
      ctx.fillStyle = this.background;
      ctx.fillRect(x, y - this.height, this.width, this.height + this.depth);
    }
    if (this.num.foreground == null && this.foreground != null) this.num.foreground = this.foreground;
    if (this.den.foreground == null && this.foreground != null) this.den.foreground = this.foreground;
    // 分数线位于数学轴线（基线上方 AXIS_HEIGHT）
    const fracLineY: number = y - AXIS_HEIGHT * this.fs;
    // 分子居中（相对分数线定位）
    const numX: number = x + (this.width - this.num.width) / 2;
    this.num.draw(ctx, numX, fracLineY + this.numBaselineOffset);
    // 分母居中（相对分数线定位）
    const denX: number = x + (this.width - this.den.width) / 2;
    this.den.draw(ctx, denX, fracLineY + this.denBaselineOffset);
    // 分数线
    ctx.strokeStyle = this.foreground ?? '#000000';
    ctx.lineWidth = Math.max(1, DEFAULT_RULE_THICKNESS * this.fs);
    ctx.beginPath();
    ctx.moveTo(x, fracLineY);
    ctx.lineTo(x + this.width, fracLineY);
    ctx.stroke();
  }
}
