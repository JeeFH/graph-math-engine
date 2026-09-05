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
 * 动效时长常量（Design Token）
 *
 * ArkUI animateTo / .animation 的 duration 参数不支持 $r() 资源引用，
 * 故以常量类集中管理，供 graph-ui 内部统一引用。
 *
 * 使用方式：
 *   import { UiMotion } from 'calcengine-graph-ui';
 *   animateTo({ duration: UiMotion.NORMAL }, () => { ... })
 */
export class UiMotion {
  /** 快速反馈：按压态、微交互、小元素显隐 */
  static readonly FAST: number = 150;

  /** 常规过渡：列表项展开、Tab 切换、普通属性动画 */
  static readonly NORMAL: number = 200;

  /** 中速过渡：面板展开/收起、弹窗出入场、较大区域变化 */
  static readonly MEDIUM: number = 300;

  /** 慢速过渡：页面级转场、全屏覆盖物、引导动效 */
  static readonly SLOW: number = 400;

  /** 错峰入场步长：多卡片依次入场的相邻延迟间隔 */
  static readonly STAGGER: number = 100;
}
