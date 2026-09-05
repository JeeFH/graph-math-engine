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
// box/SqrtBox.ets
// 根号盒子：单一干净的根号笔画，三笔成型（小斜勾 → 大斜杠 → 横杠），
// 不叠加 √ 字形。根号笔画整体覆盖内部 body 的真实高度（body.height + body.depth），
// 各锚点由 body 度量推导；并设最小框架高度（≈一个基本字符 box），避免空根号坍缩成横线。
import { Box } from '../box/Box';

  const MIN_FRAME_RATIO: number = 0.4;   // 根号最小框架高度 / 字号（约一个基本字符 box）

export class SqrtBox extends Box {
  body: Box;
  private fs: number = 0;

  /** 根号符号右侧、被开方数起点的水平偏移，供 LayoutMap 定位 */
  bodyOffsetX: number = 0;

  constructor(body: Box, fontSize: number) {
    super();
    this.body = body;
    this.fs = fontSize;
    this.relayout();
  }

  /** 用当前被开方数尺寸重算根号盒布局，供实测后重排调用 */
  relayout(): void {
    const legW: number = this.fs * 0.26;
    const topGap: number = this.fs * 0.1;    // 横线与 body 顶部的视觉间距（≈2.4px @fs24）
    this.bodyOffsetX = legW;
    this.width = legW + this.body.width;
    const bodyTotal: number = this.body.height + this.body.depth + topGap;
    const effTotal: number = Math.max(bodyTotal, this.fs * MIN_FRAME_RATIO);
    // 盒子总高 = effTotal（≥ 最小框架），多余高度加到上方，避免空根号坍缩
    this.height = effTotal - this.body.depth;
    this.depth = this.body.depth;
  }

  draw(ctx: CanvasRenderingContext2D, x: number, y: number): void {
    if (this.background) {
      ctx.fillStyle = this.background;
      ctx.fillRect(x, y - this.height, this.width, this.height + this.depth);
    }
    const fs: number = this.fs;
    const legW: number = fs * 0.26;
    const topGap: number = fs * 0.1;

    // 根号笔画的垂直边界：最低点 = body 底；最高点 = 底 - effTotal（不足最小框架时抬高）
    const yBot: number = y + this.body.depth;
    const bodyTotal: number = this.body.height + this.body.depth + topGap;
    const effTotal: number = Math.max(bodyTotal, fs * MIN_FRAME_RATIO);
    const yTop: number = yBot - effTotal;   // 横杠 / 大斜杠右上顶点（≥ body 顶）

    // P1 小钩尾部压到 body 底之上 topGap 处：大斜杠(P1→P2)上升量 = 内部盒子真实高度
    // P0 小钩左上起点仅比 P1 高 totalH*kHook（短钩），并往 X 正半轴、下方挪一点
    const totalH: number = yBot - yTop;
    const kHook: number = 0.12;                 // 小钩占 totalH 的比例（短）
    const yHookBot: number = yBot;                  // P1：对齐 body 底，确保根号最低点不悬空
    const yHookTop: number = yHookBot - totalH * kHook; // P0：比 P1 高一点点

    const strokeW: number = Math.max(1, fs * 0.05);  // 三笔共用同一线宽：横杠与斜杠粗细一致
    ctx.strokeStyle = this.foreground ?? '#000000';
    ctx.lineWidth = strokeW;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.beginPath();
    ctx.moveTo(x + legW * 0.12, yHookTop);                    // P0 小钩左上起点（下压 + 右移）
    ctx.lineTo(x + legW * 0.38, yHookBot);                    // 第1笔：小斜勾 → 右下（短）
    ctx.lineTo(x + legW,        yTop);                        // 第2笔：大斜杠 → 右上
    ctx.lineTo(x + legW + this.body.width, yTop);             // 第3笔：横杠 → 向右
    ctx.stroke();

    // body 仍按原基线 y 绘制
    if (this.body.foreground == null && this.foreground != null) this.body.foreground = this.foreground;
    this.body.draw(ctx, x + legW, y);
  }
}
