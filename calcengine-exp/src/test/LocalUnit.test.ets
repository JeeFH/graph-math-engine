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
 * calcengine-exp 本地单元测试
 * - parseLinear ↔ serializeLinear 往返幂等性
 * - simplify 化简规则（同底数因子合并为幂）
 * - TreeCursor 分支导航（resolveRow / resolveBranch）
 * - MathField 命令插入 / 删除与序列化
 */

import { describe, it, expect } from '@ohos/hypium';
import { VstFrac, VstNode, VstNum } from '../main/ets/vst/VstNodes';
import { resolveRow, resolveBranch, BRANCH_NUM, BRANCH_DEN } from '../main/ets/vst/TreeCursor';
import { MathField } from '../main/ets/vst/VstEditor';
import { serializeLinear } from '../main/ets/vst/VstSerializer';
import { simplify } from '../main/ets/vst/ExpressionSimplifier';
import { parseLinear } from '../main/ets/parser/ExprParser';

export default function exprrenderLocalUnitTest() {
  describe('ParseSerializeRoundTrip', () => {
    it('roundtrip_idempotent', 0, () => {
      const cases: string[] = ['x+1', 'x^2-3x+1', '1/x', 'sin(x)', 'sqrt(x)', '(x+1)(x-1)', '2π'];
      for (let i = 0; i < cases.length; i++) {
        const s1: string = serializeLinear(parseLinear(cases[i]));
        expect(s1.length > 0).assertTrue();
        // 二次往返必须收敛（序列化格式稳定）
        const s2: string = serializeLinear(parseLinear(s1));
        expect(s2).assertEqual(s1);
      }
    });

    it('empty_input', 0, () => {
      const row = parseLinear('');
      expect(row.children.length).assertEqual(0);
    });
  });

  describe('SimplifyRules', () => {
    it('same_base_factors_merge_to_power', 0, () => {
      // x·x 化简后应与 x^2 的 VST 序列化一致
      const merged: string = serializeLinear(simplify(parseLinear('x*x')));
      const direct: string = serializeLinear(parseLinear('x^2'));
      expect(merged).assertEqual(direct);
    });
  });

  describe('TreeCursor', () => {
    it('resolve_frac_branches', 0, () => {
      const row = parseLinear('1/2');
      expect(row.children.length).assertEqual(1);
      const frac: VstNode = row.children[0];
      expect(frac instanceof VstFrac).assertTrue();
      const num: VstNode[] | undefined = resolveBranch(frac, BRANCH_NUM);
      const den: VstNode[] | undefined = resolveBranch(frac, BRANCH_DEN);
      expect(num !== undefined).assertTrue();
      expect(den !== undefined).assertTrue();
      if (num !== undefined && den !== undefined) {
        expect(num.length).assertEqual(1);
        expect(den.length).assertEqual(1);
        expect(num[0] instanceof VstNum).assertTrue();
        expect(den[0] instanceof VstNum).assertTrue();
      }
      // resolveRow 走路径 [childIdx=0, branch=NUM]
      const viaPath: VstNode[] = resolveRow(row, [0, BRANCH_NUM]);
      expect(viaPath.length).assertEqual(1);
    });
  });

  describe('MathFieldCommands', () => {
    it('insert_and_serialize', 0, () => {
      const field: MathField = new MathField();
      field.execute('insertVar', 'x');
      field.execute('insertOp', '+');
      field.execute('insertText', '1');
      expect(field.serialize()).assertEqual('x+1');
    });

    it('backspace_removes_last', 0, () => {
      const field: MathField = new MathField();
      field.execute('insertVar', 'x');
      field.execute('insertOp', '+');
      field.execute('insertText', '1');
      field.execute('backspace');
      const s: string = field.serialize();
      expect(s.indexOf('1') < 0).assertTrue();
      expect(s.indexOf('x') >= 0).assertTrue();
    });
  });
}
