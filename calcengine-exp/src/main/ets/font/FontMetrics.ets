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
// font/FontMetrics.ets
// 字符宽度度量表（相对 em，乘以 fontSize 得像素宽）。
//
// 背景：上一版 GlyphBox 用静态离屏 CanvasRenderingContext2D.measureText 测宽，
// 在 ArkUI 中该 ctx 未绑定 Canvas 组件，measureText 返回 0，导致所有字形宽度
// 塌缩为 1px、字符全部重叠。这里改用"预置宽度表"，完全不依赖任何 Canvas 上下文，
// 布局阶段即可确定宽度，且与真实绘制表面解耦。
// 数据近似 HarmonyOS Sans / 无衬线体比例（参考 Arial 字形宽度）。

const ITALIC_WIDTH_FACTOR: number = 1.0;  // 斜体宽度近似；取 1.0 避免低估导致重叠

/** 基线 -> 顶部（覆盖上伸部 ascender）；收紧：0.78 → 0.74 */
export const GLYPH_ASCENT_RATIO: number = 0.74;
/** 基线 -> 底部（覆盖下伸部 descender）；收紧：0.24 → 0.22 */
export const GLYPH_DESCENT_RATIO: number = 0.22;

const GLYPH_WIDTHS: Record<string, number> = {
  // 数字（等宽）
  '0': 0.556, '1': 0.556, '2': 0.556, '3': 0.556, '4': 0.556,
  '5': 0.556, '6': 0.556, '7': 0.556, '8': 0.556, '9': 0.556,
  // 大写
  'A': 0.667, 'B': 0.667, 'C': 0.722, 'D': 0.722, 'E': 0.667, 'F': 0.611,
  'G': 0.778, 'H': 0.722, 'I': 0.278, 'J': 0.500, 'K': 0.667, 'L': 0.556,
  'M': 0.833, 'N': 0.722, 'O': 0.778, 'P': 0.667, 'Q': 0.778, 'R': 0.722,
  'S': 0.667, 'T': 0.611, 'U': 0.722, 'V': 0.667, 'W': 0.944, 'X': 0.667,
  'Y': 0.667, 'Z': 0.611,
  // 小写
  'a': 0.556, 'b': 0.556, 'c': 0.500, 'd': 0.556, 'e': 0.556, 'f': 0.278,
  'g': 0.556, 'h': 0.556, 'i': 0.222, 'j': 0.222, 'k': 0.500, 'l': 0.222,
  'm': 0.833, 'n': 0.556, 'o': 0.556, 'p': 0.556, 'q': 0.556, 'r': 0.333,
  's': 0.500, 't': 0.278, 'u': 0.556, 'v': 0.500, 'w': 0.722, 'x': 0.500,
  'y': 0.500, 'z': 0.500,
  // 标点 / 空白
  ' ': 0.278, '.': 0.278, ',': 0.278, ';': 0.278, ':': 0.278, '!': 0.333,
  '?': 0.556, '\'': 0.222, '"': 0.333, '`': 0.333, '_': 0.278,
  // 括号
  '(': 0.333, ')': 0.333, '[': 0.278, ']': 0.278, '{': 0.389, '}': 0.389,
  // 取整符号
  '⌈': 0.333, '⌉': 0.333, '⌊': 0.333, '⌋': 0.333,
  // 运算符
  '+': 0.584, '-': 0.333, '*': 0.422, '/': 0.278, '=': 0.584, '^': 0.422,
  '~': 0.556, '<': 0.584, '>': 0.584, '|': 0.220, '&': 0.722, '%': 0.833,
  '#': 0.556, '$': 0.556, '@': 0.944, '\\': 0.278,
  // 数学符号（常用）
  '×': 0.500, '÷': 0.583, 'π': 0.556, 'τ': 0.556, '√': 0.500,
  '≈': 0.584, '≠': 0.584, '≤': 0.584, '≥': 0.584, '±': 0.584, '·': 0.278,
  '∞': 0.722, '°': 0.333, '′': 0.222, '∂': 0.500, '∑': 0.722, '∫': 0.500,
  'α': 0.500, 'β': 0.500, 'γ': 0.500, 'δ': 0.500, 'θ': 0.500, 'λ': 0.222,
  'μ': 0.556, 'σ': 0.500, 'φ': 0.500, 'ω': 0.556, 'ε': 0.500, 'ρ': 0.500,
  'ν': 0.500, 'ξ': 0.500, 'ψ': 0.500, 'χ': 0.500, 'η': 0.500, 'κ': 0.500,
  'ζ': 0.500, 'υ': 0.500, 'Α': 0.667, 'Β': 0.667, 'Γ': 0.667, 'Δ': 0.722,
  'Θ': 0.722, 'Λ': 0.667, 'Ξ': 0.667, 'Π': 0.722, 'Σ': 0.722, 'Φ': 0.722,
  'Ψ': 0.722, 'Ω': 0.722
};

/** 测量文本宽度（像素）。多字符逐字累加；未知字符按 CJK 1.0em / 其余 0.5em 兜底。 */
export function measureTextWidth(text: string, fontSize: number, italic: boolean): number {
  if (!text || text.length === 0) return 0;
  let total: number = 0;
  for (let i: number = 0; i < text.length; i++) {
    const ch: string = text.charAt(i);
    const w: number = GLYPH_WIDTHS[ch];
    if (w === undefined) {
      total += (ch.charCodeAt(0) > 0x2000) ? 1.0 : 0.5;
    } else {
      total += w;
    }
  }
  if (italic) total *= ITALIC_WIDTH_FACTOR;
  return total * fontSize;
}

/** 字形上伸部高度（基线以上，像素）。 */
export function glyphAscent(fontSize: number): number {
  return fontSize * GLYPH_ASCENT_RATIO;
}

/** 字形下伸部深度（基线以下，像素）。 */
export function glyphDescent(fontSize: number): number {
  return fontSize * GLYPH_DESCENT_RATIO;
}

/**
 * 单字符"可见上伸比例"（相对 em）。按字形类别区分，使盒子紧贴可见字形，
 * 而非统一套用最大上伸部（0.74）把 x-height 小写字母的盒子撑高近一倍。
 * - 数字 / 大写 / 带升部小写(b,d,f,h,k,l,t) / 带点的 i,j / 取整符号：可见顶接近全高
 * - 其余（a,c,e,m,n,o,r,s,u,v,w,x,z、运算符、希腊小写等）：x-height 高度
 */
function charAscentRatio(ch: string): number {
  if (ch >= '0' && ch <= '9') return 0.72;
  if ((ch >= 'A' && ch <= 'Z') || (ch >= 'Α' && ch <= 'Ω')) return 0.72;
  if ('bdfhkltij⌈⌉⌊⌋'.indexOf(ch) >= 0) return 0.72;
  return 0.5;
}

/**
 * 单字符"可见下伸比例"（相对 em）。仅带降部小写(g,p,q,y)与 j 有下伸部。
 */
function charDescentRatio(ch: string): number {
  if ('gpqy'.indexOf(ch) >= 0) return 0.21;
  if (ch === 'j') return 0.21;
  return 0;
}

/** 按内容取字符集内最大可见上伸高度（像素），用于 GlyphBox 高度（紧贴字形）。 */
export function glyphContentAscent(text: string, fontSize: number): number {
  if (!text || text.length === 0) return 0;
  let max: number = 0;
  for (let i: number = 0; i < text.length; i++) {
    const r: number = charAscentRatio(text.charAt(i));
    if (r > max) max = r;
  }
  return max * fontSize;
}

/** 按内容取字符集内最大可见下伸深度（像素），用于 GlyphBox 深度（紧贴字形）。 */
export function glyphContentDescent(text: string, fontSize: number): number {
  if (!text || text.length === 0) return 0;
  let max: number = 0;
  for (let i: number = 0; i < text.length; i++) {
    const r: number = charDescentRatio(text.charAt(i));
    if (r > max) max = r;
  }
  return max * fontSize;
}
