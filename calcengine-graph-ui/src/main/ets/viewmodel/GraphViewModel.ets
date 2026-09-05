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
// calcengine-graph-ui/src/main/ets/viewmodel/GraphViewModel.ets
/**
 * 图形模式 ViewModel（状态管理核心）
 *
 * 职责：
 * 1. 持有并管理 graphFunctions 数组（增/删/改）
 * 2. 持有 graphActiveId / graphNextId / isDegMode
 * 3. 持有 graphExprErrors / graphValidatedIds 状态
 * 4. 持有 graphFields: Map<number, MathField> 实例池
 * 5. 持有 RenderDispatcher 实例（从 GraphCanvas 迁移过来，共享同一实例）
 * 6. 暴露 classifyResult 查询接口（供 UI 层显示模式标签）
 *
 * 约束：
 * - 纯逻辑类，不依赖任何 UI 组件（无 build()/struct，不 import 任何组件）
 * - 可观察属性以 @Trace 标记，配合 @ObservedV2 驱动 @ComponentV2（宿主组件）重渲染
 * - ArkTS 严格模式：无 any/unknown，所有字段均有明确类型注解
 */

// 引擎符号统一从 calcengine-graph 包入口导入（本文件已从引擎包移出至 UI 包，
// 不再与 engine/types 同处一个模块，相对路径已不适用）。
import {
  GraphFunction, GraphLineStyle, MarkerCategory, GRAPH_PALETTE,
  graphDisplayName, nextFreeLabelIndex,
  RenderDispatcher, RenderMode, renderModeLabel, ExprClassifier,
  FunctionEvaluator, BivariateEvaluator, type ClassifyResult
} from 'calcengine-graph';
import { MathField, parseLinear, simplify, serializeLinear, Cursor, VstRow } from 'calcengine-exp';
import { getMathLogger } from 'calcengine-core';

@ObservedV2
export class GraphViewModel {
  // ── 核心状态（@Trace 驱动 UI 重渲染） ──
  /** 函数列表（单一真相源，GraphCanvas / GraphDisplayArea 均从此读取） */
  @Trace private _functions: GraphFunction[] = [
    { id: 1, expr: '', color: GRAPH_PALETTE[0], enabled: true, lineStyle: 'solid', lineWidth: 3, name: undefined, labelIndex: 0 }
  ];
  /** 当前选中函数 id */
  @Trace private _activeId: number = 1;
  /** 角度模式（DEG=true / RAD=false） */
  @Trace private _isDegMode: boolean = false;
  /** MathField 版本计数器，每次 execute 后递增，驱动 MathFieldView 光标重绘 */
  @Trace private _fieldVersion: number = 0;
  /** 表达式验证错误集合：驱动红色背景 + 表达式变色 */
  @Trace private _exprErrors: Set<number> = new Set();
  /** 错误状态版本号，变化时触发 GraphDisplayArea 重渲染 */
  @Trace private _exprErrorVersion: number = 0;
  /** 呼吸灯闪烁目标 id：驱动 GraphDisplayArea 对已有空占位条目执行闪烁提醒 */
  @Trace private _flashId: number = -1;

  // ── 内部状态（非可观察） ──
  /** 自增 ID */
  private _nextId: number = 2;
  /** 统一渲染调度器（从 GraphCanvas 迁移，与 GraphCanvas 共享同一实例） */
  private renderDispatcher: RenderDispatcher = new RenderDispatcher();
  /** 模式缓存（fnId → ClassifyResult，供 UI 消费） */
  private classifyCache: Map<number, ClassifyResult> = new Map();
  /** MathField 实例池 */
  private fields: Map<number, MathField> = new Map();
  /** 已验证过的函数 ID 集合（懒渲染状态：光标离开后进入懒模式） */
  private validatedIds: Set<number> = new Set();

  // ── 公开只读访问器 ──
  get functions(): GraphFunction[] {
    return this._functions;
  }

  get activeId(): number {
    return this._activeId;
  }

  get isDegMode(): boolean {
    return this._isDegMode;
  }

  get fieldVersion(): number {
    return this._fieldVersion;
  }

  get exprErrors(): Set<number> {
    return this._exprErrors;
  }

  get exprErrorVersion(): number {
    return this._exprErrorVersion;
  }

  /** 呼吸灯闪烁目标 id（-1 = 无闪烁） */
  get flashId(): number {
    return this._flashId;
  }

  /**
   * 获取指定函数的渲染模式可读标签（供 UI 模式标签显示）。
   * 空表达式返回空字符串。
   */
  getModeLabel(fnId: number): string {
    const cached: ClassifyResult | undefined = this.classifyCache.get(fnId);
    if (cached !== undefined) {
      return renderModeLabel(cached.mode);
    }
    // 缓存缺失时（如 setDegMode 清空缓存后）按当前表达式实时分类并回填缓存
    const fn: GraphFunction | undefined =
      this._functions.find((f: GraphFunction): boolean => f.id === fnId);
    if (fn === undefined || fn.expr.trim().length === 0) {
      return '';
    }
    const result: ClassifyResult = ExprClassifier.classify(fn.expr);
    this.classifyCache.set(fnId, result);
    return renderModeLabel(result.mode);
  }

  /** 获取指定函数的分类结果（尚未分类时返回 null） */
  getClassify(fnId: number): ClassifyResult | null {
    const cached: ClassifyResult | undefined = this.classifyCache.get(fnId);
    return cached !== undefined ? cached : null;
  }

  // ── 操作方法 ──

  /**
   * 新增函数，返回新函数 id。
   * 约束：列表中最多存在 1 个空表达式条目，且必须是末尾条目（作为新建占位符）。
   * 若末尾已有空占位符，不新增条目，改为触发闪烁提醒并返回该占位符 id。
   */
  addFunction(): number {
    // 焦点即将离开旧活跃槽：自动保存其编辑中内容，避免未点 √ 导致完成态丢失
    if (this._activeId >= 0) {
      this.flushFieldToExpr(this._activeId);
    }
    // 约束检查：末尾条目是否已是空占位符
    const lastFn: GraphFunction | undefined = this._functions[this._functions.length - 1];
    if (lastFn !== undefined && lastFn.expr.trim().length === 0) {
      // 已有空占位符 → 闪烁提醒 + 选中该占位符，不新增
      this._flashId = lastFn.id;
      this._activeId = lastFn.id;
      const field: MathField = this.getField(lastFn.id);
      field.cursor = new Cursor([], 0, -1);
      field.version++;
      field.onChange?.();
      setTimeout((): void => { this._flashId = -1; }, 700);
      return lastFn.id;
    }
    const color: string = GRAPH_PALETTE[this._functions.length % GRAPH_PALETTE.length];
    const newId: number = this._nextId;
    // 固定标签序号：取当前默认名称函数已占用序号中的最小空闲值（删除留下的空缺可被复用，但绝不影响已有函数的标签）
    const labelIdx: number = nextFreeLabelIndex(this._functions);
    const fn: GraphFunction = {
      id: newId, expr: '', color: color, enabled: true,
      lineStyle: 'solid', lineWidth: 3, name: undefined, labelIndex: labelIdx
    };
    this._functions = [...this._functions, fn];
    this._nextId++;
    this._activeId = newId;
    const field: MathField = this.ensureField(newId, '?');
    field.cursor = new Cursor([], 0, -1);
    field.version++;
    field.onChange?.();
    this.syncToRenderDispatcher();
    return newId;
  }

  /**
   * 导入外部表达式（历史页跨页导入专用）：
   * 1. 复用 addFunction 的槽位选择策略（末尾空槽优先，否则新建并分配递增标签 y₁/y₂…）
   * 2. setExpr 写入完成态 + 同步渲染调度器
   * 3. 移除旧 MathField 并按导入表达式重建编辑态，避免占位符 '?' 覆盖导入内容
   */
  importExpr(expr: string): number {
    const id: number = this.addFunction();
    this.setExpr(id, expr);
    // 关键修复：重建 MathField，使编辑态与完成态一致
    this.removeField(id);
    try {
      const field: MathField = this.ensureField(id, expr);
      field.cursor = new Cursor([], 0, -1);
      field.version++;
      field.onChange?.();
    } catch (e) {
      getMathLogger().warn(`[GraphViewModel] importExpr: field rebuild failed for id=${id}`);
    }
    return id;
  }

  /** 删除函数（同步清理关联缓存、MathField、错误与懒渲染状态） */
  removeFunction(id: number): void {
    this._functions = this._functions.filter((f: GraphFunction): boolean => f.id !== id);
    this.removeField(id);
    this.classifyCache.delete(id);
    this.validatedIds.delete(id);
    if (this._exprErrors.has(id)) {
      const newErrors: Set<number> = new Set(this._exprErrors);
      newErrors.delete(id);
      this._exprErrors = newErrors;
      this._exprErrorVersion++;
    }
    if (this._activeId === id) {
      this._activeId = this._functions.length > 0 ? this._functions[0].id : -1;
      if (this._activeId >= 0) {
        const field: MathField = this.getField(this._activeId);
        field.cursor = new Cursor([], 0, -1);
        field.version++;
        field.onChange?.();
      }
    }
    this.syncToRenderDispatcher();
  }

  /**
   * 设置表达式（核心逻辑）：
   * 1. 更新 _functions 数组中对应 fn 的 expr（并写入 renderMode）
   * 2. 调用 ExprClassifier.classify(expr) 更新 classifyCache
   * 3. 调用 renderDispatcher.syncFunctions() 触发渲染器重建
   * 4. 标记 validatedIds 中该 id 为已验证
   */
  setExpr(id: number, expr: string): void {
    const classify: ClassifyResult = ExprClassifier.classify(expr);
    this._functions = this._functions.map((f: GraphFunction): GraphFunction => {
      if (f.id === id) {
        const updated: GraphFunction = this.copyFunction(f);
        updated.expr = expr;
        updated.renderMode = classify.mode;
        return updated;
      }
      return f;
    });
    this.classifyCache.set(id, classify);
    this.renderDispatcher.syncFunctions(this._functions, this._isDegMode);
    this.validatedIds.add(id);
    // 约束：非末尾条目表达式被清空时自动销毁（用户主动清空 → 条目自动移除）
    if (expr.trim().length === 0 && this._functions.length > 1) {
      const thisIdx: number = this._functions.findIndex((f: GraphFunction): boolean => f.id === id);
      const lastIdx: number = this._functions.length - 1;
      if (thisIdx >= 0 && thisIdx < lastIdx) {
        this.removeFunction(id);
      }
    }
  }

  /** 设置当前选中函数（光标离开旧槽位时自动保存编辑内容并标记为已验证，重置新槽位光标） */
  setActiveId(id: number): void {
    if (!this._functions.some((f: GraphFunction): boolean => f.id === id)) {
      return;
    }
    if (this._activeId >= 0 && this._activeId !== id) {
      // 自动缓存保存：用户未点 √ 就转移焦点时，将活跃态完整表达式同步到完成态，
      // 避免 ExprView 显示上次 flush 的旧值（如 sin(x) 变成 sin）
      this.flushFieldToExpr(this._activeId);
      this.validatedIds.add(this._activeId);
    }
    this._activeId = id;
    const field: MathField = this.getField(id);
    field.cursor = new Cursor([], 0, -1);
    field.version++;
    field.onChange?.();
  }

  /**
   * 取消当前活跃槽的编辑态：flush 编辑内容 → 标记已验证 → 设 activeId = -1。
   * 用于点击 √ 按钮后，表达式从活跃编辑态转为完成态（MathFieldView → ExprView）。
   */
  deactivateActive(): void {
    if (this._activeId >= 0) {
      this.flushFieldToExpr(this._activeId);
      this.validatedIds.add(this._activeId);
    }
    this._activeId = -1;
  }

  /** 切换函数可见性 */
  toggleEnabled(id: number): void {
    this._functions = this._functions.map((f: GraphFunction): GraphFunction => {
      if (f.id === id) {
        const updated: GraphFunction = this.copyFunction(f);
        updated.enabled = !f.enabled;
        return updated;
      }
      return f;
    });
    this.syncToRenderDispatcher();
  }

  /** 设置颜色 */
  setColor(id: number, color: string): void {
    this._functions = this._functions.map((f: GraphFunction): GraphFunction => {
      if (f.id === id) {
        const updated: GraphFunction = this.copyFunction(f);
        updated.color = color;
        return updated;
      }
      return f;
    });
  }

  /** 设置线型（不等式无线条属性，忽略设置以防止残留路径污染） */
  setLineStyle(id: number, style: GraphLineStyle): void {
    if (this.isFunctionInequality(id)) {
      return;
    }
    this._functions = this._functions.map((f: GraphFunction): GraphFunction => {
      if (f.id === id) {
        const updated: GraphFunction = this.copyFunction(f);
        updated.lineStyle = style;
        return updated;
      }
      return f;
    });
  }

  /** 设置线宽（不等式无线条属性，忽略设置以防止残留路径污染） */
  setLineWidth(id: number, w: number): void {
    if (this.isFunctionInequality(id)) {
      return;
    }
    this._functions = this._functions.map((f: GraphFunction): GraphFunction => {
      if (f.id === id) {
        const updated: GraphFunction = this.copyFunction(f);
        updated.lineWidth = w;
        return updated;
      }
      return f;
    });
  }

  /** 设置某函数的指定标记分类显示（零点/极值/拐点/渐近线），与图像可见性解耦 */
  setMarkerCategory(id: number, category: MarkerCategory, show: boolean): void {
    this._functions = this._functions.map((f: GraphFunction): GraphFunction => {
      if (f.id === id) {
        const updated: GraphFunction = this.copyFunction(f);
        if (category === 'zeros') { updated.showZeros = show; }
        else if (category === 'extrema') { updated.showExtrema = show; }
        else if (category === 'inflections') { updated.showInflections = show; }
        else { updated.showAsymptotes = show; }
        return updated;
      }
      return f;
    });
  }

  /** 切换某函数的分析卡片显隐（控制分析坞中的卡片） */
  toggleAnalysis(id: number): void {
    this._functions = this._functions.map((f: GraphFunction): GraphFunction => {
      if (f.id === id) {
        const updated: GraphFunction = this.copyFunction(f);
        updated.showAnalysis = !(f.showAnalysis ?? false);
        return updated;
      }
      return f;
    });
  }

  /**
   * 设置角度模式（核心逻辑）：
   * 1. 更新 _isDegMode
   * 2. 清空 classifyCache
   * 3. 调用 renderDispatcher.disposeAll() + syncFunctions() 全量重建
   */
  setDegMode(isDeg: boolean): void {
    if (this._isDegMode === isDeg) {
      return;
    }
    this._isDegMode = isDeg;
    this.classifyCache.clear();
    this.renderDispatcher.disposeAll();
    this.renderDispatcher.syncFunctions(this._functions, this._isDegMode);
  }

  /** 复制函数，返回新函数 id（源函数不存在时返回 -1），副本名称自动追加唯一后缀 */
  duplicateFunction(id: number): number {
    // 焦点即将转移到新副本：先自动保存旧活跃槽的编辑内容
    if (this._activeId >= 0) {
      this.flushFieldToExpr(this._activeId);
    }
    const src: GraphFunction | undefined =
      this._functions.find((f: GraphFunction): boolean => f.id === id);
    if (src === undefined) {
      return -1;
    }
    const newId: number = this._nextId;
    const copy: GraphFunction = this.copyFunction(src);
    copy.id = newId;
    copy.name = this.generateDuplicateName(src);
    this._functions = [...this._functions, copy];
    this._nextId++;
    this._activeId = newId;
    this.ensureField(newId, src.expr || '?');
    // 传播分类缓存，保证 classifyCache 与 RenderDispatcher 状态一致（验收标准 5）
    const srcClassify: ClassifyResult | undefined = this.classifyCache.get(id);
    if (srcClassify !== undefined) {
      this.classifyCache.set(newId, srcClassify);
    }
    this.syncToRenderDispatcher();
    return newId;
  }

  /** 重命名函数（空字符串清除别名；清除后若原固定序号已被其他默认名称函数占用，重新分配最小可用序号） */
  renameFunction(id: number, name: string): void {
    // 清除别名回归默认名称时的冲突检测：原序号若已被占用则重新分配，避免标签重复
    let restoredIndex: number = -1;
    if (name.length === 0) {
      const target: GraphFunction | undefined =
        this._functions.find((f: GraphFunction): boolean => f.id === id);
      if (target !== undefined) {
        const occupied: boolean = this._functions.some((f: GraphFunction): boolean =>
          f.id !== id && (f.name === undefined || f.name.length === 0) &&
          f.labelIndex === target.labelIndex);
        if (occupied) {
          restoredIndex = nextFreeLabelIndex(this._functions);
        }
      }
    }
    this._functions = this._functions.map((f: GraphFunction): GraphFunction => {
      if (f.id === id) {
        const updated: GraphFunction = this.copyFunction(f);
        updated.name = name.length > 0 ? name : undefined;
        if (restoredIndex >= 0) {
          updated.labelIndex = restoredIndex;
        }
        return updated;
      }
      return f;
    });
  }

  /** 清空所有函数，重置为初始状态（保留一个空函数槽位） */
  clearAll(): void {
    // 先无效化 activeId，触发 GraphCanvas 关闭工具栏
    this._activeId = -1;
    const initialId: number = 1;
    const initialFn: GraphFunction = {
      id: initialId, expr: '', color: GRAPH_PALETTE[0], enabled: true,
      lineStyle: 'solid', lineWidth: 3, name: undefined, labelIndex: 0
    };
    this._functions = [initialFn];
    this._nextId = 2;
    // 清空所有缓存与调度器资源
    this.fields.clear();
    this.classifyCache.clear();
    this.validatedIds.clear();
    this.renderDispatcher.disposeAll();
    // 创建新的 MathField
    const field: MathField = new MathField(parseLinear('?'));
    field.onChange = (): void => {
      this._fieldVersion++;
    };
    field.cursor = new Cursor([], 0, -1);
    field.version++;
    this.fields.set(initialId, field);
    // 清空错误状态
    this._exprErrors = new Set();
    this._exprErrorVersion++;
    this._fieldVersion++;
    // 下一帧设置新的 activeId，确保工具栏已关闭
    setTimeout((): void => {
      this._activeId = initialId;
    }, 0);
  }

  /**
   * 接续恢复：用迁移数据替换当前函数列表。
   * 防御性处理：逐个校验函数字段，跳过畸形条目；单个表达式解析失败不影响其他函数。
   */
  restoreFunctions(fns: GraphFunction[]): void {
    if (fns.length === 0) {
      return;
    }
    // 过滤出字段完整的合法函数（id/expr/color 必须存在且类型正确）
    const valid: GraphFunction[] = [];
    for (const f of fns) {
      if (f === null || f === undefined) {
        continue;
      }
      if (typeof f.id !== 'number' || typeof f.expr !== 'string' || typeof f.color !== 'string') {
        getMathLogger().warn(`[GraphViewModel] restoreFunctions: skip malformed fn: ${JSON.stringify(f)}`);
        continue;
      }
      // 补齐可选字段默认值，避免后续渲染访问 undefined
      const safe: GraphFunction = {
        id: f.id,
        expr: f.expr,
        color: f.color,
        enabled: typeof f.enabled === 'boolean' ? f.enabled : true,
        lineStyle: f.lineStyle === 'dashed' ? 'dashed' : 'solid',
        lineWidth: typeof f.lineWidth === 'number' ? f.lineWidth : 3,
        labelIndex: typeof f.labelIndex === 'number' ? f.labelIndex : 0,
        name: typeof f.name === 'string' ? f.name : undefined,
        renderMode: typeof f.renderMode === 'number' ? f.renderMode : undefined,
        showZeros: typeof f.showZeros === 'boolean' ? f.showZeros : false,
        showExtrema: typeof f.showExtrema === 'boolean' ? f.showExtrema : false,
        showInflections: typeof f.showInflections === 'boolean' ? f.showInflections : false,
        showAsymptotes: typeof f.showAsymptotes === 'boolean' ? f.showAsymptotes : false
      };
      valid.push(safe);
    }
    if (valid.length === 0) {
      getMathLogger().warn('[GraphViewModel] restoreFunctions: no valid functions after validation, abort');
      return;
    }
    this._functions = valid;
    // 更新 nextId 为最大 id + 1
    let maxId = 0;
    for (const f of valid) {
      if (f.id > maxId) {
        maxId = f.id;
      }
    }
    this._nextId = maxId + 1;
    // 重建 MathField 实例池（单个表达式解析失败时降级为空槽位，不中断整体恢复）
    this.fields.clear();
    this.classifyCache.clear();
    this.validatedIds.clear();
    for (const f of valid) {
      let field: MathField;
      try {
        if (f.expr.length > 0) {
          field = new MathField(simplify(parseLinear(f.expr)));
        } else {
          field = new MathField(parseLinear('?'));
        }
      } catch (parseErr) {
        getMathLogger().warn(`[GraphViewModel] restoreFunctions: parse failed for id=${f.id}, expr=${f.expr}, fallback to empty`);
        field = new MathField(parseLinear('?'));
      }
      field.onChange = (): void => {
        this._fieldVersion++;
      };
      this.fields.set(f.id, field);
    }
    this._fieldVersion++;
    this.syncToRenderDispatcher();
    getMathLogger().info(`[GraphViewModel] restoreFunctions: restored ${valid.length} functions`);
  }

  // ── 引擎同步 ──

  /** 将函数列表同步到渲染调度器（幂等，基于差异重建渲染器） */
  syncToRenderDispatcher(): void {
    this.renderDispatcher.syncFunctions(this._functions, this._isDegMode);
  }

  /** 获取渲染调度器实例（与 GraphCanvas 通过引用传递共享同一实例） */
  getRenderDispatcher(): RenderDispatcher {
    return this.renderDispatcher;
  }

  // ── MathField 管理 ──

  /** 获取指定函数的 MathField（不存在时按当前表达式创建） */
  getField(id: number): MathField {
    let f: MathField | undefined = this.fields.get(id);
    if (f !== undefined) {
      return f;
    }
    const fn: GraphFunction | undefined =
      this._functions.find((x: GraphFunction): boolean => x.id === id);
    // 加载时先 simplify 归一：fn.expr 中的 '*' 是序列化消歧符（供 core Tokenizer 正确分词），
    // parseLinear 会将其还原为 VstOp('*')，编辑态直接渲染会显示点乘 ·。
    // simplify 移除该乘号（mergeProducts 忽略显式乘），恢复隐式乘法显示，与编辑行为一致。
    f = new MathField(simplify(parseLinear(fn !== undefined ? (fn.expr || '?') : '?')));
    f.onChange = (): void => {
      this._fieldVersion++;
    };
    this.fields.set(id, f);
    return f;
  }

  /** 确保指定函数的 MathField 存在（不存在时按给定表达式创建） */
  ensureField(id: number, expr?: string): MathField {
    const existing: MathField | undefined = this.fields.get(id);
    if (existing !== undefined) {
      return existing;
    }
    // 同 getField：simplify 归一，移除序列化消歧 '*' 对应的 VstOp，保持隐式乘法显示。
    const f: MathField = new MathField(simplify(parseLinear(expr ?? '?')));
    f.onChange = (): void => {
      this._fieldVersion++;
    };
    this.fields.set(id, f);
    return f;
  }

  /** 移除指定函数的 MathField */
  removeField(id: number): void {
    this.fields.delete(id);
  }

  // ── 表达式验证 ──

  /**
   * 自动缓存保存：将指定槽位 MathField 的当前内容序列化后同步回 fn.expr。
   * 用于焦点转移时未点 √ 确认的场景，保证完成态（ExprView）与活跃编辑态一致。
   * - 纯占位符（'?'）视为未输入，归一为空串，避免完成态显示虚线方块/误出模式标签
   * - 内容无变化时直接返回，不触发重分类/重渲染
   * - 不做合法性校验（错误标记仅由显式 √ 验证 validateExpr 负责）
   */
  private flushFieldToExpr(id: number): void {
    const field: MathField | undefined = this.fields.get(id);
    if (field === undefined) {
      return;
    }
    // 图象模式开启数字因子折叠：使录入的 `2·3x` 归一为 `6x`。
    // 化简结果会回写 fn.expr 并直接交给求值器，因此这一步也是
    // 「显示层产出下游词法器读不懂的 token」这类缺陷的源头治理。
    const beautified: VstRow = simplify(field.root, true);
    const serialized: string = serializeLinear(beautified);
    const effective: string = serialized.trim() === '?' ? '' : serialized;
    const fn: GraphFunction | undefined =
      this._functions.find((f: GraphFunction): boolean => f.id === id);
    if (fn === undefined || fn.expr === effective) {
      return;
    }
    this.setExpr(id, effective);
  }

  /** 指定函数是否已验证（光标曾离开该槽位，存在完成态） */
  isValidated(id: number): boolean {
    return this.validatedIds.has(id);
  }

  /**
   * 实时渲染预检：判断表达式当前是否可被渲染（纯查询，不产生错误标记/不改任何状态）。
   * 与 validateExpr 的合法性判断逻辑一致：显函数需 FunctionEvaluator 可求值，
   * 其余模式（隐函数/不等式/二元方程）由对应渲染器容错。
   * 用于逐键实时渲染：输入中途的不完整表达式（如 "x+"）返回 false，
   * 调用方据此跳过写回，保留上一次合法图像。
   */
  isExprRenderable(expr: string): boolean {
    const trimmed: string = expr.trim();
    if (trimmed.length === 0) {
      return false;
    }
    try {
      const classifyResult: ClassifyResult = ExprClassifier.classify(trimmed);
      if (classifyResult.mode === RenderMode.EXPLICIT) {
        const ev: FunctionEvaluator = new FunctionEvaluator(trimmed, this._isDegMode);
        return ev.isValid;
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  /**
   * 验证指定函数的表达式：
   * 序列化当前 MathField 内容 → 分类 → 校验合法性。
   * 合法：清除错误标记 + setExpr 触发重绘 + 标记已验证；非法：设置错误标记。
   */
  validateExpr(id: number): boolean {
    if (id < 0) {
      return false;
    }
    const field: MathField | undefined = this.fields.get(id);
    if (field === undefined) {
      return false;
    }
    // 图象模式开启数字因子折叠（与 flushFieldToExpr 保持一致）
    const beautified: VstRow = simplify(field.root, true);
    const serialized: string = serializeLinear(beautified);
    const trimmed: string = serialized.trim();
    let isValid: boolean = true;
    if (trimmed.length > 0) {
      try {
        const classifyResult: ClassifyResult = ExprClassifier.classify(trimmed);
        if (classifyResult.mode === RenderMode.EXPLICIT) {
          const ev: FunctionEvaluator = new FunctionEvaluator(trimmed, this._isDegMode);
          isValid = ev.isValid;
        } else {
          // 隐函数/不等式/二元方程同样需要校验：求值器现在会在解析期
          // 把畸形结构（如相邻数值、栈残留）判为非法，不再静默产出全 NaN 网格。
          const bev: BivariateEvaluator = new BivariateEvaluator(
            classifyResult.normalizedExpr, this._isDegMode);
          isValid = bev.isValid;
        }
      } catch (e) {
        isValid = false;
      }
    }
    const newErrors: Set<number> = new Set(this._exprErrors);
    if (isValid) {
      newErrors.delete(id);
      this._exprErrors = newErrors;
      this._exprErrorVersion++;
      this.setExpr(id, serialized);
      this.validatedIds.add(id);
    } else {
      newErrors.add(id);
      this._exprErrors = newErrors;
      this._exprErrorVersion++;
      // 非法时也保存表达式到 fn.expr（完成态无条件接收活跃态内容）
      // 不调用 setExpr，避免对非法表达式触发 classify/syncFunctions/validatedIds
      this._functions = this._functions.map((f: GraphFunction): GraphFunction => {
        if (f.id === id) {
          const updated: GraphFunction = this.copyFunction(f);
          updated.expr = serialized;
          return updated;
        }
        return f;
      });
    }
    return isValid;
  }

  /** 获取表达式错误集合 */
  getExprErrors(): Set<number> {
    return this._exprErrors;
  }

  // ── 私有工具 ──

  /** 指定函数是否为不等式（差异化设置逻辑用；优先消费 classifyCache，缺失时按当前表达式实时分类） */
  private isFunctionInequality(id: number): boolean {
    const cached: ClassifyResult | undefined = this.classifyCache.get(id);
    if (cached !== undefined) {
      return cached.mode === RenderMode.INEQUALITY;
    }
    const fn: GraphFunction | undefined =
      this._functions.find((f: GraphFunction): boolean => f.id === id);
    if (fn === undefined || fn.expr.trim().length === 0) {
      return false;
    }
    return ExprClassifier.classify(fn.expr).mode === RenderMode.INEQUALITY;
  }

  /**
   * 为复制的函数生成唯一名称：
   * - 源函数使用默认名称（如 y₈）→ 追加数字后缀（y₈1、y₈2…）
   * - 源函数使用自定义名称（如 “正弦”）→ 追加递增数字（正弦1、正弦2…）
   * - 先剥离源名称尾部已有数字后缀，取同根名称的最大后缀 +1，避免 y₈1→y₈11 的累加 bug
   */
  private generateDuplicateName(src: GraphFunction): string {
    const srcName: string = graphDisplayName(src);
    // 剥离尾部 ASCII 数字得到根名称（如 "y₈1" → "y₈"，"正弦2" → "正弦"）
    const rootMatch: RegExpMatchArray | null = srcName.match(/^(.*\D)(\d+)$/);
    const root: string = rootMatch !== null ? rootMatch[1] : srcName;
    // 扫描列表中所有同根名称，取最大数字后缀
    let maxSuffix: number = 0;
    for (let i: number = 0; i < this._functions.length; i++) {
      const displayName: string = graphDisplayName(this._functions[i]);
      if (displayName.length > root.length && displayName.startsWith(root)) {
        const suffixStr: string = displayName.substring(root.length);
        if (/^\d+$/.test(suffixStr)) {
          const num: number = parseInt(suffixStr, 10);
          if (num > maxSuffix) {
            maxSuffix = num;
          }
        }
      }
    }
    return root + (maxSuffix + 1).toString();
  }

  /** 完整复制函数对象（保留包括 renderMode、labelIndex 及四个分类标记在内的全部字段，避免遗漏） */
  private copyFunction(f: GraphFunction): GraphFunction {
    const copy: GraphFunction = {
      id: f.id, expr: f.expr, color: f.color, enabled: f.enabled,
      lineStyle: f.lineStyle, lineWidth: f.lineWidth, name: f.name, renderMode: f.renderMode,
      labelIndex: f.labelIndex,
      showZeros: f.showZeros, showExtrema: f.showExtrema,
      showInflections: f.showInflections, showAsymptotes: f.showAsymptotes
    };
    return copy;
  }
}
