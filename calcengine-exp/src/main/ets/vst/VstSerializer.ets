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
// vst/VstSerializer.ets
// 自研：VstRow → 线性求值串（供 FunctionEvaluator 求值，不做显示）。
// 序列化格式须与 core 求值器及 parseLinear 严格互逆。

import {
  VstNode, VstRow, VstNum, VstVar, VstConst, VstOp, VstPlaceholder,
  VstFrac, VstSqrt, VstRoot, VstPow, VstParen,
  VstFunc, VstCeil, VstFloor, VstPostfix, VstNeg, VstLog
} from './VstNodes';

/** 将 VstRow 序列化为线性求值字符串 */
export function serializeLinear(root: VstRow): string {
  return serializeRow(root);
}

function serializeRow(row: VstRow): string {
  const parts: string[] = [];
  for (const child of row.children) {
    parts.push(serializeNode(child));
  }
  // 相邻段之间按需插入 '*' 消歧，避免 core Tokenizer 的字母分支把
  // 「变量/常量 + 函数名/常量」合并成单一 token（如 "x"+"sin(x)"→"xsin"、
  // "x"+"e^x"→"xe"），导致 FunctionEvaluator 抛"未知标识符"而验证失败。
  let out: string = '';
  for (let i: number = 0; i < parts.length; i++) {
    if (i > 0 && needsMulSeparator(parts[i - 1], parts[i])) {
      out += '*';
    }
    out += parts[i];
  }
  return out;
}

/** 判断相邻两段序列化结果之间是否需插入 '*' 乘号消歧。
 *  仅当前段以 ASCII 字母结尾、且后段以 ASCII 字母或数字开头时插入：
 *    [x, sin(x)]→"x*sin(x)"、[x, e^x]→"x*e^x"、[x, 2]→"x*2"、[pi, x]→"pi*x"。
 *  数字结尾→字母开头（2x）、字母结尾→'('开头（x(x+1)）、')'结尾→任意（sin(x)y）
 *  等情形 Tokenizer本就能正确分词，不插入以保持串最简。
 *  插入的 '*' 在显示链路经 simplify 的 mergeProducts 移除，仍渲染为隐式乘法。 */
function needsMulSeparator(prev: string, next: string): boolean {
  if (prev.length === 0 || next.length === 0) {
    return false;
  }
  const pc: string = prev.charAt(prev.length - 1);
  const nc: string = next.charAt(0);
  return isAsciiLetter(pc) && (isAsciiLetter(nc) || isAsciiDigit(nc));
}

function isAsciiLetter(ch: string): boolean {
  return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z');
}

function isAsciiDigit(ch: string): boolean {
  return ch >= '0' && ch <= '9';
}

function serializeNode(node: VstNode): string {
  if (node instanceof VstNum) return node.text;
  if (node instanceof VstVar) return node.name;
  if (node instanceof VstConst) {
    if (node.sym === 'π') return 'pi';
    if (node.sym === 'τ') return 'tau';
    return node.sym;
  }
  if (node instanceof VstOp) {
    if (node.sym === '×') return '*';
    if (node.sym === '÷') return '/';
    // 乘号族统一归一为 '*'：序列化产物是交给下游词法/求值层的机器串，
    // 必须落在对方白名单内。历史上 '·' 直接透传，而 Tokenizer 的运算符
    // 白名单不含它，落入「忽略非法字符」分支被静默丢弃，使 `2·3x`
    // 被切成 [2,3,x] 并恒求值为 NaN（画布全空且零报错）。
    // 显示字形由 ExprRenderer.render 的 mulGlyph 参数在绘制期决定，故此处归一显示中性。
    if (node.sym === '·' || node.sym === '∙' || node.sym === '⋅' ||
      node.sym === '•' || node.sym === '∗') return '*';
    return node.sym;
  }
  if (node instanceof VstPlaceholder) return '?';

  if (node instanceof VstFrac) {
    const numStr: string = serializeRow(new VstRow(node.num));
    const denStr: string = serializeRow(new VstRow(node.den));
    const numW: string = needsFracParen(node.num) ? '(' + numStr + ')' : numStr;
    const denW: string = needsFracParen(node.den) ? '(' + denStr + ')' : denStr;
    return numW + '/' + denW;
  }
  if (node instanceof VstSqrt) {
    return 'sqrt(' + serializeRow(new VstRow(node.body)) + ')';
  }
  if (node instanceof VstRoot) {
    return 'root(' + serializeRow(new VstRow(node.index)) + ',' +
           serializeRow(new VstRow(node.body)) + ')';
  }
  if (node instanceof VstPow) {
    const baseStr: string = serializeRow(new VstRow(node.base));
    const expStr: string = serializeRow(new VstRow(node.exp));
    const baseWrapped: string = needsPowParen(node.base) ? '(' + baseStr + ')' : baseStr;
    const expWrapped: string = needsPowParen(node.exp) ? '(' + expStr + ')' : expStr;
    return baseWrapped + '^' + expWrapped;
  }
  if (node instanceof VstParen) {
    return '(' + serializeRow(new VstRow(node.body)) + ')';
  }
  if (node instanceof VstFunc) {
    return node.name + '(' + serializeRow(new VstRow(node.body)) + ')';
  }
  if (node instanceof VstCeil) {
    return 'ceil(' + serializeRow(new VstRow(node.body)) + ')';
  }
  if (node instanceof VstFloor) {
    return 'floor(' + serializeRow(new VstRow(node.body)) + ')';
  }
  if (node instanceof VstPostfix) {
    const inner: string = serializeRow(new VstRow(node.body));
    if (node.op === '!') {
      if (needsPostfixParen(node.body)) {
        return '(' + inner + ')!';
      }
      return inner + '!';
    }
    return '(' + inner + ')' + node.op;
  }
  if (node instanceof VstNeg) {
    const inner: string = serializeRow(new VstRow(node.body));
    if (needsNegParen(node.body)) {
      return '(-' + inner + ')';
    }
    return '-' + inner;
  }
  if (node instanceof VstLog) {
    const baseStr: string = serializeRow(new VstRow(node.logBase));
    const bodyStr: string = serializeRow(new VstRow(node.body));
    return 'log(' + baseStr + ',' + bodyStr + ')';
  }
  return '';
}

function isCompound(node: VstNode): boolean {
  return node instanceof VstFrac || node instanceof VstPow || node instanceof VstNeg;
}

function needsPowParen(children: VstNode[]): boolean {
  if (children.length === 0) return false;
  if (children.length > 1) return true;
  return children[0] instanceof VstFrac || children[0] instanceof VstPow ||
         children[0] instanceof VstNeg || children[0] instanceof VstParen;
}

function needsFracParen(children: VstNode[]): boolean {
  // 仅当分子/分母含运算符或复合结构时才加括号，避免最外层简单原子被多余括号包裹。
  // 例如 1/(1-1/(1-1/1)) 的分子 1 不需要括号，而分母 1-1/(1-1/1) 含运算符需要括号。
  if (children.length === 0) return false;
  if (children.length > 1) return true;
  const c: VstNode = children[0];
  return c instanceof VstOp || c instanceof VstFrac || c instanceof VstPow ||
         c instanceof VstNeg || c instanceof VstParen || c instanceof VstFunc ||
         c instanceof VstSqrt || c instanceof VstRoot || c instanceof VstLog;
}

function needsPostfixParen(children: VstNode[]): boolean {
  if (children.length === 0) return false;
  if (children.length > 1) return true;
  return isCompound(children[0]);
}

function needsNegParen(children: VstNode[]): boolean {
  if (children.length === 0) return false;
  if (children.length > 1) return true;
  return isCompound(children[0]);
}
