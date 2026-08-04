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
 * graph-ui 模块入口
 * 图形引擎的 Canvas 组件参考实现：
 * - GraphCanvas：交互式画布（手势 / 设置面板 / 取色 / 截图导出）
 * - GraphDisplayArea：函数槽位列表（表达式行 / 行内菜单 / 重命名）
 * - AnalysisDock：函数分析横向滚动卡片坞
 * 分享 / 存储等宿主能力通过适配器接口注入，默认空实现。
 */

// ── 核心组件 ──
export { GraphCanvas } from './src/main/ets/components/GraphCanvas';
export { GraphCanvasController } from './src/main/ets/components/GraphCanvasController';
export { GraphDisplayArea } from './src/main/ets/components/GraphDisplayArea';
export { AnalysisDock } from './src/main/ets/components/AnalysisDock';
export type { AnalysisCardData } from './src/main/ets/components/AnalysisDock';

// ── 宿主注入适配器（分享 / 缩略图存储） ──
export type { GraphShareAdapter, GraphStorageAdapter } from './src/main/ets/support/GraphAdapters';
export { NoopShareAdapter, NoopStorageAdapter } from './src/main/ets/support/GraphAdapters';
export { GraphExportService } from './src/main/ets/export/GraphExportService';

// ── 辅助组件与常量 ──
export { ModeTag, MODE_STYLES, MODE_STYLES_DARK } from './src/main/ets/support/ModeTag';
export type { ModeTagStyle } from './src/main/ets/support/ModeTag';
export { UiMotion } from './src/main/ets/support/UiMotion';
