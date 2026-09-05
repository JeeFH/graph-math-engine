/*
 * Copyright 2026 graph-math-engine contributors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
/**
 * mathkit/MathLogger.ets
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
        console.info(`[mathkit] ${message}`);
    }
    warn(message: string): void {
        console.warn(`[mathkit] ${message}`);
    }
    error(message: string): void {
        console.error(`[mathkit] ${message}`);
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
