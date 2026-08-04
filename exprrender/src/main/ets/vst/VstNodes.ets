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
// vst/VstNodes.ets
// 自研 VST 节点模型（视觉语法树）。
// 设计：运算符降级为"行内原子"；每个结构的"洞"是一行（VstNode[]）。
// 与 鍘熷寮曟搸 retex 的 Atom 树不同，这里模型与布局严格分离（布局见 box/ + engine/ExprRender）。

export type BranchName = 'body' | 'num' | 'den' | 'base' | 'exp' | 'index' | 'logBase';

/** VST 节点基类 */
export class VstNode {
  kind: string = '';

  /** 子节点列表（VstRow: 所有行内原子；叶子: []; 结构: 空但由分支方法提供） */
  getChildren(): VstNode[] { return []; }
  setChild(_index: number, _child: VstNode): void {}
  childCount(): number { return 0; }

  /** 结构的分支列表 */
  branches(): Record<string, VstNode[]> { return {}; }

  /** 深拷贝 */
  clone(): VstNode { return new VstNode(); }

  /** 判断是否为叶子（没有分支，也没有行内的子节点） */
  isLeaf(): boolean { return true; }
}

// ── 行（序列容器）──

export class VstRow extends VstNode {
  children: VstNode[] = [];

  constructor(children: VstNode[] = []) {
    super();
    this.kind = 'row';
    this.children = [...children];
  }

  getChildren(): VstNode[] { return this.children; }
  setChild(index: number, child: VstNode): void {
    if (index >= 0 && index < this.children.length) {
      this.children[index] = child;
    }
  }
  childCount(): number { return this.children.length; }

  clone(): VstRow {
    const clonedChildren: VstNode[] = [];
    for (const c of this.children) {
      clonedChildren.push(c.clone());
    }
    return new VstRow(clonedChildren);
  }

  isLeaf(): boolean { return false; }
}

// ── 叶子节点 ──

/** 数字 "123", "1.5", "-3" */
export class VstNum extends VstNode {
  text: string;

  constructor(text: string) {
    super();
    this.kind = 'num';
    this.text = text;
  }

  clone(): VstNum { return new VstNum(this.text); }
  leafLength(): number { return this.text.length; }
}

/** 变量 x, y, z, t... */
export class VstVar extends VstNode {
  name: string;

  constructor(name: string) {
    super();
    this.kind = 'var';
    this.name = name;
  }

  clone(): VstVar { return new VstVar(this.name); }
  leafLength(): number { return this.name.length; }
}

/** 常量 π, e */
export class VstConst extends VstNode {
  sym: string;

  constructor(sym: string) {
    super();
    this.kind = 'const';
    this.sym = sym;
  }

  clone(): VstConst { return new VstConst(this.sym); }
  leafLength(): number { return this.sym.length; }
}

/** 运算符 + - × ÷ = , */
export class VstOp extends VstNode {
  sym: string;

  constructor(sym: string) {
    super();
    this.kind = 'op';
    this.sym = sym;
  }

  clone(): VstOp { return new VstOp(this.sym); }
  leafLength(): number { return this.sym.length; }
}

/** 占位符（未完成输入） */
export class VstPlaceholder extends VstNode {
  constructor() {
    super();
    this.kind = 'placeholder';
  }
  clone(): VstPlaceholder { return new VstPlaceholder(); }
  leafLength(): number { return 0; }
}

// ── 结构节点 ──

function cloneRow(arr: VstNode[] | undefined): VstNode[] {
  if (!arr) return [];
  const result: VstNode[] = [];
  for (const n of arr) { result.push(n.clone()); }
  return result;
}

/** 分式：分子/分母各为一行 */
export class VstFrac extends VstNode {
  num: VstNode[] = [];
  den: VstNode[] = [];

  constructor(num: VstNode[] = [], den: VstNode[] = []) {
    super();
    this.kind = 'frac';
    this.num = cloneRow(num);
    this.den = cloneRow(den);
  }

  branches(): Record<string, VstNode[]> {
    return { 'num': this.num, 'den': this.den };
  }

  clone(): VstFrac {
    return new VstFrac(cloneRow(this.num), cloneRow(this.den));
  }

  isLeaf(): boolean { return false; }
}

/** 平方根：body 为一行 */
export class VstSqrt extends VstNode {
  body: VstNode[] = [];

  constructor(body: VstNode[] = []) {
    super();
    this.kind = 'sqrt';
    this.body = cloneRow(body);
  }

  branches(): Record<string, VstNode[]> { return { 'body': this.body }; }
  clone(): VstSqrt { return new VstSqrt(cloneRow(this.body)); }
  isLeaf(): boolean { return false; }
}

/** n 次根：双洞 index 和 body */
export class VstRoot extends VstNode {
  index: VstNode[] = [];
  body: VstNode[] = [];

  constructor(index: VstNode[] = [], body: VstNode[] = []) {
    super();
    this.kind = 'root';
    this.index = cloneRow(index);
    this.body = cloneRow(body);
  }

  branches(): Record<string, VstNode[]> {
    return { 'index': this.index, 'body': this.body };
  }

  clone(): VstRoot {
    return new VstRoot(cloneRow(this.index), cloneRow(this.body));
  }

  isLeaf(): boolean { return false; }
}

/** 幂：base 和 exp 各为一行 */
export class VstPow extends VstNode {
  base: VstNode[] = [];
  exp: VstNode[] = [];

  constructor(base: VstNode[] = [], exp: VstNode[] = []) {
    super();
    this.kind = 'pow';
    this.base = cloneRow(base);
    this.exp = cloneRow(exp);
  }

  branches(): Record<string, VstNode[]> {
    return { 'base': this.base, 'exp': this.exp };
  }

  clone(): VstPow {
    return new VstPow(cloneRow(this.base), cloneRow(this.exp));
  }

  isLeaf(): boolean { return false; }
}

/** 括号包裹 */
export class VstParen extends VstNode {
  body: VstNode[] = [];

  constructor(body: VstNode[] = []) {
    super();
    this.kind = 'paren';
    this.body = cloneRow(body);
  }

  branches(): Record<string, VstNode[]> { return { 'body': this.body }; }
  clone(): VstParen { return new VstParen(cloneRow(this.body)); }
  isLeaf(): boolean { return false; }
}

/** 函数调用：name + 参数行 */
export class VstFunc extends VstNode {
  name: string;
  body: VstNode[] = [];

  constructor(name: string, body: VstNode[] = []) {
    super();
    this.kind = 'func';
    this.name = name;
    this.body = cloneRow(body);
  }

  branches(): Record<string, VstNode[]> { return { 'body': this.body }; }
  clone(): VstFunc { return new VstFunc(this.name, cloneRow(this.body)); }
  isLeaf(): boolean { return false; }
}

/** 上取整 */
export class VstCeil extends VstNode {
  body: VstNode[] = [];

  constructor(body: VstNode[] = []) {
    super();
    this.kind = 'ceil';
    this.body = cloneRow(body);
  }

  branches(): Record<string, VstNode[]> { return { 'body': this.body }; }
  clone(): VstCeil { return new VstCeil(cloneRow(this.body)); }
  isLeaf(): boolean { return false; }
}

/** 下取整 */
export class VstFloor extends VstNode {
  body: VstNode[] = [];

  constructor(body: VstNode[] = []) {
    super();
    this.kind = 'floor';
    this.body = cloneRow(body);
  }

  branches(): Record<string, VstNode[]> { return { 'body': this.body }; }
  clone(): VstFloor { return new VstFloor(cloneRow(this.body)); }
  isLeaf(): boolean { return false; }
}

/** 阶乘等后缀：body 是操作数 */
export class VstPostfix extends VstNode {
  op: string;
  body: VstNode[] = [];

  constructor(op: string, body: VstNode[] = []) {
    super();
    this.kind = 'postfix';
    this.op = op;
    this.body = cloneRow(body);
  }

  branches(): Record<string, VstNode[]> { return { 'body': this.body }; }
  clone(): VstPostfix { return new VstPostfix(this.op, cloneRow(this.body)); }
  isLeaf(): boolean { return false; }
}

/** 对数函数 log_base(body)：base 为底数（下标），body 为参数 */
export class VstLog extends VstNode {
  logBase: VstNode[] = [];
  body: VstNode[] = [];

  constructor(logBase: VstNode[] = [], body: VstNode[] = []) {
    super();
    this.kind = 'log';
    this.logBase = cloneRow(logBase);
    this.body = cloneRow(body);
  }

  branches(): Record<string, VstNode[]> {
    return { 'logBase': this.logBase, 'body': this.body };
  }

  clone(): VstLog {
    return new VstLog(cloneRow(this.logBase), cloneRow(this.body));
  }

  isLeaf(): boolean { return false; }
}

/** 一元负号 */
export class VstNeg extends VstNode {
  body: VstNode[] = [];

  constructor(body: VstNode[] = []) {
    super();
    this.kind = 'neg';
    this.body = cloneRow(body);
  }

  branches(): Record<string, VstNode[]> { return { 'body': this.body }; }
  clone(): VstNeg { return new VstNeg(cloneRow(this.body)); }
  isLeaf(): boolean { return false; }
}
