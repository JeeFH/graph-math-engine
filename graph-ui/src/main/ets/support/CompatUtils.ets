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
 * CompatUtils - API 兼容性工具（graph-ui 自包含极简实现）
 *
 * 集中管理高版本 API 的版本判断，组件代码不直接引用
 * deviceInfo / hdsMaterial 等高版本符号。
 */

import { deviceInfo } from '@kit.BasicServicesKit';
import { hdsMaterial, SystemMaterialParams } from '@kit.UIDesignKit';

/** API 版本阈值：HarmonyOS 6.1.0 → API 23（distributionOSApiVersion 值） */
const API_V23: number = 60100;

/**
 * 判断当前设备 API 版本是否 >= 目标版本
 * @param target - API 版本阈值（distributionOSApiVersion 值）
 */
export function isApiVersionAtLeast(target: number): boolean {
  return deviceInfo.distributionOSApiVersion >= target;
}

/**
 * 安全获取 systemMaterialEffect
 * - API >= 23：返回 ADAPTIVE 材质效果对象
 * - API <  23：返回 undefined（不设置该属性，避免崩溃）
 */
export function getSystemMaterialEffect(): SystemMaterialParams | undefined {
  if (!isApiVersionAtLeast(API_V23)) {
    return undefined;
  }
  return {
    materialType: hdsMaterial.MaterialType.ADAPTIVE,
    materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE,
  };
}
