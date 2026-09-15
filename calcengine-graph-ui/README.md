# calcengine-graph-ui

> **参考实现，未经生产验证**，视为实验性模块。

CalcEngine 图象引擎的 **Canvas 组件参考实现**：`GraphCanvas` + 分析坞 + `GraphViewModel`。

依赖 [`calcengine-graph`](../calcengine-graph)、[`calcengine-exp`](../calcengine-exp)、[`calcengine-core`](../calcengine-core)。它的定位是**集成样例**——如果你已有自己的 UI 层，只依赖 `calcengine-graph` 即可，不必引入本包。

## 安装

```json5
{
  "dependencies": {
    "calcengine-graph-ui": "^0.2.0"
  }
}
```

## 快速开始

```typescript
import { GraphViewModel, GraphCanvas, GraphCanvasController } from 'calcengine-graph-ui';
import type { MarkerCategory } from 'calcengine-graph';

const vm = new GraphViewModel();
const id = vm.addFunction('sin(x)');
vm.addFunction('x^2+y^2=4');   // 隐函数（圆）
vm.addFunction('y>x^2');       // 不等式

// 控制器：宿主无需持有组件实例即可下发命令（如截取缩略图）
const controller = new GraphCanvasController();

@Entry
@Component
struct GraphPage {
  private vm: GraphViewModel = new GraphViewModel();

  build() {
    Column() {
      GraphCanvas({
        functions: this.vm.functions,
        activeId: this.vm.activeId,
        isDegMode: false,
        isDark: false,
        renderDispatcher: this.vm.getRenderDispatcher(),
        controller: controller,
        // 可选适配器（未注入时功能自动降级：分享入口隐藏、缩略图不落地）
        shareAdapter: myShareAdapter,
        storageAdapter: myStorageAdapter,
        // 高级分析门控
        advancedAnalysisEnabled: true
      })
    }
  }
}
```

`GraphViewModel` 归属本包而非 `calcengine-graph`：它依赖 `calcengine-exp` 的 `MathField` 与序列化能力，属 UI 状态层，不属于纯引擎职责。

## 能力出口（适配器注入）

分享与缩略图持久化通过适配器接口与宿主解耦；未注入时使用 `NoopShareAdapter` / `NoopStorageAdapter`，不执行任何落地操作。

```typescript
import type { GraphShareAdapter, GraphStorageAdapter } from 'calcengine-graph-ui';

interface GraphShareAdapter {
  // GraphCanvas 完成截图、水印合成与 JPEG 打包后调用
  shareImage(jpegBuffer: ArrayBuffer, pixelMap: image.PixelMap): Promise<void>;
}

interface GraphStorageAdapter {
  // 返回存储引用（路径 / URI / 记录 id），失败返回空字符串
  saveThumbnail(jpegBuffer: ArrayBuffer): Promise<string>;
}
```

图象水印合成的品牌信息同样由宿主注入，均为可选：

```typescript
import { GraphImageExporter } from 'calcengine-graph-ui';

GraphImageExporter.composeWatermark(pixelMap, fontSize, fg, logoResId, brandName, ...);
// logoResId <= 0 时跳过 logo；brandName 为空时跳过品牌文字
```

## 其余导出

`GraphDisplayArea`（显示区域）、`AnalysisDock`（分析卡片坞）、`GraphExportService`（导出服务）、`ModeTag` / `MODE_STYLES` / `MODE_STYLES_DARK`（模式标签）、`UiMotion`（动效工具）。

## 许可证

MIT License - 详见 [LICENSE](./LICENSE)
