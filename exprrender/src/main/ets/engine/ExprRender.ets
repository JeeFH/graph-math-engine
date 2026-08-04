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
// engine/ExprRender.ets
// 自研渲染翻译层：VstRow（视觉语法树，纯模型） -> Box 树（布局树，含宽高/基线）。
// 与 鍘熷寮曟搸 retex 的 Atom 链不同，这里模型与布局严格分离：
//   VST 节点不含任何像素信息；所有布局在 box/ 中完成。
//
// sourcePath 约定（必须与 vst/TreeCursor 的 cursor.path 语义一致）：
//   - 行 HBox 的 sourcePath = 该行对应的 cursor.path 前缀（即"父路径"）
//   - 叶子 GlyphBox 的 sourcePath = [...父路径, 自身在行内的索引]
//     （末位仅作 offset 用，LayoutMap 不会把它当路径段）
//   - 结构盒（FracBox 等）的 sourcePath = [...父路径, 自身索引]（= myPath）
//     LayoutMap 的 walk* 方法在此基础上追加分支码（BRANCH_*）得到子行路径
//   - 结构内的子行（num/den/base/exp/body/index）sourcePath = [...myPath, 分支码]

import {
  VstNode, VstRow, VstNum, VstVar, VstConst, VstOp, VstPlaceholder,
  VstFrac, VstSqrt, VstRoot, VstPow, VstParen,
  VstFunc, VstCeil, VstFloor, VstPostfix, VstNeg, VstLog
} from '../vst/VstNodes';
import {
  BRANCH_NUM, BRANCH_DEN, BRANCH_BODY, BRANCH_BASE, BRANCH_EXP, BRANCH_INDEX,
  BRANCH_LOG_BASE
} from '../vst/TreeCursor';

import { Box } from '../box/Box';
import { GlyphBox } from '../box/GlyphBox';
import { HBox } from '../box/HBox';
import { FracBox } from '../box/FracBox';
import { SqrtBox } from '../box/SqrtBox';
import { PowerBox } from '../box/PowerBox';
import { SubscriptBox } from '../box/SubscriptBox';
import { ParenBox } from '../box/ParenBox';
import { AbsBox } from '../box/AbsBox';
import { CeilFloorBox } from '../box/CeilFloorBox';
import { PlaceholderBox } from '../box/PlaceholderBox';
import { SCRIPT_FACTOR } from '../font/TeXMetrics';

const FAMILY: string = 'HarmonyOS Sans';

export class ExprRenderer {
  /** 乘号显示字形：默认 '·'（图象模式）；基础模式历史传 '×'。
   *  由 render 入口统一设置，供 nodeToBox 的 VstOp 分支读取。
   *  rowToBox/nodeToBox 为 private static 且仅在 render 内同步递归（ArkUI 单线程），
   *  每次 render 入口都会重设，无跨调用污染，故无需逐层传参。 */
  private static mulGlyph: string = '·';
  /** 线性除法模式：默认 false（除法渲染为分数 FracBox）；
   *  true 时 VstFrac 线性渲染为「分子 ÷ 分母」，尾部 VstOp('/') 显示 '÷'。
   *  特定模式传 true；图象模式保持默认，不受影响。 */
  private static divLinear: boolean = false;

  /**
   * 将 VstRow 渲染为 Box 布局树。
   * @param root 表达式根行
   * @param fontSize 基准字号
   * @param foreground 可选前景色（不传则由各视图层设置）
   * @param mulGlyph 乘号显示字形（默认 '·'；基础模式历史传 '×'）
   * @param divLinear 线性除法模式（默认 false；特定模式传 true，除法显示 ÷ 而非分数）
   */
  static render(root: VstRow, fontSize: number, foreground?: string, mulGlyph: string = '·', divLinear: boolean = false): Box {
    ExprRenderer.mulGlyph = mulGlyph;
    ExprRenderer.divLinear = divLinear;
    const box: Box = ExprRenderer.rowToBox(root.children, fontSize, []);
    if (foreground) box.foreground = foreground;
    return box;
  }

  /** 行 -> HBox。rowPath = 该行在 cursor.path 中的前缀；fracDepth = 当前分数嵌套层数；expFrac = 指数内分式额外偏移；originalFontSize = 原始基准字号（用于计算累计缩减） */
  private static rowToBox(row: VstNode[], fontSize: number, rowPath: number[], fracDepth: number = 0, expFrac: number = 0, originalFontSize: number = 0): HBox {
    const childrenBoxes: Box[] = [];
    for (let i: number = 0; i < row.length; i++) {
      childrenBoxes.push(ExprRenderer.nodeToBox(row[i], fontSize, rowPath, i, fracDepth, expFrac, originalFontSize));
    }
    const hb: HBox = new HBox(childrenBoxes, fontSize * 0.05);
    hb.sourcePath = [...rowPath];
    return hb;
  }

  /** 单节点 -> Box。parentPath = 包含该节点的行路径；idx = 该行内索引；fracDepth = 当前分数嵌套层数；expFrac = 指数内分式额外偏移；originalFontSize = 原始基准字号 */
  private static nodeToBox(node: VstNode, fontSize: number, parentPath: number[], idx: number, fracDepth: number = 0, expFrac: number = 0, originalFontSize: number = 0): Box {
    const myPath: number[] = [...parentPath, idx];

    if (node instanceof VstNum) return ExprRenderer.leafBox(node.text, fontSize, false, parentPath, idx);
    if (node instanceof VstVar) return ExprRenderer.leafBox(node.name, fontSize, true, parentPath, idx);
    if (node instanceof VstConst) return ExprRenderer.leafBox(node.sym, fontSize, false, parentPath, idx);
    if (node instanceof VstOp) {
      // 显示用符号映射：乘号（*/×/·）统一渲染为可配置字形 mulGlyph。
      // 完成态经 simplify 归一后乘号以 VstOp('·') 存在（'*'/'×' 不存活），
      // 故三种符号一并处理：图象模式默认 '·'，基础模式历史传 '×'。
      // 除法已统一为分数，VstOp('/') 仅出现于输入中的悬挂除号；
      // 线性除法模式下显示 '÷'，否则保持 '/'。完成态隐式乘法（无运算符的 2x、xy 等）不受影响。
      const isMult: boolean = node.sym === '*' || node.sym === '×' || node.sym === '·';
      let disp: string = node.sym;
      if (isMult) {
        disp = ExprRenderer.mulGlyph;
      } else if (node.sym === '/' && ExprRenderer.divLinear) {
        disp = '÷';
      }
      return ExprRenderer.leafBox(disp, fontSize, false, parentPath, idx);
    }
    if (node instanceof VstPlaceholder) {
      const p: PlaceholderBox = new PlaceholderBox(fontSize);
      p.sourcePath = [...myPath];
      return p;
    }
    if (node instanceof VstFrac) {
      // 线性除法模式：分子 ÷ 分母 横向排列，不构造分数盒
      if (ExprRenderer.divLinear) {
        const linNum: HBox = ExprRenderer.rowToBox(node.num, fontSize, [...myPath, BRANCH_NUM], fracDepth, expFrac, originalFontSize);
        const linDen: HBox = ExprRenderer.rowToBox(node.den, fontSize, [...myPath, BRANCH_DEN], fracDepth, expFrac, originalFontSize);
        const linDiv: GlyphBox = new GlyphBox('÷', fontSize, false, FAMILY);
        const linHb: HBox = new HBox([linNum, linDiv, linDen], fontSize * 0.05);
        linHb.sourcePath = [...myPath];
        return linHb;
      }
      // 初始化 originalFontSize：首次进入分式时记录
      const origFs: number = originalFontSize > 0 ? originalFontSize : fontSize;
      // 字号递减基于原始字号：指数内2层 -2,-4；普通分式4层 0,-2,-4,-6,-8
      const reduction: number = expFrac > 0
        ? Math.min(fracDepth, 2) * 2
        : Math.min(fracDepth, 4) * 2;
      const childFs: number = origFs - reduction - expFrac;
      const fb: FracBox = new FracBox(
        ExprRenderer.rowToBox(node.num, childFs, [...myPath, BRANCH_NUM], fracDepth + 1, expFrac, origFs),
        ExprRenderer.rowToBox(node.den, childFs, [...myPath, BRANCH_DEN], fracDepth + 1, expFrac, origFs),
        fontSize
      );
      fb.sourcePath = [...myPath];
      return fb;
    }
    if (node instanceof VstPow) {
      const expOrigFs: number = fontSize * SCRIPT_FACTOR;
      const pb: PowerBox = new PowerBox(
        ExprRenderer.rowToBox(node.base, fontSize, [...myPath, BRANCH_BASE], fracDepth, expFrac, originalFontSize),
        ExprRenderer.rowToBox(node.exp, expOrigFs, [...myPath, BRANCH_EXP], 0, 6, expOrigFs),
        fontSize
      );
      pb.sourcePath = [...myPath];
      return pb;
    }
    if (node instanceof VstSqrt) {
      const sb: SqrtBox = new SqrtBox(
        ExprRenderer.rowToBox(node.body, fontSize, [...myPath, BRANCH_BODY], fracDepth, expFrac, originalFontSize),
        fontSize
      );
      sb.sourcePath = [...myPath];
      return sb;
    }
    if (node instanceof VstRoot) {
      // 没有专用 n 次根号盒：渲染为 [小索引][√body] 的 HBox。
      // 索引盒与根号盒各自携带分支路径，由 LayoutMap 通用 HBox 处理定位。
      const indexOrigFs: number = fontSize * SCRIPT_FACTOR;
      const indexBox: HBox = ExprRenderer.rowToBox(node.index, indexOrigFs, [...myPath, BRANCH_INDEX], fracDepth, expFrac, indexOrigFs);
      const sqrtBox: SqrtBox = new SqrtBox(
        ExprRenderer.rowToBox(node.body, fontSize, [...myPath, BRANCH_BODY], fracDepth, expFrac, originalFontSize),
        fontSize
      );
      // 注意：根号盒 sourcePath 保持为 myPath（walkSqrt 在其上追加 BRANCH_BODY），
      // 否则会与 VstRoot 的分支路径叠加重复。
      sqrtBox.sourcePath = [...myPath];
      const rootHBox: HBox = new HBox([indexBox, sqrtBox], fontSize * 0.02);
      rootHBox.sourcePath = [...myPath];
      return rootHBox;
    }
    if (node instanceof VstParen) {
      const p: ParenBox = new ParenBox(
        ExprRenderer.rowToBox(node.body, fontSize, [...myPath, BRANCH_BODY], fracDepth, expFrac, originalFontSize),
        fontSize
      );
      p.sourcePath = [...myPath];
      return p;
    }
    if (node instanceof VstFunc) {
      // abs 渲染为 |body|，其余渲染为 名称( body )
      if (node.name === 'abs') {
        const a: AbsBox = new AbsBox(
          ExprRenderer.rowToBox(node.body, fontSize, [...myPath, BRANCH_BODY], fracDepth, expFrac, originalFontSize),
          fontSize
        );
        a.sourcePath = [...myPath];
        return a;
      }
      // log10（lg）渲染为 log₁₀(body)："log" + 下标"10" + 括号
      if (node.name === 'log10') {
        const nameBox: GlyphBox = new GlyphBox('log', fontSize, false, FAMILY);
        const subOrigFs: number = fontSize * SCRIPT_FACTOR;
        const subBox: GlyphBox = new GlyphBox('10', subOrigFs, false, FAMILY);
        const subscript: SubscriptBox = new SubscriptBox(nameBox, subBox, fontSize);
        subscript.sourcePath = [...myPath];
        const paren: ParenBox = new ParenBox(
          ExprRenderer.rowToBox(node.body, fontSize, [...myPath, BRANCH_BODY], fracDepth, expFrac, originalFontSize),
          fontSize
        );
        paren.sourcePath = [...myPath];
        const hb: HBox = new HBox([subscript, paren], fontSize * 0.04);
        hb.sourcePath = [...myPath];
        return hb;
      }
      const nameBox: GlyphBox = new GlyphBox(node.name, fontSize, false, FAMILY);
      const paren: ParenBox = new ParenBox(
        ExprRenderer.rowToBox(node.body, fontSize, [...myPath, BRANCH_BODY], fracDepth, expFrac, originalFontSize),
        fontSize
      );
      // VstFunc 的 body 分支路径为 [...myPath, BRANCH_BODY]；
      // 令内部 ParenBox 的 sourcePath = myPath，walkWrapped 追加 BRANCH_BODY 后即得正确路径。
      paren.sourcePath = [...myPath];
      // 函数名做成一个紧凑整体（自然字距，不再逐字母带间隙），与参数括号间留薄间距
      const hb: HBox = new HBox([nameBox, paren], fontSize * 0.04);
      hb.centerFirstChild = true;  // 每次 relayout 自动重算 shift，使函数名视觉中心对齐括号视觉中心
      hb.sourcePath = [...myPath];
      return hb;
    }
    if (node instanceof VstCeil) {
      const c: CeilFloorBox = new CeilFloorBox(
        ExprRenderer.rowToBox(node.body, fontSize, [...myPath, BRANCH_BODY], fracDepth, expFrac, originalFontSize),
        true, fontSize
      );
      c.sourcePath = [...myPath];
      return c;
    }
    if (node instanceof VstFloor) {
      const f: CeilFloorBox = new CeilFloorBox(
        ExprRenderer.rowToBox(node.body, fontSize, [...myPath, BRANCH_BODY], fracDepth, expFrac, originalFontSize),
        false, fontSize
      );
      f.sourcePath = [...myPath];
      return f;
    }
    if (node instanceof VstPostfix) {
      // 后缀（阶乘等）：[ body ][ op ]，op 为装饰字形无 sourcePath
      const parts: Box[] = [];
      parts.push(ExprRenderer.rowToBox(node.body, fontSize, [...myPath, BRANCH_BODY], fracDepth, expFrac, originalFontSize));
      parts.push(new GlyphBox(node.op, fontSize, false, FAMILY));
      const hb: HBox = new HBox(parts, fontSize * 0.02);
      hb.sourcePath = [...myPath];
      return hb;
    }
    if (node instanceof VstNeg) {
      // 一元负号：[-][ body ]，'-' 为装饰字形无 sourcePath
      const parts: Box[] = [];
      parts.push(new GlyphBox('-', fontSize, false, FAMILY));
      parts.push(ExprRenderer.rowToBox(node.body, fontSize, [...myPath, BRANCH_BODY], fracDepth, expFrac, originalFontSize));
      const hb: HBox = new HBox(parts, fontSize * 0.02);
      hb.sourcePath = [...myPath];
      return hb;
    }
    if (node instanceof VstLog) {
      // log_x(y) 渲染：[log][x 下标] + [( y )]
      const nameBox: GlyphBox = new GlyphBox('log', fontSize, false, FAMILY);
      const logBaseOrigFs: number = fontSize * SCRIPT_FACTOR;
      const baseBox: HBox = ExprRenderer.rowToBox(node.logBase, logBaseOrigFs, [...myPath, BRANCH_LOG_BASE], fracDepth, expFrac, logBaseOrigFs);
      const parenBox: ParenBox = new ParenBox(
        ExprRenderer.rowToBox(node.body, fontSize, [...myPath, BRANCH_BODY], fracDepth, expFrac, originalFontSize),
        fontSize
      );
      parenBox.sourcePath = [...myPath];
      const subBox: SubscriptBox = new SubscriptBox(nameBox, baseBox, fontSize);
      subBox.sourcePath = [...myPath];
      const hb: HBox = new HBox([subBox, parenBox], fontSize * 0.04);
      hb.sourcePath = [...myPath];
      return hb;
    }
    // 兜底
    const ph: PlaceholderBox = new PlaceholderBox(fontSize);
    ph.sourcePath = [...myPath];
    return ph;
  }

  private static leafBox(text: string, fontSize: number, italic: boolean, parentPath: number[], idx: number): GlyphBox {
    const g: GlyphBox = new GlyphBox(text, fontSize, italic, FAMILY);
    g.sourcePath = [...parentPath, idx];
    return g;
  }
}
