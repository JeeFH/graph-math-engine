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
// box/CeilFloorBox.ets
// 取整包裹盒子：⌈ body ⌉（向上取整）或 ⌊ body ⌋（向下取整）。
// 用"左竖线 + 右竖线 + 顶/底横段"的线条绘制，随内容高度自适应。
// 最小框架高度 = 字符高度 + 上标高度（≈1.4em），避免空符号坍缩。

import { Box } from './Box';

const MIN_FRAME: number = 0.45;  // 最小框架高度 / 字号（字符 + 上标高度）

export class CeilFloorBox extends Box {
  body: Box;
  isCeil: boolean;
  private fs: number = 0;
  private ext: number = 0;   // 顶/底横段向内的伸长长度
  private gap: number = 0;   // 水平间距（符号与内容之间）
  private vGap: number = 0;  // 垂直间距（符号与内容上下之间）

  /** 左符右侧、内容的水平偏移，供 LayoutMap 定位 */
  bodyOffsetX: number = 0;

  constructor(body: Box, isCeil: boolean, fontSize: number) {
    super();
    this.body = body;
    this.isCeil = isCeil;
    this.fs = fontSize;
    this.ext = fontSize * 0.15;
    this.gap = fontSize * 0.05;
    this.vGap = fontSize * 0.04;
    this.bodyOffsetX = this.ext + this.gap;
    this.relayout();
  }

  /** 用当前内容尺寸重算取整盒布局，供实测后重排调用 */
  relayout(): void {
    this.width = this.ext + this.gap + this.body.width + this.gap + this.ext;
    const totalH: number = this.body.height + this.body.depth + this.vGap * 2;
    const effH: number = Math.max(totalH, this.fs * MIN_FRAME);
    // 多余高度全部加到上方（height），保持 depth 与 body 对齐
    this.height = effH - this.body.depth;
    this.depth = this.body.depth;
  }

  draw(ctx: CanvasRenderingContext2D, x: number, y: number): void {
    if (this.background) {
      ctx.fillStyle = this.background;
      ctx.fillRect(x, y - this.height, this.width, this.height + this.depth);
    }
    const yTop: number = y - this.height;
    const yBot: number = y + this.depth;
    const lw: number = Math.max(1, this.fs * 0.06);
    ctx.strokeStyle = this.foreground ?? '#000000';
    ctx.lineWidth = lw;
    ctx.lineCap = 'butt';
    ctx.lineJoin = 'miter';
    const lx: number = x + lw / 2;
    const rx: number = x + this.width - lw / 2;

    // 单路径绘制，miter 连接保证拐角直角无断点
    if (this.isCeil) {
      // 左侧 ┘ 形（竖线 + 顶横段）
      ctx.beginPath();
      ctx.moveTo(lx + this.ext, yTop);
      ctx.lineTo(lx, yTop);
      ctx.lineTo(lx, yBot);
      ctx.stroke();
      // 右侧 └ 形（顶横段 + 竖线）
      ctx.beginPath();
      ctx.moveTo(rx, yBot);
      ctx.lineTo(rx, yTop);
      ctx.lineTo(rx - this.ext, yTop);
      ctx.stroke();
    } else {
      // 左侧 ┐ 形（竖线 + 底横段）
      ctx.beginPath();
      ctx.moveTo(lx, yTop);
      ctx.lineTo(lx, yBot);
      ctx.lineTo(lx + this.ext, yBot);
      ctx.stroke();
      // 右侧 ┌ 形（底横段 + 竖线）
      ctx.beginPath();
      ctx.moveTo(rx - this.ext, yBot);
      ctx.lineTo(rx, yBot);
      ctx.lineTo(rx, yTop);
      ctx.stroke();
    }

    if (this.body.foreground == null && this.foreground != null) this.body.foreground = this.foreground;
    this.body.draw(ctx, x + this.ext + this.gap, y);
  }
}
