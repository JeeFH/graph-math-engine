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
// box/SubscriptBox.ets
// 下标盒子：底数 + 下标（右下方缩小）。用于 log_x(y) 等对数函数底数渲染。

import { Box } from './Box';
import { SUB_DROP, SUB1 } from '../font/TeXMetrics';

export class SubscriptBox extends Box {
  base: Box;
  sub: Box;
  private fs: number = 0;

  /** 下标基线相对本盒基线的偏移（正，在右下方）；供 LayoutMap 放置光标 */
  subBaselineOffset: number = 0;

  constructor(base: Box, sub: Box, fontSize: number) {
    super();
    this.base = base;
    this.sub = sub;
    this.fs = fontSize;
    this.relayout();
  }

  relayout(): void {
    // 下标基线下沉量：SUB1 + SUB_DROP * fontSize（下标顶部不超过基线下方 SUB_DROP）
    const drop: number = SUB1 * this.fs + SUB_DROP * this.fs;
    this.subBaselineOffset = drop;
    this.width = this.base.width + this.sub.width;
    this.height = this.base.height;
    this.depth = Math.max(this.base.depth, drop + this.sub.depth);
  }

  draw(ctx: CanvasRenderingContext2D, x: number, y: number): void {
    if (this.background) {
      ctx.fillStyle = this.background;
      ctx.fillRect(x, y - this.height, this.width, this.height + this.depth);
    }
    if (this.base.foreground == null && this.foreground != null) this.base.foreground = this.foreground;
    if (this.sub.foreground == null && this.foreground != null) this.sub.foreground = this.foreground;
    this.base.draw(ctx, x, y);
    this.sub.draw(ctx, x + this.base.width, y + this.subBaselineOffset);
  }
}
