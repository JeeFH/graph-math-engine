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
// graph-ui/src/main/ets/components/AnalysisDock.ets
/**
 * AnalysisDock - 函数分析横向滚动坞
 *
 * 位于 GraphCanvas 底部，承载多个函数分析卡片。
 * 用户通过行菜单"图象分析"开关控制卡片显隐。
 *
 * 特性：
 * - 横向滚动容器，卡片向右堆叠
 * - 错峰入场动画（参考 EntranceCard 模式）
 * - 三重聚焦绑定：点击卡片 → 同步选中 Canvas 曲线 + 表达式列表行
 * - 卡片含：曲线颜色标识、函数标签、表达式、函数性质（定义域/值域/对称性/周期性/增长阶）
 */

import {
  GlobalAnalysisResult,
  domainTextOf,
  rangeTextOf,
  symmetryTextOf,
  periodTextOf,
  growthTextOf
} from 'graph';
import { UiMotion } from '../support/UiMotion';

/** 分析卡片数据（由 GraphCanvas 组装传入） */
export interface AnalysisCardData {
  fnId: number;
  expr: string;
  name: string;
  color: string;
  result: GlobalAnalysisResult | null;
}

@Component
export struct AnalysisDock {
  /** 卡片数据列表 */
  @Prop cards: AnalysisCardData[] = [];
  /** 当前选中卡片 fnId（与 Canvas/列表 activeId 同步） */
  @Prop activeCardId: number = -1;
  /** 卡片选中回调（触发三重绑定） */
  onCardSelect: (fnId: number) => void = (): void => {};
  /** 卡片关闭回调 */
  onCardClose: (fnId: number) => void = (): void => {};

  // ── 常量 ──────────────────────────────────────
  private readonly CARD_W: number = 200;
  private readonly CARD_H: number = 130;
  private readonly CARD_GAP: number = 8;
  private readonly DOCK_H: number = 146; // CARD_H + 上下间距
  private readonly DOCK_PAD_H: number = 8;

  build() {
    Row() {
      Scroll() {
        Row({ space: this.CARD_GAP }) {
          ForEach(this.cards, (card: AnalysisCardData, index: number): void => {
            this.analysisCardBuilder(card, index);
          }, (card: AnalysisCardData): string => card.fnId.toString())
        }
        .padding({ left: this.DOCK_PAD_H, right: this.DOCK_PAD_H })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(this.DOCK_H)
    }
    .width('100%')
    .height(this.DOCK_H)
    .backgroundColor('rgba(0,0,0,0.02)')
  }

  /** 单个分析卡片 */
  @Builder
  analysisCardBuilder(card: AnalysisCardData, index: number): void {
    AnalysisCard({
      card: card,
      isActive: card.fnId === this.activeCardId,
      delay: UiMotion.STAGGER * index,
      onSelect: (fnId: number): void => { this.onCardSelect(fnId); },
      onClose: (fnId: number): void => { this.onCardClose(fnId); }
    })
      .width(this.CARD_W)
      .height(this.CARD_H)
  }
}

/**
 * AnalysisCard - 单个函数分析卡片
 *
 * 错峰入场动画：onAppear 时 opacity 0→1 + translateY 12→0
 */
@Component
struct AnalysisCard {
  card: AnalysisCardData = { fnId: 0, expr: '', name: '', color: '#185FA5', result: null };
  isActive: boolean = false;
  delay: number = 0;
  onSelect: (fnId: number) => void = (): void => {};
  onClose: (fnId: number) => void = (): void => {};

  @State private entered: boolean = false;

  build() {
    Column() {
      // 顶部：颜色圆点 + 标签 + 表达式 + 关闭按钮
      Row({ space: 4 }) {
        // 曲线颜色标识
        Circle()
          .width(10)
          .height(10)
          .fill(this.card.color)

        // 函数标签
        Text(this.card.name)
          .fontSize($r('app.float.font_caption'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))

        // 表达式
        Text(this.card.expr)
          .fontSize($r('app.float.font_caption'))
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        // 关闭按钮
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize($r('app.float.font_body_sm'))
          .fontColor([$r('sys.color.font_tertiary')])
          .onClick(() => {
            this.onClose(this.card.fnId);
          })
      }
      .width('100%')
      .padding({ bottom: 4 })

      // 函数性质信息
      Column({ space: 2 }) {
        this.propRow($r('app.string.graph_analysis_domain'), domainTextOf(this.card.result))
        this.propRow($r('app.string.graph_analysis_range'), rangeTextOf(this.card.result))
        this.propRow($r('app.string.graph_analysis_symmetry'), symmetryTextOf(this.card.result))
        this.propRow($r('app.string.graph_analysis_period'), periodTextOf(this.card.result))
        this.propRow($r('app.string.graph_analysis_growth'), growthTextOf(this.card.result))
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .padding(8)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius($r('app.float.radius_md'))
    .border({
      width: this.isActive ? 1.5 : 0,
      color: this.isActive ? $r('sys.color.brand') : Color.Transparent
    })
    .shadow({
      radius: 6,
      color: 'rgba(0,0,0,0.10)',
      offsetX: 0,
      offsetY: 1
    })
    .opacity(this.entered ? 1 : 0)
    .translate({ y: this.entered ? 0 : 12 })
    .animation({ duration: UiMotion.SLOW, curve: Curve.EaseOut, delay: this.delay })
    .onAppear(() => { this.entered = true; })
    .onClick(() => {
      this.onSelect(this.card.fnId);
    })
  }

  /** 性质信息行：label + value */
  @Builder
  propRow(label: Resource, value: string): void {
    Row() {
      Text(label)
        .fontSize($r('app.float.font_caption'))
        .fontColor($r('sys.color.font_tertiary'))
        .width(42)
      Text(value)
        .fontSize($r('app.float.font_caption'))
        .fontColor($r('sys.color.font_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
  }
}
