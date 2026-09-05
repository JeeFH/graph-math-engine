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
// calcengine-graph/src/main/ets/engine/IRenderer.ets
/**
 * 统一渲染器抽象接口 + 共享类型定义
 *
 * 四大渲染模式（显函数 / 隐函数 / 不等式 / 二元方程）共用此接口，
 * 由 RenderDispatcher 统一调度，GraphCanvas 仅依赖 IRenderer 产物。
 */

import { Viewport } from '../math/GraphMath';
import { WorldSample } from './SampleCache';
import { GraphLineStyle } from '../types/GraphTypes';
import { ExtractionBudget } from './ExtractionBudget';

// ==================== 渲染模式枚举 ====================

/** 渲染模式枚举 */
export enum RenderMode {
  /** A: 显函数 y = f(x) */
  EXPLICIT = 0,
  /** B: 隐函数 F(x,y) = 0 */
  IMPLICIT = 1,
  /** C: 不等式 F(x,y) > 0 / < 0 / >= / <= */
  INEQUALITY = 2,
  /** D: 二元方程 F(x,y) = 0（与 B 复用底层网格，业务逻辑区分） */
  BIVARIATE_EQ = 3
}

/** RenderMode 可读标签（调试 / 日志用） */
export function renderModeLabel(mode: RenderMode): string {
  switch (mode) {
    case RenderMode.EXPLICIT: return '显函数';
    case RenderMode.IMPLICIT: return '隐函数';
    case RenderMode.INEQUALITY: return '不等式';
    case RenderMode.BIVARIATE_EQ: return '二元方程';
    default: return '未知';
  }
}

// ==================== 基本图元 ====================

/** 线段（世界坐标） */
export interface LineSegment {
  x1: number;
  y1: number;
  x2: number;
  y2: number;
}

/** 二维点（世界坐标） */
export interface Point2D {
  x: number;
  y: number;
}

/** 多边形（世界坐标顶点序列） */
export interface Polygon {
  points: Point2D[];
}

// ==================== 统一渲染数据产物 ====================

/** 单条表达式的完整渲染数据 */
export interface RenderData {
  /** 渲染模式 */
  mode: RenderMode;
  /** 函数稳定 id */
  fnId: number;
  /** 曲线颜色（hex） */
  color: string;
  /** 线宽（vp） */
  lineWidth: number;
  /** 线型 */
  lineStyle: GraphLineStyle;
  /** 表达式原文（调试用） */
  expr: string;
  /** A 模式：1D 采样点序列 */
  samples1D?: WorldSample[];
  /** B/D 模式：等值线段集合 */
  contourSegments?: LineSegment[];
  /** C 模式：填充区域多边形 */
  fillRegions?: Polygon[];
  /** C 模式：不等式边界等值线 */
  boundarySegments?: LineSegment[];
  /** 缓存是否有效 */
  cacheValid: boolean;
}

// ==================== 渲染器抽象接口 ====================

/**
 * 统一渲染器接口
 *
 * 四种模式各自实现此接口，RenderDispatcher 通过接口统一调度。
 * 生命周期：创建 → buildCache → (extractVisible)* → extendCache → ... → dispose
 */
export interface IRenderer {
  /** 当前渲染模式（只读） */
  readonly mode: RenderMode;

  /**
   * 构建/重建缓存（首次加载或表达式变更时调用）
   * @param vp 当前视口
   * @param pixelWorldDx 单像素对应的世界坐标间距（用于 LOD 决策）
   */
  buildCache(vp: Viewport, pixelWorldDx: number): void;

  /**
   * 增量扩展缓存（视口平移超出缓冲边界时调用）
   * @param newVp 新的视口范围
   */
  extendCache(newVp: Viewport): void;

  /**
   * 提取当前视口内可见的渲染数据
   * @param vp 当前视口
   * @returns 渲染数据（供 GraphDisplayArea 绘制）
   */
  extractVisible(vp: Viewport): RenderData;

  /**
   * 释放所有资源（模式切换 / 函数删除时调用）
   * 实现类必须将大对象（缓存数组、网格矩阵）置 null，让 GC 回收。
   */
  dispose(): void;

  /**
   * 判断当前缓存是否完全覆盖给定视口
   * @param vp 待检测视口
   * @returns true 表示缓存有效且覆盖，无需重建
   */
  cacheCovers(vp: Viewport): boolean;
}

/**
 * 分块构建渲染器接口（隐函数 / 不等式 / 二元方程的二维网格渲染器实现）
 *
 * 背景：二维网格全量构建需数十万次求值，若一次性同步执行会阻塞主线程
 * 导致 appfreeze。本接口把构建拆为「beginBuild 创建空网格」+「buildChunk
 * 逐行分片填充」，由调度方（GraphCanvas）在帧间逐块泵入，避免长时阻塞。
 *
 * 构建期间渲染器继续用旧网格渲染（渐进式更新），新网格填满后才原子替换。
 *
 * 提取阶段同样必须分帧：网格填满后的等值线/区域提取（AMR 递归）成本可达
 * 千万级求值，历史上它被放在 extractVisible 的脏标记分支里同步执行，而
 * extractVisible 又由手势回调里的 draw() 调用，直接导致 THREAD_BLOCK_6S。
 * 现在提取一律通过 pumpExtraction 在帧间推进，extractVisible 只做查询。
 */
export interface IChunkedGridRenderer extends IRenderer {
  /**
   * 开始分块构建：创建空网格（不求值）。快速返回。
   * @param vp 当前视口
   * @param pixelWorldDx 单像素对应的世界坐标间距
   */
  beginBuild(vp: Viewport, pixelWorldDx: number): void;

  /**
   * 填充接下来的 maxNodeRows 个节点行。
   * @param maxNodeRows 本次最多填充的节点行数（控制单帧耗时）
   * @returns true 表示网格已全部构建完成并已替换生效
   */
  buildChunk(maxNodeRows: number): boolean;

  /** 网格是否已填满并生效（可以开始提取） */
  isGridReady(): boolean;

  /** 是否有未完成的轮廓/区域提取（供调度方判断是否需要继续泵入） */
  hasPendingExtraction(): boolean;

  /**
   * 推进一步提取，严格遵守预算后让出主线程。
   * 提取未完成时仍可用已提取部分渲染（曲线渐进长出）。
   *
   * 调用约定：调度方需先执行 budget.begin() 开启本轮预算窗口。
   * 实现方不得自行 begin，以便多个渲染器共享同一预算窗口（全局每帧上限）。
   *
   * @param budget 本轮预算（行数/求值次数/墙钟）
   * @param vp 当前视口（用于按可见性优先排序，使部分结果先覆盖用户正在看的区域）
   * @returns true 表示提取已完成（或已因硬上限截断）
   */
  pumpExtraction(budget: ExtractionBudget, vp: Viewport): boolean;

  /**
   * 登记目标提取精度（缩放导致缓存线段密度不足时）。
   * 只记录不执行，由 commitPendingPrecision 在动画结束后生效。
   */
  refreshExtraction(pixelWorldDx: number): void;

  /**
   * 提交待定精度：缩放/运镜期间只记录目标精度，动画结束后一次性生效，
   * 避免动画每帧重置提取游标导致永远提不完。
   * @returns true 表示确实触发了重提取
   */
  commitPendingPrecision(): boolean;
}
