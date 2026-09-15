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
 * calcengine-core/src/main/ets/math/MathLogger.ets
 *
 * SDK 轻量日志抽象。
 * SDK 内部不直接依赖 hilog 等宿主平台日志设施，
 * 默认输出到 console；宿主应用可通过 setMathLogger 注入自定义实现
 * （如转发到 hilog / 远端日志系统）。
 */

/** 日志级别接口：宿主按需实现 */
export interface MathLogger {
  info(message: string): void;
  warn(message: string): void;
  error(message: string): void;
}

/** 默认实现：console 输出 */
class ConsoleMathLogger implements MathLogger {
  info(message: string): void {
    console.info(`[calcengine-core] ${message}`);
  }

  warn(message: string): void {
    console.warn(`[calcengine-core] ${message}`);
  }

  error(message: string): void {
    console.error(`[calcengine-core] ${message}`);
  }
}

let currentLogger: MathLogger = new ConsoleMathLogger();

/**
 * 注入自定义日志实现（建议在应用启动时调用一次）。
 * @param logger 实现 MathLogger 接口的对象
 */
export function setMathLogger(logger: MathLogger): void {
  currentLogger = logger;
}

/** 获取当前日志实现（SDK 内部使用） */
export function getMathLogger(): MathLogger {
  return currentLogger;
}
