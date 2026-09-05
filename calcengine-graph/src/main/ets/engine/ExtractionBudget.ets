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
// calcengine-graph/src/main/ets/engine/ExtractionBudget.ets
/**
 * 等值线提取预算（把「不可中断的一次性全量提取」改为「可续跑的分帧提取」）
 *
 * 背景（缺陷类：帧路径契约违规 + 成本无上界）：
 * 原实现把全网格 AMR 提取放在 `extractVisible` 的脏标记分支里，而 `extractVisible`
 * 由 `draw()` 在 `PanGesture.onActionEnd` 内同步调用。于是「平移结束的一次重绘」
 * 等价于「在 UI 线程上同步跑完整个网格的递归细分」，实测触发 THREAD_BLOCK_6S：
 *
 *   PanRecognizer::SendCallbackMsg
 *    └ GraphCanvas.onActionEnd → draw() → drawCurves → RenderDispatcher.extractAll
 *      └ ImplicitRenderer.extractVisible → rebuildSegmentCache → extractCellAMR …
 *
 * 成本无上界是另一半原因：AMR_MAX_DEPTH=4 的四路递归使单个变号格最坏需 ~85 次求值、
 * 产出 256 条线段，而网格上限 500×500。对 sin(x·y) 这类零集为 xy=kπ 双曲线族的
 * 高频函数，极大比例的基础格都是变号格，总代价达千万级求值 + 百万级线段对象，
 * 一次性同步执行必然冻结主线程（日志中 Rss 420MB、设备级卡死重启）。
 *
 * 本模块提供三重约束，使最坏耗时由常数决定、与被积函数的振荡密度解耦：
 * 1. 单次泵入的行数 / 求值次数 / 墙钟时间上限（分帧，UI 永不长时间阻塞）；
 * 2. 段数软上限 → 降低 AMR 深度（密度降级，曲线仍连续）；
 * 3. 段数硬上限 → 截断并标记（内存有界）。
 */

/** 段数软上限：越过后 AMR 深度降级，用更粗的线段密度换取覆盖更大范围 */
export const SEGMENT_SOFT_CAP: number = 60000;
/** 段数硬上限：越过后停止提取并置 truncated，保证内存有界 */
export const SEGMENT_HARD_CAP: number = 200000;

/**
 * 单次提取泵入的预算。
 *
 * 由调度方（GraphCanvas）按交互状态选择档位：手势/动画期用小预算让帧优先，
 * 空闲期用大预算尽快补全质量。
 */
export class ExtractionBudget {
  /** 单次泵入最多完成的单元格行数 */
  readonly maxCellRows: number;
  /** 单次泵入最多消耗的 AMR 探针求值次数 */
  readonly maxEvals: number;
  /** 单次泵入的墙钟上限（毫秒） */
  readonly deadlineMs: number;
  /** 单次泵入最多填充的网格节点行数（网格构建阶段用） */
  readonly maxGridRows: number;

  private rowsUsed: number = 0;
  private evalsUsed: number = 0;
  private startMs: number = 0;

  constructor(maxCellRows: number, maxEvals: number, deadlineMs: number,
    maxGridRows: number) {
    this.maxCellRows = maxCellRows;
    this.maxEvals = maxEvals;
    this.deadlineMs = deadlineMs;
    this.maxGridRows = maxGridRows;
  }

  /** 手势 / 运镜动画期：让帧优先，保证交互流畅 */
  static gesture(): ExtractionBudget {
    return new ExtractionBudget(8, 40000, 6, 16);
  }

  /** 空闲期：尽快补全到完整质量 */
  static idle(): ExtractionBudget {
    return new ExtractionBudget(32, 200000, 12, 64);
  }

  /** 开始一轮泵入：清零计数并记录起始时刻 */
  begin(): void {
    this.rowsUsed = 0;
    this.evalsUsed = 0;
    this.startMs = Date.now();
  }

  /** 记满一行（行是预算的最小结算单位，避免逐格计时开销） */
  countRow(): void {
    this.rowsUsed++;
  }

  /** 记账 n 次探针求值 */
  consumeEvals(n: number): void {
    this.evalsUsed += n;
  }

  /** 求值配额是否已耗尽（AMR 内部用于决定是否降级） */
  evalsExhausted(): boolean {
    return this.evalsUsed >= this.maxEvals;
  }

  /**
   * 本轮是否应停止。
   * 墙钟检查放在行边界（而非逐格），Date.now() 调用次数 = 行数，开销可忽略。
   */
  shouldStop(): boolean {
    if (this.rowsUsed >= this.maxCellRows) {
      return true;
    }
    if (this.evalsUsed >= this.maxEvals) {
      return true;
    }
    return (Date.now() - this.startMs) >= this.deadlineMs;
  }
}
