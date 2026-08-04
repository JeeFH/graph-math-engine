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
// vst/VstEditor.ets
// 自研编辑器门面：持 root + Cursor，提供 execute() 命令调度 + undo/redo 快照栈。
// 对标 MathLive 的 _Model + command dispatch，但精简为纯数据 + 快照栈。
// 注：本文件为 vst2/MathField 的自研重写版，命令实现来自 vst/Commands。

import { VstRow, VstPlaceholder, VstVar, VstConst } from './VstNodes';
import { Cursor, moveLeft, moveRight, moveUp, moveDown, BRANCH_EXP } from './TreeCursor';
import {
  insertText, insertAtom, insertOp, makeFraction, makePower, makeNthRoot,
  insertStruct, insertFunc, insertPostfix, insertLog, insertPowBase, backspace,
  doMoveLeft, doMoveRight, doMoveUp, doMoveDown, closeParen
} from './Commands';
import { serializeLinear } from './VstSerializer';

// ── 快照 ──

interface Snapshot {
  root: VstRow;
  cursor: Cursor;
}

export class MathField {
  root: VstRow;
  cursor: Cursor;
  /** 版本计数器：每次 execute/undo/redo 成功后递增，供外部消费者（如 MathFieldView）感知变更 */
  version: number = 0;
  private undoStack: Snapshot[] = [];
  private redoStack: Snapshot[] = [];
  private maxUndo: number = 100;

  onChange?: () => void;
  onCursorChange?: () => void;

  constructor(initialRoot?: VstRow, initialCursor?: Cursor) {
    this.root = initialRoot ?? new VstRow([new VstPlaceholder()]);
    this.cursor = initialCursor ?? new Cursor([], 0, -1);
  }

  /** 初始化/重置为占位符根 */
  reset(): void {
    this.root = new VstRow([new VstPlaceholder()]);
    this.cursor = new Cursor([], 0, -1);
    this.undoStack = [];
    this.redoStack = [];
    this.version++;
  }

  /** 从现有 VstRow 和光标创建（用于切换函数时加载已有表达式）*/
  load(root: VstRow, cursorAtEnd?: boolean): void {
    this.root = root.clone() as VstRow;
    this.cursor = new Cursor();
    if (cursorAtEnd) {
      this.cursor.offset = root.children.length;
      this.cursor.charOffset = -1;
    }
    this.undoStack = [];
    this.redoStack = [];
    this.version++;
  }

  // ── 命令调度 ──

  /** 通用命令入口 */
  execute(command: string, ...args: string[]): boolean {
    // 保存快照（撤销用）
    this.pushUndo();
    this.redoStack = [];

    let handled: boolean = true;
    let newResult: [VstRow, Cursor] = [this.root, this.cursor.clone()];

    switch (command) {
      case 'insertText':
        newResult = insertText(this.root, this.cursor, args[0] ?? '');
        break;
      case 'insertNum':
        newResult = insertText(this.root, this.cursor, args[0] ?? '');
        break;
      case 'insertVar':
        newResult = insertAtom(this.root, this.cursor, new VstVar(args[0] ?? 'x'));
        break;
      case 'insertConst':
        newResult = insertAtom(this.root, this.cursor, new VstConst(args[0] ?? 'e'));
        break;
      case 'insertOp':
        newResult = insertOp(this.root, this.cursor, args[0] ?? '+');
        break;
      case 'makeFraction':
        newResult = makeFraction(this.root, this.cursor);
        break;
      case 'makePower':
        newResult = makePower(this.root, this.cursor);
        break;
      case 'makePowerFill':
        // makePowerFill(base): 先 makePower，再填指数
        newResult = makePower(this.root, this.cursor);
        if (args[0]) {
          const r2: VstRow = newResult[0];
          const c2: Cursor = newResult[1];
          // 在指数 placeholder 上 insertText
          newResult = insertText(r2, c2, args[0]);
          // 填充预设指数后退出 exp 分支，光标落在整个 Pow 之后，
          // 后续输入向右追加（修复“输入跑到左侧”问题）
          const c3: Cursor = newResult[1];
          if (c3.path.length >= 2 && c3.path[c3.path.length - 1] === BRANCH_EXP) {
            const powIdx: number = c3.path[c3.path.length - 2];
            c3.path = c3.path.slice(0, c3.path.length - 2);
            c3.offset = powIdx + 1;
            c3.charOffset = -1;
            newResult = [newResult[0], c3];
          }
        }
        break;
      case 'makeNthRoot':
        // makeNthRoot：插入 □^(1/□)，光标进入分母
        newResult = makeNthRoot(this.root, this.cursor);
        break;
      case 'insertStruct':
        newResult = insertStruct(this.root, this.cursor, args[0] ?? '', args[1]);
        break;
      case 'insertFunc':
        newResult = insertFunc(this.root, this.cursor, args[0] ?? 'f');
        break;
      case 'insertLog':
        newResult = insertLog(this.root, this.cursor);
        break;
      case 'insertPowBase':
        newResult = insertPowBase(this.root, this.cursor, args[0] ?? 'e');
        break;
      case 'insertPostfix':
        newResult = insertPostfix(this.root, this.cursor, args[0] ?? '!');
        break;
      case 'backspace':
        newResult = backspace(this.root, this.cursor);
        break;
      case 'moveLeft':
        this.undoStack.pop();
        newResult = [this.root, doMoveLeft(this.root, this.cursor)];
        break;
      case 'moveRight':
        this.undoStack.pop();
        newResult = [this.root, doMoveRight(this.root, this.cursor)];
        break;
      case 'moveUp':
        this.undoStack.pop();
        newResult = [this.root, doMoveUp(this.root, this.cursor)];
        break;
      case 'moveDown':
        this.undoStack.pop();
        newResult = [this.root, doMoveDown(this.root, this.cursor)];
        break;
      case 'closeParen':
        newResult = closeParen(this.root, this.cursor);
        // 「关闭」仅移动光标（root 引用不变）→ 弹出快照不建撤销点；
        // 「包裹」会改动树结构（root 为新对象）→ 保留快照作为撤销点。
        if (newResult[0] === this.root) {
          this.undoStack.pop();
        }
        break;
      case 'undo':
        this.undoStack.pop();
        return this.doUndo();
      case 'redo':
        this.undoStack.pop();
        return this.doRedo();
      default:
        handled = false;
        this.undoStack.pop();
        break;
    }

    if (handled) {
      this.root = newResult[0];
      // 空根守卫：结构解体可能掏空根行，恢复为占位符根
      if (this.root.children.length === 0) {
        this.root = new VstRow([new VstPlaceholder()]);
        this.cursor = new Cursor([], 0, -1);
      } else {
        this.cursor = newResult[1];
      }
      this.version++;
      this.fireCallbacks();
    }
    return handled;
  }

  // ── undo/redo ──

  private pushUndo(): void {
    const snap: Snapshot = {
      root: this.root.clone() as VstRow,
      cursor: this.cursor.clone()
    };
    this.undoStack.push(snap);
    if (this.undoStack.length > this.maxUndo) {
      this.undoStack.shift();
    }
  }

  private doUndo(): boolean {
    if (this.undoStack.length === 0) return false;
    this.redoStack.push({
      root: this.root.clone() as VstRow,
      cursor: this.cursor.clone()
    });
    const snap: Snapshot = this.undoStack.pop()!;
    this.root = snap.root;
    this.cursor = snap.cursor;
    this.version++;
    this.fireCallbacks();
    return true;
  }

  private doRedo(): boolean {
    if (this.redoStack.length === 0) return false;
    this.undoStack.push({
      root: this.root.clone() as VstRow,
      cursor: this.cursor.clone()
    });
    const snap: Snapshot = this.redoStack.pop()!;
    this.root = snap.root;
    this.cursor = snap.cursor;
    this.version++;
    this.fireCallbacks();
    return true;
  }

  // ── 序列化（求值用）──

  serialize(): string {
    return serializeLinear(this.root);
  }

  private fireCallbacks(): void {
    if (this.onChange) this.onChange();
    if (this.onCursorChange) this.onCursorChange();
  }
}
