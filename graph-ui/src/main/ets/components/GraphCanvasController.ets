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
// features/graph/src/main/ets/components/GraphCanvasController.ets
/**
 * 画布控制器（仿 WebviewController 的 Controller 模式）
 *
 * 用途：让父组件（瀹夸富缁勪欢）无需直接持有 GraphCanvas 组件实例，
 * 即可命令画布执行"截取指定函数缩略图"等操作。
 *
 * 工作原理：
 * - 瀹夸富缁勪欢 持有本控制器实例，并通过普通引用属性传给 GraphCanvas（引用传递，不可用 @Prop 深拷贝）。
 * - GraphCanvas 在 aboutToAppear 时把真正的截图实现注册进来，aboutToDisappear 时注销。
 * - 瀹夸富缁勪欢 调用 captureThumbnail(fnId) 时，实际执行的是当前已挂载画布注册的实现。
 *
 * 注意：手机端竖屏与平板端是两套 GraphCanvas（if/else 互斥渲染），同一时刻只有一个挂载，
 * 因此控制器始终指向当前生效的画布实例。
 */

import { image } from '@kit.ImageKit';

export class GraphCanvasController {
  /** 截图实现：由 GraphCanvas 注册，入参为函数 id 与静默模式标志，返回缩略图沙箱绝对路径（失败返回空串） */
  private captureImpl: ((fnId: number, silent: boolean) => Promise<string>) | null = null;
  /** 视图快照实现：由 GraphCanvas 注册，返回当前可见视口的 PixelMap；传入 fnId 时仅渲染该目标函数。失败返回 null */
  private viewCaptureImpl: ((fnId?: number) => Promise<image.PixelMap | null>) | null = null;

  /** GraphCanvas 挂载时注册截图实现 */
  registerCapture(impl: (fnId: number, silent: boolean) => Promise<string>): void {
    this.captureImpl = impl;
  }

  /** GraphCanvas 挂载时注册视图快照实现（“保存至历史记录”飞行动画用；fnId 可选，指定后仅截取该目标函数） */
  registerViewCapture(impl: (fnId?: number) => Promise<image.PixelMap | null>): void {
    this.viewCaptureImpl = impl;
  }

  /** GraphCanvas 卸载时注销，避免持有失效实例 */
  unregisterCapture(): void {
    this.captureImpl = null;
    this.viewCaptureImpl = null;
  }

  /**
   * 截取指定函数的图像缩略图（仅该函数曲线 + 坐标系）。
   * @param fnId 目标函数 id
   * @param silent 静默模式：不播放运镜动画，截图后恢复用户当前视口（缩略图自动刷新用，默认 false）
   * @returns 缩略图沙箱绝对路径；画布未挂载或截图失败时返回空字符串
   */
  async captureThumbnail(fnId: number, silent: boolean = false): Promise<string> {
    if (this.captureImpl === null) {
      return '';
    }
    return await this.captureImpl(fnId, silent);
  }

  /**
   * 截取当前可见视口快照，供“保存至历史记录”飞行动画生成缩略图使用。
   * @param fnId 可选。指定后仅渲染该目标函数（与 captureThumbnail 保存的缩略图内容一致）；不指定则渲染全部函数。
   * @returns 当前视图 PixelMap；画布未挂载或截图失败时返回 null
   */
  async captureView(fnId?: number): Promise<image.PixelMap | null> {
    if (this.viewCaptureImpl === null) {
      return null;
    }
    return await this.viewCaptureImpl(fnId);
  }

}
