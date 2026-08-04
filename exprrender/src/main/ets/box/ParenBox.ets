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
// box/ParenBox.ets
// 圆括号包裹盒子：( body )
// 采用"按内容高度纵向拉伸字形"的方式绘制左右括号，使括号随内容（如上标、分数）
// 自适应高度，且左右一致，避免固定字号字形在内容偏高时显得过小/不一致。

import { Box } from './Box';
import { measureTextWidth, glyphAscent, glyphDescent } from '../font/FontMetrics';

export class ParenBox extends Box {
  body: Box;
  private fs: number = 0;
  private parenW: number = 0;  // 括号可见宽度
  private parenGap: number = 0;  // 括号与内容之间的水平间隙

  /** 左括号右侧、内容的水平偏移，供 LayoutMap 定位 */
  bodyOffsetX: number = 0;

  constructor(body: Box, fontSize: number) {
    super();
    this.body = body;
    this.fs = fontSize;
    // 括号 advance width 含约 40% 不可见边距，乘以 0.6 得到真实可见宽度
    this.parenW = measureTextWidth('(', fontSize, false) * 0.6;
    this.parenGap = fontSize * 0.2;                 // 新增
    this.bodyOffsetX = this.parenW + this.parenGap;  // 由 parenW 改为 parenW + gap
    this.relayout();
  }

  /** 用当前内容尺寸重算括号盒布局，供实测后重排调用 */
  relayout(): void {
    // 宽度 = 左括号 + 间隙 + 内容 + 间隙 + 右括号（括号紧贴内容两端）
    this.width = this.parenW + this.parenGap + this.body.width + this.parenGap + this.parenW;
    this.height = this.body.height;
    this.depth = this.body.depth;
  }

  draw(ctx: CanvasRenderingContext2D, x: number, y: number): void {
    if (this.background) {
      ctx.fillStyle = this.background;
      ctx.fillRect(x, y - this.height, this.width, this.height + this.depth);
    }
    // 把 '(' ')' 字形按本盒实际高度（内容高）纵向拉伸，使其覆盖完整内容高度。
    // 关键：拉伸分母必须是圆括号在真机字体下的"自然上下伸部之和"，不能用固定的全行高
    // glyphAscent+glyphDescent(≈0.96fs)——HarmonyOS Sans 的圆括号实际只跨约 0.48fs，
    // 若用 0.96fs 作分母，缩放后括号只剩盒子高度的二分之一（即用户反馈的半高问题）。
    // 因此用已绑定 ctx 实测括号真实度量；未绑定/老接口时回退全行高（渲染期不会走到）。
    // 字号单位用 vp（密度无关），与 GlyphBox.draw/measureGlyph 保持同一坐标空间，
    // 避免高 DPR 设备上括号笔画与字形密度缩放不一致。
    ctx.font = `${this.fs}vp 'HarmonyOS Sans'`;
    let natA: number = 0;
    let natD: number = 0;
    try {
      const mk: TextMetrics = ctx.measureText('(');
      if (typeof mk.actualBoundingBoxAscent === 'number' && mk.actualBoundingBoxAscent > 0) {
        natA = mk.actualBoundingBoxAscent;
      }
      if (typeof mk.actualBoundingBoxDescent === 'number' && mk.actualBoundingBoxDescent > 0) {
        natD = mk.actualBoundingBoxDescent;
      }
    } catch (_e) { /* 忽略，走回退 */ }
    let natH: number;
    if (natA > 0 || natD > 0) {
      natH = natA + natD;
    } else {
      natH = glyphAscent(this.fs) + glyphDescent(this.fs);
    }
    const scaleY: number = natH > 0 ? (this.height + this.depth) / natH : 1;
    // 垂直居中：让拉伸后的括号中心对齐盒子中心，避免上下偏移
    const sb: number = (this.depth - this.height) / (2 * scaleY) - (natD - natA) / 2;
    ctx.save();
    ctx.translate(x, y);
    ctx.scale(1, scaleY);
    ctx.fillStyle = this.foreground ?? '#000000';
    ctx.textBaseline = 'alphabetic';
    // 左括号：左对齐锚在盒子左缘。'(' 墨迹在 advance box 左侧（左 bearing 小、右 bearing 大），
    // 墨迹右缘仅略超 parenW，由 parenGap 吸收，贴合盒子左缘无截断。
    ctx.textAlign = 'left';
    ctx.fillText('(', 0, sb);
    // 右括号：必须右对齐锚在盒子右缘。')' 墨迹在 advance box 右侧（左 bearing 大、右 bearing 小），
    // 旧写法用 textAlign='left' 锚在 width-parenW，墨迹右缘越出盒子右边界约 0.35×adv
    // （越界量恒定，与总宽无关——故调整宽度参数无法修复），位于表达式最右端时被画布裁掉。
    // 改为右对齐后 advance box 右缘对齐盒子右缘，墨迹（右 bearing 小）恰好收在盒内，
    // 左缘少量越界由 parenGap 吸收。
    ctx.textAlign = 'right';
    ctx.fillText(')', this.width, sb);
    ctx.restore();

    if (this.body.foreground == null && this.foreground != null) this.body.foreground = this.foreground;
    this.body.draw(ctx, x + this.bodyOffsetX, y);  // 由 x + this.parenW 改为引用 bodyOffsetX
  }
}
