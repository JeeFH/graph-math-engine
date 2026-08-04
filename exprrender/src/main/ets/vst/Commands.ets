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
// vst/Commands.ets
// 自研编辑命令层：纯函数 (root, cursor) → [newRoot, newCursor]。
// 结构一击删除；智能分数/幂吸取左邻短项；操作符为行内原子。

import {
  VstNode, VstRow, VstNum, VstVar, VstConst, VstOp, VstPlaceholder,
  VstFrac, VstSqrt, VstRoot, VstPow, VstParen,
  VstFunc, VstCeil, VstFloor, VstPostfix, VstNeg, VstLog
} from './VstNodes';
import {
  Cursor, resolveRow, resolveBranch, structBranches, BRANCH_INDEX, BRANCH_BODY,
  BRANCH_LOG_BASE, isLeafNode,
  moveLeft as cursorMoveLeft, moveRight as cursorMoveRight,
  moveUp as cursorMoveUp, moveDown as cursorMoveDown
} from './TreeCursor';

// ── 工具函数 ──

function ensureGap(root: VstRow, cursor: Cursor): void {
  if (cursor.inLeaf()) {
    cursor.charOffset = -1;
    // 在分支内时，offset+1 可能越过分支行末尾，
    // 导致后续 rebuildPath / replaceAt 使用越界 childIdx → 崩溃。
    // 仅当 offset 仍在分支行范围内时才递增。
    if (cursor.path.length >= 2) {
      const branchRow: VstNode[] = resolveRow(root, cursor.path);
      if (cursor.offset + 1 <= branchRow.length) {
        cursor.offset = cursor.offset + 1;
      }
    } else {
      cursor.offset = cursor.offset + 1;
    }
  }
}

function cloneNode(node: VstNode): VstNode {
  return node.clone();
}

/** 从 root 出发，按 path 替换子节点为 newNode，返回新树 */
function replaceAt(root: VstRow, path: number[], newNode: VstNode): VstRow {
  if (path.length < 2) {
    const idx: number = path.length === 0 ? -1 : path[0];
    const newRow: VstRow = root.clone() as VstRow;
    if (idx >= 0 && idx < newRow.children.length) {
      newRow.children[idx] = newNode;
    }
    return newRow;
  }
  const childIdx: number = path[0];
  const branchCode: number = path[1];
  if (childIdx < 0 || childIdx >= root.children.length) return root;
  const child: VstNode = root.children[childIdx];
  const branch: VstNode[] | undefined = resolveBranch(child, branchCode);
  if (!branch) return root;
  const subRoot: VstRow = new VstRow(branch);
  const newSubRoot: VstRow = replaceAt(subRoot, path.slice(2), newNode);
  const structClone: VstNode = child.clone();
  setBranch(structClone, branchCode, newSubRoot.children);
  const rootClone: VstRow = root.clone() as VstRow;
  rootClone.children[childIdx] = structClone;
  return rootClone;
}

function setBranch(node: VstNode, branchCode: number, children: VstNode[]): void {
  if (branchCode === -1 && node instanceof VstFrac) node.num = children;
  else if (branchCode === -2 && node instanceof VstFrac) node.den = children;
  else if (branchCode === -3) {
    if (node instanceof VstSqrt) node.body = children;
    else if (node instanceof VstParen) node.body = children;
    else if (node instanceof VstFunc) node.body = children;
    else if (node instanceof VstCeil) node.body = children;
    else if (node instanceof VstFloor) node.body = children;
    else if (node instanceof VstNeg) node.body = children;
    else if (node instanceof VstRoot) node.body = children;
    else if (node instanceof VstLog) node.body = children;
    else if (node instanceof VstPostfix) node.body = children;
  }
  else if (branchCode === -4 && node instanceof VstPow) node.base = children;
  else if (branchCode === -5 && node instanceof VstPow) node.exp = children;
  else if (branchCode === -6 && node instanceof VstRoot) node.index = children;
  else if (branchCode === BRANCH_LOG_BASE && node instanceof VstLog) node.logBase = children;
}

function leafText(node: VstNode): string {
  if (node instanceof VstNum) return node.text;
  if (node instanceof VstVar) return node.name;
  if (node instanceof VstConst) return node.sym;
  return '';
}

function setLeafText(node: VstNode, text: string): void {
  if (node instanceof VstNum) node.text = text;
  else if (node instanceof VstVar) node.name = text;
  else if (node instanceof VstConst) node.sym = text;
}

function leafLen(node: VstNode): number {
  if (node instanceof VstNum) return node.text.length;
  if (node instanceof VstVar) return node.name.length;
  if (node instanceof VstConst) return node.sym.length;
  return 0;
}

function insertInRow(row: VstRow, offset: number, node: VstNode): VstRow {
  const newRow: VstRow = row.clone() as VstRow;
  const children: VstNode[] = newRow.children;
  if (offset >= children.length) {
    children.push(node);
  } else {
    const newCh: VstNode[] = [];
    for (let i = 0; i < children.length; i++) {
      if (i === offset) newCh.push(node);
      newCh.push(children[i]);
    }
    if (offset >= children.length) newCh.push(node);
    newRow.children = newCh;
  }
  return newRow;
}

function removeFromRow(row: VstRow, offset: number): [VstRow, VstNode | null] {
  const newRow: VstRow = row.clone() as VstRow;
  const children: VstNode[] = newRow.children;
  if (offset < 0 || offset >= children.length) return [newRow, null];
  const removed: VstNode = children[offset];
  const newCh: VstNode[] = [];
  for (let i = 0; i < children.length; i++) {
    if (i !== offset) newCh.push(children[i]);
  }
  newRow.children = newCh;
  return [newRow, removed];
}

function getRow(root: VstRow, cursor: Cursor): VstNode[] {
  return resolveRow(root, cursor.path);
}

function parentPath(cursor: Cursor): number[] {
  if (cursor.path.length < 2) return [];
  return cursor.path.slice(0, cursor.path.length - 2);
}

// ── 隐式参数捕获 ──

function captureLeftTerm(row: VstRow, offset: number): VstNode[] {
  const children: VstNode[] = row.children;
  const captured: VstNode[] = [];
  for (let i = offset - 1; i >= 0; i--) {
    const child: VstNode = children[i];
    if (child instanceof VstOp) break;
    if (child instanceof VstPlaceholder) break;
    captured.unshift(child.clone());
  }
  return captured;
}

// ── insertText ──

export function insertText(root: VstRow, cursor: Cursor, ch: string): [VstRow, Cursor] {
  let newCursor: Cursor = cursor.clone();
  const rowNodes: VstNode[] = getRow(root, cursor);

  if (cursor.inLeaf()) {
    const atom: VstNode = rowNodes[cursor.offset];
    const text: string = leafText(atom) + ch;
    const cloneAtom: VstNode = atom.clone();
    setLeafText(cloneAtom, text);
    const newRoot: VstRow = replaceAt(root, [...cursor.path, cursor.offset], cloneAtom);
    newCursor.charOffset = newCursor.charOffset + 1;
    return [newRoot, newCursor];
  }

  // 间隙态光标高亮叶子 → 将字符拼接到该叶子末尾。
  // 修复导航（← →）后光标落在叶子之前的间隙，
  // 导致 insertText 在叶子左侧插入新节点而非拼接到叶子末尾。
  if (cursor.offset < rowNodes.length) {
    const target: VstNode = rowNodes[cursor.offset];
    if (isLeafNode(target)) {
      const len: number = leafLen(target);
      if (len > 0) {
        const text: string = leafText(target) + ch;
        const cloneAtom: VstNode = target.clone();
        setLeafText(cloneAtom, text);
        const newRoot: VstRow = replaceAt(root, [...cursor.path, cursor.offset], cloneAtom);
        newCursor.offset = cursor.offset;
        newCursor.charOffset = len + 1;
        return [newRoot, newCursor];
      }
    }
  }

  if (cursor.offset < rowNodes.length && rowNodes[cursor.offset] instanceof VstPlaceholder) {
    const newNode: VstNum = new VstNum(ch);
    const newRoot: VstRow = replaceAt(root, [...cursor.path, cursor.offset], newNode);
    newCursor.charOffset = 1;
    return [newRoot, newCursor];
  }

  if (cursor.offset > 0) {
    const left: VstNode = rowNodes[cursor.offset - 1];
    if (left instanceof VstNum) {
      const newNum: VstNum = left.clone() as VstNum;
      newNum.text = newNum.text + ch;
      const newRoot: VstRow = replaceAt(root, [...cursor.path, cursor.offset - 1], newNum);
      newCursor.offset = cursor.offset - 1;
      newCursor.charOffset = newNum.text.length;
      return [newRoot, newCursor];
    }
  }

  const newNode: VstNum = new VstNum(ch);
  const newRow: VstRow = insertInRow(rowToVstRow(root, cursor.path), cursor.offset, newNode);
  const newRoot: VstRow = rebuildPath(root, cursor.path, newRow);
  newCursor.charOffset = 1;
  newCursor.offset = cursor.offset;
  return [newRoot, newCursor];
}

// ── insertAtom ──

export function insertAtom(root: VstRow, cursor: Cursor, node: VstNode): [VstRow, Cursor] {
  let newCursor: Cursor = cursor.clone();

  // 间隙→叶子转换：光标在间隙态高亮叶子时，移入叶子末尾。
  // 修复导航（← →）后光标落在叶子之前的间隙，
  // 导致 insertAtom 将新节点插入到叶子左侧而非右侧。
  if (!newCursor.inLeaf()) {
    const nodes: VstNode[] = getRow(root, newCursor);
    if (newCursor.offset < nodes.length) {
      const target: VstNode = nodes[newCursor.offset];
      if (isLeafNode(target)) {
        newCursor.charOffset = leafLen(target);
      }
    }
  }

  // ── 处理光标在叶子内的情况 ──
  // 退出叶子后 offset+1 可能越过分支行末尾，
  // 此时将 offset 回退到 branchRow.length - 1（叶子本身位置），
  // 后续占位符替换逻辑会替换该叶子，offset + 1 后指向新节点之后。
  let atBranchEnd: boolean = false;
  if (newCursor.inLeaf()) {
    newCursor.charOffset = -1;
    newCursor.offset = newCursor.offset + 1;
    if (newCursor.path.length >= 2) {
      const branchRow: VstNode[] = resolveRow(root, newCursor.path);
      if (newCursor.offset >= branchRow.length) {
        // 退出叶子后越界——回退到叶子位置（该位置应是占位符）
        newCursor.offset = branchRow.length - 1;
        atBranchEnd = true;
      }
    }
  }

  const rowNodes: VstNode[] = getRow(root, newCursor);

  // 占位符在当前 offset 位置
  if (newCursor.offset < rowNodes.length && rowNodes[newCursor.offset] instanceof VstPlaceholder) {
    const newRoot: VstRow = replaceAt(root, [...newCursor.path, newCursor.offset], node);
    newCursor.charOffset = -1;
    newCursor.offset = newCursor.offset + 1;
    return [newRoot, newCursor];
  }

  // 占位符在前一个位置
  if (newCursor.offset > 0 && rowNodes[newCursor.offset - 1] instanceof VstPlaceholder) {
    const newRoot: VstRow = replaceAt(root, [...newCursor.path, newCursor.offset - 1], node);
    newCursor.charOffset = -1;
    // 分支末尾替换：offset 需指向新节点之后（= branchRow.length）
    // 普通情况：offset 已在正确位置（替换不改变行长度）
    if (atBranchEnd) {
      newCursor.offset = newCursor.offset + 1;
    }
    return [newRoot, newCursor];
  }

  // 无占位符——在 gap 位置插入新节点
  // 分支末尾场景：之前为检查占位符将 offset 回退到 branchRow.length - 1，
  // 但实际插入应在 branchRow.length（叶子之后）。
  if (atBranchEnd) {
    newCursor.offset = newCursor.offset + 1;
  }
  const newRow: VstRow = insertInRow(rowToVstRow(root, newCursor.path), newCursor.offset, node);
  const newRoot: VstRow = rebuildPath(root, newCursor.path, newRow);
  // 插入后光标必须落在新节点之后（无论是否分支末尾）。
  // 旧逻辑在 atBranchEnd 时漏加 1，导致光标停在新插入的运算符之前：
  // 指数/分母内输入 5+6 时，6 被 insertText 拼接到左侧的 5 上变成 "56+"。
  newCursor.offset = newCursor.offset + 1;
  newCursor.charOffset = -1;
  return [newRoot, newCursor];
}

// ── insertOp ──

export function insertOp(root: VstRow, cursor: Cursor, op: string): [VstRow, Cursor] {
  if (op === '-' && cursor.offset === 0 && !cursor.inLeaf()) {
    return insertStruct(root, cursor, 'neg');
  }
  return insertAtom(root, cursor, new VstOp(op));
}

// ── makeFraction ──

export function makeFraction(root: VstRow, cursor: Cursor): [VstRow, Cursor] {
  let newCursor: Cursor = cursor.clone();
  // 间隙→叶子转换：导航后光标高亮叶子时，移入叶子末尾，
  // 使 ensureGap 退出到叶子之后，captureLeftTerm 正确拿到该叶子作为分子。
  if (!newCursor.inLeaf()) {
    const nodes: VstNode[] = getRow(root, newCursor);
    if (newCursor.offset < nodes.length) {
      const target: VstNode = nodes[newCursor.offset];
      if (isLeafNode(target)) {
        newCursor.charOffset = leafLen(target);
      }
    }
  }
  ensureGap(root, newCursor);
  const captured: VstNode[] = captureLeftTerm(rowToVstRow(root, newCursor.path), newCursor.offset);
  const frac: VstFrac = new VstFrac(
    captured.length > 0 ? captured : [new VstPlaceholder()],
    [new VstPlaceholder()]
  );

  let newRoot: VstRow;
  let insertIdx: number;

  if (captured.length > 0) {
    const oldRow: VstRow = rowToVstRow(root, newCursor.path);
    const newChildren: VstNode[] = [];
    const start: number = newCursor.offset - captured.length;
    for (let i = 0; i < oldRow.children.length; i++) {
      if (i < start || i >= newCursor.offset) {
        newChildren.push(oldRow.children[i].clone());
      }
    }
    const newRow: VstRow = new VstRow(newChildren);
    newRoot = rebuildPath(root, newCursor.path, newRow);
    const o2: number = start;
    const targetRow: VstRow = rowToVstRow(newRoot, newCursor.path);
    const inserted: VstRow = insertInRow(targetRow, o2, frac);
    newRoot = rebuildPath(newRoot, newCursor.path, inserted);
    insertIdx = o2;
    newCursor.path = [...newCursor.path, o2, -2];
  } else {
    const res: [VstRow, Cursor] = insertAtom(root, newCursor, frac);
    newRoot = res[0];
    insertIdx = res[1].offset - 1;
    newCursor.path = [...newCursor.path, insertIdx, -1];
  }

  newCursor.offset = 0;
  newCursor.charOffset = -1;
  return [newRoot, newCursor];
}

// ── makePower ──

export function makePower(root: VstRow, cursor: Cursor): [VstRow, Cursor] {
  let newCursor: Cursor = cursor.clone();
  // 间隙→叶子转换：导航后光标高亮叶子时，移入叶子末尾，
  // 使 ensureGap 退出到叶子之后，左邻捕获正确拿到该叶子作为底数。
  if (!newCursor.inLeaf()) {
    const nodes: VstNode[] = getRow(root, newCursor);
    if (newCursor.offset < nodes.length) {
      const target: VstNode = nodes[newCursor.offset];
      if (isLeafNode(target)) {
        newCursor.charOffset = leafLen(target);
      }
    }
  }
  ensureGap(root, newCursor);
  const rowNodes: VstNode[] = getRow(root, newCursor);

  let base: VstNode[] = [];
  let offsetChange: number = 0;
  if (newCursor.offset > 0) {
    const leftAtom: VstNode = rowNodes[newCursor.offset - 1];
    if (!(leftAtom instanceof VstOp) && !(leftAtom instanceof VstPlaceholder)) {
      base = [leftAtom.clone()];
      offsetChange = 1;
    }
  }
  if (base.length === 0) {
    base = [new VstPlaceholder()];
  }
  const exp: VstNode[] = [new VstPlaceholder()];
  const pow: VstPow = new VstPow(base, exp);

  let newRoot: VstRow;
  let insertIdx: number;

  if (offsetChange > 0) {
    const oldRow: VstRow = rowToVstRow(root, newCursor.path);
    const newChildren: VstNode[] = [];
    for (let i = 0; i < oldRow.children.length; i++) {
      if (i !== newCursor.offset - 1) newChildren.push(oldRow.children[i].clone());
    }
    const newRow: VstRow = new VstRow(newChildren);
    newRoot = rebuildPath(root, newCursor.path, newRow);
    const o2: number = newCursor.offset - 1;
    const targetRow: VstRow = rowToVstRow(newRoot, newCursor.path);
    const inserted: VstRow = insertInRow(targetRow, o2, pow);
    newRoot = rebuildPath(newRoot, newCursor.path, inserted);
    insertIdx = o2;
    newCursor.path = [...newCursor.path, o2, -5];
  } else {
    const res: [VstRow, Cursor] = insertAtom(root, newCursor, pow);
    newRoot = res[0];
    insertIdx = res[1].offset - 1;
    newCursor.path = [...newCursor.path, insertIdx, -4];
  }

  newCursor.offset = 0;
  newCursor.charOffset = -1;
  return [newRoot, newCursor];
}

// ── insertStruct ──

function needsImplicitMul(root: VstRow, cursor: Cursor, structKind: string): boolean {
  if (structKind !== 'abs' && structKind !== 'ceil' && structKind !== 'floor' &&
      structKind !== 'sqrt' && structKind !== 'root' && structKind !== 'paren') {
    return false;
  }
  if (cursor.offset <= 0 || cursor.inLeaf()) return false;
  const rowNodes: VstNode[] = getRow(root, cursor);
  const left: VstNode = rowNodes[cursor.offset - 1];
  return left instanceof VstNum || left instanceof VstVar || left instanceof VstConst ||
    left instanceof VstParen || left instanceof VstCeil || left instanceof VstFloor ||
    left instanceof VstPostfix || left instanceof VstFrac || left instanceof VstPow ||
    (left instanceof VstFunc && left.name === 'abs');
}

export function insertStruct(root: VstRow, cursor: Cursor, kind: string, extra?: string): [VstRow, Cursor] {
  let nodeObj: VstNode;
  let enterBranch: number = BRANCH_BODY;

  switch (kind) {
    case 'sqrt':
      nodeObj = new VstSqrt([new VstPlaceholder()]);
      break;
    case 'root':
      nodeObj = new VstRoot([new VstPlaceholder()], [new VstPlaceholder()]);
      enterBranch = BRANCH_BODY;
      break;
    case 'paren':
      nodeObj = new VstParen([new VstPlaceholder()]);
      break;
    case 'ceil':
      nodeObj = new VstCeil([new VstPlaceholder()]);
      break;
    case 'floor':
      nodeObj = new VstFloor([new VstPlaceholder()]);
      break;
    case 'func':
      nodeObj = new VstFunc(extra ?? 'f', [new VstPlaceholder()]);
      break;
    case 'neg':
      nodeObj = new VstNeg([new VstPlaceholder()]);
      break;
    case 'postfix':
      nodeObj = new VstPostfix(extra ?? '!', [new VstPlaceholder()]);
      break;
    case 'abs':
      nodeObj = new VstFunc('abs', [new VstPlaceholder()]);
      break;
    default:
      return [root, cursor.clone()];
  }

  let effectiveRoot: VstRow = root;
  let effectiveCursor: Cursor = cursor.clone();
  if (needsImplicitMul(root, cursor, kind)) {
    const mulResult: [VstRow, Cursor] = insertOp(effectiveRoot, effectiveCursor, '×');
    effectiveRoot = mulResult[0];
    effectiveCursor = mulResult[1];
  }

  const result = insertAtom(effectiveRoot, effectiveCursor, nodeObj);
  const newCursor: Cursor = result[1];
  const structIdx: number = newCursor.offset - 1;
  newCursor.path = [...newCursor.path, structIdx, enterBranch];
  newCursor.offset = 0;
  newCursor.charOffset = -1;

  return [result[0], newCursor];
}

/** makeNthRoot：插入 □^(1/□)，光标进入分母占位符 */
export function makeNthRoot(root: VstRow, cursor: Cursor): [VstRow, Cursor] {
  // 1. 先创建幂结构（会吸取左邻项作为底数）
  const powResult: [VstRow, Cursor] = makePower(root, cursor);
  let r2: VstRow = powResult[0];
  let c2: Cursor = powResult[1];

  // 2. 构造分数 1/□
  const frac: VstFrac = new VstFrac(
    [new VstNum('1')],
    [new VstPlaceholder()]
  );

  // 3. 用分数替换指数分支中的占位符
  const fracResult: [VstRow, Cursor] = insertAtom(r2, c2, frac);
  r2 = fracResult[0];
  c2 = fracResult[1];

  // 4. 光标进入分母占位符
  const fracIdx: number = c2.offset - 1;
  c2.path = [...c2.path, fracIdx, -2];
  c2.offset = 0;
  c2.charOffset = -1;

  return [r2, c2];
}

export function insertFunc(root: VstRow, cursor: Cursor, name: string): [VstRow, Cursor] {
  return insertStruct(root, cursor, 'func', name);
}

/** 插入对数函数 log_x(y)：底数为下标，参数为括号内内容 */
export function insertLog(root: VstRow, cursor: Cursor): [VstRow, Cursor] {
  const nodeObj: VstLog = new VstLog([new VstPlaceholder()], [new VstPlaceholder()]);
  const result = insertAtom(root, cursor.clone(), nodeObj);
  const newCursor: Cursor = result[1];
  // VstLog 插入后位于 newCursor.offset - 1
  const logIdx: number = newCursor.offset - 1;
  // 光标进入底数分支
  newCursor.path = [...newCursor.path, logIdx, BRANCH_LOG_BASE];
  newCursor.offset = 0;
  newCursor.charOffset = -1;
  return [result[0], newCursor];
}

/** insertPowBase：插入预设底数的幂结构 base^□，光标进入指数占位符。
 *  用于图键盘 e^x / 10^x 等快捷键。 */
export function insertPowBase(root: VstRow, cursor: Cursor, base: string): [VstRow, Cursor] {
  // 解析底数字符串为 VstNode
  let baseNode: VstNode;
  if (base === 'e') {
    baseNode = new VstConst('e');
  } else {
    baseNode = new VstNum(base);
  }
  const pow: VstPow = new VstPow([baseNode], [new VstPlaceholder()]);
  const result: [VstRow, Cursor] = insertAtom(root, cursor.clone(), pow);
  const newCursor: Cursor = result[1];
  const powIdx: number = newCursor.offset - 1;
  // 光标进入指数分支（BRANCH_EXP = -5）
  newCursor.path = [...newCursor.path, powIdx, -5];
  newCursor.offset = 0;
  newCursor.charOffset = -1;
  return [result[0], newCursor];
}

export function insertPostfix(root: VstRow, cursor: Cursor, op: string): [VstRow, Cursor] {
  let newCursor: Cursor = cursor.clone();
  // 间隙→叶子转换：导航后光标高亮叶子时，移入叶子末尾，
  // 使 ensureGap 退出到叶子之后，左邻捕获正确拿到该叶子作为操作数。
  if (!newCursor.inLeaf()) {
    const nodes: VstNode[] = getRow(root, newCursor);
    if (newCursor.offset < nodes.length) {
      const target: VstNode = nodes[newCursor.offset];
      if (isLeafNode(target)) {
        newCursor.charOffset = leafLen(target);
      }
    }
  }
  ensureGap(root, newCursor);
  const rowNodes: VstNode[] = getRow(root, newCursor);
  let captured: VstNode[] = [];
  let offsetChange: number = 0;
  if (newCursor.offset > 0) {
    const leftAtom: VstNode = rowNodes[newCursor.offset - 1];
    if (!(leftAtom instanceof VstOp) && !(leftAtom instanceof VstPlaceholder)) {
      captured = [leftAtom.clone()];
      offsetChange = 1;
    }
  }
  if (captured.length === 0) {
    captured = [new VstPlaceholder()];
  }

  const postfix: VstPostfix = new VstPostfix(op, captured);

  let newRoot: VstRow = root;
  let offset2: number = newCursor.offset;
  if (offsetChange > 0) {
    const oldRow: VstRow = rowToVstRow(root, newCursor.path);
    const newChildren: VstNode[] = [];
    for (let i = 0; i < oldRow.children.length; i++) {
      if (i !== newCursor.offset - 1) newChildren.push(oldRow.children[i].clone());
    }
    const newRow: VstRow = new VstRow(newChildren);
    newRoot = rebuildPath(root, newCursor.path, newRow);
    offset2 = newCursor.offset - 1;
  }

  const targetRow: VstRow = rowToVstRow(newRoot, newCursor.path);
  const inserted: VstRow = insertInRow(targetRow, offset2, postfix);
  newRoot = rebuildPath(newRoot, newCursor.path, inserted);

  newCursor.offset = offset2 + 1;
  newCursor.charOffset = -1;

  return [newRoot, newCursor];
}

// ── backspace ──

export function backspace(root: VstRow, cursor: Cursor): [VstRow, Cursor] {
  const newCursor: Cursor = cursor.clone();
  const rowNodes: VstNode[] = getRow(root, cursor);

  if (cursor.inLeaf() && cursor.charOffset > 0) {
    const atom: VstNode = rowNodes[cursor.offset];
    const text: string = leafText(atom);
    const newText: string = text.slice(0, cursor.charOffset - 1) + text.slice(cursor.charOffset);
    if (newText.length === 0) {
      const newRoot: VstRow = replaceAt(root, [...cursor.path, cursor.offset], new VstPlaceholder());
      newCursor.charOffset = -1;
      return [newRoot, newCursor];
    }
    const cloneAtom: VstNode = atom.clone();
    setLeafText(cloneAtom, newText);
    const newRoot: VstRow = replaceAt(root, [...cursor.path, cursor.offset], cloneAtom);
    newCursor.charOffset = cursor.charOffset - 1;
    return [newRoot, newCursor];
  }

  if (cursor.inLeaf() && cursor.charOffset === 0) {
    const _result1 = removeFromRow(rowToVstRow(root, cursor.path), cursor.offset);
    const newRow = _result1[0];
    const newRoot: VstRow = rebuildPath(root, cursor.path, newRow);
    newCursor.charOffset = -1;
    newCursor.offset = Math.min(cursor.offset, newRow.children.length);
    return [newRoot, newCursor];
  }

  // 间隙态：删除光标当前高亮的元素（与导航高亮的元素一致）。
  // 高亮元素索引与 cursorBoxRect 判定一致：offset < len → offset（间隙右侧节点）；
  // offset >= len（行尾）→ len-1（末节点）。修复旧逻辑“只删间隙左侧节点、
  // offset=0 时无操作”导致首元素/最后残留元素无法删除的“死结构”问题。
  if (rowNodes.length > 0) {
    const e: number = cursor.offset < rowNodes.length ? cursor.offset : rowNodes.length - 1;
    const _result2 = removeFromRow(rowToVstRow(root, cursor.path), e);
    const newRow = _result2[0];
    const newRoot: VstRow = rebuildPath(root, cursor.path, newRow);
    newCursor.offset = Math.min(e, newRow.children.length);
    newCursor.charOffset = -1;
    return [newRoot, newCursor];
  }

  if (cursor.offset === 0 && cursor.path.length >= 2) {
    const branchCode: number = cursor.path[cursor.path.length - 1];
    const myIdx: number = cursor.path[cursor.path.length - 2];
    const pp: number[] = parentPath(cursor);
    const parentRowNodes: VstNode[] = resolveRow(root, pp);
    if (myIdx < parentRowNodes.length) {
      const nodeObj: VstNode = parentRowNodes[myIdx];
      const allBranches: number[] = structBranches(nodeObj);
      const allContent: VstNode[] = [];
      for (const bc of allBranches) {
        const branchChildren: VstNode[] | undefined = resolveBranch(nodeObj, bc);
        if (branchChildren) {
          for (const c of branchChildren) {
            allContent.push(c.clone());
          }
        }
      }
      const parentRow: VstRow = rowToVstRow(root, pp);
      const newChildren: VstNode[] = [];
      for (let i = 0; i < parentRow.children.length; i++) {
        if (i === myIdx) {
          for (const c of allContent) newChildren.push(c);
        } else {
          newChildren.push(parentRow.children[i].clone());
        }
      }
      const newParentRow: VstRow = new VstRow(newChildren);
      const newRoot: VstRow = rebuildPath(root, pp, newParentRow);
      newCursor.path = [...pp];
      newCursor.offset = myIdx;
      newCursor.charOffset = -1;
      return [newRoot, newCursor];
    }
  }

  return [root, newCursor];
}

// ── closeParen ──

/**
 * 右括号智能响应（参考 鍘熷寮曟搸 设计模式）：
 *
 * 1.「关闭」语义 —— 光标直接位于 VstParen 的 body 分支内时：
 *    将光标移出该括号（落到其右侧间隙），不改动树结构。
 *    覆盖「按 ( 插入括号对 → 输入内容 → 按 ) 退出」的自然输入流程，避免重复包裹。
 *
 * 2.「包裹」语义 —— 其余情况（根行，或指数/分母/函数参数/根式等子分支）：
 *    将光标所在的整行用 VstParen 包裹，光标置于新括号右侧。
 *    - 根行 2x+3，光标在 3 右侧 → (2x+3)
 *    - 指数分支 E^⟨2x+1⟩，光标在 1 右侧 → E^((2x+1))
 *    支持任意嵌套（分数、指数、函数参数、根式等），仅包裹光标所在子分支的整行。
 */
export function closeParen(root: VstRow, cursor: Cursor): [VstRow, Cursor] {
  const c: Cursor = cursor.clone();
  ensureGap(root, c);

  // ── 1. 关闭：光标直接位于 VstParen 的 body 分支内 → 移出该括号 ──
  if (c.path.length >= 2) {
    const branchCode: number = c.path[c.path.length - 1];
    const parenIdx: number = c.path[c.path.length - 2];
    const pp: number[] = c.path.slice(0, c.path.length - 2);
    const parentRow: VstNode[] = resolveRow(root, pp);
    if (branchCode === BRANCH_BODY && parenIdx >= 0 && parenIdx < parentRow.length &&
        parentRow[parenIdx] instanceof VstParen) {
      c.path = [...pp];
      c.offset = parenIdx + 1;
      c.charOffset = -1;
      return [root, c];
    }
  }

  // ── 2. 包裹：将光标所在整行用 VstParen 包裹 ──
  const rowNodes: VstNode[] = getRow(root, c);
  if (rowNodes.length === 0) {
    return [root, c];  // 空行防御：不执行任何操作
  }
  // 幂等守卫：整行已是单个括号时不重复包裹，仅将光标移到该括号右侧
  if (rowNodes.length === 1 && rowNodes[0] instanceof VstParen) {
    c.offset = 1;
    c.charOffset = -1;
    return [root, c];
  }
  const paren: VstParen = new VstParen(rowNodes);
  const newRow: VstRow = new VstRow([paren]);
  const newRoot: VstRow = rebuildPath(root, c.path, newRow);
  c.offset = 1;
  c.charOffset = -1;
  return [newRoot, c];
}

export function doMoveLeft(root: VstRow, cursor: Cursor): Cursor {
  const c: Cursor = cursor.clone();
  cursorMoveLeft(root, c);
  return c;
}

export function doMoveRight(root: VstRow, cursor: Cursor): Cursor {
  const c: Cursor = cursor.clone();
  cursorMoveRight(root, c);
  return c;
}

export function doMoveUp(root: VstRow, cursor: Cursor): Cursor {
  const c: Cursor = cursor.clone();
  cursorMoveUp(root, c);
  return c;
}

export function doMoveDown(root: VstRow, cursor: Cursor): Cursor {
  const c: Cursor = cursor.clone();
  cursorMoveDown(root, c);
  return c;
}

// ── 辅助：path → VstRow ──

function rowToVstRow(root: VstRow, path: number[]): VstRow {
  if (path.length === 0) return root;
  const rowNodes: VstNode[] = resolveRow(root, path);
  return new VstRow(rowNodes);
}

function rebuildPath(root: VstRow, path: number[], newRow: VstRow): VstRow {
  if (path.length === 0) return newRow;
  if (path.length < 2) {
    const idx: number = path[0];
    const r: VstRow = root.clone() as VstRow;
    r.children = newRow.children;
    return r;
  }
  const childIdx: number = path[0];
  const branchCode: number = path[1];
  // 防御性边界检查：光标路径与树结构不一致时安全回退
  if (childIdx < 0 || childIdx >= root.children.length) {
    return root;
  }
  const child: VstNode = root.children[childIdx];
  const branchChildren: VstNode[] | undefined = resolveBranch(child, branchCode);
  if (!branchChildren) {
    return root;
  }
  const subRoot: VstRow = new VstRow(branchChildren);
  const newSubRoot: VstRow = rebuildPath(subRoot, path.slice(2), newRow);
  const structClone: VstNode = child.clone();
  setBranch(structClone, branchCode, newSubRoot.children);
  const rootClone: VstRow = root.clone() as VstRow;
  rootClone.children[childIdx] = structClone;
  return rootClone;
}
