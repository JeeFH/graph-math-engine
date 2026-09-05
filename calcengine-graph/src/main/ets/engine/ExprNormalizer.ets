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
// calcengine-graph/src/main/ets/engine/ExprNormalizer.ets
/**
 * 表达式归一化器（词法前置重写）
 *
 * 背景（缺陷类：跨层词表不对称 + 静默失败）：
 * 上游「显示/化简层」与下游「词法/求值层」各自维护一份符号词表，两者不重合时
 * 上游产出的合法 token 会被下游词法器当作非法字符处理。Tokenizer 对非法字符的
 * 兜底是 `i++` 静默丢弃，于是 `2·3x` 被切成 `[2,3,x]`：隐式乘法只在
 * num→var/const/lpar/func 之间插入乘号，num 与 num 相邻不会补，最终 RPN 求值后
 * 栈上残留 2 个元素，evaluate 恒返回 NaN，而 isValid 仍为 true ——
 * 表现为「表达式看着正常、画布全空、零报错」。
 *
 * 职责：在 Tokenizer.tokenize 之前，把上游可能产出、而词法器白名单未覆盖的
 * 符号保守地重写为词法器认识的等价形式。只做等价重写，不做语义推断。
 *
 * 覆盖两类：
 * 1. 字符级：Unicode 乘除号族、全角标点/数字/字母、不可见字符。
 * 2. 结构级：n 次根模板 root(n, b) 的一元函数改写。
 *    上游序列化器对 n 次根输出 root(index, body)（二元形式），而求值器的
 *    func 节点只弹 1 个操作数，二元函数无法表达；改写在归一化阶段完成，
 *    求值器无需引入 arity 机制。
 */

/** 归一化幂等性保障：结构改写最多迭代次数（防止畸形输入导致死循环） */
const MAX_ROOT_REWRITE: number = 64;

export class ExprNormalizer {

  /**
   * 完整归一化：字符级重写 + 根式模板改写。
   * 幂等：对已归一化的字符串再次调用返回同一结果。
   */
  static normalize(expr: string): string {
    return ExprNormalizer.normalizeRoots(ExprNormalizer.normalizeChars(expr));
  }

  /**
   * 字符级归一化：逐字符映射。
   * 空串映射（返回 ''）表示该字符被删除。
   */
  static normalizeChars(expr: string): string {
    if (expr.length === 0) {
      return expr;
    }
    let out: string = '';
    for (let i: number = 0; i < expr.length; i++) {
      out += ExprNormalizer.mapChar(expr.charAt(i));
    }
    return out;
  }

  /** 单字符映射。返回 '' 表示删除（不可见字符），否则返回等价 ASCII 形式或原字符 */
  private static mapChar(ch: string): string {
    // 不可见字符：直接删除（Tokenizer 同样会静默丢弃，此处提前消除以稳定长度语义）
    if (ch === '\u00A0' || ch === '\u200B' || ch === '\u2060' || ch === '\uFEFF') {
      return '';
    }
    switch (ch) {
      // 乘号族：Tokenizer.isOperatorChar 只认 '*' 与 '×'
      case '\u00B7': // · 中点（上游化简器产出的显式乘号，本缺陷的主入口）
      case '\u2219': // ∙ 子弹运算符
      case '\u22C5': // ⋅ 数学点算子
      case '\u2022': // • 项目符号
      case '\u2217': // ∗ 星号算子
      case '\uFF0A': // ＊ 全角星号
        return '*';
      // 除号族：Tokenizer 只认 '/' 与 '÷'
      case '\u2215': // ∕ 除号
      case '\u2044': // ⁄ 分数斜杠
      case '\uFF0F': // ／ 全角斜杠
        return '/';
      // 负号族：Tokenizer 只认 '-'
      case '\u2212': // − 数学减号
      case '\uFF0D': // － 全角减号
        return '-';
      // 全角标点
      case '\uFF08': return '('; // （
      case '\uFF09': return ')'; // ）
      case '\uFF3B': return '['; // ［
      case '\uFF3D': return ']'; // ］
      case '\uFF5C': return '|'; // ｜
      case '\uFF0C': return ','; // ，
      case '\uFF0E': return '.'; // ．
      case '\uFF0B': return '+'; // ＋
      case '\uFF3E': return '^'; // ＾
      case '\uFF05': return '%'; // ％
      case '\uFF1D': return '='; // ＝
      case '\uFF1C': return '<'; // ＜
      case '\uFF1E': return '>'; // ＞
      case '\uFF01': return '!'; // ！
      default:
        break;
    }
    const code: number = ch.charCodeAt(0);
    // 全角数字 ０-９
    if (code >= 0xFF10 && code <= 0xFF19) {
      return String.fromCharCode(code - 0xFF10 + 0x30);
    }
    // 全角大写字母 Ａ-Ｚ
    if (code >= 0xFF21 && code <= 0xFF3A) {
      return String.fromCharCode(code - 0xFF21 + 0x41);
    }
    // 全角小写字母 ａ-ｚ
    if (code >= 0xFF41 && code <= 0xFF5A) {
      return String.fromCharCode(code - 0xFF41 + 0x61);
    }
    return ch;
  }

  /**
   * 结构级归一化：把 root(n, b) 改写为一元形式。
   *
   * - n = 2 → sqrt(b)
   * - n = 3 → cbrt(b)（走 Math.cbrt，天然支持负数且无有理逼近误差）
   * - 其它 n → (b)^(1/(n))，配合幂运算的实数域根语义得到奇次根的实值分支
   *
   * n 非数字字面量时原样保留，交由解析层报出「未知标识符: root」，
   * 而不是静默产出错误曲线。
   */
  static normalizeRoots(expr: string): string {
    let s: string = expr;
    let guard: number = 0;
    while (guard < MAX_ROOT_REWRITE) {
      const hit: number = ExprNormalizer.findRootCall(s);
      if (hit < 0) {
        break;
      }
      const openParen: number = hit + 4;
      const close: number = ExprNormalizer.matchParen(s, openParen);
      if (close < 0) {
        break; // 括号不匹配：交由解析层报错
      }
      const inner: string = s.substring(openParen + 1, close);
      const comma: number = ExprNormalizer.topLevelComma(inner);
      if (comma < 0) {
        break; // 缺少参数分隔符：交由解析层报错
      }
      const indexStr: string = inner.substring(0, comma).trim();
      const body: string = inner.substring(comma + 1).trim();
      if (!ExprNormalizer.isNumberLiteral(indexStr)) {
        break;
      }
      const n: number = Number(indexStr);
      let replacement: string = '';
      if (n === 2) {
        replacement = 'sqrt(' + body + ')';
      } else if (n === 3) {
        replacement = 'cbrt(' + body + ')';
      } else if (n !== 0) {
        replacement = '(' + body + ')^(1/(' + indexStr + '))';
      } else {
        break;
      }
      // 从改写起点继续扫描：嵌套 root 会在后续迭代中被消除（每次迭代深度严格递减）
      s = s.substring(0, hit) + replacement + s.substring(close + 1);
      guard++;
    }
    return s;
  }

  /** 查找带词边界的 root( 调用起点，未找到返回 -1（大小写不敏感） */
  private static findRootCall(s: string): number {
    const lower: string = s.toLowerCase();
    let from: number = 0;
    while (from < lower.length) {
      const idx: number = lower.indexOf('root(', from);
      if (idx < 0) {
        return -1;
      }
      if (idx > 0) {
        const before: string = s.charAt(idx - 1);
        const isWordChar: boolean =
          (before >= 'a' && before <= 'z') || (before >= 'A' && before <= 'Z') ||
          (before >= '0' && before <= '9') || before === '_';
        if (isWordChar) {
          from = idx + 1;
          continue; // 属于更长标识符的一部分（如 sqrtroot、croot）
        }
      }
      return idx;
    }
    return -1;
  }

  /** 返回 openParen 处 '(' 的配对 ')' 下标，未配对返回 -1 */
  private static matchParen(s: string, openParen: number): number {
    if (openParen >= s.length || s.charAt(openParen) !== '(') {
      return -1;
    }
    let depth: number = 0;
    for (let i: number = openParen; i < s.length; i++) {
      const ch: string = s.charAt(i);
      if (ch === '(') {
        depth++;
      } else if (ch === ')') {
        depth--;
        if (depth === 0) {
          return i;
        }
      }
    }
    return -1;
  }

  /** 返回参数串中位于括号深度 0 的第一个逗号下标，无则 -1 */
  private static topLevelComma(s: string): number {
    let depth: number = 0;
    for (let i: number = 0; i < s.length; i++) {
      const ch: string = s.charAt(i);
      if (ch === '(' || ch === '[') {
        depth++;
      } else if (ch === ')' || ch === ']') {
        depth--;
      } else if (ch === ',' && depth === 0) {
        return i;
      }
    }
    return -1;
  }

  /** 是否为纯数字字面量（含一元负号与科学计数法） */
  private static isNumberLiteral(s: string): boolean {
    return /^-?\d+(\.\d+)?([eE][+-]?\d+)?$/.test(s);
  }
}
