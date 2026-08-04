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
// font/MathSpacing.ets
// ReTeX Glue spacing system

export const MATH_ORD = 0;
export const MATH_OP = 1;
export const MATH_BIN = 2;
export const MATH_REL = 3;
export const MATH_OPEN = 4;
export const MATH_CLOSE = 5;
export const MATH_PUNCT = 6;
export const MATH_INNER = 7;

const glues: number[] = new Array<number>(256);

function idx(l: number, r: number, k: number): number {
  return l | (r << 3) | (k << 6);
}

function setGl(l: number, r: number, k: number, v: number): void {
  glues[idx(l, r, k)] = v;
}

// Glue lookup table
setGl(0, 1, 0, 3); setGl(0, 1, 1, 3); setGl(0, 2, 0, 4); setGl(0, 2, 1, 4);
setGl(0, 3, 0, 5); setGl(0, 3, 1, 5); setGl(0, 7, 0, 3); setGl(0, 7, 1, 3);
setGl(1, 0, 0, 3); setGl(1, 0, 1, 3); setGl(1, 1, 0, 3); setGl(1, 1, 1, 3);
setGl(1, 3, 0, 5); setGl(1, 3, 1, 5); setGl(1, 7, 0, 3); setGl(1, 7, 1, 3);
setGl(2, 0, 0, 4); setGl(2, 0, 1, 4); setGl(2, 1, 0, 4); setGl(2, 1, 1, 4);
setGl(2, 4, 0, 4); setGl(2, 4, 1, 4); setGl(2, 7, 0, 4); setGl(2, 7, 1, 4);
setGl(3, 0, 0, 5); setGl(3, 0, 1, 5); setGl(3, 1, 0, 5); setGl(3, 1, 1, 5);
setGl(3, 4, 0, 5); setGl(3, 4, 1, 5); setGl(3, 7, 0, 5); setGl(3, 7, 1, 5);
setGl(5, 1, 0, 3); setGl(5, 1, 1, 3); setGl(5, 2, 0, 3); setGl(5, 2, 1, 3);
setGl(5, 3, 0, 5); setGl(5, 3, 1, 5); setGl(5, 7, 0, 3); setGl(5, 7, 1, 3);
setGl(6, 0, 0, 3); setGl(6, 0, 1, 3); setGl(6, 1, 0, 4); setGl(6, 1, 1, 4);
setGl(6, 3, 0, 5); setGl(6, 3, 1, 5); setGl(6, 4, 0, 3); setGl(6, 4, 1, 3);
setGl(6, 5, 0, 3); setGl(6, 5, 1, 3); setGl(6, 6, 0, 4); setGl(6, 6, 1, 4);
setGl(6, 7, 0, 5); setGl(6, 7, 1, 5);
setGl(7, 0, 0, 3); setGl(7, 0, 1, 3); setGl(7, 1, 0, 3); setGl(7, 1, 1, 3);
setGl(7, 2, 0, 4); setGl(7, 2, 1, 4); setGl(7, 3, 0, 5); setGl(7, 3, 1, 5);
setGl(7, 4, 0, 3); setGl(7, 4, 1, 3); setGl(7, 6, 0, 3); setGl(7, 6, 1, 3);
setGl(7, 7, 0, 3); setGl(7, 7, 1, 3);

/** Get glue width from math spacing table */
export function getGlueWidth(lType: number, rType: number, fontSize: number): number {
  const l: number = lType <= 7 ? lType : 0;
  const r: number = rType <= 7 ? rType : 0;
  if (l < 0 || l > 7 || r < 0 || r > 7) {
    return 0;
  }
  const val: number | undefined = glues[idx(l, r, 1)];
  if (val === undefined || val === null) {
    return 0;
  }
  return val * (fontSize / 18);
}

/** Classify character type for math spacing */
export function classifyCharType(text: string): number {
  if (text.length === 0) {
    return 0;
  }
  const ch: string = text[0];
  // digits
  if (ch >= '0' && ch <= '9') {
    return 0;
  }
  // letters
  if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')) {
    return 0;
  }
  // pi (π), tau (τ), e
  if ("\u03c0\u03c4e".indexOf(ch) >= 0) {
    return 0;
  }
  // binop: +  -  x  %  ÷  (division)
  if ("+-x%\u00f7\u00b7\u00d7".indexOf(ch) >= 0) {
    return 2;
  }
  // rel: =  <  >  ≠  ≤  ≥
  if ("=<>\u2260\u2264\u2265".indexOf(ch) >= 0) {
    return 3;
  }
  // open
  if ("([{".indexOf(ch) >= 0) {
    return 4;
  }
  // close
  if (")]}".indexOf(ch) >= 0) {
    return 5;
  }
  // punct
  if (",;".indexOf(ch) >= 0) {
    return 6;
  }
  return 0;
}