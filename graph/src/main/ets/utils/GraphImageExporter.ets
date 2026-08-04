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
// graph/src/main/ets/utils/GraphImageExporter.ets
/**
 * 图形图象导出工具类
 *
 * 职责：将函数图象 PixelMap 合成水印栏（可选 logo + 品牌名 + 表达式 + 颜色圆点），
 * 输出最终合成 PixelMap。与画布渲染/手势/动画无关，属于纯图片后处理。
 *
 * 品牌信息由宿主注入（logoResId / brandName），均为可选：
 * logoResId <= 0 时跳过 logo，brandName 为空时跳过品牌文字。
 */

import { image } from '@kit.ImageKit';
import { drawing } from '@kit.ArkGraphics2D';
import { resourceManager } from '@kit.LocalizationKit';

/** 表达式渲染回调：由 GraphCanvas 提供（需要画布上下文临时渲染） */
export type ExprPixelMapProvider = (expr: string) => Promise<image.PixelMap | null>;

export class GraphImageExporter {
  /**
   * 合成品牌水印栏：在函数图象底部追加 logo + 品牌名 + 表达式 + 颜色圆点。
   *
   * @param graphPixelMap - 原始函数图象 PixelMap
   * @param exprLabel - 表达式文本（showExpr=false 时忽略）
   * @param fnColor - 函数曲线颜色（hex，如 '#4A90D9'）
   * @param isDark - 暗色模式
   * @param showExpr - 是否显示表达式
   * @param resMgr - 资源管理器（加载品牌 logo，仅 logoResId > 0 时使用）
   * @param logoResId - 品牌 logo 资源 ID（<= 0 时跳过 logo）
   * @param brandName - 品牌文字（空串时跳过品牌文字）
   * @param exprProvider - 表达式数学排版渲染回调（可选，null 时回退纯文本）
   * @returns 合成后的 PixelMap（原始图象 + 水印栏）
   */
  static async composeWatermark(
    graphPixelMap: image.PixelMap,
    exprLabel: string,
    fnColor: string,
    isDark: boolean,
    showExpr: boolean,
    resMgr: resourceManager.ResourceManager,
    logoResId: number,
    brandName: string,
    exprProvider: ExprPixelMapProvider | null
  ): Promise<image.PixelMap> {
    // 1. 获取图像像素尺寸
    const graphInfo: image.ImageInfo = await graphPixelMap.getImageInfo();
    const wPx: number = graphInfo.size.width;
    const hPx: number = graphInfo.size.height;

    // 2. 计算水印栏高度（图像宽度的 12%，钳制在 60~160px）
    const barH: number = Math.max(60, Math.min(160, Math.round(wPx * 0.12)));
    const totalH: number = hPx + barH;

    // 3. 创建目标 PixelMap（零填充 → 透明底）
    const bufSize: number = wPx * totalH * 4;
    const initBuf: ArrayBuffer = new ArrayBuffer(bufSize);
    const initOpts: image.InitializationOptions = {
      size: { width: wPx, height: totalH },
      srcPixelFormat: image.PixelMapFormat.RGBA_8888
    };
    const finalMap: image.PixelMap = await image.createPixelMap(initBuf, initOpts);

    // 4. 创建 drawing.Canvas
    const canvas: drawing.Canvas = new drawing.Canvas(finalMap);

    // 5. 绘制函数图像到顶部
    canvas.drawImage(graphPixelMap, 0, 0);

    // 6. 绘制水印栏背景
    const bgBrush: drawing.Brush = new drawing.Brush();
    if (isDark) {
      bgBrush.setColor(255, 42, 42, 42);
    } else {
      bgBrush.setColor(255, 247, 247, 247);
    }
    canvas.attachBrush(bgBrush);
    canvas.drawRect(0, hPx, wPx, totalH);
    canvas.detachBrush();

    // 7. 绘制顶部分割线
    const linePen: drawing.Pen = new drawing.Pen();
    if (isDark) {
      linePen.setColor(255, 58, 58, 58);
    } else {
      linePen.setColor(255, 224, 224, 224);
    }
    linePen.setStrokeWidth(1);
    canvas.attachPen(linePen);
    canvas.drawLine(0, hPx, wPx, hPx);
    canvas.detachPen();

    // 8. 布局参数
    const padX: number = Math.round(barH * 0.3);
    const logoSize: number = Math.round(barH * 0.5);
    const barCenterY: number = hPx + Math.round(barH / 2);
    const textAlpha: number = 255;
    const textR: number = isDark ? 204 : 51;
    const textG: number = isDark ? 204 : 51;
    const textB: number = isDark ? 204 : 51;

    // 9. 加载并绘制品牌 logo（左侧，仅宿主提供有效资源 ID 时）
    let brandTextX: number = padX;
    if (logoResId > 0) {
      try {
        const rawMedia: Uint8Array = await resMgr.getMediaContent(logoResId);
        const logoSrc: image.ImageSource = image.createImageSource(rawMedia.buffer as ArrayBuffer);
        const logoMap: image.PixelMap = await logoSrc.createPixelMap({
          desiredSize: { width: logoSize * 2, height: logoSize * 2 }
        });
        const logoY: number = hPx + Math.round((barH - logoSize) / 2);
        // 圆角裁切（radius 9）+ 2x 分辨率缩放绘制
        canvas.save();
        const logoRect: drawing.RoundRect = new drawing.RoundRect(
          { left: padX, top: logoY, right: padX + logoSize, bottom: logoY + logoSize }, 9, 9);
        canvas.clipRoundRect(logoRect);
        canvas.translate(padX, logoY);
        canvas.scale(0.5, 0.5);
        canvas.drawImage(logoMap, 0, 0);
        canvas.restore();
        brandTextX = padX + logoSize + Math.round(barH * 0.12);
        logoSrc.release();
      } catch (_e) {
        // logo 加载失败时仅显示文字
        brandTextX = padX;
      }
    }

    // 10. 绘制品牌文字（logo 右侧，垂直居中；brandName 为空时跳过）
    if (brandName.length > 0) {
      const brandFontSize: number = Math.round(barH * 0.22);
      const brandFont: drawing.Font = new drawing.Font();
      brandFont.setSize(brandFontSize);
      brandFont.enableEmbolden(true);
      const brandBlob: drawing.TextBlob =
        drawing.TextBlob.makeFromString(brandName, brandFont);
      const brandBrush: drawing.Brush = new drawing.Brush();
      brandBrush.setColor(textAlpha, textR, textG, textB);
      canvas.attachBrush(brandBrush);
      // 基线偏移：近似垂直居中（基线约在字体大小的 0.7 处）
      const brandBaselineY: number = barCenterY + Math.round(brandFontSize * 0.35);
      canvas.drawTextBlob(brandBlob, brandTextX, brandBaselineY);
      canvas.detachBrush();
    }

    // 11. 绘制表达式（右侧，右对齐）—— 直接渲染表达式本身，不附加 "y=" 等前缀
    if (showExpr) {
      const exprFontSize: number = Math.round(barH * 0.2);
      // 渲染表达式为数学排版 PixelMap（由 ExprView 同源引擎提供）
      const exprPixelMap: image.PixelMap | null =
        exprProvider !== null ? await exprProvider(exprLabel) : null;
      let exprBodyW: number = 0;
      let exprDrawH: number = exprFontSize;
      let exprScale: number = 1;
      if (exprPixelMap !== null) {
        const exprInfo: image.ImageInfo = await exprPixelMap.getImageInfo();
        const exprNativeW: number = exprInfo.size.width;
        const exprNativeH: number = exprInfo.size.height;
        // 目标高度 = 栏高的 55%（数学结构需要较多纵向空间）
        exprDrawH = Math.round(barH * 0.55);
        exprScale = exprDrawH / exprNativeH;
        exprBodyW = Math.round(exprNativeW * exprScale);
      } else {
        // 回退：纯文本表达式
        const fallbackFont: drawing.Font = new drawing.Font();
        fallbackFont.setSize(exprFontSize);
        exprBodyW = Math.round(
          fallbackFont.measureText(exprLabel, drawing.TextEncoding.TEXT_ENCODING_UTF8));
      }
      // 颜色圆点参数
      const dotRadius: number = Math.round(barH * 0.06);
      const dotGap: number = dotRadius * 2;
      // 总宽度 = 圆点直径 + 间距 + 表达式宽度
      const totalExprW: number = dotRadius * 2 + dotGap + exprBodyW;
      // 右对齐起始 x
      const exprAreaX: number = Math.max(brandTextX + 10, wPx - padX - totalExprW);

      // 12. 绘制曲线颜色圆点（表达式左侧）
      const dotCenterX: number = exprAreaX + dotRadius;
      if (dotCenterX > brandTextX + 20) {
        const dotBrush: drawing.Brush = new drawing.Brush();
        const hexColor: string = fnColor.replace('#', '');
        const cR: number = parseInt(hexColor.substring(0, 2), 16);
        const cG: number = parseInt(hexColor.substring(2, 4), 16);
        const cB: number = parseInt(hexColor.substring(4, 6), 16);
        dotBrush.setColor(255, cR, cG, cB);
        canvas.attachBrush(dotBrush);
        canvas.drawCircle(dotCenterX, barCenterY, dotRadius);
        canvas.detachBrush();
      }

      // 绘制表达式主体（无 "y=" 前缀，直接显示表达式内容）
      const exprBodyX: number = exprAreaX + dotRadius * 2 + dotGap;
      if (exprPixelMap !== null) {
        const exprDrawY: number = barCenterY - Math.round(exprDrawH / 2);
        canvas.save();
        canvas.translate(exprBodyX, exprDrawY);
        canvas.scale(exprScale, exprScale);
        canvas.drawImage(exprPixelMap, 0, 0);
        canvas.restore();
      } else {
        // 回退纯文本
        const fallbackFont2: drawing.Font = new drawing.Font();
        fallbackFont2.setSize(exprFontSize);
        const fallbackBlob: drawing.TextBlob =
          drawing.TextBlob.makeFromString(exprLabel, fallbackFont2);
        const fallbackBrush: drawing.Brush = new drawing.Brush();
        fallbackBrush.setColor(textAlpha, textR, textG, textB);
        canvas.attachBrush(fallbackBrush);
        const fallbackBaselineY: number = barCenterY + Math.round(exprFontSize * 0.35);
        canvas.drawTextBlob(fallbackBlob, exprBodyX, fallbackBaselineY);
        canvas.detachBrush();
      }
    } // end if (showExpr)

    return finalMap;
  }
}
