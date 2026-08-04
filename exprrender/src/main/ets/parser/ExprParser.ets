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
// parser/ExprParser.ets
// 自研：线性求值串 -> VstRow（serializeLinear 的逆操作）。
// 用于从持久化的 graphFunctions.expr（求值串）加载回编辑器树。
// 与 Node 黑盒 parse_linear_test.mjs 逐字对齐（54 case 往返幂等验证通过）。
//
// 容错增强（2026-07-24）：归一化键盘常见的"显示格式"字符（×÷−·、上标 unicode、√），
// 并支持 ⌈⌋ 取整符号；空串或解析失败时返回空行（不再回退成单个占位符），
// 避免整条完成态表达式塌陷成"只剩虚线方块"。

import {
  VstNode, VstRow, VstNum, VstVar, VstConst, VstOp, VstPlaceholder,
  VstFrac, VstSqrt, VstRoot, VstPow, VstParen,
  VstFunc, VstCeil, VstFloor, VstPostfix, VstNeg, VstLog
} from '../vst/VstNodes';

/** 已知函数名（含序列化名 asin/acos/atan/log10 等）。
 *  以数组形式供「最长前缀贪心匹配」遍历：解析标识符时优先匹配最长函数名前缀，
 *  使 "sinx" 拆为 sin(x)、"xsinx" 拆为 x·sin(x)，而非逐字符消费成 s·i·n·x。 */
const FUNC_NAME_LIST: string[] = [
  'sinh', 'cosh', 'tanh', 'asin', 'acos', 'atan',
  'log10', 'log2', 'sin', 'cos', 'tan', 'csc', 'sec', 'cot',
  'sqrt', 'root', 'abs', 'floor', 'ceil', 'ln', 'log'
];

/** 常量名列表（供最长前缀匹配：tau/pi/e） */
const CONST_NAME_LIST: string[] = ['tau', 'pi', 'e'];

/** 常量名映射（序列化串 -> 内部符号）*/
const CONSTS: Record<string, string> = { 'e': 'e', 'pi': 'π', 'tau': 'τ' };

/** 显示格式字符 -> 规范求值字符的归一化表 */
const CHAR_MAP: Record<string, string> = {
  '×': '*', '÷': '/', '−': '-', '·': '*', '∗': '*',
  '，': ',',
  '²': '^2', '³': '^3', '⁰': '^0', '¹': '^1', '⁴': '^4',
  '⁵': '^5', '⁶': '^6', '⁷': '^7', '⁸': '^8', '⁹': '^9',
  'ⁿ': '^n', '√': 'sqrt',
  // 上标字母（修饰字母/语音扩展上标）-> '^字母'：
  // 修复 "x²·eˣ" 类复合表达式——ˣ（U+02E3）等上标字母此前未收录，
  // normalizeExpr 无法转换，parsePrimary 遇未知字符报错，parseLinear 返回空行，
  // 导致 ExprView 回退为红色原始文本。与既有 'ⁿ'->'^n' 同一归一化策略。
  'ˣ': '^x', 'ʸ': '^y', 'ᵗ': '^t', 'ᵃ': '^a', 'ᵇ': '^b', 'ᵉ': '^e',
  'ᵐ': '^m', 'ᵏ': '^k', 'ˡ': '^l', 'ˢ': '^s', 'ʰ': '^h', 'ⁱ': '^i',
  'ᵒ': '^o', 'ᵖ': '^p', 'ʳ': '^r', 'ᵘ': '^u', 'ᵛ': '^v', 'ʷ': '^w',
  'ᶻ': '^z', 'ᵈ': '^d', 'ᵍ': '^g', 'ʲ': '^j', 'ᶠ': '^f', 'ᶜ': '^c'
};

/** 把键盘/显示格式的求值串归一化为解析器可识别的规范形式 */
function normalizeExpr(s: string): string {
  if (!s || s.length === 0) return '';
  let out: string = '';
  for (let i: number = 0; i < s.length; i++) {
    const ch: string = s.charAt(i);
    const m: string | undefined = CHAR_MAP[ch];
    out += (m !== undefined) ? m : ch;
  }
  return out;
}

class Parser {
  private s: string = '';
  private i: number = 0;
  err: boolean = false;

  constructor(s: string) {
    this.s = s;
    this.i = 0;
    this.err = false;
  }

  private peek(): string {
    return this.i < this.s.length ? this.s.charAt(this.i) : '';
  }

  private next(): string {
    const ch: string = this.s.charAt(this.i);
    this.i++;
    return ch;
  }

  private skipWs(): void {
    while (this.i < this.s.length && (this.s.charAt(this.i) === ' ' || this.s.charAt(this.i) === '\t' || this.s.charAt(this.i) === '\n')) {
      this.i++;
    }
  }

  eof(): boolean {
    return this.i >= this.s.length;
  }

  private isDigit(ch: string): boolean {
    return (ch >= '0' && ch <= '9') || ch === '.';
  }

  private isAlpha(ch: string): boolean {
    return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z');
  }

  /** 判定是否为关系运算符起始字符 */
  private isRelational(c: string): boolean {
    return c === '=' || c === '>' || c === '<' || c === '≥' || c === '≤';
  }

  /** 试探并消费一个关系运算符（可能为多字符如 >= <=），返回其符号 */
  private consumeRelOp(): string {
    const c: string = this.peek();
    if (c === '≥' || c === '≤') {
      this.next();
      return c;
    }
    if (c === '>' || c === '<') {
      this.next();
      if (this.peek() === '=') {
        this.next();
        return c === '>' ? '≥' : '≤';
      }
      return c;
    }
    if (c === '=') {
      this.next();
      return '=';
    }
    return '';
  }

  /** 顶层：扁平行（运算符 + - * 作为行内原子；行首 - 为一元负号）。
   *  - 除法 '/' 渲染为分数 VstFrac（分子=紧邻左侧的操作数，分母=下一个因子），
   *    这样 (x/2)、(1/x^2)、(1/e) 等都显示为分数而非斜杠。
   *  - 相邻因子（无运算符）视为隐式乘法，直接并列（如 2x、πx、2(x+1)）。
   *  - 序列化的括号/结构已编码结合性，故无需优先级。
   */
  parseExpr(): VstRow | null {
    this.skipWs();
    const children: VstNode[] = [];
    const first: VstNode | null = this.parseAdditive();
    if (first == null || this.err) return null;
    children.push(first);
    this.skipWs();
    while (!this.eof()) {
      const c: string = this.peek();
      if (c === '+' || c === '-') {
        this.next();
        children.push(new VstOp(c));
        this.skipWs();
        if (this.eof()) { break; }  // 宽容处理：尾部运算符保留为 VstOp
        const rhs: VstNode | null = this.parseAdditive();
        if (rhs == null || this.err) return null;
        children.push(rhs);
      } else if (c === '*') {
        this.next();
        children.push(new VstOp('*'));
        this.skipWs();
        if (this.eof()) { break; }  // 宽容处理：尾部运算符保留为 VstOp
        const rhs: VstNode | null = this.parseAdditive();
        if (rhs == null || this.err) return null;
        children.push(rhs);
      } else if (c === '/') {
        // 除法 -> 分数：分子为紧邻左侧的操作数，分母为下一个完整加法表达式
        // （而非单个 factor），这样分母中的 - + * 等运算符不会被截断，
        // 无需序列化器额外加括号来界定分母边界。
        this.next();
        this.skipWs();
        if (children.length === 0) { this.err = true; return null; }
        // 宽容处理：尾部 '/' 无法构成分数，保留为运算符
        if (this.eof()) {
          children.push(new VstOp('/'));
          break;
        }
        const numNode: VstNode = children.pop() as VstNode;
        const den: VstNode | null = this.parseAdditive();
        if (den == null || this.err) return null;
        children.push(new VstFrac([numNode], [den]));
      } else if (this.isRelational(c)) {
        // 关系运算符：= > < ≥ ≤（与加减乘同级放入行内）
        const relSym: string = this.consumeRelOp();
        children.push(new VstOp(relSym));
        this.skipWs();
        if (this.eof()) { break; }  // 宽容处理：尾部关系运算符保留为 VstOp
        const rhs: VstNode | null = this.parseAdditive();
        if (rhs == null || this.err) return null;
        children.push(rhs);
      } else if (this.canStartFactor(c) && children.length > 0) {
        // 隐式乘法：相邻因子直接并列（无运算符符号）。
        // 但若左、右两侧都是数字字面量（如 "9 6"），省略乘号会被误读为 "96"，
        // 必须显式插入乘号（渲染为 ·）。其余情形（2x、xy、2(x+1) 等）保持隐式。
        const rhs: VstNode | null = this.parseFactor();
        if (rhs == null || this.err) return null;
        const last: VstNode = children[children.length - 1];
        if (last instanceof VstNum && rhs instanceof VstNum) {
          children.push(new VstOp('*'));
        }
        children.push(rhs);
      } else {
        break;
      }
    }
    return new VstRow(children);
  }

  /** 字符是否可作为一个新因子的起始（用于隐式乘法判定） */
  private canStartFactor(c: string): boolean {
    return this.isDigit(c) || this.isAlpha(c) || c === '(' ||
           c === '⌈' || c === '⌊' || c === 'π' || c === 'τ' || c === '?';
  }

  private parseAdditive(): VstNode | null {
    this.skipWs();
    let prefixNeg: boolean = false;
    if (this.peek() === '-') {
      this.next();
      prefixNeg = true;
    }
    const node: VstNode | null = this.parseFactor();
    if (node == null || this.err) return null;
    if (prefixNeg) return new VstNeg([node]);
    return node;
  }

  private parseFactor(): VstNode | null {
    this.skipWs();
    let node: VstNode | null = this.parsePrimary();
    if (node == null || this.err) return null;
    // 幂：^ ( exp ) 或 ^单原子（对标 MathLive 的 x^2 无括号格式）。
    // 右结合（x^a^b = x^(a^b)）：先把连续 '^' 的指数收集成链，再从右向左折叠，
    // 这样既得到右结合结构，又不改变阶乘优先级（阶乘仍作用于整个幂塔）。
    this.skipWs();
    if (this.peek() === '^') {
      const exps: VstNode[][] = [];
      while (this.peek() === '^') {
        this.next();
        this.skipWs();
        let exp: VstNode[] | null;
        if (this.peek() === '(') {
          // 括号包裹的指数：^(exp)
          this.next();
          const expRow: VstRow | null = this.parseExpr();
          if (expRow == null || this.err) return null;
          this.skipWs();
          if (this.peek() !== ')') { this.err = true; return null; }
          this.next();
          exp = expRow.children;
        } else {
          // 无括号单原子指数：^digit 或 ^var
          const expNode: VstNode | null = this.parsePrimary();
          if (expNode == null || this.err) return null;
          exp = [expNode];
        }
        exps.push(exp);
        this.skipWs();
      }
      // 从右向左折叠：x^a^b -> x^(a^b)
      let t: VstNode[] = exps[exps.length - 1];
      for (let k: number = exps.length - 2; k >= 0; k--) {
        t = [new VstPow(exps[k], t)];
      }
      node = new VstPow([node], t);
    }
    // 阶乘：直接在因子后
    while (this.peek() === '!') {
      this.next();
      node = new VstPostfix('!', [node]);
      this.skipWs();
    }
    return node;
  }

  private parsePrimary(): VstNode | null {
    this.skipWs();
    const c: string = this.peek();
    if (c === '(') {
      this.next();
      const inner: VstRow | null = this.parseExpr();
      if (inner == null || this.err) return null;
      this.skipWs();
      if (this.peek() !== ')') { this.err = true; return null; }
      this.next();
      // 单子节点的括号视为分组，解包（避免序列化时括号无限累积）
      // 注意：分数 (a)/(b) 已在 parseExpr 的 '/' 分支统一处理，这里不再单独判断。
      if (inner.children.length === 1) return inner.children[0];
      return new VstParen(inner.children);
    }
    // 上取整 ⌈ ... ⌉
    if (c === '⌈') {
      this.next();
      const inner: VstRow | null = this.parseExpr();
      if (inner == null || this.err) return null;
      this.skipWs();
      if (this.peek() !== '⌉') { this.err = true; return null; }
      this.next();
      return new VstCeil(inner.children);
    }
    // 下取整 ⌊ ... ⌋
    if (c === '⌊') {
      this.next();
      const inner: VstRow | null = this.parseExpr();
      if (inner == null || this.err) return null;
      this.skipWs();
      if (this.peek() !== '⌋') { this.err = true; return null; }
      this.next();
      return new VstFloor(inner.children);
    }
    if (this.isDigit(c)) {
      let num: string = '';
      while (!this.eof() && this.isDigit(this.peek())) {
        num += this.next();
      }
      return new VstNum(num);
    }
    if (this.isAlpha(c)) {
      // 贪心匹配：先试当前位置的最长函数名，再试最长常量名，否则消费单字符变量。
      // 这样「变量后紧跟函数」（隐式乘法）与「无括号函数参数」都能正确拆分：
      //   "xsinx" -> x·sin(x)、"xlogx" -> x·log(x)、"xe^x" -> x·e^x、"sinx" -> sin(x)。
      // （旧逻辑预读整个字母序列、仅当整体恰为函数/常量名才识别，导致 "sinx" 整体
      //   不是函数名而只能逐字符消费成 s·i·n·x，x 与函数相连的表达式解析错误。）
      const funcName: string = this.matchFuncName();
      if (funcName !== '') {
        this.i += funcName.length; // 消费函数名
        this.skipWs();
        if (this.peek() === '(') {
          this.next();
          return this.parseFuncBody(funcName);
        }
        // 无括号参数：sinx -> sin(x)、logx -> log(x)，参数取单个 primary。
        // root 需两个参数（根指数、被开方数）必须带括号，无括号 root 视为错误。
        if (funcName === 'root') {
          this.err = true;
          return null;
        }
        const arg: VstNode | null = this.parsePrimary();
        if (arg == null || this.err) return null;
        return this.buildFuncNode(funcName, [arg]);
      }
      const constName: string = this.matchConstName();
      if (constName !== '') {
        this.i += constName.length; // 消费常量名（tau/pi/e）
        return new VstConst(CONSTS[constName]);
      }
      // 单字符变量：非函数/常量的多字母序列逐字符消费，
      // 由后续 parseFactor 解析为隐式乘积（如 "xxx" -> x·x·x，"xy" -> x·y）。
      const first: string = this.next();
      return new VstVar(first);
    }
    if (c === '?') {
      this.next();
      return new VstPlaceholder();
    }
    // 直接书写的常量符号（不经过 'pi'/'tau' 规范化）
    if (c === 'π') { this.next(); return new VstConst('π'); }
    if (c === 'τ') { this.next(); return new VstConst('τ'); }
    // 其它字符（如 '='）：无法解析
    this.err = true;
    return null;
  }

  /** 在当前位置匹配最长函数名前缀（如 "sinhx" 匹配 "sinh" 而非 "sin"）；无匹配返回 '' */
  private matchFuncName(): string {
    let best: string = '';
    for (let k: number = 0; k < FUNC_NAME_LIST.length; k++) {
      const name: string = FUNC_NAME_LIST[k];
      if (name.length > best.length && this.startsWithAt(name, this.i)) {
        best = name;
      }
    }
    return best;
  }

  /** 在当前位置匹配最长常量名前缀（tau/pi/e）；无匹配返回 '' */
  private matchConstName(): string {
    let best: string = '';
    for (let k: number = 0; k < CONST_NAME_LIST.length; k++) {
      const name: string = CONST_NAME_LIST[k];
      if (name.length > best.length && this.startsWithAt(name, this.i)) {
        best = name;
      }
    }
    return best;
  }

  /** 判断 this.s 在 pos 处是否以 prefix 开头 */
  private startsWithAt(prefix: string, pos: number): boolean {
    if (pos + prefix.length > this.s.length) {
      return false;
    }
    for (let k: number = 0; k < prefix.length; k++) {
      if (this.s.charAt(pos + k) !== prefix.charAt(k)) {
        return false;
      }
    }
    return true;
  }

  /** 解析函数括号内参数（假定 '(' 已消费），处理 sqrt/root/abs/floor/ceil/log 等特殊函数 */
  private parseFuncBody(id: string): VstNode | null {
    if (id === 'sqrt') {
      const b: VstRow | null = this.parseExpr();
      if (b == null || this.err) return null;
      this.skipWs();
      if (this.peek() !== ')') { this.err = true; return null; }
      this.next();
      return new VstSqrt(b.children);
    }
    if (id === 'root') {
      const idx: VstRow | null = this.parseExpr();
      if (idx == null || this.err) return null;
      this.skipWs();
      if (this.peek() !== ',') { this.err = true; return null; }
      this.next();
      const b: VstRow | null = this.parseExpr();
      if (b == null || this.err) return null;
      this.skipWs();
      if (this.peek() !== ')') { this.err = true; return null; }
      this.next();
      return new VstRoot(idx.children, b.children);
    }
    if (id === 'abs' || id === 'floor' || id === 'ceil') {
      const b: VstRow | null = this.parseExpr();
      if (b == null || this.err) return null;
      this.skipWs();
      if (this.peek() !== ')') { this.err = true; return null; }
      this.next();
      if (id === 'abs') return new VstFunc('abs', b.children);
      if (id === 'floor') return new VstFloor(b.children);
      return new VstCeil(b.children);
    }
    if (id === 'log') {
      const first: VstRow | null = this.parseExpr();
      if (first == null || this.err) return null;
      this.skipWs();
      if (this.peek() === ',') {
        // log(base,body) 形式 -> VstLog
        this.next();
        const body: VstRow | null = this.parseExpr();
        if (body == null || this.err) return null;
        this.skipWs();
        if (this.peek() !== ')') { this.err = true; return null; }
        this.next();
        return new VstLog(first.children, body.children);
      }
      // log(body) 单参数形式 -> VstFunc
      if (this.peek() !== ')') { this.err = true; return null; }
      this.next();
      return new VstFunc('log', first.children);
    }
    // 普通函数
    const b: VstRow | null = this.parseExpr();
    if (b == null || this.err) return null;
    this.skipWs();
    if (this.peek() !== ')') { this.err = true; return null; }
    this.next();
    return new VstFunc(id, b.children);
  }

  /** 由函数名与单个参数构建函数节点（用于无括号参数场景；root 不会进入此分支） */
  private buildFuncNode(funcName: string, args: VstNode[]): VstNode | null {
    if (funcName === 'sqrt') return new VstSqrt(args);
    if (funcName === 'abs') return new VstFunc('abs', args);
    if (funcName === 'floor') return new VstFloor(args);
    if (funcName === 'ceil') return new VstCeil(args);
    // sin/cos/tan/ln/log/log10/log2 等统一为 VstFunc
    return new VstFunc(funcName, args);
  }
}

/** 将线性求值串解析为 VstRow。
 *  - 空串/空白 -> 空行（渲染为空，不带虚线框）
 *  - 解析失败 -> 空行（不再回退成单个占位符，避免完成态表达式只剩虚线方块）
 *  - 合法串 -> 正常 VstRow
 */
export function parseLinear(expr: string): VstRow {
  if (expr == null) {
    return new VstRow([]);
  }
  const norm: string = normalizeExpr(expr);
  if (norm.trim().length === 0) {
    return new VstRow([]);
  }
  const p: Parser = new Parser(norm);
  const row: VstRow | null = p.parseExpr();
  if (row == null || p.err || !p.eof()) {
    return new VstRow([]);
  }
  return row;
}
