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
// features/graph/src/main/ets/engine/BivariateEqRenderer.ets
/**
 * 二元方程渲染器（模式 D: F(x,y) = 0）
 *
 * 与隐函数渲染器（ImplicitRenderer）共用底层二维网格采样 + Marching Squares 等值线提取，
 * 仅在业务语义上区分：
 * - 隐函数：用户直接输入 F(x,y)，画 F(x,y)=0 等值线
 * - 二元方程：用户输入 L(x,y) = R(x,y)，标准化为 F(x,y) = L - R = 0
 *
 * 算法完全相同，因此直接继承 ImplicitRenderer，仅覆盖 mode 标识。
 */

import { RenderMode, RenderData } from './IRenderer';
import { ImplicitRenderer } from './ImplicitRenderer';
import { Viewport } from '../math/GraphMath';

export class BivariateEqRenderer extends ImplicitRenderer {
  /** 覆盖 mode 为 BIVARIATE_EQ */
  readonly mode: RenderMode = RenderMode.BIVARIATE_EQ;

  /**
   * 覆写 extractVisible：将 mode 标记为 BIVARIATE_EQ，
   * 其余逻辑与 ImplicitRenderer 完全一致。
   */
  extractVisible(vp: Viewport): RenderData {
    const base: RenderData = super.extractVisible(vp);
    return {
      mode: RenderMode.BIVARIATE_EQ,
      fnId: base.fnId,
      color: base.color,
      lineWidth: base.lineWidth,
      lineStyle: base.lineStyle,
      expr: base.expr,
      contourSegments: base.contourSegments,
      cacheValid: base.cacheValid
    };
  }
}
