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

/**
 * 段数上限的绝对边界（仅作上钳位，实际取值由 SegmentCaps.of 按画布像素推导）。
 * 这两个常数不再是实际生效值，保留为“永不越过的天花板”。
 */
export const SEGMENT_SOFT_CAP: number = 60000;
export const SEGMENT_HARD_CAP: number = 200000;

/**
 * 每个画布像素列允许的最大段数。
 *
 * 取值权衡：一个铺满视口的普通曲线（如圆 x²+y²=4）在 400x400 网格下本就产出
 * 约 2500 段；取 4 会让它在软上限处就被降质，属误伤。取 16（1080px 画布 →
 * 硬上限 17280 段）既留下充足余量使正常曲线全速完整提取，又把病态情形
 * （实测 sin(x*y) 顶到 200000）砍掉一个数量级以上。
 */
const SEGMENTS_PER_CANVAS_PX: number = 16;
/** 段数下限：极小画布或异常视口下仍保证曲线成形 */
const SEGMENT_CAP_FLOOR: number = 2048;

/**
 * 由视口与像素尺度推导的段数上限。
 *
 * 背景（实测）：原先使用固定硬上限 200000。对 1080px 宽的画布，相当于每像素列
 * 185 段，远超可分辨限度；实测 sin(x*y) 在 400x400 网格下段数稳定顶到 200000。
 * 后果有二：
 * 1. 每次 pumpExtraction 后的 draw() 要重绘全部累积段，开销随段数线性增长，
 *    多轮 pump 叠加后形成远超单帧预算的主线程占用；
 * 2. 20 万个 LineSegment 对象常驻，叠加每帧新建的结果数组，GC 压力显著。
 *
 * 因此上限应由“画布能分辨多少段”决定，而不应由“愿意分配多少内存”决定。
 * 超出后行为与软上限一致：降 AMR 深度、以更粗密度覆盖更大范围（曲线仍连续）。
 */
export class SegmentCaps {
  /** 软上限：越过后 AMR 深度降级 */
  readonly soft: number;
  /** 硬上限：越过后停止提取并置 truncated */
  readonly hard: number;

  constructor(soft: number, hard: number) {
    this.soft = soft;
    this.hard = hard;
  }

  /**
   * @param pixelWorldDx 单像素对应的世界坐标间距（<=0 或非有限时退回默认画布宽度）
   * @param worldWidth 当前视口的世界坐标宽度
   */
  static of(pixelWorldDx: number, worldWidth: number): SegmentCaps {
    let canvasPx: number = 400;
    if (pixelWorldDx > 0 && worldWidth > 0) {
      const px: number = worldWidth / pixelWorldDx;
      if (isFinite(px) && px > 0) {
        canvasPx = px;
      }
    }
    let hard: number = Math.round(canvasPx * SEGMENTS_PER_CANVAS_PX);
    if (hard < SEGMENT_CAP_FLOOR) hard = SEGMENT_CAP_FLOOR;
    if (hard > SEGMENT_HARD_CAP) hard = SEGMENT_HARD_CAP;
    let soft: number = Math.round(hard / 2);
    if (soft < SEGMENT_CAP_FLOOR / 2) soft = Math.round(SEGMENT_CAP_FLOOR / 2);
    if (soft > SEGMENT_SOFT_CAP) soft = SEGMENT_SOFT_CAP;
    return new SegmentCaps(soft, hard);
  }
}

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
