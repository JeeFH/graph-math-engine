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
 * graph-ui 宿主能力适配器（依赖倒置层）
 *
 * 开源版不包含任何 App 私有能力的实现（系统分享面板、碰一碰分享、
 * 相册保存、缩略图持久化等）。这些能力全部抽象为接口，由宿主 App
 * 按需注入；未注入时使用内置的无操作默认实现，组件功能自动降级。
 *
 * - GraphShareAdapter：图象分享出口（JPEG 字节 + PixelMap），
 *   宿主可对接系统分享面板 / 碰一碰 / 第三方分享 SDK。
 * - GraphStorageAdapter：缩略图持久化出口（JPEG 字节 → 存储引用），
 *   宿主可对接沙箱文件 / 端云协同目录 / 数据库 Blob 等。
 */

import { image } from '@kit.ImageKit';

/**
 * 图象分享适配器。
 * GraphCanvas 完成截图、水印合成与 JPEG 打包后调用 shareImage，
 * 具体的分享通道（系统分享面板等）由宿主实现。
 */
export interface GraphShareAdapter {
  /**
   * 分享一张已打包的 JPEG 图象。
   * @param jpegBuffer JPEG 字节数据
   * @param pixelMap 合成后的 PixelMap（供需要 PixelMap 的分享通道使用）
   */
  shareImage(jpegBuffer: ArrayBuffer, pixelMap: image.PixelMap): Promise<void>;
}

/**
 * 缩略图持久化适配器。
 * GraphCanvas 截取函数缩略图并打包 JPEG 后调用 saveThumbnail，
 * 具体的落地方式（沙箱文件 / 云空间 / 数据库）由宿主实现。
 */
export interface GraphStorageAdapter {
  /**
   * 保存缩略图 JPEG 字节数据。
   * @param jpegBuffer JPEG 字节数据
   * @returns 存储引用（绝对路径 / URI / 记录 id），失败返回空字符串
   */
  saveThumbnail(jpegBuffer: ArrayBuffer): Promise<string>;
}

/** 默认分享适配器：不注册任何分享通道（分享入口在 UI 上自动隐藏） */
export class NoopShareAdapter implements GraphShareAdapter {
  async shareImage(_jpegBuffer: ArrayBuffer, _pixelMap: image.PixelMap): Promise<void> {
    // 默认不执行任何分享
  }
}

/** 默认存储适配器：仅返回空字符串，不落地任何文件 */
export class NoopStorageAdapter implements GraphStorageAdapter {
  async saveThumbnail(_jpegBuffer: ArrayBuffer): Promise<string> {
    return '';
  }
}
