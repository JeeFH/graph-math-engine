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
 * ModeTag - 渲染模式胶囊标签（graph-ui 自包含实现）
 *
 * 根据图形渲染模式枚举值显示对应的胶囊标签（颜色 + 文字），
 * 用于 GraphDisplayArea 函数行标识当前表达式的渲染模式。
 */

/** 模式标签颜色配置 */
export interface ModeTagStyle {
  bg: string;
  text: string;
}

/**
 * 各模式的标签配色与文案（下标对齐 graph 模块 RenderMode 枚举值：
 * EXPLICIT=0 / IMPLICIT=1 / INEQUALITY=2 / BIVARIATE_EQ=3）
 */
export const MODE_STYLES: ModeTagStyle[] = [
  { bg: '#185FA5', text: 'y=f(x)' },      // EXPLICIT = 0
  { bg: '#2E7D32', text: 'F(x,y)=0' },    // IMPLICIT = 1
  { bg: '#ED6C02', text: '不等式' },        // INEQUALITY = 2
  { bg: '#6A1B9A', text: '方程' },          // BIVARIATE_EQ = 3
];

/** 暗色模式下颜色提亮 */
export const MODE_STYLES_DARK: ModeTagStyle[] = [
  { bg: '#42A5F5', text: 'y=f(x)' },
  { bg: '#66BB6A', text: 'F(x,y)=0' },
  { bg: '#FFA726', text: '不等式' },
  { bg: '#AB47BC', text: '方程' },
];

/** 空表达式（占位态） */
const EMPTY_STYLE: ModeTagStyle = { bg: '#9E9E9E', text: '输入表达式' };
const EMPTY_STYLE_DARK: ModeTagStyle = { bg: '#757575', text: '输入表达式' };

@Component
export struct ModeTag {
  /** 渲染模式（graph RenderMode 枚举值），-1 表示空表达式 */
  @Prop mode: number = -1;
  /** 暗色模式 */
  @Prop isDark: boolean = false;

  private getStyle(): ModeTagStyle {
    if (this.mode < 0 || this.mode >= MODE_STYLES.length) {
      return this.isDark ? EMPTY_STYLE_DARK : EMPTY_STYLE;
    }
    return this.isDark ? MODE_STYLES_DARK[this.mode] : MODE_STYLES[this.mode];
  }

  build() {
    Text(this.getStyle().text)
      .fontSize($r('app.float.font_overline'))
      .fontColor('#FFFFFF')
      .backgroundColor(this.getStyle().bg)
      .borderRadius($r('app.float.radius_sm'))
      .height(20)
      .padding({ left: 6, right: 6 })
      .textAlign(TextAlign.Center)
      .maxLines(1)
  }
}
