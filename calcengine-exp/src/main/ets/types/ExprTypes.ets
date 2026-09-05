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
// types/ExprTypes.ets
// ???????????????????
// ???VST ??? vst2/VstNodes ????????????

/** ?????? */
export class VstParseError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'VstParseError';
  }
}

/** ???? */
export interface ExprStyle {
  fontSize?: number;
  color?: string;
  fontFamily?: string;
  italicVariables?: boolean;
  debug?: boolean;
  debugMask?: DebugMask;
}

/** ?????? */
export interface DebugMask {
  glyph?: boolean;
  hbox?: boolean;
  paren?: boolean;
  abs?: boolean;
  frac?: boolean;
  sqrt?: boolean;
  power?: boolean;
}

/** ?????? */
export class ExprMetrics {
  width: number = 0;
  height: number = 0;
  baseline: number = 0;
  ascent: number = 0;
  descent: number = 0;
}

/** ?????? */
export function normalizeStyle(style?: ExprStyle): ExprStyle {
  const s: ExprStyle = {};
  s.fontSize = style && style.fontSize !== undefined ? style.fontSize : 18;
  s.color = style && style.color !== undefined ? style.color : '#000000';
  s.fontFamily = style && style.fontFamily !== undefined ? style.fontFamily : 'sans-serif';
  s.italicVariables = style && style.italicVariables !== undefined ? style.italicVariables : true;
  s.debug = style && style.debug !== undefined ? style.debug : false;
  s.debugMask = style && style.debugMask !== undefined ? style.debugMask : undefined;
  return s;
}
