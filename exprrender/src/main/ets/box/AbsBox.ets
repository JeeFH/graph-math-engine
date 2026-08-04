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
// box/AbsBox.ets
// 绝对值包裹盒子：| body |
// 用两条纵向直线绘制竖线，随内容高度自适应（内容含分数/上标时竖线同步拉长）。

import { Box } from './Box';

export class AbsBox extends Box {
  body: Box;
  private fs: number = 0;
  private barW: number = 0;  // 竖线粗细（同时作为预留宽度）
  private gap: number = 0;

  /** 左竖线右侧、内容的水平偏移，供 LayoutMap 定位 */
  bodyOffsetX: number = 0;

  constructor(body: Box, fontSize: number) {
    super();
    this.body = body;
    this.fs = fontSize;
    this.barW = fontSize * 0.06;
    this.gap = fontSize * 0.1;
    this.bodyOffsetX = this.barW + this.gap;
    this.relayout();
  }

  /** 用当前内容尺寸重算绝对值盒布局，供实测后重排调用 */
  relayout(): void {
    this.width = this.barW + this.gap + this.body.width + this.gap + this.barW;
    this.height = this.body.height;
    this.depth = this.body.depth;
  }

  draw(ctx: CanvasRenderingContext2D, x: number, y: number): void {
    if (this.background) {
      ctx.fillStyle = this.background;
      ctx.fillRect(x, y - this.height, this.width, this.height + this.depth);
    }
    const yTop: number = y - this.height;
    const yBot: number = y + this.depth;
    const lw: number = Math.max(1, this.barW);
    ctx.strokeStyle = this.foreground ?? '#000000';
    ctx.lineWidth = lw;
    ctx.lineCap = 'butt';
    // 左竖线
    ctx.beginPath();
    ctx.moveTo(x + lw / 2, yTop);
    ctx.lineTo(x + lw / 2, yBot);
    ctx.stroke();
    // 右竖线
    const rx: number = x + this.width - lw / 2;
    ctx.beginPath();
    ctx.moveTo(rx, yTop);
    ctx.lineTo(rx, yBot);
    ctx.stroke();

    if (this.body.foreground == null && this.foreground != null) this.body.foreground = this.foreground;
    this.body.draw(ctx, x + this.barW + this.gap, y);
  }
}
