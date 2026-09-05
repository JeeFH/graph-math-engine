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
 * 图象渲染缺陷修复的回归测试。
 *
 * 覆盖两个缺陷类：
 * 类 A（跨层词表不对称 + 静默失败）
 *   - ExprNormalizer：Unicode 乘号族、全角标点、n 次根模板改写
 *   - EngineFunctions：cbrt、负底数奇分母有理指数的实值根
 *   - 求值器：`2·3x` 可求值、畸形结构在解析期显式失败而非静默产出全 NaN
 * 类 B（提取预算缺失 + 帧路径契约违规）
 *   - extractVisible 绝不触发提取（崩溃栈的直接回归点）
 *   - sin(x·y) 的分帧提取：单轮泵入耗时受控、总轮数有限、段数不越硬上限
 */

import { describe, it, expect } from '@ohos/hypium';
import { ExprNormalizer } from '../main/ets/engine/ExprNormalizer';
import { EngineFunctions } from '../main/ets/engine/EngineFunctions';
import { FunctionEvaluator } from '../main/ets/engine/FunctionEvaluator';
import { BivariateEvaluator } from '../main/ets/engine/BivariateEvaluator';
import { ImplicitRenderer } from '../main/ets/engine/ImplicitRenderer';
import { ExtractionBudget, SEGMENT_HARD_CAP } from '../main/ets/engine/ExtractionBudget';
import { RenderData } from '../main/ets/engine/IRenderer';
import { Viewport } from '../main/ets/math/GraphMath';

const EPS: number = 1e-6;

function near(a: number, b: number, tol: number = EPS): boolean {
  return Math.abs(a - b) <= tol;
}

/** 测试视口：[-5,5]²，像素世界间距 0.02（约 500px 宽的画布） */
function testViewport(): Viewport {
  const vp: Viewport = { xMin: -5, xMax: 5, yMin: -5, yMax: 5 };
  return vp;
}

const TEST_PW_DX: number = 10 / 500;

/** 把网格填满（分块构建），返回填充轮数 */
function fillGrid(r: ImplicitRenderer, vp: Viewport): number {
  r.beginBuild(vp, TEST_PW_DX);
  let rounds: number = 0;
  while (!r.buildChunk(64)) {
    rounds++;
    if (rounds > 200) {
      break;
    }
  }
  return rounds;
}

export default function engineFixesTest() {

  // ==================== 类 A：归一化 ====================

  describe('ExprNormalizerTest', () => {
    it('unicode_multiplication_family', 0, () => {
      // '·' 是本缺陷的主入口：上游化简器主动产出它，而词法器白名单不含它
      expect(ExprNormalizer.normalize('2·3x')).assertEqual('2*3x');
      expect(ExprNormalizer.normalize('2∙3x')).assertEqual('2*3x');
      expect(ExprNormalizer.normalize('2⋅3x')).assertEqual('2*3x');
      expect(ExprNormalizer.normalize('2•3x')).assertEqual('2*3x');
      expect(ExprNormalizer.normalize('2∗3x')).assertEqual('2*3x');
    });

    it('fullwidth_punctuation', 0, () => {
      // sin（xy）：全角括号曾被静默丢弃，使表达式退化为 sin·x·y 之类的畸形结构
      expect(ExprNormalizer.normalize('sin（xy）')).assertEqual('sin(xy)');
      expect(ExprNormalizer.normalize('ｘ＾２')).assertEqual('x^2');
      expect(ExprNormalizer.normalize('２ｘ')).assertEqual('2x');
    });

    it('root_template_rewrite', 0, () => {
      // 上游序列化器对 n 次根输出 root(index, body)，而求值器只支持一元函数
      expect(ExprNormalizer.normalize('root(2,x)')).assertEqual('sqrt(x)');
      expect(ExprNormalizer.normalize('root(3,x)')).assertEqual('cbrt(x)');
      expect(ExprNormalizer.normalize('root(5,x)')).assertEqual('(x)^(1/(5))');
      // 嵌套：每轮迭代深度严格递减
      expect(ExprNormalizer.normalize('root(3,root(3,x))')).assertEqual('cbrt(cbrt(x))');
      // 带表达式体
      expect(ExprNormalizer.normalize('root(3,x+1)')).assertEqual('cbrt(x+1)');
    });

    it('does_not_touch_similar_identifiers', 0, () => {
      // sqrt / cbrt 内部含 'rt(' 但不含带词边界的 'root('
      expect(ExprNormalizer.normalize('sqrt(x)')).assertEqual('sqrt(x)');
      expect(ExprNormalizer.normalize('cbrt(x)')).assertEqual('cbrt(x)');
    });

    it('idempotent', 0, () => {
      const once: string = ExprNormalizer.normalize('2·3x+root(3,y)');
      const twice: string = ExprNormalizer.normalize(once);
      expect(twice).assertEqual(once);
    });
  });

  // ==================== 类 A：函数表与实数域根 ====================

  describe('EngineFunctionsTest', () => {
    it('cbrt_registered_and_odd', 0, () => {
      expect(EngineFunctions.isFunctionName('cbrt')).assertTrue();
      expect(EngineFunctions.isFunctionName('CBRT')).assertTrue();
      // root 不是函数名：它由 ExprNormalizer 在词法前改写掉
      expect(EngineFunctions.isFunctionName('root')).assertFalse();
      expect(EngineFunctions.names().indexOf('cbrt') >= 0).assertTrue();
      expect(EngineFunctions.apply('cbrt', -8, false)).assertEqual(-2);
      expect(EngineFunctions.apply('cbrt', 27, false)).assertEqual(3);
    });

    it('rational_reconstruction', 0, () => {
      // 连分数渐近分数天然最简：0.5 → 1/2（偶分母），不得误判为 2/2
      const half: [number, number] | null = EngineFunctions.toRational(0.5);
      expect(half != null).assertTrue();
      if (half != null) {
        expect(half[0]).assertEqual(1);
        expect(half[1]).assertEqual(2);
      }
      const third: [number, number] | null = EngineFunctions.toRational(1 / 3);
      expect(third != null).assertTrue();
      if (third != null) {
        expect(third[0]).assertEqual(1);
        expect(third[1]).assertEqual(3);
      }
      const twoThirds: [number, number] | null = EngineFunctions.toRational(2 / 3);
      expect(twoThirds != null).assertTrue();
      if (twoThirds != null) {
        expect(twoThirds[0]).assertEqual(2);
        expect(twoThirds[1]).assertEqual(3);
      }
      // 无理指数不是小分母有理数
      expect(EngineFunctions.toRational(Math.PI) == null).assertTrue();
    });

    it('pow_real_negative_base', 0, () => {
      // 缺陷现象：x^(1/3) 在 x<0 恒 NaN → 左半平面整片空白
      expect(near(EngineFunctions.powReal(-8, 1 / 3), -2, 1e-9)).assertTrue();
      expect(near(EngineFunctions.powReal(-8, 2 / 3), 4, 1e-9)).assertTrue();
      expect(near(EngineFunctions.powReal(-8, -1 / 3), -0.5, 1e-9)).assertTrue();
      // 整数指数仍走 Math.pow
      expect(EngineFunctions.powReal(-2, 3)).assertEqual(-8);
      expect(EngineFunctions.powReal(-2, 2)).assertEqual(4);
      // 正底数不受影响
      expect(EngineFunctions.powReal(8, 1 / 3)).assertEqual(2);
      expect(EngineFunctions.powReal(2, 10)).assertEqual(1024);
    });

    it('pow_real_keeps_nan_for_even_denominator', 0, () => {
      // 负底数的偶次根在实数域无解，必须保持 NaN（不得返回复数模）
      expect(Number.isNaN(EngineFunctions.powReal(-4, 0.5))).assertTrue();
      expect(Number.isNaN(EngineFunctions.powReal(-4, 1 / 4))).assertTrue();
      // 无理指数同样无实值
      expect(Number.isNaN(EngineFunctions.powReal(-2, Math.PI))).assertTrue();
      // 溢出归一为 NaN
      expect(Number.isNaN(EngineFunctions.powReal(1e300, 2))).assertTrue();
    });
  });

  // ==================== 类 A：求值器端到端 ====================

  describe('EvaluatorNormalizationTest', () => {
    it('middle_dot_expression_evaluates', 0, () => {
      // 修复前：'2·3x' → 词法器丢弃 '·' → [2,3,x] → 栈残留 → 恒 NaN 且 isValid=true
      const ev: FunctionEvaluator = new FunctionEvaluator('2·3x');
      expect(ev.isValid).assertTrue();
      expect(ev.evaluate(5)).assertEqual(30);
      expect(ev.evaluate(-2)).assertEqual(-12);
    });

    it('cube_root_renders_both_half_planes', 0, () => {
      // 三条录入路径都必须给出完整的奇函数曲线
      const viaFunc: FunctionEvaluator = new FunctionEvaluator('cbrt(x)');
      expect(viaFunc.isValid).assertTrue();
      expect(viaFunc.evaluate(-8)).assertEqual(-2);

      const viaTemplate: FunctionEvaluator = new FunctionEvaluator('root(3,x)');
      expect(viaTemplate.isValid).assertTrue();
      expect(viaTemplate.evaluate(-27)).assertEqual(-3);

      const viaPow: FunctionEvaluator = new FunctionEvaluator('x^(1/3)');
      expect(viaPow.isValid).assertTrue();
      expect(near(viaPow.evaluate(-8), -2, 1e-9)).assertTrue();
      // 奇对称：f(-x) = -f(x)
      for (const x of [0.5, 1, 2.5, 7.3]) {
        expect(near(viaPow.evaluate(-x), -viaPow.evaluate(x), 1e-9)).assertTrue();
      }
    });

    it('sqrt_of_negative_stays_nan', 0, () => {
      const ev: FunctionEvaluator = new FunctionEvaluator('sqrt(x)');
      expect(Number.isNaN(ev.evaluate(-4))).assertTrue();
      expect(ev.evaluate(9)).assertEqual(3);
    });

    it('malformed_structure_fails_explicitly', 0, () => {
      // 静默失败 → 显式失败：相邻数值（词法器丢弃非法字符后的典型残留）
      const ev: FunctionEvaluator = new FunctionEvaluator('2 3 x');
      expect(ev.isValid).assertFalse();
      expect(ev.error != null).assertTrue();

      const bev: BivariateEvaluator = new BivariateEvaluator('2 3');
      expect(bev.isValid).assertFalse();
    });

    it('bivariate_normalization', 0, () => {
      // sin（xy）：全角括号 + 隐式乘法
      const full: BivariateEvaluator = new BivariateEvaluator('sin（xy）');
      expect(full.isValid).assertTrue();
      expect(near(full.evaluate(Math.PI / 2, 1), 1, 1e-9)).assertTrue();

      const dot: BivariateEvaluator = new BivariateEvaluator('2·3x*y');
      expect(dot.isValid).assertTrue();
      expect(dot.evaluate(1, 1)).assertEqual(6);

      const cbrt2: BivariateEvaluator = new BivariateEvaluator('cbrt(x)+y');
      expect(cbrt2.isValid).assertTrue();
      expect(cbrt2.evaluate(-8, 0)).assertEqual(-2);
    });

    it('evaluate_never_throws_on_domain_errors', 0, () => {
      // 热路径契约：域错误返回 NaN，不抛异常（抛异常会构建栈追踪并阻塞主线程）
      const ev: FunctionEvaluator = new FunctionEvaluator('1/x + sqrt(x) + x^(1/2)');
      let threw: boolean = false;
      try {
        ev.evaluate(0);
        ev.evaluate(-1);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertFalse();
      expect(Number.isNaN(ev.evaluate(-1))).assertTrue();
    });
  });

  // ==================== 类 B：帧路径契约与提取预算 ====================

  describe('ExtractionPipelineTest', () => {
    it('extract_visible_never_triggers_extraction', 0, () => {
      // 崩溃栈的直接回归点：网格就绪但提取未开始时，extractVisible 必须立即返回，
      // 不得在帧路径上同步跑完整网格的 AMR 递归。
      const vp: Viewport = testViewport();
      const r: ImplicitRenderer = new ImplicitRenderer(1, 'x^2+y^2-4', false);
      fillGrid(r, vp);
      expect(r.isGridReady()).assertTrue();
      expect(r.hasPendingExtraction()).assertTrue();

      const t0: number = Date.now();
      const data: RenderData = r.extractVisible(vp);
      const elapsed: number = Date.now() - t0;
      // 帧路径只做查询：即使给足宽松阈值，也远低于曾经动辄数秒的同步重提取
      expect(elapsed < 100).assertTrue();
      const segs = data.contourSegments;
      expect(segs == null || segs.length === 0).assertTrue();
      // 查询不得消耗提取进度
      expect(r.hasPendingExtraction()).assertTrue();
      r.dispose();
    });

    it('smooth_curve_completes_with_few_pumps', 0, () => {
      const vp: Viewport = testViewport();
      const r: ImplicitRenderer = new ImplicitRenderer(2, 'x^2+y^2-4', false);
      fillGrid(r, vp);
      const budget: ExtractionBudget = ExtractionBudget.idle();
      let pumps: number = 0;
      while (r.hasPendingExtraction() && pumps < 500) {
        r.pumpExtraction(budget, vp);
        pumps++;
      }
      expect(r.hasPendingExtraction()).assertFalse();
      const data: RenderData = r.extractVisible(vp);
      const segs = data.contourSegments;
      expect(segs != null).assertTrue();
      if (segs != null) {
        // 半径 2 的圆在 [-5,5]² 内应产出足量线段
        expect(segs.length > 20).assertTrue();
        expect(segs.length < SEGMENT_HARD_CAP).assertTrue();
      }
      r.dispose();
    });

    it('high_frequency_expression_is_bounded', 0, () => {
      // sin(x·y) 的零集是 xy=kπ 双曲线族，振荡密度随 |x|,|y| 增大而升高。
      // 修复前：AMR 无全局上界 → 千万级求值 + 百万级线段一次性同步执行 →
      // THREAD_BLOCK_6S、Rss 420MB、设备级卡死。
      // 修复后：振荡早退 + 段数软/硬上限 + 分帧预算，使最坏耗时由常数决定。
      const vp: Viewport = testViewport();
      const r: ImplicitRenderer = new ImplicitRenderer(3, 'sin(x*y)', false);
      fillGrid(r, vp);
      expect(r.hasPendingExtraction()).assertTrue();

      const budget: ExtractionBudget = ExtractionBudget.gesture();
      let pumps: number = 0;
      let worstPumpMs: number = 0;
      while (r.hasPendingExtraction() && pumps < 2000) {
        const t0: number = Date.now();
        r.pumpExtraction(budget, vp);
        const dt: number = Date.now() - t0;
        if (dt > worstPumpMs) {
          worstPumpMs = dt;
        }
        pumps++;
      }
      // 必须收敛：不允许无限提取
      expect(r.hasPendingExtraction()).assertFalse();
      expect(pumps < 2000).assertTrue();
      // 单轮泵入耗时受控：gesture 档墙钟上限 6ms，给足 GC/调度抖动余量
      expect(worstPumpMs < 300).assertTrue();

      const data: RenderData = r.extractVisible(vp);
      const segs = data.contourSegments;
      expect(segs != null).assertTrue();
      if (segs != null) {
        // 段数受硬上限约束（内存有界），且确实画出了曲线
        expect(segs.length <= SEGMENT_HARD_CAP).assertTrue();
        expect(segs.length > 0).assertTrue();
      }
      r.dispose();
    });

    it('extraction_is_resumable_across_pumps', 0, () => {
      // 分帧提取的单调性：每轮泵入只增不减，且不会重复产出同一批线段
      const vp: Viewport = testViewport();
      const r: ImplicitRenderer = new ImplicitRenderer(4, '9x^2+y^2-x-y', false);
      fillGrid(r, vp);
      const budget: ExtractionBudget = ExtractionBudget.gesture();

      let prev: number = 0;
      let guard: number = 0;
      while (r.hasPendingExtraction() && guard < 2000) {
        r.pumpExtraction(budget, vp);
        const d: RenderData = r.extractVisible(vp);
        const cur: number = (d.contourSegments != null) ? d.contourSegments.length : 0;
        expect(cur >= prev).assertTrue();
        prev = cur;
        guard++;
      }
      expect(r.hasPendingExtraction()).assertFalse();
      expect(prev > 0).assertTrue();
      r.dispose();
    });
  });
}
