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
// box/PowerBox.ets
// 上下标盒子：底数 + 上标（右上方缩小）。下标由 VstRow 以行内形式处理，本类仅画上标。

import { Box } from './Box';
import { SUP1 } from '../font/TeXMetrics';

export class PowerBox extends Box {
  base: Box;
  exp: Box;
  private fs: number = 0;

  /** 指数基线相对本盒基线的偏移（负，在右上方）；供 LayoutMap 放置光标 */
  expBaselineOffset: number = 0;

  constructor(base: Box, exp: Box, fontSize: number) {
    super();
    this.base = base;
    this.exp = exp;
    this.fs = fontSize;
    this.isPower = true;
    this.relayout();
  }

  /** 用当前底数/指数尺寸重算上标盒布局，供实测后重排调用 */
  relayout(): void {
    // 上标基线抬高量：
    //  - 简单上标：SUP1 一半 + 约半个指数字符高度（fs*0.25）。曾因“原位置过高”
    //    降到 SUP1 一半，但实际偏下（指数底部几乎贴基线），故再上抬半个字符高度，
    //    使指数底部明显高于基线、呈标准上标位置。
    //  - 右结合嵌套：x^a^b = x^(a^b)，此时 exp 自身是 PowerBox（指数塔堆叠在
    //    指数那一侧），把整个指数塔抬到主基线上方（指数塔最低墨迹距主基线 gap）。
    //  - 左结合嵌套（编辑器/旧数据可能产生的 Pow(Pow(x,2),2)）：底数本身是指数塔，
    //    把指数抬到塔顶之上。
    //  - 高指数（分数等）：抬到指数底部在主基线上方。
    const simpleRaise: number = SUP1 * this.fs * 0.5 + this.fs * 0.25;
    let raise: number = simpleRaise;
    // 用 isPower 标记位而非 instanceof（ArkTS/HAR 打包可能产生类副本，跨副本
    // instanceof 偶发判否，会让嵌套检测永远走不到，正是"嵌套指数依旧重叠"的根因）。
    const nestedExp: boolean = this.exp.isPower === true;
    const nestedBase: boolean = this.base.isPower === true;
    if (nestedExp) {
      // 指数塔基线抬到常规上标位置；若指数塔自身有下伸部，则再额外抬高避免下探到主基线以下
      raise = Math.max(simpleRaise, this.exp.depth + this.fs * 0.12);
    } else if (nestedBase) {
      raise = this.base.height + this.fs * 0.12;
    } else if (this.exp.height > this.fs * 0.85) {
      raise = this.exp.depth + this.fs * 0.12;
    }

    // ── 指数底部不低于底数基线约束 ──
    // 指数盒绘制在 y - raise 处，其底部（最深墨迹）在 y - raise + exp.depth。
    // 约束：指数底部至少高于底数基线一个安全距离（safetyGap），
    // 即 raise >= exp.depth + safetyGap。
    // 当指数包含分式等高大内容时，自动上抬指数基线，并扩大 PowerBox 整体尺寸。
    const safetyGap: number = this.fs * 0.08;
    const minRaise: number = this.exp.depth + safetyGap;
    if (raise < minRaise) {
      raise = minRaise;
    }

    this.expBaselineOffset = -raise;
    this.width = this.base.width + this.exp.width;
    this.height = Math.max(this.base.height, this.exp.height + raise);
    this.depth = this.base.depth;
  }

  draw(ctx: CanvasRenderingContext2D, x: number, y: number): void {
    if (this.background) {
      ctx.fillStyle = this.background;
      ctx.fillRect(x, y - this.height, this.width, this.height + this.depth);
    }
    if (this.base.foreground == null && this.foreground != null) this.base.foreground = this.foreground;
    if (this.exp.foreground == null && this.foreground != null) this.exp.foreground = this.foreground;
    this.base.draw(ctx, x, y);
    const raise: number = -this.expBaselineOffset;
    this.exp.draw(ctx, x + this.base.width, y - raise);
  }
}
