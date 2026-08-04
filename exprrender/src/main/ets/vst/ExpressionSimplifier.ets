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
// vst/ExpressionSimplifier.ets
// 自研：完成态表达式化简器（美颜）。
// 对 VstRow 树做：
//  - block 内重排（数字前置、常量、其它）
//  - 隐式乘法处理：数字×数字必须保留 ·（如 9·6），其余省略为隐式（2x、xy）
//  - 同底数因子合并为幂（x·x·x -> x³，π·π -> π²）
//  - 函数体内乘法一律保留 ·
// 化简后的树序列化为 fn.expr 存储，不影响编辑态 MathField.root。

import {
  VstNode, VstRow, VstNum, VstVar, VstConst, VstOp, VstPlaceholder,
  VstFrac, VstSqrt, VstRoot, VstPow, VstParen,
  VstFunc, VstCeil, VstFloor, VstPostfix, VstNeg, VstLog
} from './VstNodes';

/** 对整棵 VstRow 做化简 */
export function simplify(root: VstRow): VstRow {
  const children: VstNode[] = simplifyRow(root.children, false);
  return new VstRow(children.length > 0 ? children : [new VstPlaceholder()]);
}

function simplifyRow(children: VstNode[], inFuncBody: boolean): VstNode[] {
  const flat: VstNode[] = [];
  for (const c of children) {
    flat.push(simplifyNode(c));
  }
  // 先 block 内重排（数字前置），再在同乘积项内合并同底数因子（点号重推导）。
  const rearranged: VstNode[] = rearrangeFactors(flat);
  return mergeProducts(rearranged, inFuncBody);
}

/** 解包节点数组最外层的 VstParen（如果整个数组就是一个 Paren 节点）。
 *  用于分数分子/分母：完成态不需要显示界定分母边界的括号。 */
function unwrapOuterParen(children: VstNode[]): VstNode[] {
  if (children.length === 1 && children[0] instanceof VstParen) {
    return (children[0] as VstParen).body;
  }
  return children;
}

function simplifyNode(node: VstNode): VstNode {
  if (node instanceof VstFrac) {
    const c: VstFrac = node.clone() as VstFrac;
    // 解包分子/分母最外层的 VstParen（避免完成态显示多余括号）
    c.num = unwrapOuterParen(simplifyRow(c.num, false));
    c.den = unwrapOuterParen(simplifyRow(c.den, false));
    return c;
  }
  if (node instanceof VstSqrt) {
    const c: VstSqrt = node.clone() as VstSqrt;
    c.body = simplifyRow(c.body, false);
    return c;
  }
  if (node instanceof VstRoot) {
    const c: VstRoot = node.clone() as VstRoot;
    c.index = simplifyRow(c.index, false);
    c.body = simplifyRow(c.body, false);
    return c;
  }
  if (node instanceof VstPow) {
    const c: VstPow = node.clone() as VstPow;
    c.base = simplifyRow(c.base, false);
    c.exp = simplifyRow(c.exp, false);
    return c;
  }
  if (node instanceof VstParen) {
    const c: VstParen = node.clone() as VstParen;
    c.body = simplifyRow(c.body, false);
    return c;
  }
  if (node instanceof VstFunc) {
    const c: VstFunc = node.clone() as VstFunc;
    c.body = simplifyRow(c.body, true);
    return c;
  }
  if (node instanceof VstCeil) {
    const c: VstCeil = node.clone() as VstCeil;
    c.body = simplifyRow(c.body, false);
    return c;
  }
  if (node instanceof VstFloor) {
    const c: VstFloor = node.clone() as VstFloor;
    c.body = simplifyRow(c.body, false);
    return c;
  }
  if (node instanceof VstNeg) {
    const c: VstNeg = node.clone() as VstNeg;
    c.body = simplifyRow(c.body, false);
    return c;
  }
  if (node instanceof VstPostfix) {
    const c: VstPostfix = node.clone() as VstPostfix;
    c.body = simplifyRow(c.body, false);
    return c;
  }
  if (node instanceof VstLog) {
    const c: VstLog = node.clone() as VstLog;
    c.logBase = simplifyRow(c.logBase, false);
    c.body = simplifyRow(c.body, true);
    return c;
  }
  return node;
}

/** 仅做 block 内重排：被任意 VstOp 分隔的连续因子聚成一个 block，按 数字/常量/其它 排序。
 *  乘法/加减符号原样保留，交给 mergeProducts 统一处理点号与合并。 */
function rearrangeFactors(children: VstNode[]): VstNode[] {
  const out: VstNode[] = [];
  let block: VstNode[] = [];
  const flushBlock = (): void => {
    if (block.length > 0) {
      const r: VstNode[] = reorderBlock(block);
      for (const n of r) out.push(n);
      block = [];
    }
  };
  for (const c of children) {
    if (c instanceof VstOp) {
      flushBlock();
      out.push(c);
    } else {
      block.push(c);
    }
  }
  flushBlock();
  return out;
}

function reorderBlock(block: VstNode[]): VstNode[] {
  if (block.length <= 1) return block;
  const nums: VstNode[] = [];
  const consts: VstNode[] = [];
  const others: VstNode[] = [];
  for (const n of block) {
    if (n instanceof VstNum) {
      nums.push(n);
    } else if (n instanceof VstConst) {
      consts.push(n);
    } else {
      others.push(n);
    }
  }
  return [...nums, ...consts, ...others];
}

// ── 同底数因子合并为幂 ──

function isNumLiteral(n: VstNode): boolean {
  return n instanceof VstNum;
}

/** 乘法分隔符（任意形式：* / × / ·） */
function isMultOp(n: VstNode): boolean {
  return n instanceof VstOp && (n.sym === '*' || n.sym === '×' || n.sym === '·');
}

/** 是否应显示点号：函数体内一律 ·；否则仅当左右都是数字字面量（如 9·6） */
function shouldShowDot(prev: VstNode, cur: VstNode, inFuncBody: boolean): boolean {
  if (inFuncBody) return true;
  return isNumLiteral(prev) && isNumLiteral(cur);
}

/** 在同乘积项内合并同底数因子（变量/常量）为幂；非可合并因子原样保留。
 *  数字不参与合并（保持 9·6 等显式点乘）。点号由 shouldShowDot 重新推导。 */
function mergeProducts(children: VstNode[], inFuncBody: boolean): VstNode[] {
  const out: VstNode[] = [];
  let product: VstNode[] = [];
  const flush = (): void => {
    if (product.length > 0) {
      const merged: VstNode[] = mergeRun(product);
      for (let k: number = 0; k < merged.length; k++) {
        if (k > 0 && shouldShowDot(merged[k - 1], merged[k], inFuncBody)) {
          out.push(new VstOp('·'));
        }
        out.push(merged[k]);
      }
      product = [];
    }
  };
  for (const c of children) {
    if (c instanceof VstOp && (c.sym === '+' || c.sym === '-')) {
      flush();
      out.push(c);
    } else if (isMultOp(c)) {
      // 乘法分隔符：忽略（因子已收集），点号由 shouldShowDot 重新推导
    } else {
      product.push(c);
    }
  }
  flush();
  return out;
}

/** 合并同一乘积项内相邻同底数因子为幂；返回合并后的因子序列 */
function mergeRun(factors: VstNode[]): VstNode[] {
  const result: VstNode[] = [];
  let i: number = 0;
  while (i < factors.length) {
    const f: VstNode = factors[i];
    const info: [string, number] | null = mergeInfo(f);
    if (info === null) {
      result.push(f);
      i++;
      continue;
    }
    const key: string = info[0];
    let totalExp: number = info[1];
    let j: number = i + 1;
    while (j < factors.length) {
      const g: VstNode = factors[j];
      const gi: [string, number] | null = mergeInfo(g);
      if (gi !== null && gi[0] === key) {
        totalExp += gi[1];
        j++;
      } else {
        break;
      }
    }
    if (j > i + 1 || totalExp > 1) {
      const baseSingle: VstNode = (f instanceof VstPow) ? f.base[0] : f;
      result.push(new VstPow([baseSingle.clone()], [new VstNum(String(totalExp))]));
    } else {
      result.push(f);
    }
    i = j;
  }
  return result;
}

/** 取可合并因子的合并键与指数（变量/常量及其整数次幂）；不可合并返回 null */
function mergeInfo(n: VstNode): [string, number] | null {
  if (n instanceof VstVar) {
    return ['v:' + n.name, 1];
  }
  if (n instanceof VstConst) {
    return ['c:' + n.sym, 1];
  }
  if (n instanceof VstPow && n.base.length === 1) {
    const b: VstNode = n.base[0];
    const e: number | null = numericExp(n.exp);
    if (e === null) return null;
    if (b instanceof VstVar) return ['v:' + b.name, e];
    if (b instanceof VstConst) return ['c:' + b.sym, e];
  }
  return null;
}

/** 取幂的指数数值；非单数字面量返回 null */
function numericExp(exp: VstNode[]): number | null {
  if (exp.length === 1 && exp[0] instanceof VstNum) {
    const v: number = Number((exp[0] as VstNum).text);
    return Number.isFinite(v) ? v : null;
  }
  return null;
}
