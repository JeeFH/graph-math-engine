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
/**
 * Demo 主页面（无键盘布局演示）
 *
 * 演示最小集成方式：
 * - 顶部 TextInput 输入表达式（支持显函数 / 隐函数 / 不等式 / 二元方程四类）
 * - 中部 GraphCanvas 实时绘图（手势平移缩放 / 点选曲线 / 设置面板）
 * - 底部 GraphDisplayArea 函数槽位列表（行内菜单 / 重命名 / 线型线宽）
 *
 * 状态管理：GraphViewModel 为单一真相源，每次变更后 sync() 刷新 @State。
 */

import { GraphFunction, GraphLineStyle, MarkerCategory } from 'calcengine-graph';
import { GraphCanvas, GraphCanvasController, GraphDisplayArea, GraphViewModel } from 'calcengine-graph-ui';

@Entry
@Component
struct Index {
  /** 图形状态核心（单一真相源） */
  private vm: GraphViewModel = new GraphViewModel();
  /** 画布控制器（宿主持有，引用传入） */
  private canvasController: GraphCanvasController = new GraphCanvasController();

  // ── UI 状态（vm 变更后经 sync() 刷新） ──
  @State functions: GraphFunction[] = this.vm.functions;
  @State activeId: number = this.vm.activeId;
  @State inputText: string = '';
  @State isDark: boolean = false;

  /** vm → @State 同步（vm 每次变更均整体替换 functions 引用） */
  private sync(): void {
    this.functions = this.vm.functions;
    this.activeId = this.vm.activeId;
  }

  /** 当前活跃槽的表达式（切换选中时同步输入框） */
  private syncInput(): void {
    const fn: GraphFunction | undefined =
      this.vm.functions.find((f: GraphFunction): boolean => f.id === this.activeId);
    this.inputText = fn !== undefined ? fn.expr : '';
  }

  build() {
    Column() {
      // ── 顶部：表达式输入 + 添加函数 + 暗色切换 ──
      Row({ space: 8 }) {
        TextInput({ text: this.inputText, placeholder: $r('app.string.demo_input_placeholder') })
          .layoutWeight(1)
          .height(44)
          .onChange((v: string): void => {
            this.inputText = v;
            this.vm.setExpr(this.vm.activeId, v);
            this.sync();
          })

        Button($r('app.string.demo_add_function'))
          .height(44)
          .onClick((): void => {
            this.vm.addFunction();
            this.sync();
            this.syncInput();
          })

        Toggle({ type: ToggleType.Switch, isOn: this.isDark })
          .width(48)
          .height(26)
          .onChange((isOn: boolean): void => {
            this.isDark = isOn;
          })
      }
      .width('100%')
      .padding(12)

      // ── 中部：交互式画布 ──
      GraphCanvas({
        functions: this.functions,
        activeId: this.activeId,
        isDegMode: this.vm.isDegMode,
        isDark: this.isDark,
        renderDispatcher: this.vm.getRenderDispatcher(),
        controller: this.canvasController,
        onSelect: (id: number): void => {
          this.vm.setActiveId(id);
          this.sync();
          this.syncInput();
        },
        onColorChange: (id: number, color: string): void => {
          this.vm.setColor(id, color);
          this.sync();
        },
        onLineStyleChange: (id: number, style: GraphLineStyle): void => {
          this.vm.setLineStyle(id, style);
          this.sync();
        },
        onToggle: (id: number): void => {
          this.vm.toggleEnabled(id);
          this.sync();
        },
        onRemove: (id: number): void => {
          this.vm.removeFunction(id);
          this.sync();
          this.syncInput();
        },
        onMarkerCategoryChange: (id: number, category: MarkerCategory, show: boolean): void => {
          this.vm.setMarkerCategory(id, category, show);
          this.sync();
        }
      })
        .layoutWeight(1)
        .width('100%')

      // ── 底部：函数槽位列表（手机布局） ──
      GraphDisplayArea({
        functions: this.functions,
        activeId: this.activeId,
        isDark: this.isDark,
        isPhoneDevice: true,
        isLandscape: false,
        onAdd: (): void => {
          this.vm.addFunction();
          this.sync();
          this.syncInput();
        },
        onRemove: (id: number): void => {
          this.vm.removeFunction(id);
          this.sync();
          this.syncInput();
        },
        onToggle: (id: number): void => {
          this.vm.toggleEnabled(id);
          this.sync();
        },
        onExprChange: (id: number, expr: string): void => {
          this.vm.setExpr(id, expr);
          this.sync();
        },
        onColorChange: (id: number, color: string): void => {
          this.vm.setColor(id, color);
          this.sync();
        },
        onSelect: (id: number): void => {
          this.vm.setActiveId(id);
          this.sync();
          this.syncInput();
        },
        onLineStyleChange: (id: number, style: GraphLineStyle): void => {
          this.vm.setLineStyle(id, style);
          this.sync();
        },
        onLineWidthChange: (id: number, w: number): void => {
          this.vm.setLineWidth(id, w);
          this.sync();
        },
        onDuplicate: (id: number): void => {
          this.vm.duplicateFunction(id);
          this.sync();
        },
        onRename: (id: number, name: string): void => {
          this.vm.renameFunction(id, name);
          this.sync();
        },
        onMarkerCategoryChange: (id: number, category: MarkerCategory, show: boolean): void => {
          this.vm.setMarkerCategory(id, category, show);
          this.sync();
        },
        onAnalysisToggle: (id: number): void => {
          this.vm.toggleAnalysis(id);
          this.sync();
        }
      })
        .width('100%')
        .height('32%')
    }
    .width('100%')
    .height('100%')
  }
}
