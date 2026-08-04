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

/**
 * mathkit/Tokenizer.ets
 *
 * 表达式词法分词器（纯静态工具类，零 UI 依赖）。
 * 将线性表达式字符串切分为词法单元（token），支持：
 * - 一元负号与二元减号区分（-3 → '-3'，1-3 → '1','-','3'）
 * - 科学计数法（1.2e3 / 1.2e-3），并避免吞掉常量 e（如 2e^x）
 * - 字母标识符（变量 / 函数名，含下划线与数字）
 * - Unicode 常量符号（基于 ConstantLib 最长匹配，如 π / ε₀）
 * - 运算符、括号、绝对值 |、取整 ⌈⌉⌊⌋、占位符 ?
 */

import { ConstantLib } from './ConstantLib';

export interface IdentifierPosition {
  identifier: string;
  start: number;
  end: number;
}

/** 分词位置 */
export interface TokenPosition {
  token: string;
  start: number;
}

export default class Tokenizer {
  public static isDigit(ch: string): boolean {
    return ch >= '0' && ch <= '9';
  }

  public static isLetter(ch: string): boolean {
    return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z');
  }

  public static isOperatorChar(ch: string): boolean {
    return ch === '+' || ch === '-' || ch === '*' || ch === '×' ||
      ch === '/' || ch === '÷' || ch === '%' || ch === '^' || ch === '!';
  }

  /** 判断 pos 处的 'e'/'E' 是否构成科学计数法指数：其后须跟（可选正负号及）至少一位数字。
   *  避免把 "2e^x"（2·e^x）/ "x^2e^x"（x²·eˣ）中紧跟数字的 e 误吞为科学计数法开头，
   *  产生 "2e" 这类无法识别的坏 token（e 作为常量应与前面的数字作隐式乘法）。 */
  private static isScientificExponentAhead(expression: string, pos: number): boolean {
    let j: number = pos + 1;
    if (j < expression.length && (expression[j] === '+' || expression[j] === '-')) {
      j++;
    }
    return j < expression.length && Tokenizer.isDigit(expression[j]);
  }

  /**
   * 将表达式拆分为词法单元，支持科学计数法（如 1.2e3）
   */
  public static tokenize(expression: string): string[] {
    // 初始化常数库
    ConstantLib.initialize();
    
    const tokens: string[] = [];
    let i = 0;
    const len = expression.length;

    while (i < len) {
      const ch = expression[i];

      if (ch === ' ') {
        i++;
        continue;
      }

      // 处理负数字（一元负号+数字）
      if (ch === '-') {
        // 判断是否为一元负（开头、左括号后、运算符后）
        const isUnary = (i === 0) ||
          (expression[i-1] === '(') ||
          (Tokenizer.isOperatorChar(expression[i-1]) && expression[i-1] !== ')');
        if (isUnary) {
          // 读取负数，包括可能的科学计数法
          let num = '-';
          i++; // 跳过负号
          // 读取数字部分（整数和小数）
          while (i < len && (Tokenizer.isDigit(expression[i]) || expression[i] === '.')) {
            num += expression[i];
            i++;
          }
          // 检查科学计数法（仅当 e 后跟指数数字时才消费，避免吞掉 2e^x 中的常量 e）
          if (i < len && (expression[i].toLowerCase() === 'e') && Tokenizer.isScientificExponentAhead(expression, i)) {
            num += expression[i];
            i++;
            // 允许指数部分的正负号
            if (i < len && (expression[i] === '+' || expression[i] === '-')) {
              num += expression[i];
              i++;
            }
            // 读取指数数字
            while (i < len && Tokenizer.isDigit(expression[i])) {
              num += expression[i];
              i++;
            }
          }
          tokens.push(num);
          continue;
        } else {
          // 二元运算符
          tokens.push('-');
          i++;
          continue;
        }
      }

      // 数字（正数）
      if (Tokenizer.isDigit(ch) || ch === '.') {
        let num = '';
        while (i < len && (Tokenizer.isDigit(expression[i]) || expression[i] === '.')) {
          num += expression[i];
          i++;
        }
        // 科学计数法（仅当 e 后跟指数数字时才消费，避免吞掉 x^2e^x / 2e^x 中的常量 e）
        if (i < len && (expression[i].toLowerCase() === 'e') && Tokenizer.isScientificExponentAhead(expression, i)) {
          num += expression[i];
          i++;
          if (i < len && (expression[i] === '+' || expression[i] === '-')) {
            num += expression[i];
            i++;
          }
          while (i < len && Tokenizer.isDigit(expression[i])) {
            num += expression[i];
            i++;
          }
        }
        tokens.push(num);
        continue;
      }

      // 字母（函数名，包含下划线和数字）
      // 如果函数名后紧跟 (，合并为一个 token（如 log2(, sin(）
      if (Tokenizer.isLetter(ch)) {
        let name = '';
        while (i < len && (Tokenizer.isLetter(expression[i]) || expression[i] === '_' || Tokenizer.isDigit(expression[i]))) {
          name += expression[i];
          i++;
        }
        tokens.push(name);
        continue;
      }

      // 常数符号识别（支持 Unicode 和复合符号）
      // 检查当前字符是否为常数符号的开头
      if (Tokenizer.isConstantSymbolStart(ch)) {
        // 尝试匹配最长的常数符号
        const constantSymbol = Tokenizer.matchConstantSymbol(expression, i);
        if (constantSymbol) {
          tokens.push(constantSymbol);
          i += constantSymbol.length;
          continue;
        }
      }
      // 注意：e 是 ASCII 字母，已被上方字母分支正确处理（如 exp( → 'exp'，e×3 → 'e'）

      // 运算符、括号
      if (Tokenizer.isOperatorChar(ch) || ch === '(' || ch === ')' || ch === '?' ||
          ch === '|' || ch === '⌈' || ch === '⌉' || ch === '⌊' || ch === '⌋') {
        tokens.push(ch);
        i++;
        continue;
      }

      i++; // 忽略非法字符
    }
    return tokens;
  }

  /** Token 及其在原始字符串中的起始位置 */
  public static tokenizeWithPositions(expression: string): TokenPosition[] {
    ConstantLib.initialize();
    const result: TokenPosition[] = [];
    let i = 0;
    const len = expression.length;
    while (i < len) {
      const ch = expression[i];
      const tokenStart = i;
      if (ch === ' ') {
        i++;
        continue;
      }
      // 一元负号+数字（如 -3 → 整体保留）
      if (ch === '-') {
        const isUnary = (i === 0) || (expression[i - 1] === '(') ||
          (Tokenizer.isOperatorChar(expression[i - 1]) && expression[i - 1] !== ')');
        if (isUnary) {
          // 判断后续是否为数字/小数点
          if (i + 1 < len && (Tokenizer.isDigit(expression[i + 1]) || expression[i + 1] === '.')) {
            // 尝���提取完整数字（含科学计数法）
            i++;
            while (i < len && (Tokenizer.isDigit(expression[i]) || expression[i] === '.')) i++;
            if (i < len && (expression[i] === 'e' || expression[i] === 'E')) {
              i++;
              if (i < len && (expression[i] === '+' || expression[i] === '-')) i++;
              while (i < len && Tokenizer.isDigit(expression[i])) i++;
            }
            result.push({ token: expression.substring(tokenStart, i), start: tokenStart } as TokenPosition);
            continue;
          }
          // 一元负但后非数字：当作独立运算符
          result.push({ token: '-', start: tokenStart } as TokenPosition);
          i++;
          continue;
        }
        // 二元减
        result.push({ token: '-', start: tokenStart });
        i++;
        continue;
      }
      // 数字（含小数点和科学计数法）
      if (Tokenizer.isDigit(ch) || ch === '.') {
        while (i < len && (Tokenizer.isDigit(expression[i]) || expression[i] === '.')) i++;
        if (i < len && (expression[i] === 'e' || expression[i] === 'E')) {
          i++;
          if (i < len && (expression[i] === '+' || expression[i] === '-')) i++;
          while (i < len && Tokenizer.isDigit(expression[i])) i++;
        }
        result.push({ token: expression.substring(tokenStart, i), start: tokenStart });
        continue;
      }
      // 字母 → 标识符（变量/函数名）
      if (Tokenizer.isLetter(ch)) {
        while (i < len && Tokenizer.isLetter(expression[i])) i++;
        result.push({ token: expression.substring(tokenStart, i), start: tokenStart });
        continue;
      }
      // 常数符号
      if (Tokenizer.isConstantSymbolStart(ch)) {
        const constantSymbol = Tokenizer.matchConstantSymbol(expression, i);
        if (constantSymbol) {
          result.push({ token: constantSymbol, start: tokenStart });
          i += constantSymbol.length;
          continue;
        }
      }
      // 运算符、括号、取整符号、占位符 ? 
      if (Tokenizer.isOperatorChar(ch) || ch === '(' || ch === ')' || ch === '?' ||
          ch === '|' || ch === '⌈' || ch === '⌉' || ch === '⌊' || ch === '⌋') {
        result.push({ token: ch, start: tokenStart } as TokenPosition);
        i++;
        continue;
      }
      i++; // 忽略非法字符
    }
    return result;
  }

  public static getIdentifierAtPosition(text: string, pos: number): IdentifierPosition | null {
    if (pos < 0 || pos > text.length) return null;
    let start = pos;
    while (start > 0 && (Tokenizer.isLetter(text[start - 1]) || text[start - 1] === '_' || Tokenizer.isDigit(text[start - 1]))) start--;
    let end = pos;
    while (end < text.length && (Tokenizer.isLetter(text[end]) || text[end] === '_' || Tokenizer.isDigit(text[end]))) end++;
    if (start < end) {
      return { identifier: text.substring(start, end), start, end };
    }
    return null;
  }

  public static validateTokens(tokens: string[]): boolean {
    if (tokens.length === 0) return false;
    const first = tokens[0];
    const last = tokens[tokens.length - 1];
    const invalidStart = ['*', '/', '^', '%', '!', ')'];
    const invalidEnd = ['+', '-', '*', '/', '^', '(', ','];
    if (invalidStart.includes(first) || invalidEnd.includes(last)) return false;

    let bracketCount = 0;
    for (const t of tokens) {
      if (t === '(') bracketCount++;
      else if (t === ')') {
        bracketCount--;
        if (bracketCount < 0) return false;
      }
    }
    return bracketCount === 0;
  }

  public static isValidNumberToken(token: string): boolean {
    const num = parseFloat(token);
    if (isNaN(num)) return false;
    // 检查多个小数点（科学计数法允许小数点，但只应有一个）
    const dotCount = (token.match(/\./g) || []).length;
    const eCount = (token.match(/[eE]/g) || []).length;
    return dotCount <= 1 && eCount <= 1;
  }

  /**
   * 判断字符是否为常数符号的开头
   * 常数符号可以是 Unicode 字符或复合符号（如 ε₀）
   */
  public static isConstantSymbolStart(ch: string): boolean {
    // 检查是否为已知常数符号的开头
    const allSymbols = ConstantLib.getAllSymbols();
    
    // 检查是否有常数符号以当前字符开头
    for (const symbol of allSymbols) {
      if (symbol.startsWith(ch)) {
        return true;
      }
    }
    
    return false;
  }

  /**
   * 从指定位置开始匹配最长的常数符号
   */
  public static matchConstantSymbol(expression: string, startPos: number): string | null {
    const allSymbols = ConstantLib.getAllSymbols();
    let matchedSymbol: string | null = null;
    
    // 按长度从长到短排序，优先匹配长符号
    const sortedSymbols = allSymbols.sort((a, b) => b.length - a.length);
    
    for (const symbol of sortedSymbols) {
      const endPos = startPos + symbol.length;
      if (endPos <= expression.length) {
        const substring = expression.substring(startPos, endPos);
        if (substring === symbol) {
          matchedSymbol = symbol;
          break;
        }
      }
    }
    
    return matchedSymbol;
  }
}
