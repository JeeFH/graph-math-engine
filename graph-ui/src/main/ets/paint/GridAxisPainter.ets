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
/**
 * GridAxisPainter - 坐标系网格 / 坐标轴 / 刻度标签 / 原点绘制器
 *
 * 从 GraphCanvas 拆分出的纯绘制逻辑（GraphCanvasCore 的绘制部分）：
 * - 主题配色解析（浅色 / 暗色，全部为 6 位 hex 预合成色）
 * - 网格（主格 + 次格）、坐标轴、四边智能吸附刻度标签、原点标记
 * - 刻度步长解析（自定义单位长度 / 自动 niceStep）
 * - π 系符号化标签与数值格式化工具
 *
 * 与组件状态无关，全部输入经参数传入，可独立测试。
 */

import { GraphMath, Viewport, GraphFunction } from 'graph';

/** 坐标系绘制配置（由 GraphCanvas 每帧组装传入） */
export interface GridAxisConfig {
  /** 暗色模式 */
  isDark: boolean;
  /** 显示网格 */
  showGrid: boolean;
  /** 显示坐标轴 */
  showAxes: boolean;
  /** 显示刻度标签 */
  showLabels: boolean;
  /** x 轴单位长度（0 = 自动 niceStep） */
  xUnitLength: number;
  /** y 轴单位长度（0 = 自动 niceStep） */
  yUnitLength: number;
}

export class GridAxisPainter {
  // ── 主题配色 ──
  // 关键约束：ArkUI Canvas 的 strokeStyle/fillStyle 只解析 6 位 hex（#RRGGBB），
  // 不解析 rgba(...) 与 8 位 #RRGGBBAA 透明度写法——赋值会被静默丢弃，
  // 导致沿用上一次颜色（默认黑、不透明），即「设了低透明度却仍是 100% 不透明」。
  // 故所有「半透明」效果必须按背景预合成进 RGB，只留纯 6 位色。
  // 暗色背景 ≈ #000000，亮色背景 ≈ #FFFFFF。

  /** 次网格线颜色（暗色：白线约 0.06 透明度预合成到黑；亮色：黑线约 0.06） */
  static gridMinorColor(isDark: boolean): string {
    return isDark ? '#262626' : '#EFEFEF';
  }

  /** 主网格线颜色（暗色：白线约 0.18 透明度；亮色：黑线约 0.13） */
  static gridMajorColor(isDark: boolean): string {
    return isDark ? '#2E2E2E' : '#DEDEDE';
  }

  /** 坐标轴颜色（暗色：白线约 0.47 透明度；亮色：黑线约 0.45） */
  static axisColor(isDark: boolean): string {
    return isDark ? '#777777' : '#737373';
  }

  /** 刻度标签文字颜色 */
  static labelColor(isDark: boolean): string {
    return isDark ? '#AAAAAA' : '#666666';
  }

  /** 原点圆点颜色（与坐标轴同色系，略深以突出原点位置） */
  static zeroDotColor(isDark: boolean): string {
    return isDark ? '#999999' : '#555555';
  }

  /**
   * 画布背景填充色（与宿主背景视觉一致）。
   * 用于在绘制前把画布填成不透明——否则 getPixelMap 截出的是透明底，
   * 打包 JPEG（无 alpha 通道）后会变成黑底。
   */
  static bgColor(isDark: boolean): string {
    return isDark ? '#1A1A1A' : '#FFFFFF';
  }

  // ── 步长解析 ──

  /** 解析 x 轴刻度步长：单位长度 > 0 时取单位长度，否则自动 niceStep */
  static resolveXStep(vp: Viewport, xUnitLength: number): number {
    return xUnitLength > 0 ? xUnitLength : GraphMath.niceStep(vp.xMax - vp.xMin, 10);
  }

  /** 解析 y 轴刻度步长：单位长度 > 0 时取单位长度，否则自动 niceStep */
  static resolveYStep(vp: Viewport, yUnitLength: number): number {
    return yUnitLength > 0 ? yUnitLength : GraphMath.niceStep(vp.yMax - vp.yMin, 10);
  }

  // ── 绘制 ──

  /** 网格：次网格（细）+ 主网格（稍深） */
  static drawGrid(ctx: CanvasRenderingContext2D, vp: Viewport, w: number, h: number,
    config: GridAxisConfig): void {
    const isDark: boolean = config.isDark;
    const xStep: number = GridAxisPainter.resolveXStep(vp, config.xUnitLength);
    const yStep: number = GridAxisPainter.resolveYStep(vp, config.yUnitLength);
    const minorDiv: number = 5; // 主格细分 5 份
    const xMinor: number = xStep / minorDiv;
    const yMinor: number = yStep / minorDiv;

    const xMinorCount: number = (vp.xMax - vp.xMin) / xMinor;
    const yMinorCount: number = (vp.yMax - vp.yMin) / yMinor;

    // 次网格
    if (xMinorCount <= 300 || yMinorCount <= 300) {
      ctx.strokeStyle = GridAxisPainter.gridMinorColor(isDark);
      ctx.lineWidth = 1;
      ctx.beginPath();
      if (xMinorCount <= 300) {
        const xt: number[] = GraphMath.ticks(vp.xMin, vp.xMax, xMinor);
        for (let i = 0; i < xt.length; i++) {
          const sx: number = Math.round(GraphMath.worldToScreenX(xt[i], vp, w)) + 0.5;
          ctx.moveTo(sx, 0);
          ctx.lineTo(sx, h);
        }
      }
      if (yMinorCount <= 300) {
        const yt: number[] = GraphMath.ticks(vp.yMin, vp.yMax, yMinor);
        for (let i = 0; i < yt.length; i++) {
          const sy: number = Math.round(GraphMath.worldToScreenY(yt[i], vp, h)) + 0.5;
          ctx.moveTo(0, sy);
          ctx.lineTo(w, sy);
        }
      }
      ctx.stroke();
    }

    // 主网格
    ctx.strokeStyle = GridAxisPainter.gridMajorColor(isDark);
    ctx.lineWidth = 1;
    ctx.beginPath();
    const xm: number[] = GraphMath.ticks(vp.xMin, vp.xMax, xStep);
    for (let i = 0; i < xm.length; i++) {
      const sx: number = Math.round(GraphMath.worldToScreenX(xm[i], vp, w)) + 0.5;
      ctx.moveTo(sx, 0);
      ctx.lineTo(sx, h);
    }
    const ym: number[] = GraphMath.ticks(vp.yMin, vp.yMax, yStep);
    for (let i = 0; i < ym.length; i++) {
      const sy: number = Math.round(GraphMath.worldToScreenY(ym[i], vp, h)) + 0.5;
      ctx.moveTo(0, sy);
      ctx.lineTo(w, sy);
    }
    ctx.stroke();
  }

  /** 坐标轴（X / Y），原点在可见域时绘制 */
  static drawAxes(ctx: CanvasRenderingContext2D, vp: Viewport, w: number, h: number,
    config: GridAxisConfig): void {
    const ox: number = Math.round(GraphMath.worldToScreenX(0, vp, w)) + 0.5;
    const oy: number = Math.round(GraphMath.worldToScreenY(0, vp, h)) + 0.5;
    ctx.strokeStyle = GridAxisPainter.axisColor(config.isDark);
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    if (0 >= vp.yMin && 0 <= vp.yMax) {
      ctx.moveTo(0, oy);
      ctx.lineTo(w, oy);
    }
    if (0 >= vp.xMin && 0 <= vp.xMax) {
      ctx.moveTo(ox, 0);
      ctx.lineTo(ox, h);
    }
    ctx.stroke();
  }

  /** 刻度标签（四边智能吸附：标签始终完整显示在屏幕内） */
  static drawLabels(ctx: CanvasRenderingContext2D, vp: Viewport, w: number, h: number,
    config: GridAxisConfig): void {
    const xStep: number = GridAxisPainter.resolveXStep(vp, config.xUnitLength);
    const yStep: number = GridAxisPainter.resolveYStep(vp, config.yUnitLength);
    const xAxisVisible: boolean = (0 >= vp.yMin && 0 <= vp.yMax);
    const yAxisVisible: boolean = (0 >= vp.xMin && 0 <= vp.xMax);
    const labelPad: number = 4; // 标签距屏幕边缘最小间距

    ctx.fillStyle = GridAxisPainter.labelColor(config.isDark);
    ctx.font = '11vp sans-serif';

    // ── X 轴刻度（水平方向：左右边界钳制；垂直方向：始终在轴线下方 + 逐标签吸附到可见区域） ──
    const xm: number[] = GraphMath.ticks(vp.xMin, vp.xMax, xStep);
    // 轴线屏幕 Y 坐标
    const axisScreenY: number = xAxisVisible ? GraphMath.worldToScreenY(0, vp, h) : -1;
    // Canvas 高度为 110%，上下各约 5% 延伸到屏幕外
    const visibleBottom: number = h * 10 / 11;
    const visibleTop: number = h / 22; // 顶部约 1/22 延伸到屏幕外
    for (let i = 0; i < xm.length; i++) {
      const tx: number = xm[i];
      if (Math.abs(tx) < xStep * 1e-9) {
        continue; // 跳过 0（原点单独标）
      }
      const sx: number = GraphMath.worldToScreenX(tx, vp, w);
      const labelText: string = GridAxisPainter.fmtXLabel(tx, config.xUnitLength);
      const tw: number = ctx.measureText(labelText).width;
      // 水平吸附：标签完整保持在屏幕内
      let drawX: number = sx;
      if (sx - tw / 2 < labelPad) {
        ctx.textAlign = 'left';
        drawX = labelPad;
      } else if (sx + tw / 2 > w - labelPad) {
        ctx.textAlign = 'right';
        drawX = w - labelPad;
      } else {
        ctx.textAlign = 'center';
        drawX = sx;
      }
      // 垂直吸附：始终在轴线下方，逐标签钳制到可见区域
      if (!xAxisVisible) {
        // 轴线不在屏幕内→吸附到对应边缘
        if (vp.yMax < 0) {
          ctx.textBaseline = 'top';
          ctx.fillText(labelText, drawX, visibleTop + labelPad);
        } else {
          ctx.textBaseline = 'bottom';
          ctx.fillText(labelText, drawX, visibleBottom - labelPad);
        }
      } else {
        // 轴线在屏幕内：标签在轴线下方 2px，top 基线（文字向下延伸）
        let drawY: number = axisScreenY + 2;
        ctx.textBaseline = 'top';
        // 底部钳制：标签底部不超过可见区域，切换 bottom 基线贴边
        if (drawY + 8 > visibleBottom) {
          drawY = visibleBottom - labelPad;
          ctx.textBaseline = 'bottom';
        }
        // 顶部钳制：标签顶部超出可见区域，翻转到轴线上方
        if (drawY < visibleTop + labelPad) {
          drawY = axisScreenY - 2;
          ctx.textBaseline = 'bottom';
          if (drawY - 14 < visibleTop + labelPad) {
            drawY = visibleTop + labelPad + 14;
            ctx.textBaseline = 'top';
          }
        }
        ctx.fillText(labelText, drawX, drawY);
      }
    }

    // ── Y 轴刻度（垂直方向：上下边界钳制；水平方向：跟随轴线或吸附左/右边缘） ──
    const ym: number[] = GraphMath.ticks(vp.yMin, vp.yMax, yStep);
    // 轴线屏幕位置
    const axisScreenX: number = yAxisVisible ? GraphMath.worldToScreenX(0, vp, w) : -1;
    // 判断轴线是否靠近左/右边缘（留出约 40vp 给标签宽度）
    const labelMargin: number = 40; // 预留标签宽度
    const nearLeft: boolean = yAxisVisible && axisScreenX < labelMargin;
    const nearRight: boolean = yAxisVisible && axisScreenX > w - labelMargin;
    for (let i = 0; i < ym.length; i++) {
      const ty: number = ym[i];
      if (Math.abs(ty) < yStep * 1e-9) {
        continue;
      }
      const sy: number = GraphMath.worldToScreenY(ty, vp, h);
      const labelText: string = GridAxisPainter.fmtYLabel(ty, config.yUnitLength);
      // 垂直吸附：标签完整保持在屏幕内
      let drawY: number = sy;
      if (sy < labelPad + 6) {
        drawY = labelPad + 6;
      } else if (sy > h - labelPad - 6) {
        drawY = h - labelPad - 6;
      }
      // 水平对齐：根据轴线位置智能吸附
      if (nearLeft) {
        // 轴线在左边缘→标签放到轴线右侧，左对齐，确保完整显示
        ctx.textAlign = 'left';
        ctx.fillText(labelText, axisScreenX + 6, drawY);
      } else if (nearRight) {
        // 轴线在右边缘→标签放到轴线左侧，右对齐
        ctx.textAlign = 'right';
        ctx.fillText(labelText, axisScreenX - 6, drawY);
      } else if (yAxisVisible) {
        // 轴线在中间→标签在轴线左侧，右对齐
        ctx.textAlign = 'right';
        ctx.fillText(labelText, axisScreenX - 6, drawY);
      } else {
        // 轴线不在屏幕内→吸附到对应边缘
        if (vp.xMax < 0) {
          // 全负区域→轴线在右侧→吸附右边缘
          ctx.textAlign = 'right';
          ctx.fillText(labelText, w - labelPad, drawY);
        } else {
          // 全正区域→轴线在左侧→吸附左边缘
          ctx.textAlign = 'left';
          ctx.fillText(labelText, labelPad, drawY);
        }
      }
    }

    // ── 原点 0（跟随轴线交点，四边吸附确保可见） ──
    if (xAxisVisible && yAxisVisible) {
      const ox: number = GraphMath.worldToScreenX(0, vp, w);
      const oy: number = GraphMath.worldToScreenY(0, vp, h);
      const originText: string = '0';
      const ow: number = ctx.measureText(originText).width;
      let originX: number = ox - 6;
      let originY: number = oy + 6;
      // 左侧吸附：确保文字完整在屏幕内
      if (originX - ow < labelPad) {
        originX = labelPad;
        ctx.textAlign = 'left';
      } else if (originX + ow > w - labelPad) {
        // 右侧吸附
        originX = w - labelPad;
        ctx.textAlign = 'right';
      } else {
        ctx.textAlign = 'right';
      }
      // 底部吸附
      if (originY + 14 > h - labelPad) {
        originY = h - labelPad;
        ctx.textBaseline = 'bottom';
      } else if (originY < labelPad) {
        // 顶部吸附
        originY = labelPad;
        ctx.textBaseline = 'top';
      } else {
        ctx.textBaseline = 'top';
      }
      ctx.fillText(originText, originX, originY);
    }
  }

  /** 原点标记点 */
  static drawOrigin(ctx: CanvasRenderingContext2D, vp: Viewport, w: number, h: number,
    config: GridAxisConfig): void {
    if (0 >= vp.xMin && 0 <= vp.xMax && 0 >= vp.yMin && 0 <= vp.yMax) {
      const ox: number = GraphMath.worldToScreenX(0, vp, w);
      const oy: number = GraphMath.worldToScreenY(0, vp, h);
      ctx.fillStyle = GridAxisPainter.zeroDotColor(config.isDark);
      ctx.beginPath();
      ctx.arc(ox, oy, 3, 0, Math.PI * 2);
      ctx.fill();
    }
  }

  // ── 数值格式化 ──

  /** 刻度数值格式化（去尾零） */
  static fmt(v: number): string {
    if (Math.abs(v) < 1e-12) {
      return '0';
    }
    let s: string = v.toFixed(4);
    s = s.replace(/\.?0+$/, '');
    if (s === '-0') {
      return '0';
    }
    return s;
  }

  /** 智能格式化：π/12 整数倍的干净有理倍时用 π 形式，否则回退小数 */
  static fmtSmart(v: number): string {
    if (Math.abs(v) < 1e-12) {
      return '0';
    }
    const ratio: number = v / Math.PI;
    const qs: number[] = [1, 2, 3, 4, 6, 12];
    for (let i = 0; i < qs.length; i++) {
      const q: number = qs[i];
      const p: number = Math.round(ratio * q);
      if (Math.abs(ratio - p / q) < 1e-6) {
        return GridAxisPainter.fmtPiFrac(p, q);
      }
    }
    return GridAxisPainter.fmt(v);
  }

  /** 单位长度数值 → 显示文本（π / π/2 / 数字） */
  static fmtUnit(v: number): string {
    if (Math.abs(v - Math.PI) < 1e-6) {
      return 'π';
    }
    if (Math.abs(v - Math.PI / 2) < 1e-6) {
      return 'π/2';
    }
    return GridAxisPainter.fmt(v);
  }

  /** 最大公约数（用于 π 分数化简） */
  static gcd(a: number, b: number): number {
    a = Math.abs(a);
    b = Math.abs(b);
    while (b > 0) {
      const t: number = b;
      b = a % b;
      a = t;
    }
    return a === 0 ? 1 : a;
  }

  /** 把数值格式化为 π 的有理倍数形式（如 π/2、3π/2）；无法识别时回退小数·π */
  static fmtPi(v: number): string {
    const ratio: number = v / Math.PI;
    if (Math.abs(ratio) < 1e-9) {
      return '0';
    }
    const qs: number[] = [1, 2, 3, 4, 6, 12];
    for (let i = 0; i < qs.length; i++) {
      const q: number = qs[i];
      const p: number = Math.round(ratio * q);
      if (Math.abs(ratio - p / q) < 1e-6) {
        return GridAxisPainter.fmtPiFrac(p, q);
      }
    }
    return GridAxisPainter.fmt(ratio) + 'π';
  }

  /** π 的分数倍 pπ/q 的显示文本（自动约分，如 p=1,q=2 → π/2；p=2,q=1 → 2π） */
  static fmtPiFrac(p: number, q: number): string {
    if (p === 0) {
      return '0';
    }
    const g: number = GridAxisPainter.gcd(Math.abs(p), q);
    const pp: number = p / g;
    const qq: number = q / g;
    const sign: string = pp < 0 ? '−' : '';
    const ap: number = Math.abs(pp);
    const num: string = ap === 1 ? 'π' : ap.toString() + 'π';
    if (qq === 1) {
      return sign + num;
    }
    return sign + num + '/' + qq;
  }

  /** 单位长度是否为 π 系（π 的简单有理数倍，分母 ∈ {1,2,3,4,6}）→ 轴标签符号化 */
  static isPiUnit(u: number): boolean {
    if (u <= 0) {
      return false;
    }
    const r: number = u / Math.PI;
    const dens: number[] = [1, 2, 3, 4, 6];
    for (let i = 0; i < dens.length; i++) {
      const d: number = dens[i];
      const n: number = Math.round(r * d);
      if (n !== 0 && Math.abs(r - n / d) < 1e-6) {
        return true;
      }
    }
    return false;
  }

  /** X 轴刻度标签：π 系单位则符号化，否则数字 */
  static fmtXLabel(v: number, xUnitLength: number): string {
    return GridAxisPainter.isPiUnit(xUnitLength) ? GridAxisPainter.fmtPi(v) : GridAxisPainter.fmt(v);
  }

  /** Y 轴刻度标签：π 系单位则符号化，否则数字 */
  static fmtYLabel(v: number, yUnitLength: number): string {
    return GridAxisPainter.isPiUnit(yUnitLength) ? GridAxisPainter.fmtPi(v) : GridAxisPainter.fmt(v);
  }

  /**
   * 解析单位长度输入文本 → 世界单位数值（<=0 或非法 = 自动）。
   * 支持：纯数字（如 2、0.5）、π 表达式（π、pi、2π、π/2、3π/2、pi/2 等）。
   */
  static parseUnit(s: string): number {
    const t: string = s.trim().toLowerCase().split('pi').join('π');
    if (t.length === 0) {
      return 0;
    }
    if (t.indexOf('π') >= 0) {
      const idx: number = t.indexOf('π');
      const coefStr: string = t.substring(0, idx).trim();
      const tail: string = t.substring(idx + 1).trim();
      let coef: number = 1;
      if (coefStr.length > 0 && coefStr !== '+') {
        coef = coefStr === '-' ? -1 : Number.parseFloat(coefStr);
      }
      let den: number = 1;
      if (tail.length > 0 && tail.charAt(0) === '/') {
        den = Number.parseFloat(tail.substring(1));
      }
      if (!isFinite(coef) || !isFinite(den) || den === 0) {
        return 0;
      }
      const v: number = coef * Math.PI / den;
      return v > 0 ? v : 0;
    }
    const num: number = Number.parseFloat(t);
    return (isFinite(num) && num > 0) ? num : 0;
  }

  // ── 三角函数检测（π 系单位长度建议） ──

  /**
   * 表达式是否「调用」了给定函数名。
   * 判定：函数名后紧跟 '('（允许中间有空格），且函数名前不是字母
   * （避免 "asin" 被 "sin" 误命中）。
   * 用 RegExp 而非 \b 词边界：\b 会把数字也视为词内字符，
   * 导致 "2sin(x)" 这种写法漏判。
   */
  static exprHasFunc(expr: string, names: string[]): boolean {
    const s: string = expr.toLowerCase();
    const letterRe: RegExp = new RegExp('[a-z]');
    const callRe: RegExp = new RegExp('^\\s*\\(');
    for (let k = 0; k < names.length; k++) {
      const n: string = names[k];
      let idx: number = s.indexOf(n);
      while (idx >= 0) {
        const beforeOk: boolean = idx === 0 || !letterRe.test(s.charAt(idx - 1));
        const rest: string = s.substring(idx + n.length);
        const callOk: boolean = callRe.test(rest);
        if (beforeOk && callOk) {
          return true;
        }
        idx = s.indexOf(n, idx + 1);
      }
    }
    return false;
  }

  /** 函数列表是否含三角函数（sin/cos/tan）→ x 轴建议 π 系单位长度 */
  static hasTrig(functions: GraphFunction[]): boolean {
    return functions.some((f: GraphFunction): boolean =>
      f.enabled && GridAxisPainter.exprHasFunc(f.expr, ['sin', 'cos', 'tan']));
  }

  /** 函数列表是否含反三角函数（asin/acos/atan）→ y 轴建议 π 系单位长度 */
  static hasInvTrig(functions: GraphFunction[]): boolean {
    return functions.some((f: GraphFunction): boolean =>
      f.enabled && GridAxisPainter.exprHasFunc(f.expr, ['asin', 'acos', 'atan']));
  }
}
