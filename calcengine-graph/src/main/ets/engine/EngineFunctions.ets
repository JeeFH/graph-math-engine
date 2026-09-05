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
// calcengine-graph/src/main/ets/engine/EngineFunctions.ets
/**
 * 引擎函数表（单点定义）
 *
 * 背景（缺陷类：函数注册表多处重复、逐处遗漏）：
 * 原先 FunctionEvaluator.isFuncName/applyFunc、BivariateEvaluator.isFuncName/applyFunc、
 * ExprClassifier.KNOWN_FUNCTIONS 三处各自维护同一张表，新增一个函数需要改四处，
 * 漏改任一处就会出现「分类器认为是变量 / 求值器认为未知标识符」的错配。
 * 本文件把名称表与实现收敛到单点，三处统一引用。
 *
 * 求值契约：域错误（负数开偶次方、负数阶乘等）一律返回 NaN，绝不抛异常。
 * 求值是网格采样与 1D 采样的热路径（单次可达数十万次调用），抛异常会触发
 * BuildStackTraceWithLimit 构建完整栈追踪，在热循环中足以阻塞主线程数秒。
 */

/** 一元函数名表（小写）。ExprClassifier 的变量扫描需据此排除函数名 */
const FUNCTION_NAMES: string[] = [
  'sin', 'cos', 'tan', 'asin', 'acos', 'atan',
  'sinh', 'cosh', 'tanh',
  'ln', 'log', 'log2', 'log10', 'sqrt', 'cbrt', 'abs', 'exp',
  'floor', 'ceil', 'round', 'sign', 'factorial'
];

/** 阶乘上界：超过此值的整数阶乘已溢出 double，直接判为域错误 */
const FACTORIAL_MAX: number = 170;

/** 有理指数重构的分母上界：超过即认定指数不是小分母有理数 */
const RATIONAL_MAX_DEN: number = 1024;
/** 连分数迭代上限（收敛极快，32 次远超任何实用指数） */
const RATIONAL_MAX_ITER: number = 32;
/** 有理逼近的残差容差：超出则维持「负底数非整数指数 → NaN」的原语义 */
const RATIONAL_TOL: number = 1e-9;
/** 连分数提前终止容差：小数部分小于此值视为已收敛到整数项 */
const RATIONAL_FRAC_EPS: number = 1e-12;

export class EngineFunctions {
  // ── 有理重构单元素 memo ──
  // 同一表达式的指数在整个采样过程中是常量（如 x^(1/3) 的 1/3），
  // 数十万次求值只需重构一次。按精确相等命中，powReal 是纯函数故无副作用风险。
  private static memoB: number = 0;
  private static memoHit: boolean = false;
  private static memoP: number = 0;
  private static memoQ: number = 0;

  /**
   * 实数域幂运算 a^b。
   *
   * 缺陷修正：原实现对 `a < 0 && b % 1 !== 0` 一刀切返回 NaN（或抛域错误），
   * 杀掉了奇分母有理指数在负实数域的确定实值，导致 y = x^(1/3) 的左半平面
   * 整片空白（右半平面正常）。数学上 q 为奇数时 a^(p/q) 有唯一实根。
   *
   * 分档处理：
   * - a ≥ 0：与 Math.pow 一致，非有限结果归一为 NaN。
   * - a < 0 且 b 为整数：Math.pow 本身正确。
   * - a < 0 且 b 为奇分母有理数 p/q：结果 = (-1)^p · |a|^b。
   * - 其余（含偶分母、无理指数）：NaN，与原语义一致。
   *
   * 性能：有理重构只在「原本就要失败」的分支执行，正常路径零额外开销。
   */
  static powReal(a: number, b: number): number {
    if (a >= 0) {
      const r: number = Math.pow(a, b);
      return Number.isFinite(r) ? r : NaN;
    }
    if (b % 1 === 0) {
      const r: number = Math.pow(a, b);
      return Number.isFinite(r) ? r : NaN;
    }
    let p: number = 0;
    let q: number = 0;
    if (EngineFunctions.memoHit && b === EngineFunctions.memoB) {
      p = EngineFunctions.memoP;
      q = EngineFunctions.memoQ;
    } else {
      const rational: [number, number] | null = EngineFunctions.toRational(b);
      EngineFunctions.memoB = b;
      if (rational === null) {
        EngineFunctions.memoHit = false;
        return NaN;
      }
      EngineFunctions.memoHit = true;
      p = rational[0];
      q = rational[1];
      EngineFunctions.memoP = p;
      EngineFunctions.memoQ = q;
    }
    // q 为偶数：负底数的偶次根在实数域无解
    if (q % 2 === 0) {
      return NaN;
    }
    const mag: number = Math.pow(-a, b);
    if (!Number.isFinite(mag)) {
      return NaN;
    }
    // (-1)^p：p 为奇数取负。注意 p 可为负整数，-3 % 2 === -1 仍属奇数
    return (p % 2 !== 0) ? -mag : mag;
  }

  /**
   * 用连分数把 b 重构为最简分数 p/q。
   *
   * 连分数的渐近分数天然是最简形式（相邻项行列式为 ±1），故无需再做 gcd 约分；
   * 这一点很关键：0.5 的渐近分数是 1/2 而非 2/2，若约分会把偶分母误判成奇分母。
   *
   * @returns [p, q]，或 null 表示 b 不是小分母有理数
   */
  static toRational(b: number): [number, number] | null {
    if (!Number.isFinite(b)) {
      return null;
    }
    let h0: number = 0;
    let h1: number = 1;
    let k0: number = 1;
    let k1: number = 0;
    let x: number = Math.abs(b);
    for (let i: number = 0; i < RATIONAL_MAX_ITER; i++) {
      const ai: number = Math.floor(x);
      const h2: number = ai * h1 + h0;
      const k2: number = ai * k1 + k0;
      if (k2 > RATIONAL_MAX_DEN || h2 > RATIONAL_MAX_DEN * 1024) {
        break;
      }
      h0 = h1;
      h1 = h2;
      k0 = k1;
      k1 = k2;
      const frac: number = x - ai;
      if (frac < RATIONAL_FRAC_EPS) {
        break;
      }
      x = 1 / frac;
    }
    if (k1 <= 0 || h1 <= 0) {
      return null;
    }
    const p: number = (b < 0) ? -h1 : h1;
    if (Math.abs(p / k1 - b) > RATIONAL_TOL) {
      return null;
    }
    return [p, k1];
  }

  /** 名称表副本（只读语义：调用方不得修改） */
  static names(): string[] {
    return FUNCTION_NAMES.slice();
  }

  /** 是否为一元函数名（大小写不敏感） */
  static isFunctionName(s: string): boolean {
    return FUNCTION_NAMES.indexOf(s.toLowerCase()) >= 0;
  }

  /**
   * 求值一元函数。
   * @param name 小写函数名
   * @param a 实参
   * @param isDegMode 角度模式（三角函数按角度输入/输出）
   * @returns 结果；域错误或未知函数名返回 NaN
   */
  static apply(name: string, a: number, isDegMode: boolean): number {
    const d2r: number = Math.PI / 180;
    switch (name) {
      case 'sin':
        return isDegMode ? Math.sin(a * d2r) : Math.sin(a);
      case 'cos':
        return isDegMode ? Math.cos(a * d2r) : Math.cos(a);
      case 'tan':
        return isDegMode ? Math.tan(a * d2r) : Math.tan(a);
      case 'asin':
        return isDegMode ? Math.asin(a) / d2r : Math.asin(a);
      case 'acos':
        return isDegMode ? Math.acos(a) / d2r : Math.acos(a);
      case 'atan':
        return isDegMode ? Math.atan(a) / d2r : Math.atan(a);
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
      case 'cbrt':
        // Math.cbrt 对负数返回负实根，无需额外分支
        return Math.cbrt(a);
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
        return EngineFunctions.factorial(a);
      default:
        return NaN;
    }
  }

  /** 阶乘：仅接受 [0, 170] 内的整数，否则 NaN */
  static factorial(n: number): number {
    if (!Number.isFinite(n) || n < 0 || n % 1 !== 0 || n > FACTORIAL_MAX) {
      return NaN;
    }
    let r: number = 1;
    for (let i: number = 2; i <= n; i++) {
      r *= i;
    }
    return r;
  }
}
