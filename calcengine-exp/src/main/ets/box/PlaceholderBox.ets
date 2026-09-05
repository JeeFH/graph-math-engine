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
// box/PlaceholderBox.ets
// 占位符盒子：不再绘制虚线方框（已按需求移除）。
// 仅作为布局树中的不可见锚点，供光标/结构路径定位使用；空表达式或解析占位时
// 渲染为"无内容"，而不是一个刺眼的虚线矩形。

import { Box } from './Box';

export class PlaceholderBox extends Box {
  constructor(fontSize: number) {
    super();
    // 不可见锚点：尺寸归零，避免占据布局空间或露出虚线框。
    this.width = 0;
    this.height = 0;
    this.depth = 0;
  }

  draw(_ctx: CanvasRenderingContext2D, _x: number, _y: number): void {
    // 需求：去掉虚线方框。占位符默认不绘制任何内容。
  }
}
