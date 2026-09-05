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
// view/ExprView.ets
// 自研静态表达式渲染：parseLinear -> VstRow -> Box -> Canvas。
// 去掉 鍘熷寮曟搸 retex 依赖，改用自研 box/ + engine/ExprRender。
// 公开 @Prop 接口保持不变（@Prop 在 ArkTS 中不可为复杂表达式）。

import { parseLinear } from '../parser/ExprParser';
import { simplify } from '../vst/ExpressionSimplifier';
import { VstRow } from '../vst/VstNodes';
import { VstNum } from '../vst/VstNodes';
import { Box } from '../box/Box';
import { GlyphBox } from '../box/GlyphBox';
import { HBox } from '../box/HBox';
import { FracBox } from '../box/FracBox';
import { SqrtBox } from '../box/SqrtBox';
import { PowerBox } from '../box/PowerBox';
import { ParenBox } from '../box/ParenBox';
import { AbsBox } from '../box/AbsBox';
import { CeilFloorBox } from '../box/CeilFloorBox';
import { measureAndRelayout } from '../box/measure';
import { DebugMask } from '../types/ExprTypes';
import { ExprRenderer } from '../engine/ExprRender';

const CURSOR_BLINK_MS = 530;

@Component
export struct ExprView {
  @Prop @Watch('onExprChange') expr: string = '';
  /** 文本颜色：传具体颜色字符串（如 '#FF0000'）则原样使用；
   *  缺省（空串）或传主题依赖资源色时，前景色随主题自适应——
   *  与 MathFieldView 的 isDark 标准前景色保持一致（资源色经 getColorSync
   *  无法正确解析暗色变体，统一映射为标准前景色）。 */
  @Prop @Watch('onExprChange') color: ResourceColor = '';
  @Prop @Watch('onExprChange') fontSize: number = 18;
  /** 乘号显示字形：默认 '·'（图象模式）；基础模式历史传 '×'。 */
  @Prop @Watch('onExprChange') mulGlyph: string = '·';
  @Prop @Watch('onExprChange') debug: boolean = false;
  @Prop @Watch('onExprChange') debugMask?: DebugMask;

  @StorageProp('isDarkMode') @Watch('onThemeChange') isDark: boolean = false;

  @State private boxW: number = 1;
  @State private boxH: number = 1;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private box: Box | null = null;

  aboutToAppear(): void {
    // 不在此处 renderExpr()——Canvas 未就绪时 ctx 未绑定，
    // measureAndRelayout 回退宽度表，尺寸不准。由 onReady 触发首次渲染。
  }

  onThemeChange(): void {
    this.renderExpr();
  }

  /** 前景色：与 MathFieldView 的明暗适配保持一致。
   *  主题依赖资源色（sys.color.*）经 getColorSync 无法正确解析暗色变体
   *  （配置更新滞后），故不再走 resolveColor；调用方传入具体颜色字符串时
   *  原样使用，否则统一使用基于 isDark 的标准前景色（同 MathFieldView）。
   *  注意：不能命名为 foregroundColor——与 CommonAttribute 内置属性冲突。 */
  private resolveFg(): string {
    if (typeof this.color === 'string' && this.color.length > 0) {
      return this.color;
    }
    return this.isDark ? '#E6E6E6' : '#1A1A1A';
  }

  onExprChange(): void {
    this.renderExpr();
  }

  private renderExpr(): void {
    if (this.expr.length === 0) {
      this.boxW = 1;
      this.boxH = 1;
      this.box = null;
      return;
    }
    try {
      const row: VstRow = parseLinear(this.expr);
      // 兜底：解析失败（空行）但表达式非空 → 用原始文本渲染红色提示
      if (row.children.length === 0 && this.expr.trim().length > 0) {
        const fallbackRow: VstRow = new VstRow([new VstNum(this.expr.trim())]);
        this.box = ExprRenderer.render(fallbackRow, this.fontSize, '#E53935', this.mulGlyph);
      } else {
        // 完成态化简：同底数因子合并为幂（x·x·x -> x³）、数字×数字保留 ·、其余隐式。
        // 编辑态 MathFieldView 不化简，保持输入原貌。
        const simplified: VstRow = simplify(row);
        this.box = ExprRenderer.render(simplified, this.fontSize, this.resolveFg(), this.mulGlyph);
      }
      // 用已绑定 Canvas 实测真实字形度量并向上重排，使盒子精确贴合真机字形。
      // 必须在尺寸计算之前执行，否则 Canvas 尺寸基于重排前的旧值，
      // 导致重排后 depth 增大时内容被裁切（完成态"熔断"根因）。
      if (this.ctx != null) measureAndRelayout(this.box, this.ctx);
      // 区块着色：按 debugMask 给各盒子设置底色，便于看清真实尺寸
      this.clearDebug(this.box);
      if (this.debug) this.applyDebugMask(this.box, this.debugMask);
      // 使用原始类型 @State 变量（与 MathFieldView 对齐），
      // 确保 ArkUI 可靠检测尺寸变化并触发 Canvas resize。
      this.boxW = Math.max(1, this.box!.width);
      this.boxH = Math.max(1, this.box!.height + this.box!.depth);
      this.paint();
    } catch (_e) {
      this.box = null;
      this.boxW = 1;
      this.boxH = 1;
    }
  }

  private paint(): void {
    if (this.ctx == null || this.box == null) return;
    const th: number = this.box.height + this.box.depth;
    if (th <= 0) return;
    this.ctx.clearRect(0, 0, this.box.width, th);
    this.box.draw(this.ctx, 0, this.box.height);
  }

  /** 清掉整棵盒子树的底色（关闭调试时） */
  private clearDebug(box: Box | null): void {
    if (box == null) return;
    box.background = undefined;
    for (const c of this.childBoxes(box)) this.clearDebug(c);
  }

  /** 按 debugMask 给各盒子设置底色（按类型分色），便于看清真实尺寸 */
  private applyDebugMask(box: Box, mask: DebugMask | undefined): void {
    if (box == null) return;
    const m: DebugMask = mask ?? {};
    let on: boolean = false;
    let color: string = '';
    if (box instanceof GlyphBox) { on = !!m.glyph; color = 'rgba(229,115,115,0.18)'; }
    else if (box instanceof HBox) { on = !!m.hbox; color = 'rgba(79,195,247,0.16)'; }
    else if (box instanceof ParenBox) { on = !!m.paren; color = 'rgba(129,199,132,0.18)'; }
    else if (box instanceof CeilFloorBox) { on = !!m.paren; color = 'rgba(129,199,132,0.18)'; }
    else if (box instanceof AbsBox) { on = !!m.abs; color = 'rgba(186,104,200,0.18)'; }
    else if (box instanceof FracBox) { on = !!m.frac; color = 'rgba(255,183,77,0.22)'; }
    else if (box instanceof SqrtBox) { on = !!m.sqrt; color = 'rgba(77,208,225,0.18)'; }
    else if (box instanceof PowerBox) { on = !!m.power; color = 'rgba(240,98,146,0.18)'; }
    else if (box.isPower === true) { on = !!m.power; color = 'rgba(240,98,146,0.18)'; }
    else { on = false; }
    box.background = on ? color : undefined;
    for (const c of this.childBoxes(box)) this.applyDebugMask(c, mask);
  }

  /** 取盒子的直接子盒子（供调试底色递归遍历） */
  private childBoxes(box: Box): Box[] {
    if (box instanceof HBox) return box.children;
    if (box instanceof FracBox) return [box.num, box.den];
    if (box instanceof PowerBox) return [box.base, box.exp];
    if (box.isPower === true) return [(box as PowerBox).base, (box as PowerBox).exp];
    if (box instanceof SqrtBox) return [box.body];
    if (box instanceof ParenBox) return [box.body];
    if (box instanceof AbsBox) return [box.body];
    if (box instanceof CeilFloorBox) return [box.body];
    return [];
  }

  build() {
    Canvas(this.ctx)
      .width(this.boxW)
      .height(this.boxH)
      .backgroundColor(Color.Transparent)
      .onReady((): void => { this.renderExpr(); })
      .onAreaChange((_old: SizeOptions, _new: SizeOptions): void => { this.paint(); })
  }
}
