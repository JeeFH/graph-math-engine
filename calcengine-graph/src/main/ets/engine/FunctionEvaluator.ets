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
// calcengine-graph/src/main/ets/engine/FunctionEvaluator.ets
/**
 * 函数表达式求值引擎（图象绘制模式核心地基）
 *
 * 桥接 core/Tokenizer 做词法分析，自建 shunting-yard → 逆波兰式(RPN)，
 * 支持变量 x 代入求值。完全不改 core 模块。
 *
 * 能力：
 * - 变量：x
 * - 常量：pi/π、e、tau/τ
 * - 运算符：+ - * / × ÷ ^ % 及一元负号
 * - 隐式乘法：2x、2sin(x)、(x+1)x、xe
 * - 一元函数：见 EngineFunctions（sin cos tan asin acos atan sinh cosh tanh
 *   ln log log2 log10 sqrt cbrt abs exp floor ceil round sign factorial）
 * - 根式模板：root(n, b) 由 ExprNormalizer 在词法前改写为一元形式
 * - 符号归一：Unicode 乘除号族（· ∙ ⋅ • ∗）、全角标点/数字、不可见字符
 * - 角度模式：isDegMode 时三角函数按角度计算
 */

import { Tokenizer } from 'calcengine-core';
import { ExprNormalizer } from './ExprNormalizer';
import { EngineFunctions } from './EngineFunctions';

/** RPN 令牌 */
interface RpnToken {
  kind: string;        // 'num' | 'var' | 'const' | 'binop' | 'unop' | 'func'
  value: number;        // num / const 用
  op: string;          // binop / unop 用
  name: string;        // var / func 用
}

/** 解析阶段的中间令牌 */
interface MidToken {
  kind: string;        // 'num' | 'var' | 'const' | 'lpar' | 'rpar' | 'binop' | 'unop' | 'func'
  value: number;
  op: string;
  name: string;
}

export class FunctionEvaluator {
  private readonly expr: string;
  private readonly isDegMode: boolean;
  private rpn: RpnToken[] = [];
  private valid: boolean = false;
  private errorMsg: string | null = null;
  /**
   * 预分配求值栈缓冲区（零分配热路径）：长度 = rpn.length。
   * 与 BivariateEvaluator.stackBuf 同一优化，消除 1D 采样每次调用的数组分配。
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
   * 代入变量 x 求值。
   *
   * 契约：本方法是 1D 采样的热路径（单次数万次调用），所有运行时错误
   * （域错误 / 除零 / 溢出 / RPN 栈异常）一律返回 NaN，绝不抛异常。
   * 抛异常会触发 BuildStackTraceWithLimit 构建完整栈追踪（昂贵的字符串操作），
   * 在热循环中足以阻塞主线程数秒（appfreeze）。与 BivariateEvaluator.evaluate 对齐。
   *
   * 正常路径下返回 number（可能为 NaN，如 1/x 在 x=0 处、sqrt 的负数域）。
   */
  evaluate(x: number): number {
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
        buf[sp++] = x;
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
        buf[sp - 1] = EngineFunctions.apply(t.name, buf[sp - 1], this.isDegMode);
      }
    }
    if (sp !== 1) {
      return NaN;
    }
    return buf[0];
  }

  // ================= 解析 =================
  private parse(): void {
    // 词法前归一化：消除上下游词表不对称（Unicode 乘除号族、全角标点）与
    // n 次根模板的二元形式。归一化幂等，对已规范输入无副作用。
    const raw: string = ExprNormalizer.normalize(this.expr.trim());
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
      const structErr: string | null = this.validateStructure(mids);
      if (structErr !== null) {
        this.valid = false;
        this.errorMsg = structErr;
        this.rpn = [];
        return;
      }
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

  /**
   * 结构校验：把「求值时才发现的畸形表达式」提前到解析期显式失败。
   *
   * 动机（缺陷类：静默失败）：词法器对非法字符的兜底是静默丢弃，`2·3x` 会被切成
   * `[2,3,x]`；隐式乘法只在 num→var/const/lpar/func 之间补乘号，num 与 num 相邻不会补，
   * 最终 RPN 求值后栈上残留 2 个元素，evaluate 恒返回 NaN，而 isValid 仍为 true ——
   * 表现为「表达式看着正常、画布全空、零报错」。校验后这类输入直接判为解析失败
   * 并给出可读原因，由 UI 提示用户，而不是静默画出空白。
   */
  private validateStructure(mids: MidToken[]): string | null {
    for (let i: number = 0; i + 1 < mids.length; i++) {
      const cur: MidToken = mids[i];
      const nxt: MidToken = mids[i + 1];
      const curValue: boolean = cur.kind === 'num' || cur.kind === 'const';
      const nxtValue: boolean = nxt.kind === 'num' || nxt.kind === 'const';
      if (curValue && nxtValue) {
        return '表达式中存在相邻的两个数值（可能包含无法识别的符号）';
      }
    }
    // RPN 栈深度模拟：任何时刻不得下溢，结束时必须恰好剩 1 个值
    let depth: number = 0;
    for (let i: number = 0; i < this.rpn.length; i++) {
      const t: RpnToken = this.rpn[i];
      if (t.kind === 'num' || t.kind === 'const' || t.kind === 'var') {
        depth++;
      } else if (t.kind === 'binop') {
        if (depth < 2) {
          return '运算符缺少操作数';
        }
        depth--;
      } else if (t.kind === 'unop' || t.kind === 'func') {
        if (depth < 1) {
          return '函数或负号缺少操作数';
        }
      }
    }
    if (depth !== 1) {
      return '表达式结构不完整（存在无法识别的符号或缺少运算符）';
    }
    return null;
  }

  /** 把字符串 token 分类，并标记一元负号 */
  private classify(tokens: string[]): MidToken[] {
    const out: MidToken[] = [];
    for (let i = 0; i < tokens.length; i++) {
      const tk: string = tokens[i];

      // 一元负号判定（单独 '-' 且位于开头 / 运算符 / 左括号后）
      if (tk === '-') {
        const prev: MidToken | undefined = out.length > 0 ? out[out.length - 1] : undefined;
        const isUnary: boolean = (i === 0) ||
          (prev !== undefined && (prev.kind === 'binop' || prev.kind === 'unop' || prev.kind === 'lpar'));
        if (isUnary) {
          out.push({ kind: 'unop', op: 'u-', value: 0, name: '' });
          continue;
        }
      }

      // 数字（含已合并的一元负数字、科学计数法）
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
      // 变量 x
      if (tk === 'x' || tk === 'X') {
        out.push({ kind: 'var', value: 0, op: '', name: 'x' });
        continue;
      }
      // 二元运算符
      if (tk === '+' || tk === '-' || tk === '×' || tk === '*' || tk === '÷' || tk === '/' || tk === '^' || tk === '%') {
        out.push({ kind: 'binop', op: tk, value: 0, name: '' });
        continue;
      }
      // 常量（含 Unicode 符号 π/τ 及 e），先于字母分支以避免被当函数名
      const maybeConst: number = this.lookupConst(tk);
      if (!isNaN(maybeConst)) {
        out.push({ kind: 'const', value: maybeConst, op: '', name: '' });
        continue;
      }
      // 字母串：函数名 或 常量别名
      if (/^[a-zA-Z_][a-zA-Z0-9_]*$/.test(tk)) {
        if (EngineFunctions.isFunctionName(tk)) {
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
   * num / var / const / 右括号  后跟  var / const / 左括号 / 函数  → 插入 ×（隐式乘）
   */
  private insertImplicitMul(mids: MidToken[]): MidToken[] {
    const out: MidToken[] = [];
    for (let i = 0; i < mids.length; i++) {
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
    for (let i = 0; i < mids.length; i++) {
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
          // 左结合：topPrec >= curPrec 弹；右结合：topPrec > curPrec 弹
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
        ops.pop(); // 弹掉 '('
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
    // 一元负优先级低于 ^（保证 -x^2 = -(x^2)，与科学计算器一致；
    // 图象模式画 y=-x^2 必须开口向下，否则会算成 (-x)^2 开口向上）
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
        // 除零返回 NaN（热路径禁抛异常），与 BivariateEvaluator 一致
        if (b === 0) {
          return NaN;
        }
        return a / b;
      case '^':
        // 实数域幂：负底数 + 奇分母有理指数走实根分支
        // （修复 y = x^(1/3) 在 x<0 时整片空白）；溢出/域错误归一为 NaN
        return EngineFunctions.powReal(a, b);
      case '%':
        return a % b;
      default:
        return NaN;
    }
  }

  // applyFunc / factorial / isFuncName 已收敛到 EngineFunctions（函数表单点化），
  // 避免名称表与实现在多个求值器里各维一份、逐处遗漏。

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
