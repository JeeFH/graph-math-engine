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
// box/Box.ets
// 自研渲染盒子树基类（布局树）。
// 约定：draw(ctx, x, y) 中 y 为"基线(baseline)"坐标。
//   - height = ascent（基线以上高度）
//   - depth  = descent（基线以下深度）
//   - 视觉总高 = height + depth
// sourcePath 记录该盒子对应的 VST 节点路径（供 LayoutMap 查表绘制光标）。

export abstract class Box {
  width: number = 0;
  height: number = 0;  // ascent: 基线 -> 顶部
  depth: number = 0;   // descent: 基线 -> 底部
  shift: number = 0;
  baseline: number = 0;
  sourcePath: number[] = [];
  foreground?: string;
  background?: string;
  /** 标记本盒是否为上标盒（PowerBox）。用于上标嵌套时稳健判定"底数本身已含上标"，
   *  不依赖 instanceof——ArkTS/HAR 打包可能产生类副本，跨副本 instanceof 偶发判否，
   *  会让嵌套上标检测失效（见 PowerBox.relayout 注释）。 */
  isPower: boolean = false;

  abstract draw(ctx: CanvasRenderingContext2D, x: number, y: number): void;

  /**
   * 用当前子盒的最新尺寸重算本盒的 width/height/depth 及内部偏移。
   * 默认空实现（叶子盒无需重排）；容器盒重写此方法，使其布局随子盒实测度量更新。
   * 构造时调用一次，绘制前经 measureAndRelayout 再次调用（子盒已被实测）。
   */
  relayout(): void {}
}
