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
// features/graph/src/main/ets/engine/ExprClassifier.ets
/**
 * 表达式自动判别路由器
 *
 * 扫描用户输入的原始表达式，按优先级判定渲染模式：
 *   优先级 1（最高）：含不等号 > < >= <= ≥ ≤ → 不等式渲染 (INEQUALITY)
 *   优先级 2：含等号 = 且含 x+y → 方程渲染 (BIVARIATE_EQ / IMPLICIT)
 *   优先级 3：无等号/不等号，同时含 x+y → 隐函数渲染 (IMPLICIT)
 *   优先级 4（最低）：仅含单变量 → 显函数渲染 (EXPLICIT)
 *
 * 同时输出标准化信息（拆分后的左/右侧、不等号方向等），供下游渲染器消费。
 */

import { RenderMode } from './IRenderer';

// ==================== 判定结果 ====================

/** 不等号方向 */
export type InequalityDirection = '>' | '<' | '>=' | '<=';

/** 表达式分类结果 */
export interface ClassifyResult {
  /** 判定的渲染模式 */
  mode: RenderMode;
  /** 原始表达式 */
  rawExpr: string;
  /**
   * 标准化后的 F(x,y) 表达式：
   * - EXPLICIT: 原表达式（y = f(x) 中的 f(x)）
   * - IMPLICIT: 原表达式（F(x,y) = 0 中的 F(x,y)）
   * - INEQUALITY: L - R（标准化为 F(x,y) 与 0 比较）
   * - BIVARIATE_EQ: L - R（标准化为 F(x,y) = 0）
   */
  normalizedExpr: string;
  /** 不等式方向（仅 INEQUALITY 模式有效） */
  inequalityDir?: InequalityDirection;
  /** 是否含变量 x */
  hasX: boolean;
  /** 是否含变量 y */
  hasY: boolean;
}

/** 变量扫描结果 */
interface VariableScanResult {
  hasX: boolean;
  hasY: boolean;
}

/** 关系运算符拆分结果 */
interface RelationalSplitResult {
  left: string;
  op: string;
  right: string;
}

// ==================== 已知函数名集合 ====================

/** 已知一元函数名（小写），这些不算作变量 y */
const KNOWN_FUNCTIONS: string[] = [
  'sin', 'cos', 'tan', 'asin', 'acos', 'atan',
  'sinh', 'cosh', 'tanh',
  'ln', 'log', 'log2', 'log10', 'sqrt', 'abs', 'exp',
  'floor', 'ceil', 'round', 'sign', 'factorial'
];

/** 已知常量名（小写），不算作变量 */
const KNOWN_CONSTANTS: string[] = ['pi', 'e', 'tau'];

// ==================== 关系运算符检测 ====================

/** 关系运算符正则（按长度降序匹配，避免 >= 被误拆为 > + =） */
const RELATIONAL_PATTERN: RegExp =
  />=|<=|≥|≤|≠|>|<|=/;

/** Unicode → ASCII 映射 */
function normalizeRelOp(op: string): string {
  if (op === '≥') return '>=';
  if (op === '≤') return '<=';
  return op;
}

// ==================== 变量扫描 ====================

/**
 * 扫描表达式中的变量 x / y。
 * 需排除函数名中的字母（如 sin 中的字母不算变量）和常量。
 *
 * 策略：先用正则提取所有字母序列，过滤掉已知函数名和常量，
 * 剩余的单独字母 x / y 即为变量。
 */
function scanVariables(expr: string): VariableScanResult {
  // 提取所有字母序列（连续字母作为一个标识符）
  const regex: RegExp = /[a-zA-Z_][a-zA-Z0-9_]*/g;
  const matchResult: RegExpMatchArray | null = expr.match(regex);
  const identifiers: string[] = [];
  if (matchResult !== null) {
    for (let i: number = 0; i < matchResult.length; i++) {
      identifiers.push(matchResult[i].toLowerCase());
    }
  }

  let hasX: boolean = false;
  let hasY: boolean = false;
  for (let i: number = 0; i < identifiers.length; i++) {
    const id: string = identifiers[i];
    // 跳过已知函数名
    if (KNOWN_FUNCTIONS.indexOf(id) >= 0) continue;
    // 跳过已知常量
    if (KNOWN_CONSTANTS.indexOf(id) >= 0) continue;
    // 检查是否为 x 或 y
    if (id === 'x') hasX = true;
    if (id === 'y') hasY = true;
  }
  const result: VariableScanResult = { hasX: hasX, hasY: hasY };
  return result;
}

// ==================== 表达式拆分 ====================

/**
 * 在表达式中找到第一个关系运算符并拆分为 [左侧, 运算符, 右侧]。
 * 返回 null 表示无关系运算符。
 */
function splitAtRelational(expr: string): RelationalSplitResult | null {
  const match: RegExpMatchArray | null = expr.match(RELATIONAL_PATTERN);
  if (match === null || match.index === undefined) {
    return null;
  }
  const op: string = normalizeRelOp(match[0]);
  const left: string = expr.substring(0, match.index).trim();
  const right: string = expr.substring(match.index + match[0].length).trim();
  const result: RelationalSplitResult = { left: left, op: op, right: right };
  return result;
}

// ==================== 主分类器 ====================

export class ExprClassifier {

  /**
   * 对原始表达式进行分类，返回渲染模式与标准化信息。
   *
   * @param rawExpr 用户输入的原始表达式（可能含 y=, >, < 等关系符）
   * @returns 分类结果
   */
  static classify(rawExpr: string): ClassifyResult {
    const trimmed: string = rawExpr.trim();

    // 去除可能的 "y=" 前缀（用户输入 y=x^2 形式的显函数）
    let exprBody: string = trimmed;
    const yPrefixMatch: RegExpMatchArray | null = trimmed.match(/^[yY]\s*=\s*/);
    if (yPrefixMatch !== null && yPrefixMatch.index !== undefined) {
      exprBody = trimmed.substring(yPrefixMatch.index + yPrefixMatch[0].length).trim();
    }

    // Step 1: 检测关系运算符
    const split: RelationalSplitResult | null =
      splitAtRelational(exprBody);

    if (split !== null) {
      const normalized: string = split.left + '-(' + split.right + ')';
      const vars: VariableScanResult = scanVariables(exprBody);

      // 优先级 1：不等号
      if (split.op === '>' || split.op === '<' ||
        split.op === '>=' || split.op === '<=') {
        return {
          mode: RenderMode.INEQUALITY,
          rawExpr: trimmed,
          normalizedExpr: normalized,
          inequalityDir: split.op as InequalityDirection,
          hasX: vars.hasX,
          hasY: vars.hasY
        };
      }

      // 优先级 2：等号
      if (split.op === '=') {
        if (vars.hasX && vars.hasY) {
          return {
            mode: RenderMode.BIVARIATE_EQ,
            rawExpr: trimmed,
            normalizedExpr: normalized,
            hasX: true,
            hasY: true
          };
        }
        // 仅含 x 无 y 的等式（如 x^2=4）→ 退化为显函数（y=0 特殊线）
        // 但更合理的处理是：解方程 → 得到 x 的常数值，画竖直线
        // 当前阶段先按隐函数处理（F(x)=0 的等值线即零点）
        return {
          mode: RenderMode.IMPLICIT,
          rawExpr: trimmed,
          normalizedExpr: normalized,
          hasX: vars.hasX,
          hasY: false
        };
      }
    }

    // Step 2: 无关系运算符 → 检查变量
    const vars: VariableScanResult = scanVariables(exprBody);

    if (vars.hasX && vars.hasY) {
      // 优先级 3：同时含 x 和 y → 隐函数 F(x,y) = 0
      return {
        mode: RenderMode.IMPLICIT,
        rawExpr: trimmed,
        normalizedExpr: exprBody,
        hasX: true,
        hasY: true
      };
    }

    // 优先级 4：仅含单变量 → 显函数
    // 如果只有 y 没有 x（如 y^2），也按显函数处理（x 为自变量，但这里 y 不是自变量）
    // 实际上这种情况很少见，按显函数兜底
    return {
      mode: RenderMode.EXPLICIT,
      rawExpr: trimmed,
      normalizedExpr: exprBody,
      hasX: vars.hasX,
      hasY: vars.hasY
    };
  }
}
