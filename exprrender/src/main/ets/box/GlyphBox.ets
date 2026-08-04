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
// box/GlyphBox.ets
// 文字字形盒子：绘制单个文本（数字/字母/运算符/函数名）。
//
// 宽度来自 font/FontMetrics 的字符宽度表（不依赖任何 Canvas 上下文，确定可靠），
// 上下伸部用稳定比例，与真实字体度量对齐，避免被 Canvas 边界裁切。

import { Box } from './Box';
import { measureTextWidth, glyphContentAscent, glyphContentDescent } from '../font/FontMetrics';

export class GlyphBox extends Box {
  text: string = '';
  fontSize: number = 0;
  italic: boolean = false;
  family: string = 'HarmonyOS Sans';

  constructor(text: string, fontSize: number, italic: boolean = false, family: string = 'HarmonyOS Sans') {
    super();
    this.text = text;
    this.fontSize = fontSize;
    this.italic = italic;
    this.family = family;
    // 宽度来自字符宽度表（不调用离屏 measureText，避免返回 0 导致塌缩）
    this.width = Math.max(1, measureTextWidth(text, fontSize, italic));
    // 上下伸部按字形类别紧贴可见字形（x-height 字母≈0.5em，而非统一 0.96em 全行高），
    // 避免盒子被撑高近一倍；fillText 仍画完整字形，不会裁切。
    this.height = glyphContentAscent(text, fontSize);
    this.depth = glyphContentDescent(text, fontSize);
  }

  draw(ctx: CanvasRenderingContext2D, x: number, y: number): void {
    if (this.background) {
      ctx.fillStyle = this.background;
      ctx.fillRect(x, y - this.height, this.width, this.height + this.depth);
    }
    // 字号单位必须用 vp（密度无关），不能用 px：
    // ArkUI CanvasRenderingContext2D 中 px 为物理像素，高 DPR 手机（3x）上
    // '40px' 仅约 13vp，导致表达式随设备密度等比例缩小（平板 2x 约 20vp）。
    // 与 GraphCanvas 坐标轴标签的 '11vp sans-serif' 写法保持一致，确保
    // fontSize 在所有设备上按 vp 精确渲染（手机 46 / 平板 40 补偿才生效）。
    ctx.font = `${this.italic ? 'italic ' : ''}${this.fontSize}vp ${this.family}`;
    ctx.fillStyle = this.foreground ?? '#000000';
    ctx.textBaseline = 'alphabetic';
    ctx.textAlign = 'left';
    ctx.fillText(this.text, x, y);
  }
}
