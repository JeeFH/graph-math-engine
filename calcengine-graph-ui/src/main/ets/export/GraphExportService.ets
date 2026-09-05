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
 * GraphExportService - 图像导出服务（分享 / 缩略图持久化调度）
 *
 * 从 GraphCanvas 拆分出的导出管线：
 * - JPEG 打包（ImagePacker）与缩略图等比缩放
 * - 分享调度：打包后交给注入的 GraphShareAdapter（默认 NoopShareAdapter 不做任何事）
 * - 缩略图调度：缩放 + 打包后交给注入的 GraphStorageAdapter（默认 NoopStorageAdapter 仅返回空串）
 *
 * 开源版不内置系统分享面板 / 文件系统落盘实现——这些与宿主 App 的账号、
 * 云同步、隐私策略强相关，由宿主按需实现适配器注入。
 */

import { image } from '@kit.ImageKit';
import { GraphShareAdapter, GraphStorageAdapter, NoopStorageAdapter }
  from '../support/GraphAdapters';

export class GraphExportService {
  /** 分享适配器（null 表示宿主未注入，UI 应隐藏分享入口） */
  private shareAdapter: GraphShareAdapter | null;
  /** 缩略图持久化适配器（始终非空，默认 Noop） */
  private storageAdapter: GraphStorageAdapter;

  constructor(shareAdapter: GraphShareAdapter | null = null,
    storageAdapter: GraphStorageAdapter | null = null) {
    this.shareAdapter = shareAdapter;
    this.storageAdapter = storageAdapter !== null ? storageAdapter : new NoopStorageAdapter();
  }

  /** 宿主是否注入了分享适配器（UI 据此决定是否显示分享按钮） */
  get shareEnabled(): boolean {
    return this.shareAdapter !== null;
  }

  /** 替换分享适配器（传 null 关闭分享入口） */
  setShareAdapter(adapter: GraphShareAdapter | null): void {
    this.shareAdapter = adapter;
  }

  /** 替换缩略图持久化适配器 */
  setStorageAdapter(adapter: GraphStorageAdapter): void {
    this.storageAdapter = adapter;
  }

  /**
   * 将 PixelMap 打包为 JPEG 二进制。
   * @param pixelMap 源图像
   * @param quality JPEG 质量 0-100（分享建议 92，缩略图建议 85）
   * @returns JPEG ArrayBuffer
   */
  static async packJpeg(pixelMap: image.PixelMap, quality: number): Promise<ArrayBuffer> {
    const packer: image.ImagePacker = image.createImagePacker();
    try {
      return await packer.packing(pixelMap, { format: 'image/jpeg', quality: quality });
    } finally {
      packer.release();
    }
  }

  /**
   * 等比缩小 PixelMap 使宽度不超过 maxPx（不放大，width ≤ maxPx 时不做任何事）。
   * 原地修改传入的 PixelMap。
   * @param pixelMap 源图像（正方形缩略图场景 width === height）
   * @param maxPx 目标最大边长（像素）
   */
  static async scaleToMax(pixelMap: image.PixelMap, maxPx: number): Promise<void> {
    const info: image.ImageInfo = await pixelMap.getImageInfo();
    if (info.size.width <= 0 || info.size.height <= 0) {
      return;
    }
    const factor: number = Math.min(1, maxPx / Math.max(info.size.width, info.size.height));
    if (factor < 1) {
      await pixelMap.scale(factor, factor);
    }
  }

  /**
   * 分享图像：打包 JPEG 后交给分享适配器。
   * @param pixelMap 合成后的完整图像（含水印栏）
   * @param quality JPEG 质量（默认 92）
   * @returns true 表示已提交给适配器；false 表示未注入适配器或打包失败
   */
  async shareImage(pixelMap: image.PixelMap, quality: number = 92): Promise<boolean> {
    if (this.shareAdapter === null) {
      return false;
    }
    let buf: ArrayBuffer;
    try {
      buf = await GraphExportService.packJpeg(pixelMap, quality);
    } catch (e) {
      console.error(`[GraphExportService] packJpeg failed: ${JSON.stringify(e)}`);
      return false;
    }
    try {
      await this.shareAdapter.shareImage(buf, pixelMap);
      return true;
    } catch (e) {
      console.error(`[GraphExportService] shareAdapter.shareImage failed: ${JSON.stringify(e)}`);
      return false;
    }
  }

  /**
   * 保存缩略图：等比缩小（≤ maxPx）→ 打包 JPEG → 交给持久化适配器。
   * @param pixelMap 截取的原始正方形图像
   * @param maxPx 目标最大边长（默认 480px）
   * @param quality JPEG 质量（默认 85）
   * @returns 适配器返回的存储标识（如文件路径 / 云端 uri）；失败返回空字符串
   */
  async saveThumbnail(pixelMap: image.PixelMap, maxPx: number = 480,
    quality: number = 85): Promise<string> {
    try {
      await GraphExportService.scaleToMax(pixelMap, maxPx);
      const buf: ArrayBuffer = await GraphExportService.packJpeg(pixelMap, quality);
      return await this.storageAdapter.saveThumbnail(buf);
    } catch (e) {
      console.error(`[GraphExportService] saveThumbnail failed: ${JSON.stringify(e)}`);
      return '';
    }
  }
}
