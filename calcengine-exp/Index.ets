// Index.ets - calcengine-exp 模块公开 API
// CalcEngine 表达式渲染引擎：VST（模型）-> ExprRender（翻译）-> Box 树（布局）-> Canvas2D 像素

// 基础类型
export { VstParseError, normalizeStyle } from './src/main/ets/types/ExprTypes';
export type { ExprStyle, ExprMetrics, DebugMask } from './src/main/ets/types/ExprTypes';

// ── VST 节点模型（视觉语法树，纯模型）──
export {
  VstNode, VstRow, VstNum, VstVar, VstConst, VstOp, VstPlaceholder,
  VstFrac, VstSqrt, VstRoot, VstPow, VstParen,
  VstFunc, VstCeil, VstFloor, VstPostfix, VstNeg, VstLog
} from './src/main/ets/vst/VstNodes';

// ── 纯位置光标 + 分支编码 ──
export {
  Cursor, resolveRow, resolveBranch,
  BRANCH_NUM, BRANCH_DEN, BRANCH_BODY, BRANCH_BASE, BRANCH_EXP, BRANCH_INDEX,
  BRANCH_LOG_BASE
} from './src/main/ets/vst/TreeCursor';

// ── 编辑器门面 + 命令 + 序列化/化简/图键 ──
export { MathField } from './src/main/ets/vst/VstEditor';
export { serializeLinear } from './src/main/ets/vst/VstSerializer';
export { simplify } from './src/main/ets/vst/ExpressionSimplifier';
export { resolveGraphKey } from './src/main/ets/vst/GraphKeyMap';
export type { GraphKeySpec } from './src/main/ets/vst/GraphKeyMap';

// ── 解析器：线性求值串 -> VstRow ──
export { parseLinear } from './src/main/ets/parser/ExprParser';

// ── 渲染翻译层：VstRow -> Box ──
export { ExprRenderer } from './src/main/ets/engine/ExprRender';

// ── 布局盒树（含光标定位）──
export { Box } from './src/main/ets/box/Box';
export { LayoutMap } from './src/main/ets/engine/LayoutMap';

// ── 实测重排（离屏渲染用）──
export { measureAndRelayout } from './src/main/ets/box/measure';

// ── TeX 度量（自研）──
export { AXIS_HEIGHT, DEFAULT_RULE_THICKNESS, NUM1, NUM2, NUM3, DENOM1, DENOM2,
  SUP1, SUP2, SUP3, SUP_DROP, SUB_DROP, SUB1, SUB2, X_HEIGHT, SCRIPT_SPACE,
  SCRIPT_FACTOR, SCRIPT_SCRIPT_FACTOR } from './src/main/ets/font/TeXMetrics';

// ── 数学间距（自研）──
export { getGlueWidth, classifyCharType,
  MATH_ORD, MATH_OP, MATH_BIN, MATH_REL, MATH_OPEN, MATH_CLOSE, MATH_PUNCT, MATH_INNER
} from './src/main/ets/font/MathSpacing';

// ── 主题色解析 ──
export { resolveColor } from './src/main/ets/theme/ColorResolver';

// ── 视图组件 ──
export { ExprView } from './src/main/ets/view/ExprView';
export { MathFieldView } from './src/main/ets/view/MathFieldView';
