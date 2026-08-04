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
 * graph 本地单元测试（纯逻辑层，零 UI 依赖）：
 * - ExprClassifier：四类表达式分类（显函数/隐函数/不等式/二元方程）
 * - FunctionEvaluator：求值精度（弧度/角度模式、隐式乘法、非法表达式）
 * - GlobalAnalyzer：零点/极值/对称性/周期/渐近线
 */

import { describe, it, expect } from '@ohos/hypium';
import { ExprClassifier, type ClassifyResult } from '../main/ets/engine/ExprClassifier';
import { RenderMode } from '../main/ets/engine/IRenderer';
import { FunctionEvaluator } from '../main/ets/engine/FunctionEvaluator';
import { GlobalAnalyzer, type GlobalAnalysisResult } from '../main/ets/engine/GlobalAnalyzer';

const EPS: number = 1e-6;

function near(a: number, b: number, tol: number = EPS): boolean {
  return Math.abs(a - b) <= tol;
}

export default function graphLocalUnitTest() {
  describe('ExprClassifierTest', () => {
    it('explicit_mode', 0, () => {
      const r1: ClassifyResult = ExprClassifier.classify('sin(x)');
      expect(r1.mode).assertEqual(RenderMode.EXPLICIT);
      expect(r1.hasX).assertTrue();
      expect(r1.hasY).assertFalse();
      // y= 前缀剥离后仍是显函数
      const r2: ClassifyResult = ExprClassifier.classify('y=x^2');
      expect(r2.mode).assertEqual(RenderMode.EXPLICIT);
      expect(r2.normalizedExpr).assertEqual('x^2');
    });

    it('implicit_mode', 0, () => {
      const r: ClassifyResult = ExprClassifier.classify('x^2+y^2-4');
      expect(r.mode).assertEqual(RenderMode.IMPLICIT);
      expect(r.hasX).assertTrue();
      expect(r.hasY).assertTrue();
    });

    it('inequality_mode', 0, () => {
      const r1: ClassifyResult = ExprClassifier.classify('y>x^2');
      expect(r1.mode).assertEqual(RenderMode.INEQUALITY);
      expect(r1.inequalityDir).assertEqual('>');
      expect(r1.normalizedExpr).assertEqual('y-(x^2)');
      const r2: ClassifyResult = ExprClassifier.classify('x+y<=1');
      expect(r2.mode).assertEqual(RenderMode.INEQUALITY);
      expect(r2.inequalityDir).assertEqual('<=');
    });

    it('bivariate_eq_mode', 0, () => {
      const r: ClassifyResult = ExprClassifier.classify('x^2+y^2=4');
      expect(r.mode).assertEqual(RenderMode.BIVARIATE_EQ);
      expect(r.normalizedExpr).assertEqual('x^2+y^2-(4)');
      expect(r.hasX).assertTrue();
      expect(r.hasY).assertTrue();
    });

    it('single_var_equation_falls_to_implicit', 0, () => {
      // 仅含 x 的等式（无 y）→ 隐函数兜底
      const r: ClassifyResult = ExprClassifier.classify('x^2=4');
      expect(r.mode).assertEqual(RenderMode.IMPLICIT);
      expect(r.hasY).assertFalse();
    });
  });

  describe('FunctionEvaluatorTest', () => {
    it('basic_evaluation', 0, () => {
      expect(new FunctionEvaluator('x^2').evaluate(3)).assertEqual(9);
      expect(new FunctionEvaluator('2x+1').evaluate(3)).assertEqual(7);
      expect(new FunctionEvaluator('sqrt(x)').evaluate(4)).assertEqual(2);
      expect(new FunctionEvaluator('abs(x)').evaluate(-5)).assertEqual(5);
    });

    it('implicit_multiplication', 0, () => {
      expect(new FunctionEvaluator('2x').evaluate(3)).assertEqual(6);
      expect(new FunctionEvaluator('xsin(x)').evaluate(0)).assertEqual(0);
    });

    it('radian_vs_degree', 0, () => {
      // 弧度模式（默认）
      expect(near(new FunctionEvaluator('sin(x)').evaluate(Math.PI / 2), 1)).assertTrue();
      // 角度模式
      expect(near(new FunctionEvaluator('sin(x)', true).evaluate(90), 1)).assertTrue();
      expect(near(new FunctionEvaluator('cos(x)', true).evaluate(60), 0.5)).assertTrue();
    });

    it('invalid_expr_throws', 0, () => {
      let caught: boolean = false;
      try {
        new FunctionEvaluator('x+').evaluate(1);
      } catch (e) {
        caught = true;
      }
      expect(caught).assertTrue();
    });
  });

  describe('GlobalAnalyzerTest', () => {
    it('quadratic_zeros_extrema_symmetry', 0, () => {
      const r: GlobalAnalysisResult | null = GlobalAnalyzer.analyzeGlobal('x^2-1', false);
      expect(r != null).assertTrue();
      if (r == null) {
        return;
      }
      // 零点含 ±1
      let hasPos1: boolean = false;
      let hasNeg1: boolean = false;
      for (const z of r.zeros) {
        if (near(z.x, 1, 1e-3)) {
          hasPos1 = true;
        }
        if (near(z.x, -1, 1e-3)) {
          hasNeg1 = true;
        }
      }
      expect(hasPos1).assertTrue();
      expect(hasNeg1).assertTrue();
      // 极小值点 ≈ (0, -1)
      let hasMin: boolean = false;
      for (const ex of r.extrema) {
        if (ex.kind === 'min' && near(ex.x, 0, 1e-3) && near(ex.y, -1, 1e-3)) {
          hasMin = true;
        }
      }
      expect(hasMin).assertTrue();
      // 偶函数
      expect(r.symmetry).assertEqual('even');
      // 非周期
      expect(r.period == null).assertTrue();
    });

    it('sine_period_and_zeros', 0, () => {
      const r: GlobalAnalysisResult | null = GlobalAnalyzer.analyzeGlobal('sin(x)', false);
      expect(r != null).assertTrue();
      if (r == null) {
        return;
      }
      // 最小正周期 ≈ 2π
      expect(r.period != null).assertTrue();
      if (r.period != null) {
        expect(near(r.period, 2 * Math.PI, 0.2)).assertTrue();
      }
      // 零点含 x=0
      let hasZero0: boolean = false;
      for (const z of r.zeros) {
        if (near(z.x, 0, 1e-3)) {
          hasZero0 = true;
        }
      }
      expect(hasZero0).assertTrue();
      // 奇函数
      expect(r.symmetry).assertEqual('odd');
    });

    it('reciprocal_asymptotes_no_zeros', 0, () => {
      const r: GlobalAnalysisResult | null = GlobalAnalyzer.analyzeGlobal('1/x', false);
      expect(r != null).assertTrue();
      if (r == null) {
        return;
      }
      // 无零点
      expect(r.zeros.length).assertEqual(0);
      // 垂直渐近线 x=0
      let hasPole0: boolean = false;
      for (const v of r.asymptotes.vertical) {
        if (near(v, 0, 1e-3)) {
          hasPole0 = true;
        }
      }
      expect(hasPole0).assertTrue();
      // 水平渐近线 y=0
      let hasHor0: boolean = false;
      for (const h of r.asymptotes.horizontal) {
        if (near(h.y, 0, 1e-3)) {
          hasHor0 = true;
        }
      }
      expect(hasHor0).assertTrue();
    });
  });
}
