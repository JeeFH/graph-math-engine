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
 * calcengine-core 本地单元测试：Tokenizer 分词边界
 * - 一元负号 / 二元减号区分
 * - 科学计数法（含负指数）与常量 e 不误吞
 * - 常量符号（π）与标识符
 * - tokenizeWithPositions 位置信息
 */

import { describe, it, expect } from '@ohos/hypium';
import Tokenizer, { type TokenPosition, type IdentifierPosition } from '../main/ets/math/Tokenizer';

function join(tokens: string[]): string {
  return JSON.stringify(tokens);
}

export default function mathkitLocalUnitTest() {
  describe('TokenizerTest', () => {
    it('unary_minus_vs_binary_minus', 0, () => {
      expect(join(Tokenizer.tokenize('-3'))).assertEqual(join(['-3']));
      expect(join(Tokenizer.tokenize('1-3'))).assertEqual(join(['1', '-', '3']));
      expect(join(Tokenizer.tokenize('(-2)'))).assertEqual(join(['(', '-2', ')']));
      expect(join(Tokenizer.tokenize('2*-3'))).assertEqual(join(['2', '*', '-3']));
    });

    it('scientific_notation', 0, () => {
      expect(join(Tokenizer.tokenize('1.2e3'))).assertEqual(join(['1.2e3']));
      expect(join(Tokenizer.tokenize('1.2e-3'))).assertEqual(join(['1.2e-3']));
      expect(join(Tokenizer.tokenize('5E+2'))).assertEqual(join(['5E+2']));
    });

    it('constant_e_not_swallowed', 0, () => {
      // e 后非数字 → 常量 e，与前面数字构成隐式乘法，不得吞成 '2e'
      expect(join(Tokenizer.tokenize('2e^x'))).assertEqual(join(['2', 'e', '^', 'x']));
      // e 后跟数字 → 科学计数法
      expect(join(Tokenizer.tokenize('2e3'))).assertEqual(join(['2e3']));
    });

    it('identifiers_and_constants', 0, () => {
      expect(join(Tokenizer.tokenize('sin(x)'))).assertEqual(join(['sin', '(', 'x', ')']));
      expect(join(Tokenizer.tokenize('log2(x)'))).assertEqual(join(['log2', '(', 'x', ')']));
      expect(join(Tokenizer.tokenize('2π'))).assertEqual(join(['2', 'π']));
    });

    it('tokenize_with_positions', 0, () => {
      const pos: TokenPosition[] = Tokenizer.tokenizeWithPositions('x+1');
      expect(pos.length).assertEqual(3);
      expect(pos[0].token).assertEqual('x');
      expect(pos[0].start).assertEqual(0);
      expect(pos[1].token).assertEqual('+');
      expect(pos[1].start).assertEqual(1);
      expect(pos[2].token).assertEqual('1');
      expect(pos[2].start).assertEqual(2);
    });

    it('identifier_at_position', 0, () => {
      const hit: IdentifierPosition | null = Tokenizer.getIdentifierAtPosition('sin(x)', 1);
      expect(hit != null).assertTrue();
      if (hit != null) {
        expect(hit.identifier).assertEqual('sin');
        expect(hit.start).assertEqual(0);
        expect(hit.end).assertEqual(3);
      }
    });
  });
}
