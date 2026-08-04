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
// view/MathFieldView.ets
// 自研可编辑表达式渲染：MathField.root -> Box -> Canvas，叠加聚焦高亮方块（常亮）。
// 去掉 鍘熷寮曟搸 retex 的 TeXIcon/DrawEquation/CursorBox，改用自研 ExprRenderer + LayoutMap。
//
// 光标呈现策略（聚焦高亮方块，替代竖线光标）：
//   1. 不绘制竖线，改为对光标指向的目标 Box 叠加半透明填充 + 边框，
//      由 LayoutMap.cursorBoxRect 宽松查表定位（不依赖 charOffset 精确对齐）。
//   2. 不使用闪烁定时器——高亮方块在有焦点时常亮可见。
//   3. 外部 fieldVersion 变化 → @Watch → renderBox() 重建 Box 树 + LayoutMap。
//   4. paint() 通过 setTimeout(0) 延迟到框架渲染周期之后执行，
//      确保 Canvas 不被框架后续清除。
//   5. ForEach key 不含 expr（由 GraphDisplayArea 保证），MathFieldView 不会被反复销毁重建。
import { MathField } from '../vst/VstEditor';
import { Box } from '../box/Box';
import { ExprRenderer } from '../engine/ExprRender';
import { LayoutMap } from '../engine/LayoutMap';
import { measureAndRelayout } from '../box/measure';

@Component
export struct MathFieldView {
  @Prop @Watch('onFieldChange') field: MathField = new MathField();
  @Prop @Watch('onFieldChange') fontSize: number = 40;
  /** 版本计数器：由外部传入，变化时触发 onFieldChange → renderBox()，使光标重绘 */
  @Prop @Watch('onFieldChange') fieldVersion: number = 0;
  /** 错误态标志：为 true 时表达式文字/光标变为红色 */
  @Prop @Watch('onFieldChange') errorMode: boolean = false;
  /** 乘号显示字形：默认 '·'（图象模式）；特定模式可传 '×' */
  @Prop @Watch('onFieldChange') mulGlyph: string = '·';
  /** 线性除法模式：默认 false（除法渲染为分数）；特定模式传 true，除法显示 ÷ */
  @Prop @Watch('onFieldChange') divLinear: boolean = false;

  @StorageProp('isDarkMode') @Watch('onThemeChange') isDark: boolean = false;

  @State private boxW: number = 1;
  @State private boxH: number = 1;

  private box: Box | null = null;
  private layout: LayoutMap | null = null;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  aboutToAppear(): void {
    this.renderBox();
  }

  aboutToDisappear(): void {
    // 无定时器需要清理
  }

  onFieldChange(): void {
    this.renderBox();
    // 延迟 paint 到框架渲染周期之后：
    // @Prop 变化触发组件重渲染，框架可能清除 Canvas 内容。
    // setTimeout(0) 将 paint 推到下一事件循环，确保 Canvas 已稳定。
    setTimeout(() => {
      this.paint();
    }, 0);
  }

  onThemeChange(): void {
    this.renderBox();
    setTimeout(() => {
      this.paint();
    }, 0);
  }

  private renderBox(): void {
    try {
      const fg: string = this.errorMode ? '#D7263D' : (this.isDark ? '#E6E6E6' : '#1A1A1A');
      this.box = ExprRenderer.render(this.field.root, this.fontSize, fg, this.mulGlyph, this.divLinear);
      // 用已绑定 Canvas 实测真实字形度量并向上重排，使盒子精确贴合真机字形。
      // 必须在 LayoutMap.collect 之前执行，光标定位才能与实测度量一致。
      measureAndRelayout(this.box, this.ctx);
      this.layout = new LayoutMap();
      this.layout.collect(this.box, []);
      // Canvas 尺寸下限：仅当表达式内容为零尺寸（空占位符）时才用最小尺寸兑底，
      // 避免 cursorMinW/cursorMinH 撑大真实内容的 Canvas（进而撑大表达式容器）。
      const contentW: number = this.box.width;
      const contentH: number = this.box.height + this.box.depth;
      this.boxW = Math.max(1, contentW > 0 ? contentW : this.cursorMinW());
      this.boxH = Math.max(1, contentH > 0 ? contentH : this.cursorMinH());
    } catch (_e) {
      this.box = null;
      this.layout = null;
      this.boxW = 1;
      this.boxH = 1;
    }
  }

  /** 高亮方块最小可见宽度（零宽占位符时强制扩展） */
  private cursorMinW(): number {
    return this.fontSize * 0.35;
  }

  /** 高亮方块最小可见高度（零高占位符时强制扩展，与数字字形高度一致） */
  private cursorMinH(): number {
    return this.fontSize * 0.72;
  }

  /** 绘制表达式 + 聚焦高亮方块。由 onReady / onFieldChange 延迟调用。 */
  private paint(): void {
    if (this.ctx == null || this.box == null) return;
    // 清除整个画布（而非仅 box 自身范围）：空表达式时 box 尺寸为 0 但画布被
    // 最小尺寸下限扩大，若只清 box 范围会残留上一帧的高亮方块。
    // 注意：不能因 box 高度为 0 提前返回，否则空状态下聚焦高亮无法绘制。
    this.ctx.clearRect(0, 0, this.boxW, this.boxH);
    this.box.draw(this.ctx, 0, this.box.height);
    // 聚焦高亮方块（不闪烁，始终可见）：对光标指向的目标 Box 叠加半透明填充 + 边框
    if (this.layout != null) {
      const r = this.layout.cursorBoxRect(this.field.cursor);
      if (r) {
        const actualW: number = r.width;
        const actualH: number = r.yBottom - r.yTop;
        // 零尺寸占位符 → 强制最小可见尺寸；真实内容 → 紧贴字形实际尺寸，避免高亮高于字符
        const empty: boolean = actualW <= 0 && actualH <= 0;
        const w: number = empty ? this.cursorMinW() : actualW;
        const h: number = empty ? this.cursorMinH() : actualH;
        const cx: number = r.x + r.width / 2;
        const cy: number = (r.yTop + r.yBottom) / 2;
        // 钳制到非负象限：占位符位于画布最左/最上边缘时，避免方块延伸到负坐标被裁剪
        const x0: number = Math.max(0, cx - w / 2);
        const y0: number = Math.max(0, cy - h / 2);
        this.ctx.fillStyle = this.errorMode ? 'rgba(215,38,61,0.12)'
          : (this.isDark ? 'rgba(157,195,255,0.18)' : 'rgba(32,102,255,0.12)');
        this.ctx.fillRect(x0, y0, w, h);
        this.ctx.strokeStyle = this.errorMode ? '#D7263D' : (this.isDark ? '#9DC3FF' : '#2066FF');
        this.ctx.lineWidth = Math.max(1, this.fontSize * 0.04);
        this.ctx.strokeRect(x0, y0, w, h);
      }
    }
  }

  build() {
    Canvas(this.ctx)
      .width(this.boxW)
      .height(this.boxH)
      .onReady((): void => {
        this.renderBox();
        this.paint();
      })
  }
}
