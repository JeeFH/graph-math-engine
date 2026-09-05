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
// calcengine-graph/src/main/ets/engine/RenderDispatcher.ets
/**
 * 统一渲染调度器
 *
 * 职责：
 * 1. 维护 fnId → IRenderer 映射（每个函数独立渲染器）
 * 2. 表达式变更时自动判别模式、销毁旧渲染器、创建新渲染器
 * 3. 视口变化时统一触发缓存扩展 / 精细化
 * 4. 提供 extractAll() 供 GraphCanvas 一次性获取所有渲染数据
 *
 * 生命周期：
 *   GraphCanvas.onDataChange() → RenderDispatcher.syncFunctions()
 *   GraphCanvas.onVpChange()   → RenderDispatcher.onViewportChange()
 *   GraphCanvas.draw()         → RenderDispatcher.extractAll()
 */

import { Viewport } from '../math/GraphMath';
import { GraphFunction } from '../types/GraphTypes';
import { IRenderer, IChunkedGridRenderer, RenderData, RenderMode } from './IRenderer';
import { ExprClassifier, ClassifyResult, InequalityDirection } from './ExprClassifier';
import { ExplicitRenderer } from './ExplicitRenderer';
import { ImplicitRenderer } from './ImplicitRenderer';
import { InequalityRenderer } from './InequalityRenderer';
import { BivariateEqRenderer } from './BivariateEqRenderer';
import { ExtractionBudget } from './ExtractionBudget';

/** 每个函数的渲染器槽位 */
interface RendererSlot {
  fnId: number;
  expr: string;
  isDegMode: boolean;
  mode: RenderMode;
  renderer: IRenderer;
  classifyResult: ClassifyResult;
}

export class RenderDispatcher {
  /** fnId → 渲染器槽位 */
  private slots: Map<number, RendererSlot> = new Map();
  /** 角度模式（全局） */
  private isDegMode: boolean = false;

  // ── extractAll 结果缓存（避免同帧 hitTest + drawCurves 双重提取） ──
  /** 提取代次：任何可能改变提取结果的操作（构建完成/扩展/同步）递增 */
  private extractVersion: number = 0;
  /** 上次提取的量化视口键 */
  private lastExtractKey: string = '';
  /** 上次提取时的代次 */
  private lastExtractVersion: number = -1;
  /** 上次提取结果（键与代次均匹配时直接复用） */
  private lastExtractResult: RenderData[] = [];

  /**
   * 同步函数列表：对比当前 slots 与新的 functions，
   * 增删改对应渲染器。
   *
   * @param functions 当前函数列表（来自 GraphCanvas @Prop）
   * @param isDegMode 角度模式
   */
  syncFunctions(functions: GraphFunction[], isDegMode: boolean): void {
    this.isDegMode = isDegMode;

    // 收集当前 fnId 集合
    const currentIds: Set<number> = new Set();
    for (let i: number = 0; i < functions.length; i++) {
      currentIds.add(functions[i].id);
    }

    // 删除不在列表中的函数渲染器
    const toRemove: number[] = [];
    this.slots.forEach((_slot: RendererSlot, fnId: number) => {
      if (!currentIds.has(fnId)) {
        toRemove.push(fnId);
      }
    });
    for (let i: number = 0; i < toRemove.length; i++) {
      const slot: RendererSlot | undefined = this.slots.get(toRemove[i]);
      if (slot !== undefined) {
        slot.renderer.dispose();
        this.slots.delete(toRemove[i]);
      }
    }

    // 新增或更新函数
    let changed: boolean = toRemove.length > 0;
    for (let i: number = 0; i < functions.length; i++) {
      const fn: GraphFunction = functions[i];
      if (!fn.enabled) continue;

      const existing: RendererSlot | undefined = this.slots.get(fn.id);
      if (existing === undefined) {
        // 新增
        this.createSlot(fn);
        changed = true;
      } else if (existing.expr !== fn.expr || existing.isDegMode !== isDegMode) {
        // 表达式或角度模式变更 → 重建
        existing.renderer.dispose();
        this.slots.delete(fn.id);
        this.createSlot(fn);
        changed = true;
      }
      // 否则不变，复用现有渲染器
    }
    if (changed) {
      this.extractVersion++;
    }
  }

  /**
   * 创建渲染器槽位：分类表达式 → 创建对应渲染器
   */
  private createSlot(fn: GraphFunction): void {
    const classify: ClassifyResult = ExprClassifier.classify(fn.expr);
    let renderer: IRenderer;

    switch (classify.mode) {
      case RenderMode.EXPLICIT:
        renderer = new ExplicitRenderer(fn.id, classify.normalizedExpr, this.isDegMode);
        break;
      case RenderMode.IMPLICIT:
        renderer = new ImplicitRenderer(fn.id, classify.normalizedExpr, this.isDegMode);
        break;
      case RenderMode.INEQUALITY:
        const dir: InequalityDirection = classify.inequalityDir ?? '>';
        renderer = new InequalityRenderer(fn.id, classify.normalizedExpr,
          this.isDegMode, dir);
        break;
      case RenderMode.BIVARIATE_EQ:
        renderer = new BivariateEqRenderer(fn.id, classify.normalizedExpr, this.isDegMode);
        break;
      default:
        // 兜底：按显函数处理
        renderer = new ExplicitRenderer(fn.id, classify.normalizedExpr, this.isDegMode);
        break;
    }

    this.slots.set(fn.id, {
      fnId: fn.id,
      expr: fn.expr,
      isDegMode: this.isDegMode,
      mode: classify.mode,
      renderer: renderer,
      classifyResult: classify
    });
  }

  /**
   * 视口变化：检查各渲染器缓存覆盖情况，按需扩展。
   *
   * 扩展后复检覆盖：若扩展失败（如网格节点数超上限被静默放弃、
   * 或网格尚未构建），返回 true 通知调用方触发「围绕当前视口的分块重建」，
   * 避免 cacheCovers 永远 false 而扩展永远失败的死锁（视口外永不渲染）。
   *
   * @param vp 新视口
   * @param pixelWorldDx 单像素世界坐标间距
   * @returns true 表示存在扩展失败/未覆盖的渲染器，需要全量重建
   */
  onViewportChange(vp: Viewport, pixelWorldDx: number): boolean {
    let needsRebuild: boolean = false;
    this.slots.forEach((slot: RendererSlot) => {
      if (!slot.renderer.cacheCovers(vp)) {
        slot.renderer.extendCache(vp);
        this.extractVersion++; // 网格已扩展 → 提取结果失效
        // 扩展后复检：仍不覆盖说明扩展失败（超上限/网格未建）→ 需全量重建
        if (!slot.renderer.cacheCovers(vp)) {
          needsRebuild = true;
        }
      }
      // 精度刷新：缩放导致缓存线段/区域密度不足时只登记目标精度（不重建网格）。
      // 本方法只在非手势期被调用（GraphCanvas.ensureCacheCoverage 有 isGesturing 守卫），
      // 因此可以在此安全提交待定精度；运镜动画期间则仅累积目标值，
      // 避免每帧重置提取游标导致「快照重置视角卡顿」。
      const chunked: IChunkedGridRenderer | null = this.asChunked(slot.renderer);
      if (chunked !== null) {
        chunked.refreshExtraction(pixelWorldDx);
        if (chunked.commitPendingPrecision()) {
          this.extractVersion++;
        }
      }
    });
    return needsRebuild;
  }

  /** 是否存在未完成的轮廓/区域提取（任一网格类渲染器） */
  hasPendingExtraction(): boolean {
    let pending: boolean = false;
    this.slots.forEach((slot: RendererSlot) => {
      const c: IChunkedGridRenderer | null = this.asChunked(slot.renderer);
      if (c !== null && c.hasPendingExtraction()) {
        pending = true;
      }
    });
    return pending;
  }

  /**
   * 推进所有渲染器的轮廓/区域提取一轮。
   *
   * 设计要点：
   * - 本轮预算窗口在此统一 begin，所有渲染器共享，形成全局每帧耗时上限
   *   （而非每个渲染器各得一份预算，否则 N 个函数会把帧耗时放大 N 倍）；
   * - 跨 slot 轮转，保证多函数公平，不会一个函数吃满预算饿死其它；
   * - 仅当确有推进时才递增 extractVersion，避免无效自增抹掉帧期结果缓存。
   *
   * @returns true 表示所有渲染器的提取均已完成
   */
  pumpExtractions(budget: ExtractionBudget, vp: Viewport): boolean {
    if (!this.hasPendingExtraction()) {
      return true;
    }
    budget.begin();
    let allDone: boolean = true;
    this.slots.forEach((slot: RendererSlot) => {
      const c: IChunkedGridRenderer | null = this.asChunked(slot.renderer);
      if (c === null || !c.hasPendingExtraction()) {
        return;
      }
      if (!c.pumpExtraction(budget, vp)) {
        allDone = false;
      }
    });
    // 提取有进展 → 帧期结果缓存失效，下一帧重取
    this.extractVersion++;
    return allDone;
  }

  /**
   * 首次构建所有渲染器缓存（在 syncFunctions 后调用）。
   *
   * 性能优化：跳过缓存仍覆盖视口的渲染器（未变更的函数不重建），
   * 避免每次按键都全量重建所有函数的二维网格。
   *
   * @param vp 当前视口
   * @param pixelWorldDx 单像素世界坐标间距
   */
  buildAllCaches(vp: Viewport, pixelWorldDx: number): void {
    this.slots.forEach((slot: RendererSlot) => {
      if (!slot.renderer.cacheCovers(vp)) {
        slot.renderer.buildCache(vp, pixelWorldDx);
      }
    });
    this.extractVersion++;
  }

  /**
   * 收集需要重建缓存的渲染器 fnId 列表（缓存为空或不覆盖视口）。
   * 供 GraphCanvas 的防抖分块构建调度使用。
   */
  getRebuildTargets(vp: Viewport): number[] {
    const targets: number[] = [];
    this.slots.forEach((slot: RendererSlot) => {
      // 显函数走独立的 1D 管线（GraphCanvas.scheduleCacheBuild），不参与二维网格构建，
      // 跳过以避免每次数据变更都重复构建其不被使用的渲染器缓存。
      if (slot.mode === RenderMode.EXPLICIT) {
        return;
      }
      if (!slot.renderer.cacheCovers(vp)) {
        targets.push(slot.fnId);
      }
    });
    return targets;
  }

  /**
   * 启动指定函数的缓存构建。
   * - 网格类渲染器（隐函数/不等式/二元方程）：启动分块构建（beginBuild），返回 true，
   *   调用方需随后反复调用 buildChunkFor 逐块填充。
   * - 非网格渲染器（显函数）：同步构建（很快），返回 false 表示已完成。
   */
  beginBuildFor(fnId: number, vp: Viewport, pixelWorldDx: number): boolean {
    const slot: RendererSlot | undefined = this.slots.get(fnId);
    if (slot === undefined) {
      return false;
    }
    const chunked: IChunkedGridRenderer | null = this.asChunked(slot.renderer);
    if (chunked !== null) {
      chunked.beginBuild(vp, pixelWorldDx);
      return true;
    }
    slot.renderer.buildCache(vp, pixelWorldDx);
    return false;
  }

  /**
   * 为指定函数的分块构建填充接下来的 maxNodeRows 个节点行。
   * @returns true 表示该函数网格已构建完成
   */
  buildChunkFor(fnId: number, maxNodeRows: number): boolean {
    const slot: RendererSlot | undefined = this.slots.get(fnId);
    if (slot === undefined) {
      return true;
    }
    const chunked: IChunkedGridRenderer | null = this.asChunked(slot.renderer);
    if (chunked === null) {
      return true;
    }
    const done: boolean = chunked.buildChunk(maxNodeRows);
    if (done) {
      this.extractVersion++; // 网格构建完成 → 提取结果失效
    }
    return done;
  }

  /** 判定渲染器是否支持分块构建（网格类），支持则返回分块接口引用 */
  private asChunked(r: IRenderer): IChunkedGridRenderer | null {
    if (r instanceof ImplicitRenderer) {
      return r as IChunkedGridRenderer;
    }
    if (r instanceof InequalityRenderer) {
      return r as IChunkedGridRenderer;
    }
    return null;
  }

  /**
   * 提取所有函数的渲染数据。
   *
   * @param vp 当前视口
   * @param fnStyles 函数样式信息（颜色/线宽/线型）
   * @returns 渲染数据数组
   */
  extractAll(vp: Viewport, fnStyles: Map<number, GraphFunction>): RenderData[] {
    // 量化视口键：容忍亚像素级视口抖动，同帧内 hitTest + drawCurves 复用同一结果
    const q: number = (vp.xMax - vp.xMin) / 800;
    const key: string = Math.round(vp.xMin / q) + ',' + Math.round(vp.xMax / q) + ',' +
      Math.round(vp.yMin / q) + ',' + Math.round(vp.yMax / q);
    if (key === this.lastExtractKey && this.extractVersion === this.lastExtractVersion) {
      return this.lastExtractResult;
    }

    const result: RenderData[] = [];
    this.slots.forEach((slot: RendererSlot) => {
      const data: RenderData = slot.renderer.extractVisible(vp);
      // 补充样式信息（从 fnStyles 获取）
      const style: GraphFunction | undefined = fnStyles.get(slot.fnId);
      if (style !== undefined) {
        data.color = style.color;
        data.lineWidth = style.lineWidth;
        data.lineStyle = style.lineStyle;
      }
      result.push(data);
    });

    this.lastExtractKey = key;
    this.lastExtractVersion = this.extractVersion;
    this.lastExtractResult = result;
    return result;
  }

  /**
   * 获取指定函数的渲染模式（调试 / UI 标签用）
   */
  getMode(fnId: number): RenderMode | null {
    const slot: RendererSlot | undefined = this.slots.get(fnId);
    return slot !== undefined ? slot.mode : null;
  }

  /**
   * 获取指定函数的分类结果
   */
  getClassify(fnId: number): ClassifyResult | null {
    const slot: RendererSlot | undefined = this.slots.get(fnId);
    return slot !== undefined ? slot.classifyResult : null;
  }

  /**
   * 释放所有渲染器资源
   */
  disposeAll(): void {
    this.slots.forEach((slot: RendererSlot) => {
      slot.renderer.dispose();
    });
    this.slots.clear();
  }

  /**
   * 当前活跃的渲染器数量
   */
  get size(): number {
    return this.slots.size;
  }
}
