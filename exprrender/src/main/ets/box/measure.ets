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
// box/measure.ets
// 实测重排：用"已绑定 Canvas 上下文"在绘制前实测真实字形度量，并把收紧后的尺寸
// 向后传播到父盒。这是根治"盒子比真机字形大近一倍"的唯一可靠手段——
// 手调 FontMetrics 宽度表只是一组近似，与 HarmonyOS Sans 实际字形（及可能的
// DPR/字体缩放）存在偏差；而 ctx.measureText 与 ctx.fillText 处于同一坐标空间，
// 实测结果必然与最终绘制一致，盒子因此精确贴合墨迹。
//
// 调用时机：ExprView / MathFieldView 在 paint() 中、绘制前调用 measureAndRelayout。
// 此时 this.ctx 已绑定到可见 Canvas，measureText 返回真实值（构造期 ctx 未绑定会返回 0）。

import { Box } from './Box';
import { GlyphBox } from './GlyphBox';
import { HBox } from './HBox';
import { FracBox } from './FracBox';
import { PowerBox } from './PowerBox';
import { SubscriptBox } from './SubscriptBox';
import { SqrtBox } from './SqrtBox';
import { ParenBox } from './ParenBox';
import { AbsBox } from './AbsBox';
import { CeilFloorBox } from './CeilFloorBox';
import { measureTextWidth, glyphContentAscent, glyphContentDescent } from '../font/FontMetrics';

/** 取某盒的直接子盒（供后序遍历） */
function childList(box: Box): Box[] {
  if (box instanceof HBox) return box.children;
  if (box instanceof FracBox) return [box.num, box.den];
  if (box instanceof PowerBox) return [box.base, box.exp];
  if (box instanceof SubscriptBox) return [box.base, box.sub];
  if (box instanceof SqrtBox) return [box.body];
  if (box instanceof ParenBox) return [box.body];
  if (box instanceof AbsBox) return [box.body];
  if (box instanceof CeilFloorBox) return [box.body];
  if (box.isPower === true) return [(box as PowerBox).base, (box as PowerBox).exp];
  return [];
}

/** 用已绑定 ctx 实测单个字形盒的真实度量（宽度=advance，高度/深度=墨迹边界） */
function measureGlyph(g: GlyphBox, ctx: CanvasRenderingContext2D): void {
  // 字号单位用 vp（密度无关），与 GlyphBox.draw 的 fillText 保持同一坐标空间：
  // px 为物理像素，高 DPR 设备上 measureText 会返回被密度缩放的值，
  // 导致盒子布局与真实绘制不一致、表达式随设备密度缩小。
  ctx.font = `${g.italic ? 'italic ' : ''}${g.fontSize}vp ${g.family}`;
  const m: TextMetrics = ctx.measureText(g.text);
  // 宽度：用实测 advance；为 0（未绑定）时回退宽度表
  const adv: number = (typeof m.width === 'number' && m.width > 0) ? m.width : measureTextWidth(g.text, g.fontSize, g.italic);
  g.width = Math.max(1, adv);
  // 高度：优先用墨迹上边界（actualBoundingBoxAscent），缺失/为 0 时回退可见上伸比例
  const aba: number = m.actualBoundingBoxAscent;
  g.height = (typeof aba === 'number' && aba > 0) ? aba : glyphContentAscent(g.text, g.fontSize);
  // 深度：优先用墨迹下边界（actualBoundingBoxDescent），缺失/为 0 时回退可见下伸比例
  const abd: number = m.actualBoundingBoxDescent;
  g.depth = (typeof abd === 'number' && abd > 0) ? abd : glyphContentDescent(g.text, g.fontSize);
}

/**
 * 后序遍历盒子树：先实测并/或重排所有子盒，再重排当前盒。
 * 叶子 GlyphBox 用 ctx 实测；容器盒调用自身 relayout() 从已更新的子盒重算布局。
 * @param box 根盒（可为 null）
 * @param ctx 已绑定的 Canvas 上下文（未绑定时 measureText 返回 0，自动回退宽度表）
 */
export function measureAndRelayout(box: Box | null, ctx: CanvasRenderingContext2D | null): void {
  if (box == null || ctx == null) return;
  for (const c of childList(box)) {
    measureAndRelayout(c, ctx);
  }
  if (box instanceof GlyphBox) {
    measureGlyph(box, ctx);
  } else {
    box.relayout();
  }
}
