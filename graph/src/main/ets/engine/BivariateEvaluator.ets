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
// features/graph/src/main/ets/engine/BivariateEvaluator.ets
/**
 * 双变量表达式求值引擎 F(x, y)
 *
 * 桥接 core/Tokenizer 做词法分析，自建 shunting-yard → 逆波兰式(RPN)，
 * 支持变量 x、y 同时代入求值。用于隐函数 / 不等式 / 二元方程渲染。
 *
 * 能力：
 * - 变量：x, y
 * - 常量：pi/π、e、tau/τ
 * - 运算符：+ - * / × ÷ ^ % 及一元负号
 * - 隐式乘法：2x、2y、xy、2sin(x)、(x+1)y 等
 * - 一元函数：sin cos tan asin acos atan sinh cosh tanh ln log log2 sqrt abs exp floor ceil round sign factorial
 * - 角度模式：isDegMode 时三角函数按角度计算
 *
 * 与 FunctionEvaluator 的关键区别：
 * - evaluate(x, y) 接受两个参数
 * - RPN 中 var 类型区分 name='x' 和 name='y'
 * - 隐式乘法支持 xy、yx 等双变量组合
 */

import { Tokenizer } from 'mathkit';

/** RPN 令牌 */
interface RpnToken {
  kind: string;        // 'num' | 'var' | 'const' | 'binop' | 'unop' | 'func'
  value: number;        // num / const 用
  op: string;          // binop / unop 用
  name: string;        // var 用：'x' 或 'y'
}

/** 解析阶段的中间令牌 */
interface MidToken {
  kind: string;        // 'num' | 'var' | 'const' | 'lpar' | 'rpar' | 'binop' | 'unop' | 'func'
  value: number;
  op: string;
  name: string;
}

export class BivariateEvaluator {
  private readonly expr: string;
  private readonly isDegMode: boolean;
  private rpn: RpnToken[] = [];
  private valid: boolean = false;
  private errorMsg: string | null = null;
  /**
   * 预分配求值栈缓冲区（零分配热路径）：
   * 长度 = rpn.length（RPN 栈深度永不超过令牌总数），解析成功后一次性分配。
   * evaluate() 内部复用此缓冲区，消除每次调用的数组分配——
   * 网格构建期间数十万次调用不再产生 GC 压力。
   */
  private stackBuf: Float64Array = new Float64Array(0);

  constructor(expression: string, isDegMode: boolean = false) {
    this.expr = expression;
    this.isDegMode = isDegMode;
    this.parse();
  }

  get expression(): string {
    return this.expr;
  }

  get isValid(): boolean {
    return this.valid;
  }

  get error(): string | null {
    return this.errorMsg;
  }

  /**
   * 代入变量 x, y 求值。
   *
   * 性能关键约定：本方法是网格采样的热路径（单次数十万次调用），
   * 所有运行时数学错误（域错误 / 除零 / 溢出 / RPN 栈异常）一律返回 NaN，
   * 绝不抛出异常。抛异常会触发 BuildStackTraceWithLimit 构建完整栈追踪
   * （昂贵的字符串操作），在热循环中会导致主线程阻塞数秒（appfreeze）。
   * 正常路径下返回 number（可能为 NaN / Infinity）。
   *
   * 零分配优化：使用预分配的 Float64Array 栈缓冲区 + 栈指针，
   * 整个求值过程无任何对象/数组分配。
   */
  evaluate(x: number, y: number): number {
    if (!this.valid) {
      return NaN;
    }
    const buf: Float64Array = this.stackBuf;
    let sp: number = 0;
    for (let i: number = 0; i < this.rpn.length; i++) {
      const t: RpnToken = this.rpn[i];
      if (t.kind === 'num' || t.kind === 'const') {
        buf[sp++] = t.value;
      } else if (t.kind === 'var') {
        buf[sp++] = (t.name === 'x') ? x : y;
      } else if (t.kind === 'binop') {
        if (sp < 2) {
          return NaN;
        }
        const b: number = buf[--sp];
        const a: number = buf[--sp];
        buf[sp++] = this.applyBinary(a, b, t.op);
      } else if (t.kind === 'unop') {
        if (sp < 1) {
          return NaN;
        }
        buf[sp - 1] = -buf[sp - 1];
      } else if (t.kind === 'func') {
        if (sp < 1) {
          return NaN;
        }
        buf[sp - 1] = this.applyFunc(t.name, buf[sp - 1]);
      }
    }
    if (sp !== 1) {
      return NaN;
    }
    return buf[0];
  }

  // ================= 解析 =================
  private parse(): void {
    const raw: string = this.expr.trim();
    if (raw.length === 0) {
      this.valid = false;
      this.errorMsg = '表达式为空';
      return;
    }
    let tokens: string[] = [];
    try {
      tokens = Tokenizer.tokenize(raw);
    } catch (e) {
      this.valid = false;
      this.errorMsg = (e instanceof Error) ? e.message : '词法分析失败';
      return;
    }
    if (tokens.length === 0) {
      this.valid = false;
      this.errorMsg = '无法解析表达式';
      return;
    }
    try {
      let mids: MidToken[] = this.classify(tokens);
      mids = this.insertImplicitMul(mids);
      this.rpn = this.shuntingYard(mids);
    } catch (e) {
      this.valid = false;
      this.errorMsg = (e instanceof Error) ? e.message : '解析失败';
      return;
    }
    this.valid = true;
    this.errorMsg = null;
    // 预分配求值栈缓冲区：RPN 栈深度永不超过令牌总数
    this.stackBuf = new Float64Array(this.rpn.length);
  }

  /** 把字符串 token 分类，并标记一元负号 */
  private classify(tokens: string[]): MidToken[] {
    const out: MidToken[] = [];
    for (let i: number = 0; i < tokens.length; i++) {
      const tk: string = tokens[i];

      // 一元负号判定
      if (tk === '-') {
        const prev: MidToken | undefined = out.length > 0 ? out[out.length - 1] : undefined;
        const isUnary: boolean = (i === 0) ||
          (prev !== undefined && (prev.kind === 'binop' || prev.kind === 'unop' || prev.kind === 'lpar'));
        if (isUnary) {
          out.push({ kind: 'unop', op: 'u-', value: 0, name: '' });
          continue;
        }
      }

      // 数字
      if (/^-?\d+(\.\d+)?([eE][+-]?\d+)?$/.test(tk)) {
        out.push({ kind: 'num', value: Number(tk), op: '', name: '' });
        continue;
      }
      // 括号
      if (tk === '(') {
        out.push({ kind: 'lpar', value: 0, op: '', name: '' });
        continue;
      }
      if (tk === ')') {
        out.push({ kind: 'rpar', value: 0, op: '', name: '' });
        continue;
      }
      // 变量 x 或 y
      if (tk === 'x' || tk === 'X') {
        out.push({ kind: 'var', value: 0, op: '', name: 'x' });
        continue;
      }
      if (tk === 'y' || tk === 'Y') {
        out.push({ kind: 'var', value: 0, op: '', name: 'y' });
        continue;
      }
      // 二元运算符
      if (tk === '+' || tk === '-' || tk === '×' || tk === '*' || tk === '÷' || tk === '/' || tk === '^' || tk === '%') {
        out.push({ kind: 'binop', op: tk, value: 0, name: '' });
        continue;
      }
      // 常量
      const maybeConst: number = this.lookupConst(tk);
      if (!isNaN(maybeConst)) {
        out.push({ kind: 'const', value: maybeConst, op: '', name: '' });
        continue;
      }
      // 字母串：函数名 或 常量别名
      if (/^[a-zA-Z_][a-zA-Z0-9_]*$/.test(tk)) {
        if (this.isFuncName(tk)) {
          out.push({ kind: 'func', name: tk.toLowerCase(), value: 0, op: '' });
          continue;
        }
        const c: number = this.lookupConst(tk.toLowerCase());
        if (!isNaN(c)) {
          out.push({ kind: 'const', value: c, op: '', name: '' });
          continue;
        }
        throw new Error(`未知标识符: ${tk}`);
      }
      throw new Error(`无法识别的符号: ${tk}`);
    }
    return out;
  }

  /**
   * 插入隐式乘法：
   * num / var / const / 右括号  后跟  var / const / 左括号 / 函数  → 插入 ×
   * 注意：var 包括 x 和 y，因此 xy、yx、2x、x2 等都会插入隐式乘号
   */
  private insertImplicitMul(mids: MidToken[]): MidToken[] {
    const out: MidToken[] = [];
    for (let i: number = 0; i < mids.length; i++) {
      const cur: MidToken = mids[i];
      out.push(cur);
      if (i < mids.length - 1) {
        const nxt: MidToken = mids[i + 1];
        const leftClose: boolean = cur.kind === 'num' || cur.kind === 'var' ||
          cur.kind === 'const' || cur.kind === 'rpar';
        const rightOpen: boolean = nxt.kind === 'var' || nxt.kind === 'const' ||
          nxt.kind === 'lpar' || nxt.kind === 'func';
        if (leftClose && rightOpen) {
          out.push({ kind: 'binop', op: '×', value: 0, name: '' });
        }
      }
    }
    return out;
  }

  // ================= shunting-yard =================
  private shuntingYard(mids: MidToken[]): RpnToken[] {
    const output: RpnToken[] = [];
    const ops: MidToken[] = [];
    for (let i: number = 0; i < mids.length; i++) {
      const t: MidToken = mids[i];
      if (t.kind === 'num' || t.kind === 'var' || t.kind === 'const') {
        output.push({ kind: t.kind, value: t.value, op: '', name: t.name });
      } else if (t.kind === 'func') {
        ops.push(t);
      } else if (t.kind === 'lpar') {
        ops.push(t);
      } else if (t.kind === 'binop' || t.kind === 'unop') {
        while (ops.length > 0) {
          const top: MidToken = ops[ops.length - 1];
          if (top.kind === 'lpar' || top.kind === 'func') {
            break;
          }
          const topPrec: number = this.prec(top);
          const curPrec: number = this.prec(t);
          const topRight: boolean = this.isRightAssoc(top);
          if (topRight ? (topPrec > curPrec) : (topPrec >= curPrec)) {
            output.push(this.toRpn(ops.pop()!));
          } else {
            break;
          }
        }
        ops.push(t);
      } else if (t.kind === 'rpar') {
        while (ops.length > 0 && ops[ops.length - 1].kind !== 'lpar') {
          output.push(this.toRpn(ops.pop()!));
        }
        if (ops.length === 0) {
          throw new Error('括号不匹配');
        }
        ops.pop();
        if (ops.length > 0 && ops[ops.length - 1].kind === 'func') {
          output.push(this.toRpn(ops.pop()!));
        }
      }
    }
    while (ops.length > 0) {
      const top: MidToken = ops.pop()!;
      if (top.kind === 'lpar' || top.kind === 'rpar') {
        throw new Error('括号不匹配');
      }
      output.push(this.toRpn(top));
    }
    return output;
  }

  private prec(t: MidToken): number {
    if (t.kind === 'unop') {
      return 3;
    }
    if (t.op === '^') {
      return 4;
    }
    if (t.op === '×' || t.op === '*' || t.op === '÷' || t.op === '/' || t.op === '%') {
      return 3;
    }
    if (t.op === '+' || t.op === '-') {
      return 2;
    }
    return 0;
  }

  private isRightAssoc(t: MidToken): boolean {
    return t.kind === 'unop' || t.op === '^';
  }

  private toRpn(t: MidToken): RpnToken {
    if (t.kind === 'binop' || t.kind === 'unop') {
      return { kind: t.kind, op: t.op, value: 0, name: '' };
    }
    if (t.kind === 'func') {
      return { kind: 'func', name: t.name, value: 0, op: '' };
    }
    return { kind: t.kind, value: t.value, op: '', name: t.name };
  }

  // ================= 运算 =================
  private applyBinary(a: number, b: number, op: string): number {
    switch (op) {
      case '+':
        return a + b;
      case '-':
        return a - b;
      case '×':
      case '*':
        return a * b;
      case '÷':
      case '/':
        if (b === 0) {
          return NaN;
        }
        return a / b;
      case '^': {
        if (a < 0 && b % 1 !== 0) {
          return NaN;
        }
        const r: number = Math.pow(a, b);
        if (!isFinite(r)) {
          return NaN;
        }
        return r;
      }
      case '%':
        return a % b;
      default:
        return NaN;
    }
  }

  private applyFunc(name: string, a: number): number {
    const d2r: number = Math.PI / 180;
    switch (name) {
      case 'sin':
        return this.isDegMode ? Math.sin(a * d2r) : Math.sin(a);
      case 'cos':
        return this.isDegMode ? Math.cos(a * d2r) : Math.cos(a);
      case 'tan':
        return this.isDegMode ? Math.tan(a * d2r) : Math.tan(a);
      case 'asin':
        return this.isDegMode ? Math.asin(a) / d2r : Math.asin(a);
      case 'acos':
        return this.isDegMode ? Math.acos(a) / d2r : Math.acos(a);
      case 'atan':
        return this.isDegMode ? Math.atan(a) / d2r : Math.atan(a);
      case 'sinh':
        return Math.sinh(a);
      case 'cosh':
        return Math.cosh(a);
      case 'tanh':
        return Math.tanh(a);
      case 'ln':
        return Math.log(a);
      case 'log':
        return Math.log10(a);
      case 'log2':
        return Math.log2(a);
      case 'log10':
        return Math.log10(a);
      case 'sqrt':
        return Math.sqrt(a);
      case 'abs':
        return Math.abs(a);
      case 'exp':
        return Math.exp(a);
      case 'floor':
        return Math.floor(a);
      case 'ceil':
        return Math.ceil(a);
      case 'round':
        return Math.round(a);
      case 'sign':
        return Math.sign(a);
      case 'factorial':
        return this.factorial(a);
      default:
        return NaN;
    }
  }

  private factorial(n: number): number {
    if (n < 0 || n % 1 !== 0) {
      return NaN;
    }
    let r: number = 1;
    for (let i: number = 2; i <= n; i++) {
      r *= i;
    }
    return r;
  }

  private isFuncName(s: string): boolean {
    const n: string = s.toLowerCase();
    const set: string[] = [
      'sin', 'cos', 'tan', 'asin', 'acos', 'atan',
      'sinh', 'cosh', 'tanh',
      'ln', 'log', 'log2', 'log10', 'sqrt', 'abs', 'exp',
      'floor', 'ceil', 'round', 'sign', 'factorial'
    ];
    return set.indexOf(n) >= 0;
  }

  private lookupConst(s: string): number {
    const n: string = s.toLowerCase();
    if (n === 'pi' || n === 'π') {
      return Math.PI;
    }
    if (n === 'e') {
      return Math.E;
    }
    if (n === 'tau' || n === 'τ') {
      return 2 * Math.PI;
    }
    return NaN;
  }
}
