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
// engine/LayoutMap.ets
// 自研：遍历已度量的 Box 树，收集每个插入点（cursor 可停留位置）的像素矩形。
// 供 MathFieldView 查表绘制 2D 光标 + 触控命中。
//
// 路径约定见 engine/ExprRender.ets 顶部注释；本文件是消费者：
//   - 行 HBox 携带 sourcePath（该行在 cursor.path 中的前缀）
//   - 叶子 GlyphBox 携带 sourcePath = [...父路径, 自身索引]，末位仅作 offset 用
//   - 结构盒携带 sourcePath = [...父路径, 自身索引]（= myPath），
//     本文件的 walk* 在其上追加分支码得到子行路径

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
import { Cursor, BRANCH_NUM, BRANCH_DEN, BRANCH_BODY, BRANCH_BASE, BRANCH_EXP, BRANCH_INDEX } from '../vst/TreeCursor';

// ── 插入点数据结构 ──

/** 一个可放置光标的位置的像素矩形 */
export interface InsertionPoint {
  /** Cursor 查询路径（去根后，与 Cursor.path 对齐） */
  path: number[];
  /** 行内原子间隙 offset（0..N） */
  offset: number;
  /** 叶子内字符偏移（-1 = 间隙），>=0 为叶内 */
  charOffset: number;
  /** 光标矩形：左上 x */
  x: number;
  /** 光标矩形：顶部 y */
  yTop: number;
  /** 光标矩形：底部 y */
  yBottom: number;
}

/** cursorRect 返回值类型 */
export interface CursorRect {
  x: number;
  yTop: number;
  yBottom: number;
}

/** 一个行内子盒（光标高亮目标）的像素矩形 */
export interface BoxRect {
  /** 所属行的路径（与 Cursor.path 对齐） */
  path: number[];
  /** 节点在行内的索引 */
  index: number;
  /** 矩形左边界 x */
  x: number;
  /** 矩形顶部 y */
  yTop: number;
  /** 矩形底部 y */
  yBottom: number;
  /** 矩形宽度 */
  width: number;
}

/** LayoutMap 对外接口 */
export class LayoutMap {
  points: InsertionPoint[] = [];
  /** 行内子盒矩形表：供聚焦高亮方块查表定位（key = 行路径 + 子索引） */
  boxRects: BoxRect[] = [];

  /**
   * 从已度量的 Box 树构建插入点表。
   * @param rootBox 已 measure 的根 Box
   * @param rowPath 此 Box 对应的 Cursor.path 前缀（VstRow 内各子节点的 path 由此继承）
   */
  collect(rootBox: Box, rowPath: number[]): void {
    this.points = [];
    this.boxRects = [];
    // 遍历基线取 rootBox.height，与 MathFieldView.paint 的绘制调用
    // box.draw(ctx, 0, box.height) 保持一致，使收集的像素坐标直接为画布坐标，
    // 避免光标/高亮在垂直方向整体偏移一个 ascent（此前竖线光标垂直错位的根源）。
    this.walk(rootBox, 0, rootBox.height, rowPath);
  }

  /** 查光标在当前 LayoutMap 中的像素矩形 */
  cursorRect(cursor: Cursor): CursorRect | null {
    for (const p of this.points) {
      if (this.pathMatch(p.path, cursor.path) &&
          p.offset === cursor.offset &&
          p.charOffset === cursor.charOffset) {
        return { x: p.x, yTop: p.yTop, yBottom: p.yBottom } as CursorRect;
      }
    }
    // 行内字符偏移不匹配时，回退到同 (path, offset) 的间隙点
    for (const p of this.points) {
      if (this.pathMatch(p.path, cursor.path) && p.offset === cursor.offset && p.charOffset === -1) {
        return { x: p.x, yTop: p.yTop, yBottom: p.yBottom } as CursorRect;
      }
    }
    // 回退：行尾无精确匹配 → 用最后一个插入点
    if (this.points.length > 0) {
      const last: InsertionPoint = this.points[this.points.length - 1];
      return { x: last.x, yTop: last.yTop, yBottom: last.yBottom } as CursorRect;
    }
    return null;
  }

  /**
   * 查当前光标指向的目标 Box 矩形（供聚焦高亮方块绘制）。
   * 目标索引判定：
   *   - 叶内（charOffset >= 0）：目标 = offset 处的叶子。
   *   - 间隙（charOffset = -1）：优先右侧节点 offset（插入点语义），
   *     行尾无右节点时回退左侧 offset-1。
   * 相比 cursorRect 的精确三元组匹配，此查询宽松容错，不依赖 charOffset 精确对齐。
   */
  cursorBoxRect(cursor: Cursor): BoxRect | null {
    if (cursor.charOffset >= 0) {
      return this.findBoxRect(cursor.path, cursor.offset);
    }
    let r: BoxRect | null = this.findBoxRect(cursor.path, cursor.offset);
    if (r == null) {
      r = this.findBoxRect(cursor.path, cursor.offset - 1);
    }
    return r;
  }

  private findBoxRect(path: number[], index: number): BoxRect | null {
    if (index < 0) {
      return null;
    }
    for (const r of this.boxRects) {
      if (r.index === index && this.pathMatch(r.path, path)) {
        return r;
      }
    }
    return null;
  }

  // ── 内部遍历 ──

  private walk(box: Box, x: number, y: number, path: number[]): void {
    if (box instanceof GlyphBox) {
      this.addGlyphPoints(box, x, y, path);
    } else if (box instanceof PlaceholderBox) {
      this.addPlaceholderPoint(box, x, y, path);
    } else if (box instanceof HBox) {
      this.walkHBox(box, x, y, path);
    } else if (box instanceof FracBox) {
      this.walkFrac(box, x, y, path);
    } else if (box instanceof PowerBox) {
      this.walkPower(box, x, y, path);
    } else if (box instanceof SubscriptBox) {
      this.walkSubscript(box, x, y, path);
    } else if (box.isPower === true) {
      this.walkPower(box as PowerBox, x, y, path);
    } else if (box instanceof SqrtBox) {
      this.walkSqrt(box, x, y, path);
    } else if (box instanceof ParenBox || box instanceof AbsBox || box instanceof CeilFloorBox) {
      this.walkWrapped(box, x, y, path);
    }
    // 其他未知盒子忽略
  }

  private addGlyphPoints(g: GlyphBox, x: number, y: number, path: number[]): void {
    // 默认偏移：使用 g.sourcePath 的末位作为在父行中的位置（offset）
    const idx: number = g.sourcePath.length > 0 ? g.sourcePath[g.sourcePath.length - 1] : -1;
    if (idx < 0) return;
    const yTop: number = y - g.height;
    const yBottom: number = y + g.depth;
    // 间隙在图元左侧（offset = idx，charOffset = -1）
    this.points.push({
      path: [...path],
      offset: idx,
      charOffset: -1,
      x: x,
      yTop: yTop,
      yBottom: yBottom
    });
    // 叶内各字符插入点（offset = idx，charOffset = 0..L-1）
    const L: number = g.text.length;
    for (let k: number = 0; k < L; k++) {
      const cxk: number = x + (L > 0 ? (k / L) * g.width : 0);
      this.points.push({
        path: [...path],
        offset: idx,
        charOffset: k,
        x: cxk,
        yTop: yTop,
        yBottom: yBottom
      });
    }
    // 右边缘插入点（offset = idx+1，charOffset = -1）：
    // 输入数字后光标位于叶子右侧（如 insertText 返回 charOffset=L），
    // 此点确保 cursorRect 能匹配到正确的右边缘位置。
    this.points.push({
      path: [...path],
      offset: idx + 1,
      charOffset: -1,
      x: x + g.width,
      yTop: yTop,
      yBottom: yBottom
    });
  }

  private addPlaceholderPoint(p: PlaceholderBox, x: number, y: number, path: number[]): void {
    const idx: number = p.sourcePath.length > 0 ? p.sourcePath[p.sourcePath.length - 1] : -1;
    if (idx < 0) return;
    // 占位符内部位置：offset = idx-1，使光标在根行起始位置（offset=0）时
    // 能匹配到 idx=0 的占位符。光标 x 位于占位符视觉中心。
    this.points.push({
      path: [...path],
      offset: idx - 1,
      charOffset: -1,
      x: x + p.width / 2,
      yTop: y - p.height,
      yBottom: y + p.depth
    });
  }

  private walkHBox(h: HBox, x: number, y: number, path: number[]): void {
    let cx: number = x;
    for (let i: number = 0; i < h.children.length; i++) {
      const child: Box = h.children[i];
      // 记录该子盒矩形（含结构容器），key = (行路径, 子索引)，供聚焦高亮查表。
      // 视觉基线用 y - child.shift，与 HBox.draw 的绘制基线保持一致。
      const cb: number = y - child.shift;
      this.boxRects.push({
        path: [...path],
        index: i,
        x: cx,
        yTop: cb - child.height,
        yBottom: cb + child.depth,
        width: child.width
      });
      if (child instanceof GlyphBox || child instanceof PlaceholderBox) {
        // 叶子：继承父行路径（其 sourcePath 末位即 offset，不作路径段）
        this.walk(child, cx, y, path);
      } else {
        // 容器：以该子盒自身的 sourcePath（= 其子行路径）作为上下文
        this.walk(child, cx, y, [...child.sourcePath]);
      }
      cx += child.width + (h.spacing ?? 0);
    }
    // 行尾间隙（offset = 子节点数）
    this.points.push({
      path: [...path],
      offset: h.children.length,
      charOffset: -1,
      x: cx,
      yTop: y - h.height,
      yBottom: y + h.depth
    });
  }

  private walkFrac(f: FracBox, x: number, y: number, path: number[]): void {
    // path 已为 FracBox 的 myPath（[...父路径, 自身索引]）
    // 分数线在 FracBox 基线上方 fracAxisShift 处，num/den 偏移相对分数线
    const fracLineY: number = y - f.fracAxisShift;
    const numPath: number[] = [...path, BRANCH_NUM];
    this.walk(f.num, x, fracLineY + f.numBaselineOffset, numPath);
    const denPath: number[] = [...path, BRANCH_DEN];
    const denX: number = x + (f.width - f.den.width) / 2;
    this.walk(f.den, denX, fracLineY + f.denBaselineOffset, denPath);
  }

  private walkPower(pb: PowerBox, x: number, y: number, path: number[]): void {
    const basePath: number[] = [...path, BRANCH_BASE];
    this.walk(pb.base, x, y, basePath);
    const expPath: number[] = [...path, BRANCH_EXP];
    this.walk(pb.exp, x + pb.base.width, y + pb.expBaselineOffset, expPath);
  }

  private walkSubscript(sb: SubscriptBox, x: number, y: number, path: number[]): void {
    // SubscriptBox 是纯布局组件，base（如 "log" 文本）不是可导航分支，跳过。
    // 只有 sub（如 logBase 底数）需要光标导航，用 sub 自己的 sourcePath 作为路径。
    this.walk(sb.sub, x + sb.base.width, y + sb.subBaselineOffset, [...sb.sub.sourcePath]);
  }

  private walkSqrt(s: SqrtBox, x: number, y: number, path: number[]): void {
    const bodyPath: number[] = [...path, BRANCH_BODY];
    this.walk(s.body, x + s.bodyOffsetX, y, bodyPath);
  }

  private walkWrapped(box: ParenBox | AbsBox | CeilFloorBox, x: number, y: number, path: number[]): void {
    const bodyPath: number[] = [...path, BRANCH_BODY];
    this.walk(box.body, x + box.bodyOffsetX, y, bodyPath);
  }

  private pathMatch(a: number[], b: number[]): boolean {
    if (a.length !== b.length) return false;
    for (let i: number = 0; i < a.length; i++) {
      if (a[i] !== b[i]) return false;
    }
    return true;
  }
}
