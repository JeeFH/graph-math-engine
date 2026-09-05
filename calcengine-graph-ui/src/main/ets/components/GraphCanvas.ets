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
// calcengine-graph-ui/src/main/ets/components/GraphCanvas.ets
/**
 * 图象绘图画布组件
 *
 * 用 CanvasRenderingContext2D 绘制坐标系（网格 / 坐标轴 / 刻度标签 / 原点）。
 * 视口 Viewport 控制可见域，变化即重绘。绘制坐标单位 vp（与 ArkUI 一致），
 * 框架自动处理高 DPI，线宽 / 字号均为 vp，清晰锐利。
 *
 * 手势交互（#11）：
 * - 单指拖拽：平移视口（内容跟随手指）。
 * - 双指捏合：以捏合中点为世界锚点、X/Y 等比缩放（圆形不被压扁）。
 * - 双击画布：重置视口到默认视图，带 easeInOutCubic 缓动（运镜式平滑过渡，约 380ms）；可在设置中「双击画布回到初始视图」开关，默认开。
 * 视口始终按画布宽高比校正，保证 X / Y 方向 world-per-pixel 相等。
 *
 * 选中交互（#13）：
 * - 单指轻点（TapGesture count:1）：命中检测→选中曲线并弹出浮动快捷工具条；
 *   点空白处收起工具条。命中检测跳过所有浮层覆盖区域，避免误触。
 * - 选中的函数在绘制时叠加一层灰度光晕（浅灰描边）。
 * - 浮动工具条（图标）：颜色 / 线条样式 / 函数分析 / 可见性 / 删除。
 * - 颜色按钮弹预设取色面板；“函数分析”计算零点/极值/最值，图上标注 + 底部面板列数值。
 */

import {
  GraphMath, Viewport, FunctionEvaluator, FunctionSampleCache, WorldSample, SampleEngine,
  GraphFunction, GraphLineStyle, MarkerCategory, nextLineStyle, GRAPH_COLOR_PICKER, graphDisplayName,
  GlobalAnalyzer, GlobalAnalysisResult, RenderDispatcher, RenderMode, GraphImageExporter
} from 'calcengine-graph';
import { GraphCanvasController } from './GraphCanvasController';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { parseLinear, simplify, ExprRenderer, Box, measureAndRelayout } from 'calcengine-exp';
import { AnalysisDock, AnalysisCardData } from './AnalysisDock';
import { GridAxisPainter, GridAxisConfig } from '../paint/GridAxisPainter';
import { GraphCurvePainter, CurvePaintEnv } from '../paint/GraphCurvePainter';
import { GraphGestureMath, HitTestEnv } from '../gesture/GraphGestureMath';
import { GraphExportService } from '../export/GraphExportService';
import { UiMotion } from '../support/UiMotion';

/** 特殊点标记分析缓存条目（视口无关的全局分析，表达式/角度模式变化即失效） */
interface MarkerCacheEntry {
  expr: string;
  isDeg: boolean;
  result: GlobalAnalysisResult | null;
}

/** 固定视口截图的正方形截取区域（像素坐标） */
interface CaptureRegion {
  x: number;
  y: number;
  size: number;
}


@Component
export struct GraphCanvas {
  // 视口（可见域），@State 以便变化触发重绘
  @State @Watch('onVpChange') viewport: Viewport = GraphMath.defaultViewport();
  // 待绘制函数列表（由 瀹夸富缁勪欢 @Local graphFunctions 经 @Prop 下发，编辑区写回即重绘）
  @Prop @Watch('onDataChange') functions: GraphFunction[] = [];
  // 角度模式（由 瀹夸富缁勪欢 @Local isDegMode 下发）
  @Prop @Watch('onDataChange') isDegMode: boolean = false;
  // 当前选中函数 id（与函数列表焦点同步：两端均来自 瀹夸富缁勪欢.graphActiveId 单一真相）
  @Prop @Watch('onDataChange') activeId: number = -1;
  // 画布高度百分比（全屏模式 100%）
  @Prop canvasHeightPercent: number = 100;
  // 是否横屏（用于条件化安全区扩展）
  @Prop isLandscape: boolean = false;
  // ── 可视区域中心（视图中心优化）──
  // 画布被表达式区域遮挡后真正可视区域的中心坐标（vp，以画布左上角为原点）。
  // 手机：底部 Sheet 遮挡 → 瀹夸富缁勪欢 下发可视中心 Y = (容器高 - Sheet 高)/2；X 传 -1 用画布水平中心。
  // 平板：画布自身已不含表达式区（左右分栏），传 -1 回退画布几何中心即等价于 (屏宽 - 表达式区宽)/2。
  // <=0 表示回退到画布几何中心（canvasW/2 或 canvasH/2）。
  // @Watch：首次下发直接落位默认视图；后续变化（面板模式切换）运镜重置到新可视中心
  @Prop @Watch('onVisibleCenterChange') visibleCenterX: number = -1;
  @Prop @Watch('onVisibleCenterChange') visibleCenterY: number = -1;
  // 平板沉浸式画板：右侧悬浮控件（设置齿轮/面板）的右侧避让内边距（vp）。
  // 显示态时 = 包装 Column 宽，使齿轮不被面板遮挡；沉浸态归 0 回到右上角。
  @Prop overlayRightInsetVp: number = 0;
  // 暗色模式：由宿主传入（@Prop）。开源版不绑定 AppStorage，
  // 宿主可自行决定暗色状态来源（系统 colorMode / AppStorage / 其他）。
  @Prop @Watch('onThemeChange') isDark: boolean = false;
  // Canvas 上下文（onReady 时赋值）
  private ctx: CanvasRenderingContext2D | null = null;
  // 重绘去抖：按键会高频触发 onDataChange，若每次同步重绘整个 Canvas
  // （网格 + 轴 + 多条曲线），主线程会被挤占甚至卡死。用该标志合并成「下一帧一次重绘」。
  private drawScheduled: boolean = false;
  // 画布像素尺寸（vp）—— 仅用于 Canvas 绘制（Canvas 为 110% 高度，故 canvasH 含溢出）
  @State private canvasW: number = 0;
  @State private canvasH: number = 0;
  // 根 Stack 可视尺寸（width 100% / height 100%，无溢出）—— 浮层定位基准，务必用这俩，不要用 canvasW/H
  @State private rootW: number = 0;
  @State private rootH: number = 0;
  // CanvasRenderingContext2D 实例（构造时创建，传给 Canvas 组件）
  private canvasContext: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  // 表达式导出专用离屏 Canvas 上下文（水印合成时渲染表达式 PixelMap，不干扰主画布）
  private exprExportContext: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  // 离屏 Canvas 就绪标记（onReady 触发后才允许 getPixelMap，避免 ctx 未绑定时度量回退/截图失败）
  private exprExportReady: boolean = false;
  // 离屏 Canvas 实际尺寸（vp，onAreaChange 更新），作为表达式自适应字号的最大边界
  private exprExportW: number = 0;
  private exprExportH: number = 0;
  // 手势起始视口快照（避免拖拽 / 缩放过程中的累积漂移）
  private panStartVp: Viewport = GraphMath.defaultViewport();
  private pinchStartVp: Viewport = GraphMath.defaultViewport();
  // 双指缩放起始时的捏合中点（组件坐标系 vp）。把双指中点相对起始中点的位移，
  // 等效为单指拖拽来平移视图（方向与单指一致），从而双指拖拽即可同时平移 + 缩放。
  private pinchStartCX: number = 0;
  private pinchStartCY: number = 0;
  // 视口是否已按画布宽高比初始化（首帧 onAreaChange 时校正一次）
  private vpInitialized: boolean = false;
  // 可视中心是否已消费过有效下发值：区分「启动首次下发（直接落位，无跳变）」
  // 与「面板模式变化（运镜重置）」两种响应策略
  private visibleCenterApplied: boolean = false;
  // 双指缩放进行中：屏蔽单指平移，避免抖动
  private pinchActive: boolean = false;
  // 双指刚结束的窗口：吞掉松手瞬间残留的单指平移更新，避免“释放跳变 / 卡顿”。
  // 该标记仅在单指平移彻底结束（onActionEnd）时清除，确保双指释放过程中
  // 残留的单指平移被持续屏蔽，不会被误清。
  private pinchJustEnded: boolean = false;
  // 上次「单指轻点」的时间戳（ms）：用于本 handler 内自行判定双击（<300ms 视为双击 → 重置视口），
  // 从而不必再挂一个 TapGesture(count:2) 与单指轻点竞争。0 表示无前序点击。
  private lastTapTs: number = 0;
  // 视口重置动画（运镜式缓动过渡）状态：setInterval 句柄，-1 表示无动画进行中。
  // 每帧把视口从「起始」插值到「目标默认视口」并赋给 @State viewport，
  // 借由 @Watch('onVpChange') 自动重绘，从而产生平滑的镜头移动效果。
  private vpAnimId: number = -1;
  // 视口动画完成回调（截图前置运镜等异步等待场景）；取消时也会触发，避免 Promise 悬挂
  private vpAnimFinish: (() => void) | null = null;
  // 缩放上下限（半跨度，世界单位）：防止缩到退化或放到无穷大
  private readonly MIN_HALF: number = 1e-7;
  private readonly MAX_HALF: number = 1e8;

  // ── #13 选中交互 UI 状态 ──
  // 浮动快捷工具条
  @State private showQuickBar: boolean = false;
  @State private quickX: number = 0;
  @State private quickY: number = 0;
  // ── 浮层生命周期：与函数实例绑定（实例被删除时同步销毁关联 UI，防止悬空面板/工具条） ──
  // 快捷工具条当前作用的函数实例（弹出时记录；选中漂移时直接关闭，不转移到新目标）
  private quickBarFnId: number = -1;
  // 上一次 onDataChange 的函数 id 集合快照（差分检测本次变更中被删除的函数实例）
  private prevFnIds: Set<number> = new Set();
  // 取色面板
  @State private showColorPicker: boolean = false;
  // 特殊点标记缓存（逐函数：视口无关全局分析，绘制时按视口过滤）
  private markerCache: Map<number, MarkerCacheEntry> = new Map();
  // 标记缓存异步构建在途标志（防抖合并连续按键）
  private markerBuildPending: boolean = false;
  // ── 分析坞卡片（底部横向滚动坞，替代旧浮动分析面板） ──
  @State private analysisCards: AnalysisCardData[] = [];
  @State private activeAnalysisId: number = -1;
  // 浮层尺寸常量（用于点击区域命中避让）
  private readonly BAR_W: number = 264; // 快捷工具条宽度（5×36 按钮 + 4 间隙 + 12 内边距）
  private readonly BAR_H: number = 48; // 工具条高度（36 按钮 + 12 内边距）
  private readonly BAR_GAP: number = 8; // 工具条与取色面板间距（对应 app.float.spacing_sm = 8vp）
  private readonly PICKER_W: number = 208; // 取色面板宽度（与工具条同宽）
  private readonly PICKER_H: number = 252; // 取色面板高度（标题 + 色格 + 取消按钮）
  private readonly bar_atom_size: number = 28;

  // ── #14 设置面板（右下角 FAB → 右侧设置列，上/右/下各留小间距）──
  @State private showSettings: boolean = false;
  // 显示开关（影响绘制）
  @State private showGrid: boolean = true;
  @State private showAxes: boolean = true;
  @State private showLabels: boolean = true;
  // 双击画布回到初始视图（设置可开关，默认开）
  @State private doubleTapReset: boolean = true;
  // ── #15 单位长度（刻度步长，0 = 自动 niceStep）──
  @State private xUnitLength: number = 0; // x 轴单位长度（世界单位 / 每主格）
  @State private yUnitLength: number = 0; // y 轴单位长度
  // 单位长度输入 popup 显隐（一级：单位输入框）
  @State private showXUnitPopup: boolean = false;
  @State private showYUnitPopup: boolean = false;
  // 单位长度「你可能想要」建议 popup 显隐（二级：附在输入框上，延迟 0.5s 弹出）
  @State private showXSuggest: boolean = false;
  @State private showYSuggest: boolean = false;
  // 单位长度输入框文本（自定义值）
  @State private xUnitInput: string = '';
  @State private yUnitInput: string = '';
  // 尺寸常量
  private readonly SET_BTN: number = 44; // 设置 FAB 直径（圆形）
  private readonly SET_PAD_Y: number = 0; // 浮层与画布顶部边缘的间距
  private readonly SET_PAD_X: number = 10; // 浮层与画布边缘的Y小间距
  private readonly SET_PANEL_W: number = 300; // 设置菜单宽度（popup 内容）
  private readonly SET_PANEL_H: number = 380; // 设置菜单高度（popup 内容）
  private readonly SET_R_CLOSED: number = 22; // FAB 圆角 = SET_BTN/2（满圆）
  // 根 Stack 为 100% 高度（= 真实可视区），浮层定位基准用 rootW/rootH；
  // 白边由下方 Canvas 单独 110% 顶对齐溢出兜底，不依赖根 Stack 放大。

  // ── 性能优化：缓存与手势状态 ──
  /** 预构建的 FunctionEvaluator 缓存（按函数 id）：避免每次 draw 重复解析表达式 */
  private evaluatorCache: Map<number, FunctionEvaluator> = new Map();
  /** 世界坐标预缓存：函数加载时一次性构建，视图变化仅投影 */
  private sampleCaches: Map<number, FunctionSampleCache> = new Map();
  /** 统一渲染调度器：管理四大模式渲染器的生命周期与缓存。
   *  所有权在 GraphViewModel，由 瀹夸富缁勪欢 通过 `renderDispatcher: graphVM.getRenderDispatcher()` 引用传入。
   *  注意：必须用普通属性（引用传递）而非 @Prop——@Prop 会深拷贝，
   *  导致与 ViewModel 持有的调度器实例分裂，内部渲染器/缓存不同步。 */
  renderDispatcher: RenderDispatcher = new RenderDispatcher();
  /** 画布控制器：由 瀹夸富缁勪欢 持有并引用传入（同 renderDispatcher，不可 @Prop 深拷贝）。
   *  GraphCanvas 挂载后注册缩略图截图实现，供 瀹夸富缁勪欢 间接命令画布截图（“保存至历史记录”功能）。 */
  controller: GraphCanvasController = new GraphCanvasController();
  /** 缓存构建去抖句柄 */
  private cacheBuildPending: boolean = false;
  /** 二维网格缓存防抖构建句柄（合并高频按键为一次构建） */
  private gridBuildPending: boolean = false;
  /** 二维网格构建代次号：每次数据变更自增，用于作废进行中的分块构建任务 */
  private gridBuildGen: number = 0;
  /** 缓存覆盖检查冷却（避免每次视口变更都触发 extension/refine） */
  private coverageCheckCooldown: number = 0;
  /** 手势进行中标志：true 时降质渲染（粗采样 + 跳细分），手势结束恢复全质量 */
  private isGesturing: boolean = false;
  /** 视口去抖句柄（-1 = 无待执行重绘）：合并高频 onVpChange 为单帧一次 draw */
  private vpDrawScheduled: boolean = false;
  /** 曲线绘制器（实例持有轮廓链缓存，跨帧复用） */
  private curvePainter: GraphCurvePainter = new GraphCurvePainter();
  /** 导出服务：分享 / 缩略图持久化（宿主注入适配器；默认 Noop，分享入口自动隐藏） */
  exportService: GraphExportService = new GraphExportService();
  /** 水印栏品牌名（空字符串时水印栏不显示品牌信息） */
  @Prop brandName: string = '';
  /** 水印栏品牌 logo 资源 id（$r('app.media.xxx').id；<=0 表示不显示 logo） */
  brandLogoResId: number = -1;

  // 回调（由 瀹夸富缁勪欢 注入，写回 @Local graphFunctions）
  onSelect: (id: number) => void = () => {
  };
  onColorChange: (id: number, color: string) => void = () => {
  };
  onLineStyleChange: (id: number, style: GraphLineStyle) => void = () => {
  };
  onToggle: (id: number) => void = () => {
  };
  onRemove: (id: number) => void = () => {
  };
  /** 标记分类开关变更回调（由 瀹夸富缁勪欢 注入，写回 GraphViewModel.setMarkerCategory） */
  onMarkerCategoryChange: (id: number, category: MarkerCategory, show: boolean) => void = () => {
  };
  /** 分析坞卡片开关回调（由 瀹夸富缁勪欢 注入，写回 GraphViewModel.toggleAnalysis） */
  onAnalysisToggle: (id: number) => void = () => {
  };
  /** 视图变化回调（平移/缩放手势结束时触发，由 瀹夸富缁勪欢 注入驱动历史缩略图自动刷新检查） */
  onViewChanged: () => void = () => {
  };

  aboutToAppear(): void {
    // 注册缩略图截图实现（闭包在调用时动态读取 this.ctx，注册时 ctx 未就绪也不影响）
    this.controller.registerCapture((fnId: number, silent: boolean): Promise<string> => this.captureThumbnail(fnId, silent));
    // 注册视图快照实现（宿主可用返回的 PixelMap 做飞行动画等自定义用途）
    this.controller.registerViewCapture((fnId?: number): Promise<image.PixelMap | null> => this.captureViewPixelMap(fnId));
  }

  aboutToDisappear(): void {
    // 注销，避免控制器持有已卸载的画布实例
    this.controller.unregisterCapture();
  }


  build() {
    Stack() {
      Canvas(this.canvasContext)
        .width('100%')
        .height('110%')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .alignSelf(ItemAlign.Start)
        .onReady(() => {
          this.ctx = this.canvasContext;
          this.draw();
        })
        .onAreaChange((_oldArea: Area, newArea: Area): void => {
          const w: number = newArea.width as number;
          const h: number = newArea.height as number;
          this.canvasW = w;
          this.canvasH = h;
          if (!this.vpInitialized && w > 0 && h > 0) {
            // 首帧：按画布宽高比校正默认视口（圆不被压扁）；
            // aspectDefaultVp 已消费可视中心——若此时 瀹夸富缁勪欢 已下发，
            // 启动默认视图即为重置坐标位置，无需二次重置
            this.viewport = this.aspectDefaultVp();
            this.vpInitialized = true;
            if (this.visibleCenterX > 0 || this.visibleCenterY > 0) {
              this.visibleCenterApplied = true;
            }
          } else if (w > 0 && h > 0) {
            // 尺寸变化（如旋转）：按新宽高比重拟合，保持 world-per-pixel 相等且不裁切
            this.refitToAspect(w, h);
          }
          if (this.ctx) {
            this.draw();
          }
        })

      // 表达式导出专用离屏 Canvas（仅用于水印中表达式的数学排版渲染）。
      // 注意：不可用 opacity(0) 或屏外定位——会被渲染系统剔除导致 backing store 未分配、
      // getPixelMap 失败。正确做法：与主画布同尺寸同位置、zIndex(-1) 压在其后，
      // 主画布 draw() 填充不透明背景将其完全遮挡，既不可见又正常参与渲染。
      Canvas(this.exprExportContext)
        .width('100%')
        .height('110%')
        .alignSelf(ItemAlign.Start)
        .zIndex(-1)
        .onReady((): void => {
          this.exprExportReady = true;
        })
        .onAreaChange((_oldArea: Area, newArea: Area): void => {
          this.exprExportW = newArea.width as number;
          this.exprExportH = newArea.height as number;
        })

      // 浮动快捷工具条（含其下方取色面板，二者同容器、同宽）
      if (this.showQuickBar) {
        this.quickBarBuilder();
      }
      // TODO: 当前版本暂不上线函数分析功能，待技术成熟后开放
      // 分析坞（底部横向滚动卡片）
      // if (this.analysisCards.length > 0) {
      //   this.analysisDockBuilder();
      // }
      // 设置：齿轮 FAB ↔ 设置面板 共用一个右上角容器，一镜到底转场
      Stack() {
        this.settingsSharedBuilder();
      }
      .width('100%')
      .height('100%')
      .alignContent(Alignment.TopEnd)
      // 右侧避让：平板显示态下向左让出包装 Column，保证齿轮可见；变化时平滑过渡
      .padding({ right: this.overlayRightInsetVp })
      .animation({ duration: 250, curve: Curve.EaseOut })
      .hitTestBehavior(HitTestMode.Transparent);
    }
    .width('100%')
    .height('110%')
    .backgroundColor($r('sys.color.comp_background_primary'))
    .alignContent(Alignment.BottomEnd)
    // 注：不在此挂 id('graph_canvas_view')——瀹夸富缁勪欢 已在 GraphCanvas 实例上挂同名 id，
    // 重复 id 会使 getRectangleById 命中不确定；若命中本 110% 高根 Stack，
    // 飞行动画源矩形中心会比可视画布中心偏下 5%
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .onAreaChange((_old: Area, nv: Area): void => {
      this.rootW = nv.width as number;
      this.rootH = nv.height as number;
    })
    // 注：根 Stack 不挂 expandSafeArea、不放大高度，否则会把子 Canvas 的 onAreaChange
    // 尺寸测大，导致浮层按 canvasH 反推时被顶出可视区。白边由下方 Canvas 单独 110% 顶对齐溢出兜底。
    // 手势（优先级：先挂的优先级最高）：
    //  1) 单指轻点（TapGesture count:1）最高优先级 → 命中曲线/空白稳定可靠，不再被平移抢走；
    //     双击由本 handler 用时间戳自行判定 → 重置视口（避免再挂一个 count:2 手势与轻点竞争）。
    //  2) 平移 + 双指缩放（GestureGroup Parallel）低优先级 → 仅在「非轻点（位移超过阈值）」时接管。
    .gesture(
      TapGesture({ count: 1 })
        .onAction((e: GestureEvent): void => {
          // 双指缩放中或刚结束：忽略单指轻点（防误触 / 释放残留）
          if (this.pinchActive || this.pinchJustEnded) {
            this.pinchJustEnded = false;
            return;
          }
          // 防御：某些触摸场景下 fingerList 可能为空 / 首元素为 undefined（曾导致
          // “Cannot read property localX of undefined” 闪退）。取第一个有效手指，取不到则忽略本次。
          const finger: FingerInfo | undefined =
            (e.fingerList && e.fingerList.length > 0) ? e.fingerList[0] : undefined;
          if (!finger) {
            return;
          }
          const px: number = finger.localX;
          const py: number = finger.localY;
          // 点击落在设置面板 / FAB / 工具条 / 取色面板 / 分析面板内 → 交给对应浮层自身处理，
          // 画布不响应（不关闭、不触发选中）。
          if (this.isInsideOverlays(px, py)) {
            return;
          }
          // 点击画布「其他区域」→ 自动收起设置面板（带一镜到底收起动画）与单位输入 popup。
          if (this.showSettings || this.showXUnitPopup || this.showYUnitPopup) {
            this.closeSettings();
            this.closeUnitPopups();
          }
          const now: number = Date.now();
          if (this.doubleTapReset && now - this.lastTapTs < 300) {
            // 双击 → 重置视口（不重选）
            this.lastTapTs = 0;
            this.resetView();
            return;
          }
          this.lastTapTs = now;
          this.handleTap(px, py);
        })
    )
    .gesture(
      GestureGroup(
        GestureMode.Parallel,
        PanGesture({ fingers: 1, distance: 5 })
          .onActionStart((): void => {
            // 单指平移开始：若正在运镜重置动画，立即取消，由手指实时接管视口
            this.cancelVpAnim();
            this.isGesturing = true; // 降质渲染：粗采样 + 跳细分
            // 快照当前视口；视图开始移动 → 收起快捷工具条与取色面板（不长驻）
            this.panStartVp = this.cloneVp(this.viewport);
            this.showQuickBar = false;
            this.showColorPicker = false;
          })
          .onActionUpdate((e: GestureEvent): void => {
            if (this.pinchActive || this.pinchJustEnded) {
              return; // 双指缩放中、或刚结束的残留帧：忽略单指平移，避免释放跳变
            }
            const w: number = this.canvasW;
            const h: number = this.canvasH;
            if (w <= 0 || h <= 0) {
              return;
            }
            const dx: number = e.offsetX;
            const dy: number = e.offsetY;
            const vp: Viewport = this.panStartVp;
            const rangeX: number = vp.xMax - vp.xMin;
            const rangeY: number = vp.yMax - vp.yMin;
            // 内容跟随手指：右拖 → 视口左移（xMin/xMax 同减）；下拖 → 视口上移（yMin/yMax 同增）
            const newVp: Viewport = {
              xMin: vp.xMin - (dx / w) * rangeX,
              xMax: vp.xMax - (dx / w) * rangeX,
              yMin: vp.yMin + (dy / h) * rangeY,
              yMax: vp.yMax + (dy / h) * rangeY
            };
            if (this.isVpValid(newVp)) {
              this.viewport = newVp;
            }
          })
          .onActionEnd((): void => {
            // 单指平移彻底结束：清除“刚结束双指”窗口，恢复后续平移识别
            this.pinchJustEnded = false;
            this.isGesturing = false;
            // 手势期跳过的网格操作统一补偿：检查缓存覆盖 + 按需调度重建
            this.ensureCacheCoverage();
            this.draw(); // 全质量重绘
            this.onViewChanged();
          }),
        PinchGesture({ fingers: 2, distance: 1 })
          .onActionStart((e: GestureEvent): void => {
            // 双指缩放开始：取消可能仍在进行的运镜重置动画
            this.cancelVpAnim();
            this.pinchActive = true;
            this.pinchJustEnded = false;
            this.isGesturing = true; // 降质渲染
            this.pinchStartVp = this.cloneVp(this.viewport);
            // 视图开始缩放 → 收起快捷工具条与取色面板（不长驻）
            this.showQuickBar = false;
            this.showColorPicker = false;
            // 记录起始捏合中点，后续把其中点位移当作单指拖拽来平移视图
            this.pinchStartCX = e.pinchCenterX;
            this.pinchStartCY = e.pinchCenterY;
          })
          .onActionUpdate((e: PinchGestureEvent): void => {
            const w: number = this.canvasW;
            const h: number = this.canvasH;
            if (w <= 0 || h <= 0) {
              return;
            }
            const s: number = e.scale; // >= 1 放大（捏合张开）
            if (!(s > 0)) {
              return;
            }
            const base: Viewport = this.pinchStartVp;
            // 1) 双指中点位移等效为单指拖拽：中点相对起始中点的屏幕位移驱动视口平移
            //    （方向与单指一致：中点右移 → 视口左移，使内容跟随手指）
            const dx: number = e.pinchCenterX - this.pinchStartCX;
            const dy: number = e.pinchCenterY - this.pinchStartCY;
            const rangeX0: number = base.xMax - base.xMin;
            const rangeY0: number = base.yMax - base.yMin;
            const panned: Viewport = {
              xMin: base.xMin - (dx / w) * rangeX0,
              xMax: base.xMax - (dx / w) * rangeX0,
              yMin: base.yMin + (dy / h) * rangeY0,
              yMax: base.yMax + (dy / h) * rangeY0
            };
            // 2) 在平移后的视口上，以【当前捏合中点】为锚点等比缩放（纯拖拽时 s=1 → 等同单指平移）
            const wx: number = GraphMath.screenToWorldX(e.pinchCenterX, panned, w);
            const wy: number = GraphMath.screenToWorldY(e.pinchCenterY, panned, h);
            const newVp: Viewport = {
              xMin: wx - (wx - panned.xMin) / s,
              xMax: wx + (panned.xMax - wx) / s,
              yMin: wy - (wy - panned.yMin) / s,
              yMax: wy + (panned.yMax - wy) / s
            };
            if (this.isVpValid(newVp)) {
              this.viewport = newVp;
            }
          })
          .onActionEnd(() => {
            this.pinchActive = false;
            this.pinchJustEnded = true; // 进入短暂屏蔽窗，吞掉松手残留的单指平移
            this.isGesturing = false;
            this.panStartVp = this.cloneVp(this.viewport);
            // 手势期跳过的网格操作统一补偿：检查缓存覆盖 + 按需调度重建
            this.ensureCacheCoverage();
            this.draw(); // 全质量重绘
            this.onViewChanged();
          })
          .onActionCancel(() => {
            this.pinchActive = false;
            this.pinchJustEnded = true;
            this.isGesturing = false;
            this.panStartVp = this.cloneVp(this.viewport);
            this.ensureCacheCoverage();
            this.draw(); // 全质量重绘
          })
      )
    )
  }

  /** 重置视图原点下移偏置（vp）：状态栏遮挡可视区上缘，感知可视中心略低于几何中心，
   *  取典型状态栏高度的一半下移原点，修正原点视觉偏高 */
  private readonly ORIGIN_Y_BIAS_VP: number = 20;

  /**
   * 画布可视中心 Y（Canvas 坐标系，vp）。
   * 手机：瀹夸富缁勪欢 下发 visibleCenterY = (容器高 - Sheet 高)/2（屏幕坐标系，自屏幕顶部起算），
   * 换算到 Canvas 坐标系需加上画布顶部溢出偏移 (canvasH - rootH)/2
   * （Canvas 110% 高度、上下对称溢出屏幕外：屏幕中心即 canvasH/2，反推顶部溢出 = (h-rootH)/2），
   * 再加 ORIGIN_Y_BIAS_VP 下移偏置（状态栏遮挡上缘，不加偏置时原点视觉偏高）。
   * - Sheet 关闭（全屏）：visibleCenterY = 容器高/2 → 换算后 ≈ canvasH/2，原点居屏幕中心；
   * - Sheet NORMAL/MID：visibleCenterY = (容器高 - Sheet 高)/2，原点居未遮挡区域中心。
   * 平板/未下发（<=0）：回退 canvasH/2（画布已排除表达式区，屏幕中心即可见中心）。
   */
  private visibleCanvasCenterY(): number {
    const h: number = this.canvasH;
    if (this.visibleCenterY > 0) {
      const topOverflow: number = this.rootH > 0 ? Math.max(0, (h - this.rootH) / 2) : 0;
      // 下移偏置后钳制在画布范围内，避免小窗口下越界
      return Math.min(this.visibleCenterY + topOverflow + this.ORIGIN_Y_BIAS_VP, h);
    }
    return h / 2;
  }

  /**
   * 画布可视高度（未被 Sheet 遮挡部分，vp）。
   * 手机：可见区 = [屏幕顶, 容器高 - Sheet 高]，高度 = 2 * visibleCenterY；
   * 平板/未下发：回退 min(rootH, canvasH)。
   */
  private visibleCanvasHeight(): number {
    const h: number = this.canvasH;
    if (this.visibleCenterY > 0) {
      return Math.min(2 * this.visibleCenterY, h);
    }
    return this.rootH > 0 ? Math.min(this.rootH, h) : h;
  }

  /**
   * 画布可视中心 X（Canvas 坐标系，vp）。镜像 visibleCanvasCenterY 的手机算法：
   * 平板：瀹夸富缁勪欢 下发 visibleCenterX = (容器宽 - 面板可见宽)/2（面板右侧悬浮，
   * 左侧为未遮挡区）；画布宽 = 容器宽（无水平溢出），无需额外换算。
   * - 沉浸隐藏态：visibleCenterX = 容器宽/2，原点居屏幕水平中心；
   * - 显示态：visibleCenterX = (容器宽 - 面板宽)/2，原点居未遮挡区域水平中心。
   * 手机/未下发（<=0）：回退 canvasW/2。
   */
  private visibleCanvasCenterX(): number {
    const w: number = this.canvasW;
    if (this.visibleCenterX > 0) {
      return Math.min(this.visibleCenterX, w);
    }
    return w / 2;
  }

  /**
   * 画布可视宽度（未被右侧面板遮挡部分，vp）。镜像 visibleCanvasHeight：
   * 平板：可见区 = [0, 容器宽 - 面板可见宽]，宽度 = 2 * visibleCenterX；
   * 手机/未下发：回退 canvasW。
   */
  private visibleCanvasWidth(): number {
    const w: number = this.canvasW;
    if (this.visibleCenterX > 0) {
      return Math.min(2 * this.visibleCenterX, w);
    }
    return w;
  }

  /**
   * 计算默认视口下以原点为中心的最大正方形截取区域（像素坐标）。
   * 边长 = min(可视高度, 可视宽度)，水平/垂直均居中于可视区域中心
   * （与 aspectDefaultVp 的原点位置一致，保证原点恒居截图正中心）。
   * 用于分享/快照等截图场景，直接从 aspectDefaultVp 截取 1:1 正方形。
   */
  private computeCenteredSquareRegion(): CaptureRegion | null {
    const ctx: CanvasRenderingContext2D | null = this.ctx;
    const w: number = this.canvasW;
    const h: number = this.canvasH;
    if (!ctx || w <= 0 || h <= 0) {
      return null;
    }
    const cx: number = this.visibleCanvasCenterX();
    const cy: number = this.visibleCanvasCenterY();
    const side: number = Math.min(this.visibleCanvasHeight(), this.visibleCanvasWidth());
    const scale: number = ctx.width / w;
    const vpX: number = cx - side / 2;
    const vpY: number = cy - side / 2;
    const px: number = Math.max(0, Math.round(vpX * scale));
    const py: number = Math.max(0, Math.round(vpY * scale));
    const pSize: number = Math.min(
      Math.round(side * scale),
      ctx.width - px,
      ctx.height - py
    );
    if (pSize <= 0) {
      return null;
    }
    return { x: px, y: py, size: pSize };
  }
  
  /**
   * 将函数图像与底部品牌水印栏合成为一张完整图片。
   * 布局：上方为原始函数图像，下方为灰白色横栏（左侧 logo + 品牌名，右侧表达式）。
   * 品牌信息由 brandName / brandLogoResId 属性控制（默认均不显示）。
   * @param showExpr 是否显示右侧表达式和颜色圆点（false 时仅显示品牌信息）
   */
  private async composeWatermarkImage(
    graphPixelMap: image.PixelMap,
    exprLabel: string,
    fnColor: string,
    showExpr: boolean = true
  ): Promise<image.PixelMap> {
    const hostCtx: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;
    return GraphImageExporter.composeWatermark(
      graphPixelMap, exprLabel, fnColor, this.isDark, showExpr,
      hostCtx.resourceManager, this.brandLogoResId, this.brandName,
      (e: string): Promise<image.PixelMap | null> => this.renderExprToPixelMap(e)
    );
  }

  /**
   * 使用 exprrender 引擎将表达式渲染为数学排版 PixelMap。
   * 使用专用离屏 Canvas（exprExportContext），不干扰主画布内容。
   * 渲染管线与 ExprView 完全一致（parseLinear → simplify → ExprRenderer.render → measureAndRelayout → box.draw），
   * 确保水印中的表达式与屏幕上 ExprView 的排版质量一致（而非原始字符串直出）。
   * 字号自适应：先以参考字号渲染测量，若超出离屏画布则按比例缩小字号重渲染，
   * 避免分数/上下标嵌套等高表达式被截断。
   * @returns 表达式 PixelMap（透明背景），解析失败或画布未就绪时返回 null。
   */
  private async renderExprToPixelMap(expr: string): Promise<image.PixelMap | null> {
    const ctx: CanvasRenderingContext2D = this.exprExportContext;
    // 画布未就绪（onReady 未触发）或尺寸未知时，ctx 未绑定/边界不可用，直接返回 null
    const maxW: number = this.exprExportW;
    const maxH: number = this.exprExportH;
    if (!this.exprExportReady || expr.trim().length === 0 || maxW <= 0 || maxH <= 0) {
      return null;
    }
    try {
      const row = parseLinear(expr);
      const simplified = simplify(row);
      // 使用与 ExprView.resolveFg() 一致的配色
      const fg: string = this.isDark ? '#E6E6E6' : '#1A1A1A';
      // 先以参考字号渲染并测量
      let fontSize: number = 112;
      let box: Box = ExprRenderer.render(simplified, fontSize, fg);
      measureAndRelayout(box, ctx);
      let exprW: number = Math.ceil(box.width) + 4;
      let exprH: number = Math.ceil(box.height + box.depth) + 4;
      // 超出画布 → 按比例缩小字号重渲染（乘 0.95 安全系数抵消度量非线性）
      if (exprW > maxW || exprH > maxH) {
        const scale: number = Math.min(maxW / exprW, maxH / exprH) * 0.95;
        fontSize = Math.max(8, Math.floor(fontSize * scale));
        box = ExprRenderer.render(simplified, fontSize, fg);
        measureAndRelayout(box, ctx);
        exprW = Math.ceil(box.width) + 4;
        exprH = Math.ceil(box.height + box.depth) + 4;
      }
      if (exprW <= 0 || exprH <= 0 || exprW > maxW || exprH > maxH) {
        return null;
      }
      // 在离屏 Canvas 上绘制表达式（不影响主画布）
      ctx.clearRect(0, 0, exprW, exprH);
      box.draw(ctx, 2, Math.ceil(box.height) + 2);
      const pixelMap: image.PixelMap = await ctx.getPixelMap(0, 0, exprW, exprH);
      return pixelMap;
    } catch (_e) {
      return null;
    }
  }

  /**
   * 分享当前选中函数的图象（仅选中函数，不含其他函数）。
   * 流程：暂存函数可见性 → 只绘制选中函数 + 网格/坐标轴 → 截图 → 恢复所有函数 →
   * 合成底部品牌水印栏 → 打包 JPEG → 交给注入的 GraphShareAdapter。
   * 未注入分享适配器时 UI 已隐藏分享入口，此处直接返回。
   */
  private async shareSelectedGraphImage(showExpr: boolean = true): Promise<void> {
    const ctx: CanvasRenderingContext2D | null = this.ctx;
    if (!ctx || this.activeFn() == null) {
      return;
    }
    const fn: GraphFunction | null = this.activeFn();
    if (fn == null) {
      return;
    }
    const w: number = this.canvasW;
    const h: number = this.canvasH;
    if (w <= 0 || h <= 0) {
      return;
    }

    // 1. 先运镜平滑重置到默认视口（原点居中，全部曲线可见状态下运镜，观感自然）
    await this.resetViewAnimated();

    // 2. 暂存所有函数的可见性，只保留选中函数可见，在此状态下完成截图
    const savedEnabled: boolean[] = [];
    for (let i = 0; i < this.functions.length; i++) {
      savedEnabled.push(this.functions[i].enabled);
      this.functions[i].enabled = this.functions[i].id === this.activeId;
    }
    this.draw();

    // 3. 截取 1:1 正方形区域（原点居中）
    const region: CaptureRegion | null = this.computeCenteredSquareRegion();
    if (region === null) {
      for (let i = 0; i < this.functions.length; i++) {
        this.functions[i].enabled = savedEnabled[i];
      }
      this.draw();
      return;
    }
    const rawPixelMap: image.PixelMap = await ctx.getPixelMap(region.x, region.y, region.size, region.size);

    // 4. 合成底部品牌水印栏
    const pixelMap: image.PixelMap =
      await this.composeWatermarkImage(rawPixelMap, fn.expr, fn.color, showExpr);

    // 5. 恢复所有函数的可见性并重绘（视口保持在默认状态）
    for (let i = 0; i < this.functions.length; i++) {
      this.functions[i].enabled = savedEnabled[i];
    }
    this.draw();

    // 6. 打包 JPEG → 交给分享适配器（宿主实现系统分享面板等具体行为）
    const shared: boolean = await this.exportService.shareImage(pixelMap);
    if (!shared) {
      this.getUIContext().getPromptAction().showToast({ message: '分享失败' });
    }
  }

  /**
   * 分享当前画布全部函数图象（设置菜单分享按钮）。
   * 流程：绘制当前状态（所有可见函数）→ 截图 → 合成品牌水印栏（仅 logo + 品牌名）→
   * 打包 JPEG → 交给注入的 GraphShareAdapter。
   */
  private async shareFullGraphImage(): Promise<void> {
    const ctx: CanvasRenderingContext2D | null = this.ctx;
    if (!ctx) {
      return;
    }
    // 前置检查：至少存在一个「可见且有表达式内容」的函数才允许分享，
    // 否则画布上只有空坐标系，分享无意义——提示用户并中断。
    const hasGraphContent: boolean = this.functions.some((f: GraphFunction): boolean =>
      f.enabled && f.expr.trim().length > 0);
    if (!hasGraphContent) {
      this.getUIContext().getPromptAction().showToast({ message: '当前没有图像' });
      return;
    }
    // 先运镜平滑重置到默认视口（原点居中），再在此状态下完成截图
    await this.resetViewAnimated();
    this.draw();

    // 截取 1:1 正方形区域（原点居中）
    const region: CaptureRegion | null = this.computeCenteredSquareRegion();
    if (region === null) {
      this.getUIContext().getPromptAction().showToast({ message: '截图失败' });
      return;
    }
    const rawPixelMap: image.PixelMap = await ctx.getPixelMap(region.x, region.y, region.size, region.size);

    // 合成底部品牌水印栏（仅品牌信息，不显示表达式）
    const pixelMap: image.PixelMap =
      await this.composeWatermarkImage(rawPixelMap, '', '', false);

    // 视口保持在默认状态，无需恢复

    // 打包 JPEG → 交给分享适配器
    const shared: boolean = await this.exportService.shareImage(pixelMap);
    if (!shared) {
      this.getUIContext().getPromptAction().showToast({ message: '分享失败' });
    }
  }

  /**
   * 截取固定视口 1:1 正方形快照（全部或指定函数）。
   * 截取区域始终对应固定数学坐标范围（默认视口），原点 (0,0) 居中，
   * 与 captureThumbnail 采用相同的固定视口逻辑，保证截图内容一致。
   * @param fnId 可选。指定后仅渲染该目标函数（临时隐藏其他函数并重绘）；
   *             不指定则渲染全部函数。
   * @returns 固定视口 1:1 正方形 PixelMap；失败返回 null
   */
  private async captureViewPixelMap(fnId?: number): Promise<image.PixelMap | null> {
    const ctx: CanvasRenderingContext2D | null = this.ctx;
    if (!ctx) {
      return null;
    }
    // 先运镜平滑重置到默认视口（原点居中，全部曲线可见状态下运镜）
    await this.resetViewAnimated();

    // 指定目标函数时：暂存可见性，只保留目标函数可见，在此状态下完成截图
    const filterSingle: boolean = fnId !== undefined;
    const savedEnabled: boolean[] = [];
    if (filterSingle) {
      for (let i = 0; i < this.functions.length; i++) {
        savedEnabled.push(this.functions[i].enabled);
        this.functions[i].enabled = this.functions[i].id === fnId;
      }
    }
    this.draw();

    // 截取 1:1 正方形区域（原点居中）
    let result: image.PixelMap | null = null;
    const region: CaptureRegion | null = this.computeCenteredSquareRegion();
    if (region !== null) {
      try {
        result = await ctx.getPixelMap(region.x, region.y, region.size, region.size);
      } catch (e) {
        console.error(`[GraphCanvas] captureViewPixelMap getPixelMap failed: ${JSON.stringify(e)}`);
      }
    }

    // 无论截图成败，恢复所有函数可见性并重绘（视口保持在默认状态）
    if (filterSingle) {
      for (let i = 0; i < this.functions.length; i++) {
        this.functions[i].enabled = savedEnabled[i];
      }
    }
    this.draw();
    return result;
  }

  /**
   * 截取指定函数的图像缩略图（仅该函数曲线 + 坐标系，无水印）。
   * 流程：暂存可见性 → 只绘目标函数 → 截图 → 恢复 → 缩小 → 打包 JPEG →
   * 交给注入的 GraphStorageAdapter 持久化（默认 Noop 实现仅返回空串）。
   * 宿主可经 GraphCanvasController.capture 间接调用。
   * @param fnId 目标函数 id
   * @param silent 静默模式（自动刷新用）：不播放运镜动画，直接落位默认视口截图，
   *               完成后恢复用户当前视口，尽量不打断用户浏览状态
   * @returns 适配器返回的存储标识；失败返回空字符串
   */
  private async captureThumbnail(fnId: number, silent: boolean = false): Promise<string> {
    const ctx: CanvasRenderingContext2D | null = this.ctx;
    const target: GraphFunction | undefined =
      this.functions.find((f: GraphFunction): boolean => f.id === fnId);
    if (!ctx || target === undefined) {
      return '';
    }
    const w: number = this.canvasW;
    const h: number = this.canvasH;
    if (w <= 0 || h <= 0) {
      return '';
    }
    // 静默刷新遇手势进行中：直接跳过（避免与手势争抢视口/重绘），
    // 手势结束时 onViewChanged 会重新触发刷新检查，不丢更新
    if (silent && this.isGesturing) {
      return '';
    }

    // 1. 调整到默认视口（固定数学坐标范围，保证缩略图内容一致）：
    //    手动保存 → 运镜平滑重置；静默刷新 → 快照当前视口后直接落位，截完恢复
    const savedVp: Viewport = this.cloneVp(this.viewport);
    if (silent) {
      this.cancelVpAnim();
      this.viewport = this.aspectDefaultVp();
    } else {
      await this.resetViewAnimated();
    }

    // 2. 暂存所有函数的可见性，只保留目标函数可见，在此状态下完成截图
    const savedEnabled: boolean[] = [];
    for (let i = 0; i < this.functions.length; i++) {
      savedEnabled.push(this.functions[i].enabled);
      this.functions[i].enabled = this.functions[i].id === fnId;
    }
    this.draw();

    // 3. 截取 1:1 正方形区域（原点居中）；getPixelMap 可能异常，
    //    捕获后仍继续恢复可见性，并返回空串让调用方回退（表达式仍会保存，历史页显示占位图标）
    const region: CaptureRegion | null = this.computeCenteredSquareRegion();
    let pixelMap: image.PixelMap | null = null;
    if (region !== null) {
      try {
        pixelMap = await ctx.getPixelMap(region.x, region.y, region.size, region.size);
      } catch (e) {
        console.error(`[GraphCanvas] captureThumbnail getPixelMap failed: ${JSON.stringify(e)}`);
      }
    }

    // 4. 恢复所有函数的可见性并重绘（无论截图成败，避免画布残留单函数显示）；
    //    手动保存保持默认视口；静默刷新恢复用户截图前的视口，不打断浏览
    for (let i = 0; i < this.functions.length; i++) {
      this.functions[i].enabled = savedEnabled[i];
    }
    if (silent && this.isVpValid(savedVp)) {
      this.viewport = savedVp;
    }
    this.draw();

    if (pixelMap === null || region === null) {
      return '';
    }
    const captured: image.PixelMap = pixelMap;

    try {
      // 5. 缩小（≤ 480px）→ 打包 JPEG → 交给持久化适配器（宿主决定落盘位置）
      return await this.exportService.saveThumbnail(captured);
    } catch (e) {
      return '';
    }
  }

  // ── #16 x 轴单位「你可能想要」二级建议 popup（延迟 0.5s 弹出，很小）──
  @Builder
  private xSuggestPopupBuilder(): void {
    Column({ space: 6 }) {
      Text($r('app.string.graph_settings_unit_hint'))
        .fontSize($r('app.float.font_caption'))
        .fontColor($r('sys.color.font_secondary'))
      Row({ space: 6 }) {
        Text('π')
          .fontSize($r('app.float.font_body_sm'))
          .fontColor(Math.abs(this.xUnitLength - Math.PI) < 1e-6 ? Color.White : $r('sys.color.font_primary'))
          .padding({ left: $r('app.float.page_padding_h'), right: $r('app.float.page_padding_h'), top: 6, bottom: 6 })
          .borderRadius($r('app.float.radius_md'))
          .backgroundColor(Math.abs(this.xUnitLength - Math.PI) < 1e-6 ? $r('sys.color.brand') : $r('sys.color.comp_background_secondary'))
          .onClick((): void => {
            this.xUnitInput = 'π';
            this.applyXUnit();
          })
        Text('π/2')
          .fontSize($r('app.float.font_body_sm'))
          .fontColor(Math.abs(this.xUnitLength - Math.PI / 2) < 1e-6 ? Color.White : $r('sys.color.font_primary'))
          .padding({ left: $r('app.float.page_padding_h'), right: $r('app.float.page_padding_h'), top: 6, bottom: 6 })
          .borderRadius($r('app.float.radius_md'))
          .backgroundColor(Math.abs(this.xUnitLength - Math.PI / 2) < 1e-6 ? $r('sys.color.brand') : $r('sys.color.comp_background_secondary'))
          .onClick((): void => {
            this.xUnitInput = 'π/2';
            this.applyXUnit();
          })
      }
    }
    .padding(8)
  }

  // ── #16 y 轴单位「你可能想要」二级建议 popup ──
  @Builder
  private ySuggestPopupBuilder(): void {
    Column({ space: 6 }) {
      Text($r('app.string.graph_settings_unit_hint'))
        .fontSize($r('app.float.font_caption'))
        .fontColor($r('sys.color.font_secondary'))
      Row({ space: 6 }) {
        Text('π')
          .fontSize($r('app.float.font_body_sm'))
          .fontColor(Math.abs(this.yUnitLength - Math.PI) < 1e-6 ? Color.White : $r('sys.color.font_primary'))
          .padding({ left: $r('app.float.page_padding_h'), right: $r('app.float.page_padding_h'), top: 6, bottom: 6 })
          .borderRadius($r('app.float.radius_xs'))
          .backgroundColor(Math.abs(this.yUnitLength - Math.PI) < 1e-6 ? $r('sys.color.brand') : $r('sys.color.comp_background_secondary'))
          .onClick((): void => {
            this.yUnitInput = 'π';
            this.applyYUnit();
          })
        Text('π/2')
          .fontSize($r('app.float.font_body_sm'))
          .fontColor(Math.abs(this.yUnitLength - Math.PI / 2) < 1e-6 ? Color.White : $r('sys.color.font_primary'))
          .padding({ left: $r('app.float.page_padding_h'), right: $r('app.float.page_padding_h'), top: 6, bottom: 6 })
          .borderRadius($r('app.float.radius_xs'))
          .backgroundColor(Math.abs(this.yUnitLength - Math.PI / 2) < 1e-6 ? $r('sys.color.brand') : $r('sys.color.comp_background_secondary'))
          .onClick((): void => {
            this.yUnitInput = 'π/2';
            this.applyYUnit();
          })
      }
    }
    .padding(8)
  }

  // ── #16 x 轴单位长度输入 popup（一级：自定义输入框 + 确定；二级建议附在输入框上）──
  @Builder
  private xUnitPopupBuilder(): void {
    Column({ space: 10 }) {
      Text($r('app.string.graph_settings_x_unit'))
        .fontSize($r('app.float.font_caption'))
        .fontColor($r('sys.color.font_secondary'))
      TextInput({ text: this.xUnitInput, placeholder: $r('app.string.graph_settings_unit_ph') })
        .width('100%')
        .backgroundColor($r('sys.color.comp_background_secondary'))
        .borderRadius($r('app.float.radius_xs'))
        .onChange((v: string): void => {
          this.xUnitInput = v;
        })
        .onSubmit((): void => {
          this.applyXUnit();
        })
        .bindPopup(this.showXSuggest, {
          builder: (): void => this.xSuggestPopupBuilder(),
          placement: Placement.Left,
          enableArrow: true,
          popupColor: $r('sys.color.comp_background_primary'),
          onWillDismiss: (): void => {
            this.showXSuggest = false;
          }
        })
      Button($r('app.string.graph_settings_unit_ok'))
        .width('100%')
        .onClick(() => {
          this.applyXUnit();
        })
    }
    .padding(12)
    .width(200)
  }

  // ── #16 y 轴单位长度输入 popup ──
  @Builder
  private yUnitPopupBuilder(): void {
    Column({ space: 10 }) {
      Text($r('app.string.graph_settings_y_unit'))
        .fontSize($r('app.float.font_caption'))
        .fontColor($r('sys.color.font_secondary'))
      TextInput({ text: this.yUnitInput, placeholder: $r('app.string.graph_settings_unit_ph') })
        .width('100%')
        .backgroundColor($r('sys.color.comp_background_secondary'))
        .borderRadius($r('app.float.radius_xs'))
        .onChange((v: string): void => {
          this.yUnitInput = v;
        })
        .onSubmit((): void => {
          this.applyYUnit();
        })
        .bindPopup(this.showYSuggest, {
          builder: (): void => this.ySuggestPopupBuilder(),
          placement: Placement.Left,
          enableArrow: true,
          popupColor: $r('sys.color.comp_background_primary'),
          onWillDismiss: (): void => {
            this.showYSuggest = false;
          }
        })
      Button($r('app.string.graph_settings_unit_ok'))
        .width('100%')
        .onClick(() => {
          this.applyYUnit();
        })
    }
    .padding(12)
    .width(200)
  }
  /** 视口变化 → 检查缓存覆盖/精度（带冷却）→ 去抖重绘 */
  private onVpChange(): void {
    // 手势期间跳过网格操作（extendCache/重构建）：50% 缓冲区保证手势期视口不越界，
    // 手势结束时统一补偿一次，避免手势中触发昂贵网格扩展导致掉帧。
    if (!this.isGesturing) {
      const now: number = Date.now();
      if (now > this.coverageCheckCooldown) {
        this.coverageCheckCooldown = now + 200; // 每 200ms 最多检查一次
        this.ensureCacheCoverage();
      }
    }
    if (this.ctx && !this.vpDrawScheduled) {
      this.vpDrawScheduled = true;
      setTimeout((): void => {
        this.vpDrawScheduled = false;
        this.draw();
      }, 0);
    }
  }

  /** 函数列表 / 角度模式 / 选中变化 → 同步重建 evaluator + 异步构建缓存 */
  private onDataChange(): void {
    // 数据变化 → 清除所有缓存
    this.evaluatorCache.clear();
    this.sampleCaches.clear();
    // ── 函数实例绑定浮层的生命周期同步：删除函数 → 同步销毁其工具条/分析面板 ──
    this.syncOverlayLifecycles();
    // 兆底：activeId 本身失效（无对应函数）→ 收起全部浮层
    if (!this.functions.some((f: GraphFunction): boolean => f.id === this.activeId)) {
      this.showQuickBar = false;
      this.showColorPicker = false;
    }
    // 先同步构建 evaluator（解析表达式，速度快）
    for (let i: number = 0; i < this.functions.length; i++) {
      const fn: GraphFunction = this.functions[i];
      if (!fn.enabled) {
        continue;
      }
      try {
        const ev: FunctionEvaluator = new FunctionEvaluator(fn.expr, this.isDegMode);
        if (ev.isValid) {
          this.evaluatorCache.set(fn.id, ev);
        }
      } catch (e) {
        // 解析失败不缓存
      }
    }
    // 异步构建 sample cache（避免 UI 冻结）
    this.scheduleCacheBuild();
    // 同步渲染调度器（自动判别模式、创建/销毁渲染器）
    this.renderDispatcher.syncFunctions(this.functions, this.isDegMode);
    // 防抖 + 分块异步构建调度器管理的二维网格缓存（隐函数/不等式/二元方程）。
    // 不在按键热路径上同步构建，避免数十万次求值阻塞主线程导致 appfreeze。
    this.scheduleGridCacheBuild();
    // 清理已删除函数的标记缓存 + 异步预构建开启标记的函数（防抖，避免 expr 按键阻塞）
    this.pruneMarkerCache();
    this.scheduleMarkerCacheBuild();
    // 分析坞卡片同步：检测 showAnalysis 变化 + 清理已删除函数的卡片
    this.syncAnalysisCards();
    // 立即渲染第一帧（无 sample cache 时 drawCurves 会回退到 evaluator）
    if (this.ctx && !this.drawScheduled) {
      this.drawScheduled = true;
      setTimeout((): void => {
        this.drawScheduled = false;
        this.draw();
      }, 0);
    }
  }

  /**
   * 异步调度缓存构建，避免 UI 冻结。
   * 每个函数依次构建，每构建一个函数后释放控制权给 UI。
   */
  private scheduleCacheBuild(): void {
    if (this.cacheBuildPending) {
      return;
    }
    this.cacheBuildPending = true;
    const fnIds: number[] = [];
    for (let i: number = 0; i < this.functions.length; i++) {
      const fn: GraphFunction = this.functions[i];
      if (!fn.enabled) {
        continue;
      }
      const ev: FunctionEvaluator | undefined = this.evaluatorCache.get(fn.id);
      if (ev != undefined && !this.sampleCaches.has(fn.id)) {
        fnIds.push(fn.id);
      }
    }
    if (fnIds.length === 0) {
      this.cacheBuildPending = false;
      return;
    }
    let idx: number = 0;
    const buildNext = (): void => {
      if (idx >= fnIds.length) {
        this.cacheBuildPending = false;
        // 全部构建完成 → 重绘
        if (this.ctx) {
          this.draw();
        }
        return;
      }
      const fid: number = fnIds[idx];
      idx++;
      const fn: GraphFunction | undefined = this.functions.find((f: GraphFunction): boolean => f.id === fid);
      const ev: FunctionEvaluator | undefined = this.evaluatorCache.get(fid);
      if (fn != undefined && ev != undefined) {
        this.buildSampleCache(fn.id, fn.expr, ev);
      }
      // 每构建一个函数，让出控制权
      setTimeout(buildNext, 0);
    };
    setTimeout(buildNext, 0);
  }

  /**
   * 防抖调度二维网格缓存（隐函数/不等式/二元方程）的分块异步构建。
   *
   * 性能背景：二维网格全量构建需数十万次 F(x,y) 求值，若在按键热路径
   * （onDataChange）上同步执行会阻塞主线程数秒（appfreeze）。本方法：
   * 1. 防抖：高频按键合并为一次构建（拖延到输入间隙）；
   * 2. 分块：网格逐行分片填充，每块之间让出主线程，全程不阻塞 UI；
   * 3. 代次作废：数据再次变更时作废旧的构建任务，避免过时网格生效。
   */
  private scheduleGridCacheBuild(): void {
    // 作废任何进行中的分块构建（其针对的渲染器可能已被 syncFunctions 重建）
    this.gridBuildGen++;
    if (this.gridBuildPending) {
      // 已有定时器在途：不重复调度。定时器触发时会读取最新代次号与最新渲染器状态，
      // 本次按键的表达式变更会被那次构建覆盖（防抖合并）。
      return;
    }
    this.gridBuildPending = true;
    // 防抖拖延：合并连续按键，只在输入间隙构建一次
    setTimeout((): void => {
      this.gridBuildPending = false;
      // 在触发时（而非调度时）捕获当前代次号：
      // 防抖窗口内的多次按键会使 gridBuildGen 递增，若用调度时捕获的旧值会误判为过期而丢弃构建。
      // 触发时 syncFunctions 已同步完成，渲染器为最新状态，以当前代次号启动构建。
      this.runGridBuild(this.gridBuildGen);
    }, 120);
  }

  /**
   * 执行分块网格构建：逐函数、逐行分片填充，每块之间让出主线程。
   * @param gen 本次构建的代次号（与 gridBuildGen 不一致时作废）
   */
  private runGridBuild(gen: number): void {
    const vp: Viewport = this.viewport;
    const pwDx: number = (vp.xMax - vp.xMin) / Math.max(1, this.canvasW);
    const targets: number[] = this.renderDispatcher.getRebuildTargets(vp);
    if (targets.length === 0) {
      return;
    }
    // 每块填充的节点行数：手势中 16 行/块（让帧优先，保证交互流畅），
    // 空闲时 64 行/块（加速构建完成）。构建期间渲染不中断（pendingGrid 原子替换）。
    const CHUNK_ROWS: number = this.isGesturing ? 16 : 64;
    let t: number = 0;
    const stepNext = (): void => {
      if (gen !== this.gridBuildGen) {
        return; // 数据已变更，作废本次构建
      }
      if (t >= targets.length) {
        // 全部构建完成 → 重绘
        if (this.ctx) {
          this.draw();
        }
        return;
      }
      const fnId: number = targets[t];
      t++;
      const chunked: boolean = this.renderDispatcher.beginBuildFor(fnId, vp, pwDx);
      if (!chunked) {
        // 非网格渲染器已同步构建完成 → 下一个
        setTimeout(stepNext, 0);
        return;
      }
      // 网格渲染器：逐块泵入填充，每块让出主线程
      const pumpChunk = (): void => {
        if (gen !== this.gridBuildGen) {
          return; // 数据已变更，作废本次构建
        }
        const done: boolean = this.renderDispatcher.buildChunkFor(fnId, CHUNK_ROWS);
        if (done) {
          setTimeout(stepNext, 0);
        } else {
          setTimeout(pumpChunk, 0);
        }
      };
      setTimeout(pumpChunk, 0);
    };
    setTimeout(stepNext, 0);
  }

  /**
   * 构建单函数的世界坐标预缓存。
   * 采样范围 = 缓冲窗口 2W（[center-W, center+W]），基准间距 = 视口宽度 / 2000。
   * 视图平移时由 ensureCacheCoverage 动态滑动窗口 + 淘汰旧样本。
   */
  private buildSampleCache(fnId: number, expr: string, ev: FunctionEvaluator): void {
    const vp: Viewport = this.viewport;
    const range: number = vp.xMax - vp.xMin;
    const cx: number = (vp.xMin + vp.xMax) / 2;
    // 缓冲窗口 = 2W（左右各 0.5W 余量，总宽 = 视口宽度 × 2）
    const cacheHalf: number = range;
    const xMin: number = cx - cacheHalf;
    const xMax: number = cx + cacheHalf;
    const baseDx: number = range / 2000;
    const exprHash: string = expr + (this.isDegMode ? '|deg' : '|rad');
    const cache: FunctionSampleCache = SampleEngine.buildCache(ev, fnId, exprHash, xMin, xMax, baseDx);
    this.sampleCaches.set(fnId, cache);
  }

  /**
   * 确保缓存覆盖当前视口（缓冲窗口模式）：
   * - 视口触碰缓冲边界 → 重算窗口 + 淘汰旧样本 + 补采样缺口
   * - 缩放精度不足 → 可见区细化
   *
   * 缓冲窗口 = 2W（[center-W, center+W]），触发余量 = 15% W。
   * 单次触发后缓冲边缘距视口约 1W，需再平移 ~35% 才会再次触发，不会高频重算。
   */
  private ensureCacheCoverage(): void {
    const vp: Viewport = this.viewport;
    const w: number = this.canvasW;
    if (w <= 0) {
      return;
    }
    const W: number = vp.xMax - vp.xMin;
    const BUFFER_GUARD: number = W * 0.15;
    const pixelWorldDx: number = W / w;
    const keys: number[] = Array.from(this.sampleCaches.keys());
    for (let i: number = 0; i < keys.length; i++) {
      const fnId: number = keys[i];
      const cache: FunctionSampleCache | undefined = this.sampleCaches.get(fnId);
      if (cache == undefined) {
        continue;
      }
      const ev: FunctionEvaluator | undefined = this.evaluatorCache.get(fnId);
      if (ev == undefined) {
        continue;
      }

      // ── 缓冲窗口触发检测 ──
      const bufferLeft: number = cache.xMin;
      const bufferRight: number = cache.xMax;
      const triggered: boolean =
        vp.xMin <= bufferLeft + BUFFER_GUARD || vp.xMax >= bufferRight - BUFFER_GUARD;

      if (triggered) {
        // 新缓冲窗口：以当前视口为中心，宽度 2W
        const center: number = (vp.xMin + vp.xMax) / 2;
        const newLeft: number = center - W;
        const newRight: number = center + W;

        // 缺口计算（在 shrink 之前记录旧边界）
        const oldLeft: number = cache.xMin;
        const oldRight: number = cache.xMax;
        const dx: number = cache.baseDx;

        // 淘汰：裁切到新窗口范围
        cache.shrinkTo(newLeft, newRight);

        // 补采样左缺口 [newLeft, oldLeft)
        if (newLeft < oldLeft) {
          const gapEnd: number = Math.min(oldLeft, newRight);
          if (gapEnd > newLeft) {
            const leftSamples: WorldSample[] = SampleEngine.sampleRange(ev, newLeft, gapEnd - dx * 0.5, dx);
            if (leftSamples.length > 0) {
              cache.samples = leftSamples.concat(cache.samples);
            }
          }
        }
        // 补采样右缺口 (oldRight, newRight]
        if (newRight > oldRight) {
          const gapStart: number = Math.max(oldRight, newLeft);
          if (newRight > gapStart) {
            const rightSamples: WorldSample[] = SampleEngine.sampleRange(ev, gapStart + dx * 0.5, newRight, dx);
            if (rightSamples.length > 0) {
              cache.samples = cache.samples.concat(rightSamples);
            }
          }
        }
      }

      // ── 缩放精度检查（手势期间跳过细化，保证帧率） ──
      if (!this.isGesturing && cache.needsRefine(pixelWorldDx)) {
        if (!cache.refineValid(vp.xMin, vp.xMax, pixelWorldDx)) {
          const rXMin: number = vp.xMin - W * 0.2;
          const rXMax: number = vp.xMax + W * 0.2;
          SampleEngine.refineCache(cache, ev, rXMin, rXMax, pixelWorldDx);
        }
      }
    }
    // 二维网格缓存覆盖检查（隐函数/不等式/二元方程）。
    // 扩展失败（网格节点超上限/网格未建）时返回 true → 触发围绕当前视口的
    // 分块重建（重定心），保证视口平移/缩放后动态渲染新区域，不出现「视口外空白」。
    const needsGridRebuild: boolean = this.renderDispatcher.onViewportChange(vp, pixelWorldDx);
    if (needsGridRebuild) {
      this.scheduleGridCacheBuild();
    }
  }

  /** 暗色模式切换 → 重绘（网格 / 坐标轴 / 标签配色随主题变化） */
  private onThemeChange(): void {
    if (this.ctx) {
      this.draw();
    }
  }

  /**
   * 可视中心变更响应（visibleCenterX/Y @Watch）：
   * - 首次有效下发（启动/进入 GRAPH 模式）：直接落位到重置坐标位置，
   *   避免「先初始位置再重置」的可见跳变；
   * - 后续变更（手机 Sheet 档位切换 / 平板面板展开隐藏）：面板模式确实变化，
   *   运镜平滑重置到新可视中心（复用 resetView 的 easeInOutCubic 动画，
   *   与截图前置运镜的 resetViewAnimated 共用同一动画通道，互斥不冲突）。
   * 注：@Prop 仅在值真正变化时同步触发 @Watch，吸附回同一档位不会误触重置。
   */
  private onVisibleCenterChange(): void {
    if (!this.vpInitialized || this.canvasW <= 0 || this.canvasH <= 0) {
      // 画布未就绪：首帧初始化时 aspectDefaultVp 会消费最新下发值
      return;
    }
    if (!this.visibleCenterApplied) {
      // 启动首次下发：直接落位，无动画无跳变
      this.visibleCenterApplied = true;
      this.cancelVpAnim();
      this.viewport = this.aspectDefaultVp();
      return;
    }
    // 面板模式变化：运镜重置到新坐标中心
    this.resetView();
  }

  /** 重置视口为按画布宽高比校正的默认视图（运镜式缓动过渡） */
  private resetView(): void {
    const target: Viewport = this.aspectDefaultVp();
    if (!this.isVpValid(target)) {
      this.viewport = target;
      return;
    }
    // 若当前已接近默认视图，直接落位，避免无意义动画
    const cur: Viewport = this.viewport;
    const drift: number = Math.abs(cur.xMin - target.xMin) + Math.abs(cur.xMax - target.xMax) +
      Math.abs(cur.yMin - target.yMin) + Math.abs(cur.yMax - target.yMax);
    if (drift < 1e-6) {
      this.viewport = target;
      return;
    }
    this.animateViewportTo(target, 380);
  }

  /**
   * 将视口从当前值缓动插值过渡到 target，duration 毫秒内完成。
   * 采用 easeInOutCubic 缓动，模拟相机平滑推拉的效果；每帧更新 @State viewport
   * 借由 @Watch 自动重绘，动画结束精确落位到 target。
   * @param onFinish 可选。动画精确落位后回调（被新动画/手势取消时也会触发，保证不悬挂）
   */
  private animateViewportTo(target: Viewport, duration: number, onFinish?: () => void): void {
    // 取消上一段可能仍在跑的动画，避免多段叠加
    this.cancelVpAnim();
    this.vpAnimFinish = onFinish ?? null;
    const start: Viewport = this.cloneVp(this.viewport);
    const startTime: number = Date.now();
    this.vpAnimId = setInterval((): void => {
      const t: number = Math.min(1, (Date.now() - startTime) / duration);
      // easeInOutCubic：起止慢、中间快，观感如镜头缓动
      const e: number = t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
      this.viewport = {
        xMin: start.xMin + (target.xMin - start.xMin) * e,
        xMax: start.xMax + (target.xMax - start.xMax) * e,
        yMin: start.yMin + (target.yMin - start.yMin) * e,
        yMax: start.yMax + (target.yMax - start.yMax) * e
      };
      if (t >= 1) {
        clearInterval(this.vpAnimId);
        this.vpAnimId = -1;
        this.viewport = target; // 精确落位，消除浮点残留
        const cb: (() => void) | null = this.vpAnimFinish;
        this.vpAnimFinish = null;
        if (cb !== null) {
          cb();
        }
      }
    }, 16) as number;
  }

  /** 取消正在进行的视口缓动动画（用户手势接管时调用）；同时触发未决的完成回调避免悬挂 */
  private cancelVpAnim(): void {
    if (this.vpAnimId !== -1) {
      clearInterval(this.vpAnimId);
      this.vpAnimId = -1;
    }
    const cb: (() => void) | null = this.vpAnimFinish;
    this.vpAnimFinish = null;
    if (cb !== null) {
      cb();
    }
  }

  /**
   * 平滑重置视口到默认视图并等待运镜完成（历史快照/分享等截图前调用）。
   * 已处于默认视图时立即落位返回；否则复用 animateViewportTo 的 easeInOutCubic 运镜。
   */
  private resetViewAnimated(duration: number = 380): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      const target: Viewport = this.aspectDefaultVp();
      if (!this.isVpValid(target)) {
        this.viewport = target;
        resolve();
        return;
      }
      const cur: Viewport = this.viewport;
      const drift: number = Math.abs(cur.xMin - target.xMin) + Math.abs(cur.xMax - target.xMax) +
        Math.abs(cur.yMin - target.yMin) + Math.abs(cur.yMax - target.yMax);
      if (drift < 1e-6) {
        this.viewport = target;
        resolve();
        return;
      }
      this.animateViewportTo(target, duration, resolve);
    });
  }

  /**
   * 按画布当前宽高比生成默认视口（x 半跨度 10，world-per-pixel 相等，圆不被压扁）。
   * 视图中心：X 优先用 瀹夸富缁勪欢 下发的可视中心（平板回退画布水平中心）；
   * Y 取未被 Sheet 遮挡的可视区域中心（见 visibleCanvasCenterY，含屏幕→Canvas 坐标换算），
   * 与截图的 computeCenteredSquareRegion 中心一致，保证重置视图/截图时原点居可视区中心。
   * 推导：设可视中心为 (cx, cy)（画布像素），world-per-pixel wpp = 20/canvasW，
   * 令原点 (0,0) 投影到 (cx, cy)：xMin=-cx*wpp, xMax=(canvasW-cx)*wpp, yMax=cy*wpp, yMin=(cy-canvasH)*wpp。
   */
  private aspectDefaultVp(): Viewport {
    const w: number = this.canvasW;
    const h: number = this.canvasH;
    if (w <= 0 || h <= 0) {
      return GraphMath.defaultViewport();
    }
    // 可视中心 X：平板用 瀹夸富缁勪欢 下发值（未遮挡区中心），<=0 回退画布水平中心
    const cx: number = this.visibleCanvasCenterX();
    // 可视中心 Y：未被 Sheet 遮挡的可视区域中心（Canvas 坐标系，含顶部溢出换算）
    const cy: number = this.visibleCanvasCenterY();
    const wpp: number = 20 / w; // world-per-pixel（保持 x 半跨度 10 的缩放级别）
    return {
      xMin: -cx * wpp,
      xMax: (w - cx) * wpp,
      yMin: (cy - h) * wpp,
      yMax: cy * wpp
    };
  }

  /**
   * 尺寸变化时按新宽高比重拟合视口：保持中心不变，
   * 将较短半轴扩展到与较长半轴同比例，保证 world-per-pixel 相等且不裁切可见内容。
   */
  private refitToAspect(w: number, h: number): void {
    const vp: Viewport = this.viewport;
    const cx: number = (vp.xMin + vp.xMax) / 2;
    const cy: number = (vp.yMin + vp.yMax) / 2;
    const xHalf: number = (vp.xMax - vp.xMin) / 2;
    const yHalf: number = (vp.yMax - vp.yMin) / 2;
    const targetRatio: number = w / h; // 期望 x/y 跨度比
    const curRatio: number = xHalf / yHalf;
    if (curRatio < targetRatio) {
      const newXHalf: number = yHalf * targetRatio;
      this.viewport = {
        xMin: cx - newXHalf,
        xMax: cx + newXHalf,
        yMin: cy - yHalf,
        yMax: cy + yHalf
      };
    } else {
      const newYHalf: number = xHalf / targetRatio;
      this.viewport = {
        xMin: cx - xHalf,
        xMax: cx + xHalf,
        yMin: cy - newYHalf,
        yMax: cy + newYHalf
      };
    }
  }

  /** 视口合法性（有限且半跨度在上下限内） */
  private isVpValid(vp: Viewport): boolean {
    const rx: number = vp.xMax - vp.xMin;
    const ry: number = vp.yMax - vp.yMin;
    if (!isFinite(rx) || !isFinite(ry)) {
      return false;
    }
    if (rx <= this.MIN_HALF * 2 || rx >= this.MAX_HALF * 2) {
      return false;
    }
    if (ry <= this.MIN_HALF * 2 || ry >= this.MAX_HALF * 2) {
      return false;
    }
    return true;
  }

  /** 复制视口（避免手势过程中共享引用导致累积漂移） */
  private cloneVp(vp: Viewport): Viewport {
    return {
      xMin: vp.xMin,
      xMax: vp.xMax,
      yMin: vp.yMin,
      yMax: vp.yMax
    };
  }

  /** 当前选中的函数对象（无则 null） */
  private activeFn(): GraphFunction | null {
    for (let i = 0; i < this.functions.length; i++) {
      if (this.functions[i].id === this.activeId) {
        return this.functions[i];
      }
    }
    return null;
  }

  /** 选中函数的颜色（供工具条图标使用） */
  private activeColor(): string {
    const f: GraphFunction | null = this.activeFn();
    return f != null ? f.color : '#000000';
  }

  /** 选中函数的线型（供工具条图标使用） */
  private activeLineStyle(): GraphLineStyle {
    const f: GraphFunction | null = this.activeFn();
    return f != null ? f.lineStyle : 'solid';
  }

  /** 选中函数的可见性（供工具条图标使用） */
  private activeEnabled(): boolean {
    const f: GraphFunction | null = this.activeFn();
    return f != null ? f.enabled : true;
  }

  /** 选中函数的渲染模式（未注册/空表达式视为 EXPLICIT），供工具条项动态控制 */
  private activeRenderMode(): RenderMode {
    const mode: RenderMode | null = this.renderDispatcher.getMode(this.activeId);
    return mode === null ? RenderMode.EXPLICIT : mode;
  }

  /**
   * 命中检测（委托 GraphGestureMath）：返回距点击点最近且在阈值内的函数 id（无命中返回 -1）。
   * 注意：px/py 必须为 Canvas 坐标空间（非 Stack 空间），调用方需做坐标转换。
   */
  private hitTest(px: number, py: number): number {
    const env: HitTestEnv = {
      functions: this.functions,
      viewport: this.viewport,
      canvasW: this.canvasW,
      canvasH: this.canvasH,
      renderDispatcher: this.renderDispatcher,
      evaluatorCache: this.evaluatorCache
    };
    return GraphGestureMath.hitTest(env, px, py);
  }

  /** 单指轻点处理：命中检测 → 选中曲线并弹出快捷工具条；点空白收起。
   *  由 PanGesture.onActionEnd（位移很小判定为轻点）调用，避免与 PanGesture 竞争。
   *  坐标 px/py 为根 Stack 局部坐标（Stack 100% 高度），
   *  而 Canvas 为 110% 高度（顶对齐溢出），hitTest 内部使用 canvasH 做坐标转换，
   *  因此需要将 Y 坐标从 Stack 空间转换到 Canvas 空间后再做命中检测。 */
  private handleTap(px: number, py: number): void {
    // 点在任一浮层覆盖区域内 → 交给浮层自身 onClick 处理，画布忽略
    // （isInsideOverlays 使用 rootW/rootH 定位，与 px/py 同属 Stack 空间，无需转换）
    if (this.isInsideOverlays(px, py)) {
      return;
    }
    // 坐标转换：Stack 空间 → Canvas 空间（hitTest 使用 canvasH 做 worldToScreenY）
    // Canvas 高度 = rootH * 1.1，顶对齐 → Y 方向需按比例缩放
    const canvasPy: number = this.rootH > 0 ? py * this.canvasH / this.rootH : py;
    const id: number = this.hitTest(px, canvasPy);
    if (id >= 0) {
      const w: number = this.canvasW;
      // 工具条定位：quickBar 是 Stack 子元素，用 Stack 空间坐标（py 即 Stack 空间）
      this.quickX = Math.min(Math.max(px - this.BAR_W / 2, 4), Math.max(4, w - this.BAR_W - 4));
      this.quickY = Math.min(Math.max(py - this.BAR_H - 12, 4), Math.max(4, this.rootH - this.BAR_H - 4));
      this.showQuickBar = true;
      // 记录工具条绑定的函数实例（该实例被删除时工具条随之销毁）
      this.quickBarFnId = id;
      this.onSelect(id);
    } else {
      // 点空白：收起工具条（保留高亮）
      this.showQuickBar = false;
      this.showColorPicker = false;
    }
  }

  /** 判断点击是否落在任一浮层覆盖区域内（避免画布 tap 与浮层 onClick 冲突） */
  private isInsideOverlays(px: number, py: number): boolean {
    if (this.showQuickBar) {
      if (px >= this.quickX && px <= this.quickX + this.BAR_W &&
        py >= this.quickY && py <= this.quickY + this.BAR_H) {
        return true;
      }
    }
    if (this.showColorPicker && this.showQuickBar) {
      const px0: number = this.quickX;
      const py0: number = this.quickY + this.BAR_H + this.BAR_GAP;
      if (px >= px0 && px <= px0 + this.PICKER_W && py >= py0 && py <= py0 + this.PICKER_H) {
        return true;
      }
    }
    // 设置 FAB（右上角；菜单已改 bindPopup 悬浮层，画布命中区仅需覆盖 FAB 本体）
    const fx: number = this.rootW - this.SET_BTN - this.SET_PAD_X;
    const fy: number = this.SET_PAD_Y;
    if (px >= fx && px <= fx + this.SET_BTN && py >= fy && py <= fy + this.SET_BTN) {
      return true;
    }
    return false;
  }

  /** 关闭所有单位输入 popup（点击画布其他区域 / 收起设置面板时调用） */
  private closeUnitPopups(): void {
    this.showXUnitPopup = false;
    this.showYUnitPopup = false;
    this.showXSuggest = false;
    this.showYSuggest = false;
  }

  /** 同步分析坞卡片：检测 showAnalysis 变化 → 添加/移除卡片；清理已删除函数的卡片 */
  private syncAnalysisCards(): void {
    // 清理已删除函数的卡片
    const curIds: Set<number> = new Set();
    for (let i: number = 0; i < this.functions.length; i++) {
      curIds.add(this.functions[i].id);
    }
    const filtered: AnalysisCardData[] = this.analysisCards.filter(
      (c: AnalysisCardData): boolean => curIds.has(c.fnId)
    );
    // 检测 showAnalysis 开关变化
    for (let i: number = 0; i < this.functions.length; i++) {
      const fn: GraphFunction = this.functions[i];
      const wantsCard: boolean = fn.showAnalysis ?? false;
      const hasCard: boolean = filtered.some((c: AnalysisCardData): boolean => c.fnId === fn.id);
      if (wantsCard && !hasCard) {
        // 新增卡片
        const result: GlobalAnalysisResult | null = GlobalAnalyzer.analyzeGlobal(fn.expr, this.isDegMode);
        filtered.push({
          fnId: fn.id,
          expr: fn.expr,
          name: graphDisplayName(fn),
          color: fn.color,
          result: result
        });
      } else if (!wantsCard && hasCard) {
        // 移除卡片
        const idx: number = filtered.findIndex((c: AnalysisCardData): boolean => c.fnId === fn.id);
        if (idx >= 0) {
          filtered.splice(idx, 1);
        }
      }
    }
    // 更新已有卡片的表达式/名称/结果（表达式可能已变化）
    for (let i: number = 0; i < filtered.length; i++) {
      const card: AnalysisCardData = filtered[i];
      const fn: GraphFunction | undefined = this.functions.find((f: GraphFunction): boolean => f.id === card.fnId);
      if (fn != undefined) {
        card.expr = fn.expr;
        card.name = graphDisplayName(fn);
        card.color = fn.color;
        // 表达式变化时重算
        card.result = GlobalAnalyzer.analyzeGlobal(fn.expr, this.isDegMode);
      }
    }
    this.analysisCards = filtered;
  }

  /** 切换分析卡片显隐（由行菜单“图象分析”开关触发） */
  private toggleAnalysisCard(fnId: number): void {
    const idx: number = this.analysisCards.findIndex((c: AnalysisCardData): boolean => c.fnId === fnId);
    if (idx >= 0) {
      const updated: AnalysisCardData[] = [...this.analysisCards];
      updated.splice(idx, 1);
      this.analysisCards = updated;
    }
  }

  /** 工具栏分析按钮回调：通过回调链写回 GraphViewModel.toggleAnalysis */
  private onToggleAnalysis(fnId: number): void {
    this.onAnalysisToggle(fnId);
  }

  /**
   * 函数实例绑定浮层的生命周期同步（onDataChange 开头调用）：
   * 用 id 集合差分检测本次变更中被删除的函数实例，并销毁与其绑定的快捷工具条
   * ——即使 activeId 已被上游抢先切换到其他有效函数（removeFunction
   * 删除选中项后会立即改选首项），也能准确关闭悬空浮层；
   * 未关闭的浮层其绑定跟随当前选中同步，供下一次删除检测使用。
   */
  private syncOverlayLifecycles(): void {
    const curIds: Set<number> = new Set();
    for (let i: number = 0; i < this.functions.length; i++) {
      curIds.add(this.functions[i].id);
    }
    // 被删除的函数 = 上次快照中存在、本次不存在的 id
    const removed: number[] = [];
    this.prevFnIds.forEach((id: number): void => {
      if (!curIds.has(id)) {
        removed.push(id);
      }
    });
    // 快捷工具条绑定的函数实例被删除 → 销毁工具条（连同其下方取色面板）
    if (this.showQuickBar && removed.indexOf(this.quickBarFnId) >= 0) {
      this.showQuickBar = false;
      this.showColorPicker = false;
    }
    // 选中已漂移到工具条绑定之外的函数（点击 DisplayArea 其他表达式槽、点击设置按钮等
    // 任何改变选中的 UI 交互）→ 工具条直接关闭，不再跟随转移到新目标——
    // 避免工具条显示在空表达式或错误目标上（画布内点击其他曲线由 handleTap 重定位，不受影响）
    if (this.showQuickBar && this.activeId !== this.quickBarFnId) {
      this.showQuickBar = false;
      this.showColorPicker = false;
    }
    this.prevFnIds = curIds;
  }

  /** 读取某函数的标记分析结果（缓存未命中或已失效时返回 null，由异步构建填充） */
  private getMarkerAnalysis(fn: GraphFunction): GlobalAnalysisResult | null {
    const cached: MarkerCacheEntry | undefined = this.markerCache.get(fn.id);
    if (cached != undefined && cached.expr === fn.expr && cached.isDeg === this.isDegMode) {
      return cached.result;
    }
    return null;
  }

  /** 清理已删除函数的标记缓存 */
  private pruneMarkerCache(): void {
    const stale: number[] = [];
    this.markerCache.forEach((entry: MarkerCacheEntry, id: number): void => {
      if (!this.functions.some((f: GraphFunction): boolean => f.id === id)) {
        stale.push(id);
      }
    });
    for (let i = 0; i < stale.length; i++) {
      this.markerCache.delete(stale[i]);
    }
  }

  /**
   * 调度标记缓存异步构建（防抖合并连续按键）：为所有启用标记的函数预计算全局分析，
   * 触发时读取最新 functions/角度模式，构建完成后 draw() 一次使标记生效。
   */
  private scheduleMarkerCacheBuild(): void {
    if (this.markerBuildPending) {
      return; // 已有定时器在途：不重复调度（触发时读最新状态，防抖合并）
    }
    this.markerBuildPending = true;
    setTimeout((): void => {
      this.markerBuildPending = false;
      let anyComputed: boolean = false;
      for (let i = 0; i < this.functions.length; i++) {
        const fn: GraphFunction = this.functions[i];
        if (!this.fnHasMarkers(fn)) {
          continue;
        }
        const cached: MarkerCacheEntry | undefined = this.markerCache.get(fn.id);
        if (cached != undefined && cached.expr === fn.expr && cached.isDeg === this.isDegMode) {
          continue; // 缓存仍有效
        }
        const result: GlobalAnalysisResult | null = GlobalAnalyzer.analyzeGlobal(fn.expr, this.isDegMode);
        this.markerCache.set(fn.id, { expr: fn.expr, isDeg: this.isDegMode, result: result });
        anyComputed = true;
      }
      if (anyComputed) {
        this.draw();
      }
    }, 100);
  }

  /** 检查函数是否启用了任何新分类标记 */
  private fnHasMarkers(fn: GraphFunction): boolean {
    return fn.showZeros === true || fn.showExtrema === true ||
      fn.showInflections === true || fn.showAsymptotes === true;
  }

  /** 主绘制入口 */
  private draw(): void {
    const ctx: CanvasRenderingContext2D | null = this.ctx;
    if (!ctx) {
      return;
    }
    const w: number = this.canvasW;
    const h: number = this.canvasH;
    if (w <= 0 || h <= 0) {
      return;
    }
    const vp: Viewport = this.viewport;

    // 填充不透明背景（替代 clearRect）：截图为 JPEG 时避免透明底变黑
    ctx.fillStyle = GridAxisPainter.bgColor(this.isDark);
    ctx.fillRect(0, 0, w, h);

    const config: GridAxisConfig = {
      isDark: this.isDark, showGrid: this.showGrid, showAxes: this.showAxes,
      showLabels: this.showLabels, xUnitLength: this.xUnitLength, yUnitLength: this.yUnitLength
    };
    if (this.showGrid) {
      GridAxisPainter.drawGrid(ctx, vp, w, h, config);
    }
    if (this.showAxes) {
      GridAxisPainter.drawAxes(ctx, vp, w, h, config);
    }
    const env: CurvePaintEnv = {
      functions: this.functions,
      activeId: this.activeId,
      isGesturing: this.isGesturing,
      isDark: this.isDark,
      renderDispatcher: this.renderDispatcher,
      evaluatorCache: this.evaluatorCache,
      sampleCaches: this.sampleCaches,
      getMarkerAnalysis: (fn: GraphFunction): GlobalAnalysisResult | null => this.getMarkerAnalysis(fn)
    };
    this.curvePainter.drawCurves(ctx, vp, w, h, env);
    this.curvePainter.drawAnalysis(ctx, vp, w, h, env);
    if (this.showLabels) {
      GridAxisPainter.drawLabels(ctx, vp, w, h, config);
    }
    GridAxisPainter.drawOrigin(ctx, vp, w, h, config);
  }



  /** 应用 X 轴单位长度输入（空/非正 → 自动），关闭两级 popup 并重绘 */
  private applyXUnit(): void {
    this.xUnitLength = GridAxisPainter.parseUnit(this.xUnitInput);
    this.showXUnitPopup = false;
    this.showXSuggest = false;
    this.draw();
  }

  /** 应用 Y 轴单位长度输入（空/非正 → 自动），关闭两级 popup 并重绘 */
  private applyYUnit(): void {
    this.yUnitLength = GridAxisPainter.parseUnit(this.yUnitInput);
    this.showYUnitPopup = false;
    this.showYSuggest = false;
    this.draw();
  }

  /** x 轴单位长度显示标签（自动 / π / π/2 / 数字） */
  private xUnitLabel() {
    if (this.xUnitLength <= 0) {
      return $r('app.string.graph_settings_unit_auto');
    }
    return GridAxisPainter.fmtUnit(this.xUnitLength);
  }

  /** y 轴单位长度显示标签（自动 / π / π/2 / 数字） */
  private yUnitLabel() {
    if (this.yUnitLength <= 0) {
      return $r('app.string.graph_settings_unit_auto');
    }
    return GridAxisPainter.fmtUnit(this.yUnitLength);
  }


  // ───────────────────────────────────────────────────────────
  // #13 浮层 UI（@Builder）
  // ───────────────────────────────────────────────────────────

  /** 浮动快捷工具条：颜色 / 线条样式 / 函数分析 / 可见性 / 删除（图标）
   *  与取色面板包裹在同一容器内：面板位于工具条下方、间隔一个 space，宽度同工具条；展开带动画。
   *  右侧独立放置分享按钮组，样式与主工具栏一致。 */
  @Builder
  private quickBarBuilder(): void {
    if (this.showQuickBar && this.activeFn() != null) {
      Column({ space: $r('app.float.spacing_sm') }) {
        // 工具条区域：主工具栏组 + 分享组
        Row({ space: 8 }) {
          // 主工具栏组
          Row({ space: 4 }) {
            // 颜色（当前色圆点）
            Column() {
              Circle()
                .width('80%')
                .height('80%')
                .fill(this.activeColor())
                .stroke(Color.White)
                .strokeWidth(1.5)
            }
            .width(this.bar_atom_size)
            .height(this.bar_atom_size)
            .justifyContent(FlexAlign.Center)
            .borderRadius($r('app.float.radius_xl'))
            .onClick(() => {
              this.showColorPicker = true;
            })

            // 线条样式（实线 / 虚线）——不等式隐藏（填充区域无线条属性）
            if (this.activeRenderMode() !== RenderMode.INEQUALITY) {
              Column() {
                SymbolGlyph(this.activeLineStyle() === 'solid'
                  ? $r('sys.symbol.circle')
                  : $r('sys.symbol.circle_dashed'))
                  .fontSize($r('app.float.font_title'))
                  .fontColor([$r('sys.color.font_primary')])
              }
              .width(this.bar_atom_size)
              .height(this.bar_atom_size)
              .justifyContent(FlexAlign.Center)
              .borderRadius($r('app.float.radius_xl'))
              .onClick(() => {
                this.onLineStyleChange(this.activeId, nextLineStyle(this.activeLineStyle()));
              })
            }

            // TODO: 当前版本暂不上线函数分析功能，待技术成熟后开放
            // 函数分析（分析坞卡片开关；开启时 icon 高亮 brand 色）
            // Column() {
            //   SymbolGlyph($r('sys.symbol.ranking'))
            //     .fontSize($r('app.float.font_title'))
            //     .fontColor((this.activeFn()?.showAnalysis ?? false)
            //       ? [$r('sys.color.brand')]
            //       : [$r('sys.color.font_primary')])
            // }
            // .width(this.bar_atom_size)
            // .height(this.bar_atom_size)
            // .justifyContent(FlexAlign.Center)
            // .borderRadius($r('app.float.radius_xl'))
            // .onClick(() => {
            //   const fn: GraphFunction | null = this.activeFn();
            //   if (fn != null) {
            //     this.onToggleAnalysis(fn.id);
            //   }
            // })

            // 可见性（eye / eye_slash）
            Column() {
              SymbolGlyph(this.activeEnabled() ? $r('sys.symbol.eye') : $r('sys.symbol.eye_slash'))
                .fontSize($r('app.float.font_title'))
                .fontColor([$r('sys.color.font_primary')])
                .opacity(this.activeEnabled() ? 1 : 0.6)
            }
            .width(this.bar_atom_size)
            .height(this.bar_atom_size)
            .justifyContent(FlexAlign.Center)
            .borderRadius($r('app.float.radius_xl'))
            .onClick(() => {
              this.onToggle(this.activeId);
            })

            // 删除
            Column() {
              SymbolGlyph($r('sys.symbol.trash_fill'))
                .fontSize($r('app.float.font_title'))
                .fontColor([$r('sys.color.warning')])
            }
            .width(this.bar_atom_size)
            .height(this.bar_atom_size)
            .justifyContent(FlexAlign.Center)
            .borderRadius($r('app.float.radius_xl'))
            .onClick(() => {
              this.onRemove(this.activeId);
              this.showQuickBar = false;
              this.showColorPicker = false;
            })
          }
          .padding(6)
          .backgroundColor($r('sys.color.comp_background_primary'))
          .borderRadius('50%')
          .shadow({
            radius: 8,
            color: 'rgba(0,0,0,0.15)',
            offsetX: 0,
            offsetY: 2
          })

          // 分享组（仅在宿主注入分享适配器时显示）
          if (this.exportService.shareEnabled) {
            Row({ space: 4 }) {
              Column() {
                SymbolGlyph($r('sys.symbol.share'))
                  .fontSize($r('app.float.font_title'))
                  .fontColor([$r('sys.color.font_primary')])
                  .fontWeight(FontWeight.Medium)
              }
              .width(this.bar_atom_size)
              .height(this.bar_atom_size)
              .justifyContent(FlexAlign.Center)
              .borderRadius($r('app.float.radius_xl'))
              .onClick(() => {
                this.shareSelectedGraphImage();
              })
            }
            .padding(6)
            .backgroundColor($r('sys.color.comp_background_primary'))
            .borderRadius('50%')
            .shadow({
              radius: 8,
              color: 'rgba(0,0,0,0.15)',
              offsetX: 0,
              offsetY: 2
            })
          }
        }

        // 取色面板（点击颜色按钮时展开，位于工具条下方、同宽）
        if (this.showColorPicker) {
          this.colorPickerInner();
        }
      }
      .alignItems(HorizontalAlign.Center)
      .position({ x: this.quickX, y: this.quickY })
      .zIndex(20)
      .transition(TransitionEffect.asymmetric(
        TransitionEffect.scale({ x: 0.6, y: 0.6 }).combine(TransitionEffect.OPACITY)
          .animation({ duration: 200, curve: Curve.EaseOut }),
        TransitionEffect.scale({ x: 0.6, y: 0.6 }).combine(TransitionEffect.OPACITY)
          .animation({ duration: 150, curve: Curve.EaseIn })
      ))
    }
  }

  /** 取色面板（预设色网格），宽度与工具条相同，展开时带从顶部展开动画 */
  @Builder
  private colorPickerInner(): void {
    Column() {
      Grid() {
        ForEach(
          GRAPH_COLOR_PICKER,
          (c: string, idx: number): void => {
            GridItem() {
              Circle()
                .width(30)
                .height(30)
                .fill(c)
                .stroke('#DDDDDD')
                .strokeWidth(1)
                .onClick(() => {
                  this.onColorChange(this.activeId, c);
                  this.showColorPicker = false;
                })
            }
          },
          (c: string, idx: number): string => 'c' + idx.toString()
        )
      }
      .columnsTemplate('1fr 1fr 1fr 1fr')
      .rowsTemplate('1fr 1fr 1fr')
      .width('100%')
      .height(150)
    }
    .width(this.PICKER_W)
    .padding(12)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius($r('app.float.radius_md'))
    .shadow({
      radius: 8,
      color: 'rgba(0,0,0,0.15)',
      offsetX: 0,
      offsetY: 2
    })
    .transition(
      TransitionEffect.scale({
        x: 1,
        y: 0,
        centerX: '50%',
        centerY: '0%'
      })
        .combine(TransitionEffect.OPACITY)
        .animation({ duration: UiMotion.NORMAL, curve: Curve.EaseOut })
    )
  }


  /** 分析坞构建器：底部横向滚动卡片，替代旧浮动分析面板 */
  @Builder
  private analysisDockBuilder(): void {
    Stack() {
      AnalysisDock({
        cards: this.analysisCards,
        activeCardId: this.activeId,
        onCardSelect: (fnId: number): void => {
          this.onSelect(fnId);
        },
        onCardClose: (fnId: number): void => {
          this.toggleAnalysisCard(fnId);
          // 同步回写 showAnalysis
          const fns: GraphFunction[] = this.functions;
          for (let i: number = 0; i < fns.length; i++) {
            if (fns[i].id === fnId) {
              this.onMarkerCategoryChange(fnId, 'zeros', false);
              this.onMarkerCategoryChange(fnId, 'extrema', false);
              this.onMarkerCategoryChange(fnId, 'inflections', false);
              this.onMarkerCategoryChange(fnId, 'asymptotes', false);
              break;
            }
          }
        }
      })
    }
    .width('100%')
    .height(146)
    .alignContent(Alignment.Bottom)
    .zIndex(10)
  }


  // ── #14 设置 FAB（右上角，圆形沉浸按钮）──
  // ── 设置：齿轮 FAB + bindPopup 悬浮菜单 ──
  // 菜单经 bindPopup 渲染在窗口 overlay 层：天然位于表达式显示区 Sheet 之上，
  // 且无需提升不透明画布层级（zIndex 仅作用于同级兄弟，画布内子节点无法盖过
  // 瀹夸富缁勪欢 层的 Sheet；而整体提升画布会让不透明画布遮没 Sheet）。
  @Builder
  private settingsSharedBuilder(): void {
    Stack({ alignContent: Alignment.Center }) {
      // 齿轮图标（FAB 锚点，菜单展开时作为 popup 锚定目标）
      SymbolGlyph($r('sys.symbol.gearshape_fill'))
        .fontSize($r('app.float.font_display_sm'))
        .fontColor([$r('sys.color.font_primary')])
    }
    .width(this.SET_BTN)
    .height(this.SET_BTN)
    .borderRadius(this.SET_R_CLOSED)
    .clip(true)
    .backgroundColor(Color.Transparent)
    .backgroundBlurStyle(BlurStyle.BACKGROUND_THIN)
    .shadow({
      radius: 8,
      color: 'rgba(0,0,0,0.15)',
      offsetX: 0,
      offsetY: 2
    })
    .alignSelf(ItemAlign.End)
    .margin({ right: this.SET_PAD_X, top: this.SET_PAD_Y })
    .zIndex(30)
    .onClick(() => {
      if (!this.showSettings) {
        this.openSettings();
      }
    })
    // 菜单悬浮层：位于窗口顶层不被任何 UI 遮挡；Sheet 保持正常渲染可见；
    // 外点蒙层自动收起（onWillDismiss），风格与行内菜单/单位 popup 一致
    .bindPopup(this.showSettings, {
      builder: (): void => this.settingsPanelBuilder(),
      placement: Placement.BottomRight,
      maskColor: 0x33000000,
      popupColor: $r('sys.color.comp_background_primary'),
      backgroundBlurStyle: BlurStyle.BACKGROUND_THICK,
      enableArrow: true,
      onWillDismiss: (): void => {
        this.closeSettings();
      }
    })
  }

  /** 设置菜单内容（bindPopup 悬浮层内渲染，尺寸固定 300×380） */
  @Builder
  private settingsPanelBuilder(): void {
      // 菜单内容（尺寸固定）
      Column({ space: $r('app.float.spacing_sm') }) {
        Row() {
          Text($r('app.string.graph_settings_title'))
            .fontSize($r('app.float.font_body'))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.font_primary'))
          Blank()
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize($r('app.float.font_title_sm'))
            .fontColor([$r('sys.color.font_tertiary')])
            .onClick(() => {
              this.closeSettings();
            })
        }
        .width('100%')

        Divider().color($r('sys.color.comp_divider'))

        // 显示网格
        Row() {
          Text($r('app.string.graph_settings_grid'))
            .fontSize($r('app.float.font_body_sm'))
            .fontColor($r('sys.color.font_primary'))
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.showGrid })
            .onChange((isOn: boolean): void => {
              this.showGrid = isOn;
              this.draw();
            })
        }
        .width('100%')

        // 显示坐标轴
        Row() {
          Text($r('app.string.graph_settings_axes'))
            .fontSize($r('app.float.font_body_sm'))
            .fontColor($r('sys.color.font_primary'))
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.showAxes })
            .onChange((isOn: boolean): void => {
              this.showAxes = isOn;
              this.draw();
            })
        }
        .width('100%')

        // 显示刻度
        Row() {
          Text($r('app.string.graph_settings_labels'))
            .fontSize($r('app.float.font_body_sm'))
            .fontColor($r('sys.color.font_primary'))
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.showLabels })
            .onChange((isOn: boolean): void => {
              this.showLabels = isOn;
              this.draw();
            })
        }
        .width('100%')

        // 双击画布回到初始视图
        Row() {
          Text($r('app.string.graph_settings_double_tap_reset'))
            .fontSize($r('app.float.font_body_sm'))
            .fontColor($r('sys.color.font_primary'))
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.doubleTapReset })
            .onChange((isOn: boolean): void => {
              this.doubleTapReset = isOn;
            })
        }
        .width('100%')

        // x 轴单位长度
        Row() {
          Text($r('app.string.graph_settings_x_unit'))
            .fontSize($r('app.float.font_body_sm'))
            .fontColor($r('sys.color.font_primary'))
          Blank()
          Text(this.xUnitLabel())
            .fontSize($r('app.float.font_body_sm'))
            .fontColor($r('sys.color.brand'))
            .padding({
              left: 10,
              right: 10,
              top: 4,
              bottom: 4
            })
            .borderRadius($r('app.float.radius_sm'))
            .backgroundColor($r('sys.color.comp_background_gray'))
            .onClick(() => {
              this.xUnitInput = this.xUnitLength > 0 ? GridAxisPainter.fmtUnit(this.xUnitLength) : '';
              this.showXUnitPopup = true;
              this.showXSuggest = false;
              // 检测到三角函数：输入框弹出 0.5s 后再弹二级「你可能想要」建议
              if (GridAxisPainter.hasTrig(this.functions)) {
                setTimeout((): void => {
                  if (this.showXUnitPopup) {
                    this.showXSuggest = true;
                  }
                }, 500);
              }
            })
            .bindPopup(this.showXUnitPopup, {
              builder: (): void => this.xUnitPopupBuilder(),
              placement: Placement.Left,
              maskColor: 0x33000000,
              popupColor: $r('sys.color.comp_background_primary'),
              enableArrow: true,
              onWillDismiss: (): void => {
                this.showXUnitPopup = false;
                this.showXSuggest = false;
              }
            })
        }
        .width('100%')

        // y 轴单位长度
        Row() {
          Text($r('app.string.graph_settings_y_unit'))
            .fontSize($r('app.float.font_body_sm'))
            .fontColor($r('sys.color.font_primary'))
          Blank()
          Text(this.yUnitLabel())
            .fontSize($r('app.float.font_body_sm'))
            .fontColor($r('sys.color.brand'))
            .padding({
              left: 10,
              right: 10,
              top: 4,
              bottom: 4
            })
            .borderRadius($r('app.float.radius_sm'))
            .backgroundColor($r('sys.color.comp_background_gray'))
            .onClick(() => {
              this.yUnitInput = this.yUnitLength > 0 ? GridAxisPainter.fmtUnit(this.yUnitLength) : '';
              this.showYUnitPopup = true;
              this.showYSuggest = false;
              // 检测到反三角函数：输入框弹出 0.5s 后再弹二级「你可能想要」建议
              if (GridAxisPainter.hasInvTrig(this.functions)) {
                setTimeout((): void => {
                  if (this.showYUnitPopup) {
                    this.showYSuggest = true;
                  }
                }, 500);
              }
            })
            .bindPopup(this.showYUnitPopup, {
              builder: (): void => this.yUnitPopupBuilder(),
              placement: Placement.Left,
              maskColor: 0x33000000,
              popupColor: $r('sys.color.comp_background_primary'),
              enableArrow: true,
              onWillDismiss: (): void => {
                this.showYUnitPopup = false;
                this.showYSuggest = false;
              }
            })
        }
        .width('100%')

        Blank()

        Row({ space: 8 }) {
          Button($r('app.string.graph_settings_reset'))
            .fontColor($r('sys.color.font_primary'))
            .layoutWeight(1)
            .onClick(() => {
              this.resetView();
            })
            .backgroundColor($r('sys.color.comp_background_primary'))

          // 分享当前图象（圆形按钮，带品牌水印栏；仅在宿主注入分享适配器时显示）
          if (this.exportService.shareEnabled) {
            Button({ type: ButtonType.Circle, stateEffect: true }) {
              SymbolGlyph($r('sys.symbol.share'))
                .fontSize($r('app.float.font_title'))
                .fontColor([$r('sys.color.font_primary')])
            }
            .height($r('app.float.button_height_sm'))
            .aspectRatio(1)
            .backgroundColor($r('sys.color.comp_background_primary'))
            .onClick(() => {
              this.shareFullGraphImage();
            })
          }
        }
        .width('100%')
      }
      .width(this.SET_PANEL_W)
      .height(this.SET_PANEL_H)
      .padding(12)
  }

  /** 展开设置菜单（bindPopup 悬浮层，由 popup 自身提供弹出转场） */
  private openSettings(): void {
    this.showSettings = true;
  }

  /** 收起设置菜单（popup 外点蒙层 onWillDismiss / ✕ 按钮 / 点画布空白处均走此入口） */
  private closeSettings(): void {
    this.showSettings = false;
  }

}
