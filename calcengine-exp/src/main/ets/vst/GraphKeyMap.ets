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
// vst/GraphKeyMap.ets
// 自研：图象模式键盘值 → MathField 命令的声明式映射表。
// 函数名沿用「显示名 → 序列化名」约定（asin/acos/atan/log10/log）。

/** 一个按键解析结果：命令名 + 参数；null 表示该键在图象模式不处理 */
export interface GraphKeySpec {
  command: string;
  args: string[];
}

const KEY_MAP: Record<string, GraphKeySpec> = {
  // ── 数字 / 小数点 ──
  '0': { command: 'insertText', args: ['0'] },
  '1': { command: 'insertText', args: ['1'] },
  '2': { command: 'insertText', args: ['2'] },
  '3': { command: 'insertText', args: ['3'] },
  '4': { command: 'insertText', args: ['4'] },
  '5': { command: 'insertText', args: ['5'] },
  '6': { command: 'insertText', args: ['6'] },
  '7': { command: 'insertText', args: ['7'] },
  '8': { command: 'insertText', args: ['8'] },
  '9': { command: 'insertText', args: ['9'] },
  '.': { command: 'insertText', args: ['.'] },

  // ── 变量 ──
  'x': { command: 'insertVar', args: ['x'] },
  'y': { command: 'insertVar', args: ['y'] },
  'z': { command: 'insertVar', args: ['z'] },
  't': { command: 'insertVar', args: ['t'] },

  // ── 常量 ──
  'e': { command: 'insertConst', args: ['e'] },
  '\\pi': { command: 'insertConst', args: ['π'] },

  // ── 括号 / 取整 / 绝对值 ──
  '(': { command: 'insertStruct', args: ['paren'] },
  'abs': { command: 'insertStruct', args: ['abs'] },
  '\\left|#?\\right|': { command: 'insertStruct', args: ['abs'] },
  'floor': { command: 'insertStruct', args: ['floor'] },
  '\\lfloor#?\\rfloor': { command: 'insertStruct', args: ['floor'] },
  'ceil': { command: 'insertStruct', args: ['ceil'] },
  '\\lceil#?\\rceil': { command: 'insertStruct', args: ['ceil'] },

  // ── 幂 / 根 ──
  'square': { command: 'makePowerFill', args: ['2'] },
  'power': { command: 'makePower', args: [] },
  'cube': { command: 'makePowerFill', args: ['3'] },
  'sqrt': { command: 'insertStruct', args: ['sqrt'] },
  'nthroot': { command: 'makeNthRoot', args: [] },
  'cbrt': { command: 'insertStruct', args: ['root'] },
  'pow_e_x': { command: 'insertPowBase', args: ['e'] },
  'pow_10_x': { command: 'insertPowBase', args: ['10'] },

  // ── 三角函数 / 反三角 / 双曲 / 对数 ──
  'sin': { command: 'insertFunc', args: ['sin'] },
  'cos': { command: 'insertFunc', args: ['cos'] },
  'tan': { command: 'insertFunc', args: ['tan'] },
  'arcsin': { command: 'insertFunc', args: ['asin'] },
  'arccos': { command: 'insertFunc', args: ['acos'] },
  'arctan': { command: 'insertFunc', args: ['atan'] },
  'sinh': { command: 'insertFunc', args: ['sinh'] },
  'cosh': { command: 'insertFunc', args: ['cosh'] },
  'tanh': { command: 'insertFunc', args: ['tanh'] },
  'csc': { command: 'insertFunc', args: ['csc'] },
  'sec': { command: 'insertFunc', args: ['sec'] },
  'cot': { command: 'insertFunc', args: ['cot'] },
  'ln': { command: 'insertFunc', args: ['ln'] },
  'lg': { command: 'insertFunc', args: ['log10'] },
  'log2': { command: 'insertFunc', args: ['log2'] },
  'logx': { command: 'insertLog', args: [] },

  // ── 二元运算符 ──
  '+': { command: 'insertOp', args: ['+'] },
  '-': { command: 'insertOp', args: ['-'] },
  '\\times': { command: 'insertOp', args: ['×'] },
  'divide': { command: 'makeFraction', args: [] },

  // ── 阶乘 ──
  '!': { command: 'insertPostfix', args: ['!'] },

  // ── 导航 / 编辑 ──
  'left': { command: 'moveLeft', args: [] },
  'right': { command: 'moveRight', args: [] },
  'up': { command: 'moveUp', args: [] },
  'down': { command: 'moveDown', args: [] },
  'backspace': { command: 'backspace', args: [] },
  'undo': { command: 'undo', args: [] },
  'redo': { command: 'redo', args: [] },

  // ── 关闭括号 ──
  ')': { command: 'closeParen', args: [] },

  // ── 关系运算符（等号 / 不等号）──
  '=': { command: 'insertOp', args: ['='] },
  '>': { command: 'insertOp', args: ['>'] },
  '<': { command: 'insertOp', args: ['<'] },
  '≥': { command: 'insertOp', args: ['≥'] },
  '≤': { command: 'insertOp', args: ['≤'] },
  '>=': { command: 'insertOp', args: ['≥'] },
  '<=': { command: 'insertOp', args: ['≤'] },
  '\\n': { command: 'checkExpr', args: [] },
  'agent': { command: 'noop', args: [] },
};

/** 将键盘 value 解析为 GraphKeySpec；未知值返回 null */
export function resolveGraphKey(value: string): GraphKeySpec | null {
  return KEY_MAP[value] ?? null;
}
