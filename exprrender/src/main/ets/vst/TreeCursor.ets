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
// vst/TreeCursor.ets
// 自研纯位置光标：只存路径，不存节点引用（消灭 stale leaf bug）。
// path 编码规则：
//   path[i]（偶数 i）= 父行中的子索引（0..N-1）
//   path[i+1]（奇数 i）= 结构分支码（负数），见 BRANCH_* 常量
//   路径终点总是一个 VstRow 的 children 数组。
// offset = 当前行内位置（间隙，0..children.length）
// charOffset = -1（间隙）/ >=0（叶子文本内偏移）

import {
  VstNode, VstRow, VstNum, VstVar, VstConst, VstOp, VstPlaceholder,
  VstFrac, VstSqrt, VstRoot, VstPow, VstParen,
  VstFunc, VstCeil, VstFloor, VstPostfix, VstNeg, VstLog
} from './VstNodes';

// ── 分支编码常量（负数）──
export const BRANCH_NONE: number = 0;
export const BRANCH_NUM: number = -1;
export const BRANCH_DEN: number = -2;
export const BRANCH_BODY: number = -3;
export const BRANCH_BASE: number = -4;
export const BRANCH_EXP: number = -5;
export const BRANCH_INDEX: number = -6;
/** 对数函数底数分支 */
export const BRANCH_LOG_BASE: number = -7;

export function isLeafNode(node: VstNode): boolean {
  return node instanceof VstNum || node instanceof VstVar ||
    node instanceof VstConst || node instanceof VstOp ||
    node instanceof VstPlaceholder;
}

/** 按 path 从 root 出发找到当前行的 children 数组 */
export function resolveRow(root: VstRow, path: number[]): VstNode[] {
  let current: VstNode[] = root.children;
  for (let i = 0; i + 1 < path.length; i += 2) {
    const childIdx: number = path[i];
    const branchCode: number = path[i + 1];
    if (childIdx < 0 || childIdx >= current.length) {
      break; // 路径越界
    }
    const child: VstNode = current[childIdx];
    const branchChildren: VstNode[] | undefined = resolveBranch(child, branchCode);
    if (!branchChildren) break;
    current = branchChildren;
  }
  return current;
}

/** 由分支码获取结构节点的指定行 */
export function resolveBranch(node: VstNode, branchCode: number): VstNode[] | undefined {
  if (branchCode === BRANCH_NUM && node instanceof VstFrac) return node.num;
  if (branchCode === BRANCH_DEN && node instanceof VstFrac) return node.den;
  if (branchCode === BRANCH_BODY) {
    if (node instanceof VstSqrt) return node.body;
    if (node instanceof VstParen) return node.body;
    if (node instanceof VstFunc) return node.body;
    if (node instanceof VstCeil) return node.body;
    if (node instanceof VstFloor) return node.body;
    if (node instanceof VstNeg) return node.body;
    if (node instanceof VstRoot) return node.body;
    if (node instanceof VstLog) return node.body;
    if (node instanceof VstPostfix) return node.body;
  }
  if (branchCode === BRANCH_BASE && node instanceof VstPow) return node.base;
  if (branchCode === BRANCH_EXP && node instanceof VstPow) return node.exp;
  if (branchCode === BRANCH_INDEX && node instanceof VstRoot) return node.index;
  if (branchCode === BRANCH_LOG_BASE && node instanceof VstLog) return node.logBase;
  return undefined;
}

/** 由结构返回其所有分支码，按遍历顺序 */
export function structBranches(node: VstNode): number[] {
  if (node instanceof VstFrac) return [BRANCH_NUM, BRANCH_DEN];
  if (node instanceof VstPow) return [BRANCH_BASE, BRANCH_EXP];
  if (node instanceof VstRoot) return [BRANCH_INDEX, BRANCH_BODY];
  if (node instanceof VstLog) return [BRANCH_LOG_BASE, BRANCH_BODY];
  if (node instanceof VstSqrt || node instanceof VstParen || node instanceof VstFunc ||
      node instanceof VstCeil || node instanceof VstFloor || node instanceof VstNeg ||
      node instanceof VstPostfix) {
    return [BRANCH_BODY];
  }
  return [];
}

/** 纯位置光标 */
export class Cursor {
  path: number[];
  offset: number;
  charOffset: number;

  constructor(path?: number[], offset?: number, charOffset?: number) {
    this.path = path ? [...path] : [];
    this.offset = offset ?? 0;
    this.charOffset = charOffset ?? -1;
  }

  clone(): Cursor {
    return new Cursor([...this.path], this.offset, this.charOffset);
  }

  inLeaf(): boolean { return this.charOffset >= 0; }

  leftAtomIndex(): number {
    return this.inLeaf() ? this.offset : this.offset - 1;
  }

  rightAtomIndex(rowLen: number): number {
    return this.inLeaf() ? this.offset : (this.offset < rowLen ? this.offset : -1);
  }
}

// ── 光标导航：DFS 插入点全序 ──

function currentRow(root: VstRow, cursor: Cursor): VstNode[] {
  return resolveRow(root, cursor.path);
}

/** 光标当前高亮的元素索引：叶内取 offset；间隙取右侧节点（行尾回退末节点）。与 LayoutMap.cursorBoxRect 的判定一致 */
function currentElementIndex(cursor: Cursor, row: VstNode[]): number {
  if (cursor.inLeaf()) {
    return cursor.offset;
  }
  return cursor.offset < row.length ? cursor.offset : row.length - 1;
}

/** 移动到行内索引 j 的元素：叶子 → 置于间隙 j（高亮该叶子）；结构 → 进入其首个分支（右移）或末个分支（左移） */
function goToElement(cursor: Cursor, row: VstNode[], j: number, forward: boolean): void {
  const node: VstNode = row[j];
  if (isLeafNode(node)) {
    cursor.offset = j;
    cursor.charOffset = -1;
    return;
  }
  const branches: number[] = structBranches(node);
  if (branches.length > 0) {
    const branch: number = forward ? branches[0] : branches[branches.length - 1];
    cursor.path.push(j);
    cursor.path.push(branch);
    const branchRow: VstNode[] = resolveBranch(node, branch)!;
    cursor.offset = forward ? 0 : branchRow.length;
    cursor.charOffset = -1;
    return;
  }
  cursor.offset = j;
  cursor.charOffset = -1;
}

/** 向右一步 */
export function moveRight(root: VstRow, cursor: Cursor): boolean {
  const row: VstNode[] = currentRow(root, cursor);
  const e: number = currentElementIndex(cursor, row);
  // 光标在间隙态高亮行尾结构 → 进入结构（避免无下一元素时卡死）
  if (!cursor.inLeaf() && row.length > 0 && cursor.offset === row.length - 1
      && !isLeafNode(row[cursor.offset])) {
    goToElement(cursor, row, cursor.offset, true);
    return true;
  }
  if (e + 1 < row.length) {
    goToElement(cursor, row, e + 1, true);
    return true;
  }
  return exitRowRight(root, cursor);
}

function exitRowRight(root: VstRow, cursor: Cursor): boolean {
  if (cursor.path.length === 0) return false;
  const branchCode: number = cursor.path.pop()!;
  const myIdx: number = cursor.path[cursor.path.length - 1];
  const parentRow: VstNode[] = resolveRow(root, cursor.path.slice(0, cursor.path.length - 1));
  if (myIdx >= 0 && myIdx < parentRow.length) {
    const nodeObj: VstNode = parentRow[myIdx];
    const branches: number[] = structBranches(nodeObj);
    // 查找当前分支的下一个分支（如 VstLog: logBase → body）
    for (let i = 0; i < branches.length - 1; i++) {
      if (branches[i] === branchCode) {
        cursor.path.push(branches[i + 1]);
        const nextRow: VstNode[] = resolveBranch(nodeObj, branches[i + 1])!;
        cursor.offset = 0;
        cursor.charOffset = -1;
        return true;
      }
    }
  }
  // 没有后续分支，退出整个结构
  cursor.path.pop();
  cursor.offset = myIdx + 1;
  cursor.charOffset = -1;
  return true;
}

/** 向左一步 */
export function moveLeft(root: VstRow, cursor: Cursor): boolean {
  const row: VstNode[] = currentRow(root, cursor);
  const e: number = currentElementIndex(cursor, row);
  // 光标在行尾、末尾元素是结构 → 从尾部进入结构（避免 e-1 跳过末尾结构）
  if (!cursor.inLeaf() && cursor.offset >= row.length && row.length > 0
      && !isLeafNode(row[row.length - 1])) {
    goToElement(cursor, row, row.length - 1, false);
    return true;
  }
  if (e - 1 >= 0) {
    goToElement(cursor, row, e - 1, false);
    return true;
  }
  return exitRowLeft(root, cursor);
}

function exitRowLeft(root: VstRow, cursor: Cursor): boolean {
  if (cursor.path.length === 0) return false;
  const branchCode: number = cursor.path.pop()!;
  const myIdx: number = cursor.path[cursor.path.length - 1];
  const parentRow: VstNode[] = resolveRow(root, cursor.path.slice(0, cursor.path.length - 1));
  if (myIdx >= 0 && myIdx < parentRow.length) {
    const nodeObj: VstNode = parentRow[myIdx];
    const branches: number[] = structBranches(nodeObj);
    // 查找当前分支的上一个分支（如 VstPow: exp → base，VstFrac: den → num）
    for (let i: number = 1; i < branches.length; i++) {
      if (branches[i] === branchCode) {
        cursor.path.push(branches[i - 1]);
        const prevRow: VstNode[] = resolveBranch(nodeObj, branches[i - 1])!;
        cursor.offset = prevRow.length;
        cursor.charOffset = -1;
        return true;
      }
    }
  }
  // 没有前序分支，退出整个结构
  cursor.path.pop();
  cursor.offset = myIdx;
  cursor.charOffset = -1;
  return true;
}

/** 上：在结构内向上一个分支（Frac: 分母→分子，Pow: exp→base）否则退出 */
export function moveUp(root: VstRow, cursor: Cursor): boolean {
  if (cursor.path.length < 2) {
    return false;
  }
  const branchCode: number = cursor.path[cursor.path.length - 1];
  const myIdx: number = cursor.path[cursor.path.length - 2];
  const parentPath: number[] = cursor.path.slice(0, cursor.path.length - 2);
  const parentRow: VstNode[] = resolveRow(root, parentPath);
  if (myIdx >= parentRow.length) return false;
  const nodeObj: VstNode = parentRow[myIdx];
  const branches: number[] = structBranches(nodeObj);
  if (branches.length >= 2) {
    let currentBranchIdx: number = -1;
    for (let i = 0; i < branches.length; i++) {
      if (branches[i] === branchCode) { currentBranchIdx = i; break; }
    }
    if (currentBranchIdx > 0) {
      cursor.path[cursor.path.length - 1] = branches[currentBranchIdx - 1];
      const upRow: VstNode[] = resolveBranch(nodeObj, branches[currentBranchIdx - 1])!;
      cursor.offset = Math.min(cursor.offset, upRow.length);
      cursor.charOffset = -1;
      return true;
    }
  }
  cursor.path.pop();
  cursor.path.pop();
  cursor.offset = myIdx;
  cursor.charOffset = -1;
  return true;
}

/** 下：在结构内向下一个分支（Frac: 分子→分母，Pow: base→exp）否则退出 */
export function moveDown(root: VstRow, cursor: Cursor): boolean {
  if (cursor.path.length < 2) {
    return false;
  }
  const branchCode: number = cursor.path[cursor.path.length - 1];
  const myIdx: number = cursor.path[cursor.path.length - 2];
  const parentPath: number[] = cursor.path.slice(0, cursor.path.length - 2);
  const parentRow: VstNode[] = resolveRow(root, parentPath);
  if (myIdx >= parentRow.length) return false;
  const nodeObj: VstNode = parentRow[myIdx];
  const branches: number[] = structBranches(nodeObj);
  if (branches.length >= 2) {
    let currentBranchIdx: number = -1;
    for (let i = 0; i < branches.length; i++) {
      if (branches[i] === branchCode) { currentBranchIdx = i; break; }
    }
    if (currentBranchIdx >= 0 && currentBranchIdx + 1 < branches.length) {
      cursor.path[cursor.path.length - 1] = branches[currentBranchIdx + 1];
      const downRow: VstNode[] = resolveBranch(nodeObj, branches[currentBranchIdx + 1])!;
      cursor.offset = Math.min(cursor.offset, downRow.length);
      cursor.charOffset = -1;
      return true;
    }
  }
  cursor.path.pop();
  cursor.path.pop();
  cursor.offset = myIdx + 1;
  cursor.charOffset = -1;
  return true;
}

/** 光标移到根行末尾 */
export function moveHome(root: VstRow, cursor: Cursor): void {
  cursor.path = [];
  cursor.offset = 0;
  cursor.charOffset = -1;
}

/** 光标移到当前行末尾 */
export function moveEnd(root: VstRow, cursor: Cursor): void {
  const row: VstNode[] = currentRow(root, cursor);
  cursor.offset = row.length;
  cursor.charOffset = -1;
}
