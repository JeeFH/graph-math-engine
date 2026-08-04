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
// font/TeXMetrics.ets
// ReTeX 标准排版参数（源自 TeXFont.java / JLaTeXMath）
// 所有值以 em（相对字号）为单位，使用前需乘以 fontSize

/** 数学轴线距基线高度（em） */
export const AXIS_HEIGHT: number = 0.25;

/** 默认分数线/规则线厚度（em） */
export const DEFAULT_RULE_THICKNESS: number = 0.04;

// ── 分数（Fraction）偏移参数 ──
/** 显示样式分子上移量（em） */
export const NUM1: number = 0.676508;
/** 文本样式/有分数线时分子上移量（em） */
export const NUM2: number = 0.393732;
/** 文本样式/无分数线时分子上移量（em） */
export const NUM3: number = 0.443731;
/** 显示样式分母下移量（em） */
export const DENOM1: number = 0.685951;
/** 文本样式分母下移量（em） */
export const DENOM2: number = 0.344841;

// ── 上下标（Script）偏移参数 ──
/** 显示样式上标移位 SUP1（em） */
export const SUP1: number = 0.412892;
/** 文本样式/非压缩上标移位 SUP2（em） */
export const SUP2: number = 0.362892;
/** 压缩样式上标移位 SUP3（em） */
export const SUP3: number = 0.288889;
/** 上标drop：基线上方距基线的距离（em） */
export const SUP_DROP: number = 0.386108;
/** 下标drop：基线下方距基线的距离（em） */
export const SUB_DROP: number = 0.05;
/** 正常下标移位（em） */
export const SUB1: number = 0.15;
/** 与上标共存时下标移位（em） */
export const SUB2: number = 0.247217;

/** 字体 x-height 默认值（em），用于上标偏移校验 */
export const X_HEIGHT: number = 0.45;

/** 脚本间距（em），上下标与基数之间的水平空隙 */
export const SCRIPT_SPACE: number = 0.04;

/** 字体缩小因子 */
export const DISPLAY_FACTOR: number = 1.0;
export const TEXT_FACTOR: number = 1.0;
export const SCRIPT_FACTOR: number = 0.7;
export const SCRIPT_SCRIPT_FACTOR: number = 0.5;