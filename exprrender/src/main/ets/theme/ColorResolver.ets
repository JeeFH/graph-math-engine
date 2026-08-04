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
// theme/ColorResolver.ets
// 将 ResourceColor（可能来自 $r(...) 资源）解析为 Canvas 可用的具体颜色字符串。
// SDK 自包含：仅依赖全局 Context/Resource 类型与 resourceManager，不引入项目私有模块。

/**
 * 解析颜色：
 * - string：原样返回（如 '#FF0000'、'rgba(...)'）
 * - Resource：经 resourceManager.getColorSync 解析（自动按当前主题）
 * - number：按 0xAARRGGBB 解释
 */
export function resolveColor(color: ResourceColor, context: Context): string {
  if (typeof color === 'string') {
    return color;
  }
  try {
    if (typeof color === 'object') {
      const num = context.resourceManager.getColorSync(color as Resource);
      return argbToRgbaString(num);
    }
    if (typeof color === 'number') {
      return argbToRgbaString(color);
    }
  } catch (e) {
    return '#000000';
  }
  return '#000000';
}

function argbToRgbaString(num: number): string {
  const a = (num >> 24) & 0xff;
  const r = (num >> 16) & 0xff;
  const g = (num >> 8) & 0xff;
  const b = num & 0xff;
  return `rgba(${r},${g},${b},${(a / 255).toFixed(3)})`;
}
