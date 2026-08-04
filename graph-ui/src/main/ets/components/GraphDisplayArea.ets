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
// graph-ui/src/main/ets/components/GraphDisplayArea.ets
/**
 * Graph function display area component
 *
 * P0+ phase: multi-function slot editing
 * - Color dot (cycle click to open palette)
 * - Expression display (Text container, driven by professional keyboard)
 * - Visibility toggle (Toggle)
 * - Delete slot
 * - Add function
 *
 * Data ownership: 瀹夸富缁勪欢 (Local graphFunctions).
 * This component receives data via @Prop, same pattern as GraphCanvas.
 * 瀹夸富缁勪欢 @Local -> this @Prop functions[], build() renders directly.
 *
 * Key fix (2026-07-15): Each row used to be a separate @Component FunctionRow + @Prop fn.
 * In ArkUI ForEach, when item key (fn.id) stays the same but content changes,
 * the framework doesn't pass updated item to child @Prop, causing fn.expr to
 * stay at initial value while GraphCanvas (which holds array internally, iterates
 * without ForEach children) updates correctly.
 *
 * Fix approach: Follow HistPanel's verified pattern - inline @Builder (functionRowBuilder)
 * inside this component, and add content signature to ForEach key (#expr#color#enabled).
 * Now when function content changes, key changes -> ForEach rebuilds the row -> inline
 * Builder renders with latest data, Text(this.fn.expr) always shows the latest expression.
 *
 * Fix (2026-07-23): Append #fn.name to ForEach key so rename also triggers row refresh.
 */

import {
  GraphFunction, GraphLineStyle, graphDisplayName, MarkerCategory,
  ExprClassifier, RenderMode
} from 'graph';
import { LengthMetrics, promptAction } from '@kit.ArkUI';
import { HdsNavDestination, ScrollEffectType, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { getSystemMaterialEffect } from '../support/CompatUtils';
import { ModeTag } from '../support/ModeTag';
import { ExprView, MathFieldView } from 'exprrender';
import { MathField } from 'exprrender';

interface HdsMenuContent {
  label: string | Resource;
  icon: Resource;
  isEnabled: boolean;
  action: () => void;
}
interface HdsMenuItem {
  content: HdsMenuContent;
}

/**
 * Function input/display area (multi-slot list, V1 component, @Prop receiving)
 * Same structure as GraphCanvas: @Watch on functions / activeId @Prop ensures
 * rebuild when 瀹夸富缁勪欢 @Local graphFunctions is reassigned.
 * ForEach with content-signature keys rebuilds each row; inline Builder renders latest data.
 */
@Component
export struct GraphDisplayArea {
  @Prop @Watch('onGraphDataChange') functions: GraphFunction[] = [];
  // 当前编辑槽id（与 瀹夸富缁勪欢 键盘输入落点同步）
  @Prop @Watch('onGraphDataChange') activeId: number = -1;
  /** Phase C / P2: 活跃编辑槽的 MathField（光标位置由树驱动），null 时退回到 ExprView 字符串代理 */
  @Prop activeField: MathField | null = null;
  /** MathField 版本计数器，变化时触发 MathFieldView 重绘以更新光标位置 */
  @Prop fieldVersion: number = 0;
  onAdd: () => void = () => {};
  onRemove: (id: number) => void = () => {};
  onToggle: (id: number) => void = () => {};
  // 保留以兼容 瀹夸富缁勪欢 的传参（表达式由专业键盘通过 瀹夸富缁勪欢.graphSetExpr 写回）
  onExprChange: (id: number, expr: string) => void = () => {};
  onColorChange: (id: number, color: string) => void = () => {};
  // 选中槽位（设为键盘输入落点）
  onSelect: (id: number) => void = () => {};
  // 行内"更多"菜单的回调
  @State private menuOpenId: number = -1;
  onLineStyleChange: (id: number, style: GraphLineStyle) => void = () => {};
  onLineWidthChange: (id: number, w: number) => void = () => {};
  onDuplicate: (id: number) => void = () => {};
  onSettings: (id: number) => void = () => {};
  /** 重命名（曲线别名） */
  onRename: (id: number, name: string) => void = () => {};
  /** 保存至历史记录（手动触发：截取该函数图像缩略图 + 表达式存入历史） */
  onSaveToHistory: (id: number) => void = () => {};
  /** 切换函数分析卡片显隐 */
  onAnalysisToggle: (id: number) => void = () => {};
  /** 设置某函数的指定标记分类显示（零点/极值/拐点/渐近线） */
  onMarkerCategoryChange: (id: number, category: MarkerCategory, show: boolean) => void = () => {};
  /** Pro 升级弹窗回调（仅在 advancedAnalysisEnabled=false 的行内提示点击时触发，宿主可选实现） */
  onOpenProIntro: () => void = () => {};
  /** 重命名弹窗控制器（每次打开动态构造以传入当前名称） */
  private renameController?: CustomDialogController;
  /** 暗色模式：由宿主传入（@Prop），不绑定 AppStorage */
  @Prop isDark: boolean = false;
  /** 高级分析功能开关（拐点 / 渐近线），由宿主门控，默认开启 */
  @Prop advancedAnalysisEnabled: boolean = true;

  // ── 呼吸灯动画状态 ──
  /** 当前执行呼吸灯动画的行 id（-1 = 无动画） */
  @State private breathingRowId: number = -1;
  /** 呼吸灯动画透明度（1.0 ↔ 0.3 交替） */
  @State private breathingOpacity: number = 1.0;
  /** 表达式验证错误集合：由 瀹夸富缁勪欢 传入，驱动红色背景 + 表达式变色 */
  exprErrors: Set<number> = new Set();
  /** 错误状态版本号，变化时触发重渲染 */
  @Prop @Watch('onGraphDataChange') exprErrorVersion: number = 0;
  /** 呼吸灯闪烁目标 id（由 GraphViewModel.flashId 驱动，已有空占位符时闪烁提醒） */
  @Prop @Watch('onFlashChange') flashId: number = -1;
  /** 是否横屏（用于条件化安全区扩展） */
  @Prop isLandscape: boolean = false;
  /** 是否手机设备：手机不包 HdsNavDestination，平板包装（与 瀹夸富缁勪欢 设备检测保持一致） */
  @Prop isPhoneDevice: boolean = false;


  // 与 GraphCanvas.onDataChange 同构：@Watch 加载即通知框架本组件需重绘
  private onGraphDataChange(): void {
    // 空实现：build() 内的 ForEach(this.functions, key 含内容签名) 随新引用重评并重建行
  }

  /** 呼吸灯触发：flashId 变化时启动透明度交替动画，提醒用户已有空占位符 */
  private onFlashChange(): void {
    if (this.flashId < 0) {
      return;
    }
    this.breathingRowId = this.flashId;
    this.breathingOpacity = 1.0;
    animateTo({
      duration: 300,
      iterations: 2,
      playMode: PlayMode.AlternateReverse
    }, (): void => {
      this.breathingOpacity = 0.3;
    });
    setTimeout((): void => {
      this.breathingRowId = -1;
      this.breathingOpacity = 1.0;
    }, 700);
  }

  /** 按 id 取最新函数对象（popup 内实时读取，避免使用行构建时捕获的旧快照） */
  private fnById(id: number): GraphFunction | undefined {
    return this.functions.find((f: GraphFunction): boolean => f.id === id);
  }

  /** 实时线型（默认 solid），供 popup 聚焦态判断 */
  private fnLineStyle(id: number): GraphLineStyle {
    const f: GraphFunction | undefined = this.fnById(id);
    return f != undefined ? f.lineStyle : 'solid';
  }

  /** 实时线宽（默认 3），供 popup 聚焦态判断 */
  private fnLineWidth(id: number): number {
    const f: GraphFunction | undefined = this.fnById(id);
    return f != undefined ? (f.lineWidth ?? 3) : 3;
  }

  /** 实时可见性（默认 true），供 popup Toggle 反映 */
  private fnEnabled(id: number): boolean {
    const f: GraphFunction | undefined = this.fnById(id);
    return f != undefined ? f.enabled : true;
  }

  /** 实时渲染模式（空表达式视为 EXPLICIT），供菜单项动态控制 */
  private fnRenderMode(id: number): RenderMode {
    const f: GraphFunction | undefined = this.fnById(id);
    if (f === undefined || f.expr.trim().length === 0) {
      return RenderMode.EXPLICIT;
    }
    return ExprClassifier.classify(f.expr).mode;
  }

  /** 实时分析卡片显隐状态 */
  private fnShowAnalysis(id: number): boolean {
    const f: GraphFunction | undefined = this.fnById(id);
    return f != undefined ? (f.showAnalysis ?? false) : false;
  }

  /** 实时标记分类开关状态 */
  private fnShowMarker(id: number, category: MarkerCategory): boolean {
    const f: GraphFunction | undefined = this.fnById(id);
    if (f === undefined) {
      return false;
    }
    if (category === 'zeros') {
      return f.showZeros ?? false;
    }
    if (category === 'extrema') {
      return f.showExtrema ?? false;
    }
    if (category === 'inflections') {
      return f.showInflections ?? false;
    }
    return f.showAsymptotes ?? false;
  }

  /** 打开重命名弹窗（动态构造控制器以传入当前名称） */
  private openRename(id: number): void {
    const cur: GraphFunction | undefined = this.fnById(id);
    const initName: string = cur != undefined && cur.name != undefined ? cur.name : '';
    this.renameController = new CustomDialogController({
      builder: RenameDialog({
        initialName: initName,
        onConfirm: (n: string): boolean => this.confirmRename(id, n)
      }),
      alignment: DialogAlignment.Center,
      customStyle: false,
      width: 300
    });
    this.renameController.open();
  }

  /** 重命名确认：唯一性校验通过后回写别名；重复时 toast 提示并拒绝（返回 false 阻止弹窗关闭） */
  private confirmRename(id: number, name: string): boolean {
    if (name.length > 0) {
      const isDuplicate: boolean = this.functions.some((f: GraphFunction): boolean =>
        f.id !== id && graphDisplayName(f) === name);
      if (isDuplicate) {
        promptAction.showToast({ message: '函数名称重复，请使用其他名称' });
        return false;
      }
    }
    this.onRename(id, name);
    return true;
  }

  /** 表达式行背景色：基于验证错误状态（check 按钮触发），不再每次按键实时验证 */
  private getExprBgColor(id: number): ResourceColor {
    if (this.exprErrors.has(id)) {
      return $r('app.color.error_bg');
    }
    return $r('sys.color.comp_background_secondary');
  }


  /**
   * 单行 UI（内联 @Builder，直接消费传入的 fn/index，随父组件 build() 重绘刷新）
   */
  @Builder
  private functionRowBuilder(fn: GraphFunction, index: number): void {
    Row({ space: $r('app.float.spacing_sm') }) {
      // 标签 y₁ / y₂ ...（有自定义别名则显示别名；默认标签为创建时分配的固定序号，不随增删滑动）
      Text(graphDisplayName(fn))
        .fontSize($r('app.float.font_body'))
        .fontStyle(FontStyle.Italic)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
        .width(40)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.MARQUEE })

      // 表达式显示：活跃槽用 MathFieldView（P2 树光标），其他槽用 ExprView
      Row() {
        if (fn.id === this.activeId && this.activeField != null) {
          MathFieldView({
            field: this.activeField!,
            fontSize: 18,
            fieldVersion: this.fieldVersion,
            errorMode: this.exprErrors.has(fn.id)
          })
        } else {
          ExprView({
            expr: fn.expr,
            fontSize: 18
          })
        }
      }
        .layoutWeight(1)
        .constraintSize({ minHeight: 40 })
        .alignItems(VerticalAlign.Center)
        .padding({
          left: $r('app.float.spacing_sm'),
          right: $r('app.float.spacing_sm'),
          top: 4,
          bottom: 4
        })
        .backgroundColor(this.getExprBgColor(fn.id))
        .borderRadius($r('app.float.radius_sm'))
        .onClick(() => {
          // 点击表达式区选中该槽，专业键盘输出定向到此函数
          this.onSelect(fn.id);
        })

      // 模式标签（根据表达式自动判定渲染模式，表达式非空时始终显示，含活跃槽）
      if (fn.expr.trim().length > 0) {
        ModeTag({ mode: ExprClassifier.classify(fn.expr).mode, isDark: this.isDark })
      }

      // 更多操作（线型/线宽/显示隐藏/重复输入/删除/设置）
      Button({ type: ButtonType.Circle, stateEffect: false }) {
        SymbolGlyph($r('sys.symbol.dot_grid_2x2'))
          .fontSize($r('app.float.font_title'))
          .fontColor([$r('sys.color.font_primary')])
      }
      .width(32)
      .height(32)
      .padding(4)
      .backgroundColor($r('sys.color.button_background_color_transparent'))
      .onClick(() => {
        this.menuOpenId = (this.menuOpenId === fn.id) ? -1 : fn.id;
      })
      .bindPopup(this.menuOpenId === fn.id, {
          builder: (): void => this.funcMenuBuilder(fn.id),
          placement: Placement.BottomRight,
          maskColor: 0x33000000,
          popupColor: $r('sys.color.comp_background_primary'),
          backgroundBlurStyle: BlurStyle.BACKGROUND_THICK,
          enableArrow: true,
          onWillDismiss: (): void => { this.menuOpenId = -1; }
        })
    }
    .width('100%')
    .onClick(() => {
      // 点选行任意处 -> 设为键盘输入落点
      this.onSelect(fn.id);
    })
    .padding({
      left: $r('app.float.spacing_sm'),
      right: $r('app.float.spacing_sm'),
      top: $r('app.float.spacing_xs'),
      bottom: $r('app.float.spacing_xs')
    })
    .backgroundColor(fn.id === this.activeId ? 'rgba(24,95,165,0.08)' : Color.Transparent)
    .opacity(fn.id === this.breathingRowId ? this.breathingOpacity : 1.0)
  }

  /** 行"更多"菜单：三组结构（线型样式 / 图象分析 / 操作项） */
  @Builder
  private funcMenuBuilder(id: number): void {
    Column() {
      // ═══ 第一组：线型样式 ═══
      Column({ space: 0 }) {
        // 线型/线宽：不等式隐藏（填充区域无线条属性）
        if (this.fnRenderMode(id) !== RenderMode.INEQUALITY) {
          // 线型（实线/虚线）
          Row() {
            Text($r('app.string.graph_menu_line_style'))
              .fontSize($r('app.float.font_body_sm'))
              .fontColor($r('sys.color.font_primary'))
            Blank()
            Row({ space: 4 }) {
              this.styleChip(id, 'solid', $r('sys.symbol.circle'))
              this.styleChip(id, 'dashed', $r('sys.symbol.circle_dashed'))
            }
          }
          .width('100%')
          .height(30)

          // 线宽（细/中/粗）
          Row() {
            Text($r('app.string.graph_menu_line_width'))
              .fontSize($r('app.float.font_body_sm'))
              .fontColor($r('sys.color.font_primary'))
            Blank()
            Row({ space: 4 }) {
              this.widthChipSymbol(id, 2, FontWeight.Lighter)
              this.widthChipSymbol(id, 3, FontWeight.Medium)
              this.widthChipSymbol(id, 4.5, FontWeight.Bold)
            }
          }
          .width('100%')
          .height(30)
        }

        // 显示/隐藏
        Row() {
          Text($r('app.string.graph_menu_visibility'))
            .fontSize($r('app.float.font_body_sm'))
            .fontColor($r('sys.color.font_primary'))
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.fnEnabled(id) })
            .width(40)
            .height(22)
            .onChange((): void => {
              this.onToggle(id);
            })
        }
        .width('100%')
        .height(30)
      }

      // ── 分割线 ──
      Divider().color($r('sys.color.comp_divider')).margin({ top: 6, bottom: 6 })

      // ═══ 第二组：图象分析 ═══
      Column({ space: 0 }) {
        // 组标题
        Text($r('app.string.graph_menu_analysis'))
          .fontSize($r('app.float.font_caption'))
          .fontColor($r('sys.color.font_tertiary'))
          .padding({ bottom: 4 })

        // TODO: 当前版本暂不上线函数分析功能，待技术成熟后开放
        // 分析总开关（当前禁用）
        // Row() {
        //   Text($r('app.string.graph_analysis_title'))
        //     .fontSize($r('app.float.font_body_sm'))
        //     .fontColor($r('sys.color.font_primary'))
        //   Blank()
        //   Toggle({ type: ToggleType.Switch, isOn: false })
        //     .width(40)
        //     .height(22)
        //     .enabled(false)
        // }
        // .width('100%')
        // .padding({ top: 6, bottom: 6 })

        // 零点（免费）
        Row() {
          Text($r('app.string.graph_analysis_zero'))
            .fontSize($r('app.float.font_body_sm'))
            .fontColor($r('sys.color.font_primary'))
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.fnShowMarker(id, 'zeros') })
            .width(40)
            .height(22)
            .onChange((isOn: boolean): void => {
              this.onMarkerCategoryChange(id, 'zeros', isOn);
            })
        }
        .width('100%')
        .height(30)

        // 极值（免费）
        Row() {
          Text($r('app.string.graph_analysis_extremum'))
            .fontSize($r('app.float.font_body_sm'))
            .fontColor($r('sys.color.font_primary'))
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.fnShowMarker(id, 'extrema') })
            .width(40)
            .height(22)
            .onChange((isOn: boolean): void => {
              this.onMarkerCategoryChange(id, 'extrema', isOn);
            })
        }
        .width('100%')
        .height(30)

        // 拐点（高级分析门控）
        if (this.advancedAnalysisEnabled) {
          Row() {
            Text($r('app.string.graph_analysis_inflection'))
              .fontSize($r('app.float.font_body_sm'))
              .fontColor($r('sys.color.font_primary'))
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.fnShowMarker(id, 'inflections') })
              .width(40)
              .height(22)
              .onChange((isOn: boolean): void => {
                this.onMarkerCategoryChange(id, 'inflections', isOn);
              })
          }
          .width('100%')
          .height(30)
        } else {
          Row({ space: 6 }) {
            Text($r('app.string.graph_analysis_inflection'))
              .fontSize($r('app.float.font_body_sm'))
              .fontColor($r('sys.color.font_tertiary'))
              .layoutWeight(1)
            Text($r('app.string.graph_analysis_pro_required'))
              .fontSize($r('app.float.font_caption'))
              .fontColor($r('sys.color.brand'))
          }
          .width('100%')
          .height(30)
          .onClick(() => { this.onOpenProIntro(); })
        }

        // 渐近线（高级分析门控）
        if (this.advancedAnalysisEnabled) {
          Row() {
            Text($r('app.string.graph_analysis_asymptote'))
              .fontSize($r('app.float.font_body_sm'))
              .fontColor($r('sys.color.font_primary'))
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.fnShowMarker(id, 'asymptotes') })
              .width(40)
              .height(22)
              .onChange((isOn: boolean): void => {
                this.onMarkerCategoryChange(id, 'asymptotes', isOn);
              })
          }
          .width('100%')
          .height(30)
        } else {
          Row({ space: 6 }) {
            Text($r('app.string.graph_analysis_asymptote'))
              .fontSize($r('app.float.font_body_sm'))
              .fontColor($r('sys.color.font_tertiary'))
              .layoutWeight(1)
            Text($r('app.string.graph_analysis_pro_required'))
              .fontSize($r('app.float.font_caption'))
              .fontColor($r('sys.color.brand'))
          }
          .width('100%')
          .height(30)
          .onClick(() => { this.onOpenProIntro(); })
        }
      }

      // ── 分割线 ──
      Divider().color($r('sys.color.comp_divider')).margin({ top: 6, bottom: 6 })

      // ═══ 第三组：操作项 ═══
      Column({ space: 0 }) {
        // 重复输入
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.square_and_square'))
            .fontSize($r('app.float.font_title_sm'))
            .fontColor([$r('sys.color.font_primary')])
          Text($r('app.string.graph_menu_duplicate'))
            .fontSize($r('app.float.font_body_sm'))
            .fontColor($r('sys.color.font_primary'))
        }
        .width('100%')
        .height(30)
        .onClick(() => {
          this.onDuplicate(id);
          this.menuOpenId = -1;
        })

        // 历史快照
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.camera_fill'))
            .fontSize($r('app.float.font_title_sm'))
            .fontColor([$r('sys.color.font_primary')])
          Text($r('app.string.graph_menu_save_history'))
            .fontSize($r('app.float.font_body_sm'))
            .fontColor($r('sys.color.font_primary'))
        }
        .width('100%')
        .height(30)
        .onClick(() => {
          this.onSaveToHistory(id);
          this.menuOpenId = -1;
        })

        // 重命名
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.square_and_pencil_fill'))
            .fontSize($r('app.float.font_title_sm'))
            .fontColor([$r('sys.color.font_primary')])
          Text($r('app.string.graph_menu_rename'))
            .fontSize($r('app.float.font_body_sm'))
            .fontColor($r('sys.color.font_primary'))
        }
        .width('100%')
        .height(30)
        .onClick(() => {
          this.menuOpenId = -1;
          this.openRename(id);
        })

        // 删除
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.trash_fill'))
            .fontSize($r('app.float.font_title_sm'))
            .fontColor([$r('sys.color.warning')])
          Text($r('app.string.graph_menu_delete'))
            .fontSize($r('app.float.font_body_sm'))
            .fontColor($r('sys.color.warning'))
        }
        .width('100%')
        .height(30)
        .onClick(() => {
          this.onRemove(id);
          this.menuOpenId = -1;
        })
      }
    }
    .padding(12)
    .width(220)
  }

  /** 线型 chip：选中态（实时线型 === style）为 brand 背景 + 白色 symbol */
  @Builder
  private styleChip(id: number, style: GraphLineStyle, sym: Resource): void {
    Button() {
      SymbolGlyph(sym)
        .fontSize($r('app.float.font_title_sm'))
        .fontColor([this.fnLineStyle(id) === style ? Color.White : $r('sys.color.font_primary')])
    }
    .width(34)
    .height(28)
    .padding(0)
    .backgroundColor(this.fnLineStyle(id) === style ? $r('sys.color.brand') : $r('sys.color.comp_background_secondary'))
    .onClick(() => {
      this.onLineStyleChange(id, style);
    })
  }

  /** 线宽预设 chip：用 sys.symbol.waveform + 三档字重（细/中/粗）表示，选中态 brand 背景 + 白色 symbol */
  @Builder
  private widthChipSymbol(id: number, w: number, weight: FontWeight): void {
    Button() {
      SymbolGlyph($r('sys.symbol.waveform'))
        .fontSize($r('app.float.font_title'))
        .fontWeight(weight)
        .fontColor([this.fnLineWidth(id) === w ? Color.White : $r('sys.color.font_primary')])
    }
    .width(34)
    .height(28)
    .padding(0)
    .backgroundColor(this.fnLineWidth(id) === w ? $r('sys.color.brand') : $r('sys.color.comp_background_secondary'))
    .onClick(() => {
      this.onLineWidthChange(id, w);
    })
  }

  build() {
    if (this.isPhoneDevice) {
      // 手机：不使用 HdsNavDestination 包装，直接渲染内容（紧凑上下布局，无需标题栏）
      this.graphListContent()
    } else {
      // 平板：使用 HdsNavDestination 包装，保留标题栏材质模糊效果
      HdsNavDestination() {
        this.graphListContent()
      }
      .titleBar({
        content:{
          title:{
            //todo:没想好~ 那就慢慢想
            mainTitle:'',
          }
        },
        style: {
          scrollEffectOpts: {
            enableScrollEffect: true,
            scrollEffectType: ScrollEffectType.GRADIENT_BLUR,
            blurEffectiveStartOffset: LengthMetrics.vp(20),
            blurEffectiveEndOffset: LengthMetrics.vp(50)
          },
          systemMaterialEffect: getSystemMaterialEffect()
        },
        avoidLayoutSafeArea: false,
        enableComponentSafeArea: false
      })
      .hideBackButton(true)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
  }

  /** 函数列表内容（手机/平板两种包装策略共用） */
  @Builder
  graphListContent(): void {
    Column() {
      // 函数列表
      List() {
        ListItem() {
          Row() {
            // 手机：顶部触控条已在 瀹夸富缁勪欢 Sheet 内提供间隔，仅留 4vp；平板保持原占位
            Blank().height(this.isPhoneDevice ? 4 : (this.isLandscape ? 100 : 50))
          }
          .width('100%')
        }
        .width('100%')
        .clip(false)

        ForEach(
          this.functions,
          (fn: GraphFunction, index: number): void => {
            ListItem() {
              this.functionRowBuilder(fn, index)
            }
          },
          // 活跃编辑槽：key 不含 expr，保持 MathFieldView 存活（光标由 fieldVersion 驱动更新）
          // 非活跃槽：key 含 expr，确保 ExprView 随表达式变化重建
          // key 含显示名称，确保重命名 / 清除别名后触发行重建
          (fn: GraphFunction): string =>
            fn.id === this.activeId
              ? `active#${fn.id}#${fn.color}#${graphDisplayName(fn)}`
              : `${fn.id}#${fn.expr}#${fn.color}#${graphDisplayName(fn)}`
        )
      }
      .layoutWeight(1)
      .height('100%')
      .width('100%')
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    // 手机：顶部圆角由 瀹夸富缁勪欢 Sheet 外层 Column（radius_lg + clip）统一提供，
    // 自身不再圆角，避免与上方同色触控条热区之间出现圆角接缝
    .backgroundColor($r('sys.color.background_tertiary'))
  }
}

/** 函数名称最大输入长度 */
const RENAME_MAX_LENGTH: number = 16;

/**
 * 重命名弹窗：输入曲线别名（系统输入法，短文本）
 * - 最大输入 16 个字符，超出时截断并 toast 提示
 * - 确认时由外部校验唯一性，校验失败不关闭弹窗
 */
@CustomDialog
struct RenameDialog {
  controller?: CustomDialogController;
  @State name: string = '';
  initialName: string = '';
  /** 返回 true 表示确认成功（关闭弹窗），false 表示校验失败（保持弹窗） */
  onConfirm: (name: string) => boolean = (): boolean => true;

  aboutToAppear(): void {
    this.name = this.initialName;
  }

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.graph_menu_rename'))
        .fontSize($r('app.float.font_body'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .alignSelf(ItemAlign.Start)
      TextInput({ text: $$this.name, placeholder: $r('app.string.graph_rename_ph') })
        .onChange((v: string): void => {
          if (v.length > RENAME_MAX_LENGTH) {
            this.name = v.substring(0, RENAME_MAX_LENGTH);
            promptAction.showToast({ message: '函数名称最多16个字符' });
          }
        })
        .height($r('app.float.button_height_sm'))
        .backgroundColor($r('sys.color.comp_background_secondary'))
        .borderRadius($r('app.float.radius_xs'))
      Row({ space: 12 }) {
        Button($r('app.string.graph_cancel'))
          .layoutWeight(1)
          .height(36)
          .backgroundColor($r('sys.color.comp_background_secondary'))
          .fontColor($r('sys.color.font_primary'))
          .onClick(() => {
            this.controller?.close();
          })
        Button($r('app.string.graph_settings_unit_ok'))
          .layoutWeight(1)
          .height(36)
          .backgroundColor($r('sys.color.brand'))
          .fontColor(Color.White)
          .onClick(() => {
            if (this.onConfirm(this.name.trim())) {
              this.controller?.close();
            }
          })
      }
      .width('100%')
      .margin({ top: 4 })
    }
    .padding(16)
    .width('100%')
  }
}