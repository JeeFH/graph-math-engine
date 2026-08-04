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
// box/HBox.ets
// 水平容器：子盒子沿基线从左到右排列（同一基线对齐）。

import { Box } from './Box';

export class HBox extends Box {
  children: Box[] = [];
  spacing: number = 0;
  /** 若为 true，relayout 时自动将第一个子盒上移，使其视觉中心对齐第二个子盒的视觉中心 */
  centerFirstChild: boolean = false;

  constructor(children: Box[] = [], spacing: number = 0) {
    super();
    this.children = children;
    this.spacing = spacing;
    this.relayout();
  }

  relayout(): void {
    let w: number = 0;
    let h: number = 0;
    let d: number = 0;
    for (let i = 0; i < this.children.length; i++) {
      const c: Box = this.children[i];
      if (i > 0) w += this.spacing;
      w += c.width;
      if (c.height > h) h = c.height;
      if (c.depth > d) d = c.depth;
    }
    this.width = w;
    this.height = h;
    this.depth = d;
    // 每次 relayout（含 measureAndRelayout 触发的）都重算 shift，确保使用最新实测尺寸
    if (this.centerFirstChild && this.children.length >= 2) {
      const first: Box = this.children[0];
      const second: Box = this.children[1];
      const secondCenter: number = (second.height - second.depth) / 2;
      const firstCenter: number = (first.height - first.depth) / 2;
      first.shift = Math.max(0, secondCenter - firstCenter);
    }
  }

  draw(ctx: CanvasRenderingContext2D, x: number, y: number): void {
    if (this.background) {
      ctx.fillStyle = this.background;
      ctx.fillRect(x, y - this.height, this.width, this.height + this.depth);
    }
    let cx: number = x;
    for (let i = 0; i < this.children.length; i++) {
      const c: Box = this.children[i];
      if (c.foreground == null && this.foreground != null) c.foreground = this.foreground;
      // shift > 0 表示子盒需要上移（用于函数名对齐括号视觉中心等场景）
      c.draw(ctx, cx, y - c.shift);
      cx += c.width + this.spacing;
    }
  }
}
