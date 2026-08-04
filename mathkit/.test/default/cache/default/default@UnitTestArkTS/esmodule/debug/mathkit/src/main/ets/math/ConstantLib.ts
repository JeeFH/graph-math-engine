import { getMathLogger } from "@normalized:N&&&mathkit/src/main/ets/math/MathLogger&0.1.0";
export interface ConstantEntry {
    /** 常数唯一标识符 */
    id: string;
    /** 显示符号（如 π, φ, ℏ） */
    symbol: string;
    /** 常数名称 */
    name: string;
    /** 数值字符串（高精度） */
    value: string;
    /** 分类：math, physics, chemistry, engineering */
    category: string;
    /** 单位（如 "m/s", "J·s"） */
    unit?: string;
    /** 描述信息 */
    description?: string;
}
/**
 * 常数库类
 */
export class ConstantLib {
    // 常数映射表：符号 -> 常数条目
    private static constants: Map<string, ConstantEntry> = new Map();
    // 标识符映射表：id -> 常数条目（用于快速查找）
    private static idMap: Map<string, ConstantEntry> = new Map();
    // 是否已初始化
    private static initialized: boolean = false;
    /**
     * 初始化常数库
     */
    public static initialize(): void {
        if (ConstantLib.initialized) {
            return;
        }
        // ── 数学常数 ─────────────────────────────────────────────────────
        ConstantLib.addConstant({
            id: 'pi',
            symbol: 'π',
            name: '圆周率',
            value: '3.14159265358979323846',
            category: 'math',
            description: 'π = 3.14159...'
        });
        ConstantLib.addConstant({
            id: 'e',
            symbol: 'e',
            name: '自然常数',
            value: '2.71828182845904523536',
            category: 'math',
            description: '自然对数的底数'
        });
        ConstantLib.addConstant({
            id: 'phi',
            symbol: 'φ',
            name: '黄金比例',
            value: '1.61803398874989484820',
            category: 'math',
            description: '(1+√5)/2'
        });
        ConstantLib.addConstant({
            id: 'euler',
            symbol: 'γ',
            name: '欧拉-马歇罗尼常数',
            value: '0.57721566490153286060',
            category: 'math',
            description: 'Euler–Mascheroni constant'
        });
        // ConstantLib.addConstant({
        //   id: 'catalan',
        //   symbol: 'G',
        //   name: '卡特兰常数',
        //   value: '0.91596559417721901505',
        //   category: 'math',
        //   description: 'Catalan\'s constant'
        // });
        // ── 物理常数 ─────────────────────────────────────────────────────
        ConstantLib.addConstant({
            id: 'c_light',
            symbol: 'c',
            name: '光速',
            value: '299792458',
            unit: 'm/s',
            category: 'physics',
            description: '真空中的光速'
        });
        ConstantLib.addConstant({
            id: 'h_planck',
            symbol: 'h',
            name: '普朗克常数',
            value: '6.62607015e-34',
            unit: 'J·s',
            category: 'physics',
            description: '量子力学基本常数'
        });
        ConstantLib.addConstant({
            id: 'hbar',
            symbol: 'ℏ',
            name: '约化普朗克',
            value: '1.054571817e-34',
            unit: 'J·s',
            category: 'physics',
            description: 'h/2π'
        });
        ConstantLib.addConstant({
            id: 'g_grav',
            symbol: 'g',
            name: '重力加速度',
            value: '9.80665',
            unit: 'm/s²',
            category: 'physics',
            description: '标准重力加速度'
        });
        ConstantLib.addConstant({
            id: 'G_newton',
            symbol: 'G',
            name: '万有引力常数',
            value: '6.67430e-11',
            unit: 'N·m²/kg²',
            category: 'physics',
            description: '牛顿引力常数'
        });
        ConstantLib.addConstant({
            id: 'k_boltz',
            symbol: 'k_B',
            name: '玻尔兹曼常数',
            value: '1.380649e-23',
            unit: 'J/K',
            category: 'physics',
            description: '统计力学基本常数'
        });
        ConstantLib.addConstant({
            id: 'eps0',
            symbol: 'ε₀',
            name: '真空介电常数',
            value: '8.8541878128e-12',
            unit: 'F/m',
            category: 'physics',
            description: '电容率'
        });
        ConstantLib.addConstant({
            id: 'mu0',
            symbol: 'μ₀',
            name: '真空磁导率',
            value: '1.25663706212e-6',
            unit: 'H/m',
            category: 'physics',
            description: '磁导率'
        });
        ConstantLib.addConstant({
            id: 'NA',
            symbol: 'Nₐ',
            name: '阿伏加德罗数',
            value: '6.02214076e+23',
            unit: 'mol⁻¹',
            category: 'physics',
            description: '1 mol 粒子数'
        });
        ConstantLib.addConstant({
            id: 'R_gas',
            symbol: 'R',
            name: '气体常数',
            value: '8.314462618',
            unit: 'J/(mol·K)',
            category: 'physics',
            description: '理想气体常数'
        });
        ConstantLib.addConstant({
            id: 'sigma_sb',
            symbol: 'σ',
            name: '斯特藩-玻尔兹曼',
            value: '5.670374419e-8',
            unit: 'W/(m²·K⁴)',
            category: 'physics',
            description: '辐射常数'
        });
        ConstantLib.addConstant({
            id: 'm_electron',
            symbol: 'mₑ',
            name: '电子质量',
            value: '9.1093837015e-31',
            unit: 'kg',
            category: 'physics',
            description: '电子静止质量'
        });
        ConstantLib.addConstant({
            id: 'm_proton',
            symbol: 'mₚ',
            name: '质子质量',
            value: '1.67262192369e-27',
            unit: 'kg',
            category: 'physics',
            description: '质子静止质量'
        });
        ConstantLib.addConstant({
            id: 'm_neutron',
            symbol: 'mₙ',
            name: '中子质量',
            value: '1.67492749804e-27',
            unit: 'kg',
            category: 'physics',
            description: '中子静止质量'
        });
        ConstantLib.addConstant({
            id: 'r_bohr',
            symbol: 'a₀',
            name: '玻尔半径',
            value: '5.29177210903e-11',
            unit: 'm',
            category: 'physics',
            description: '氢原子基态轨道半径'
        });
        // ── 化学常数 ─────────────────────────────────────────────────────
        ConstantLib.addConstant({
            id: 'atm',
            symbol: 'atm',
            name: '标准大气压',
            value: '101325',
            unit: 'Pa',
            category: 'chemistry',
            description: '1标准大气压'
        });
        ConstantLib.addConstant({
            id: 'stp_T',
            symbol: 'T₀',
            name: '标准温度',
            value: '273.15',
            unit: 'K',
            category: 'chemistry',
            description: '0°C 转 K'
        });
        ConstantLib.addConstant({
            id: 'water_mw',
            symbol: 'M(H₂O)',
            name: '水的摩尔质量',
            value: '18.01528',
            unit: 'g/mol',
            category: 'chemistry',
            description: 'H₂O 分子量'
        });
        ConstantLib.addConstant({
            id: 'c_water',
            symbol: 'cₚ(H₂O)',
            name: '水比热容',
            value: '4186',
            unit: 'J/(kg·K)',
            category: 'chemistry',
            description: '液态水比热容'
        });
        ConstantLib.addConstant({
            id: 'faraday',
            symbol: 'F',
            name: '法拉第常数',
            value: '96485.33212',
            unit: 'C/mol',
            category: 'chemistry',
            description: '1mol 电子的电荷量'
        });
        ConstantLib.addConstant({
            id: 'ryd',
            symbol: 'R∞',
            name: '里德堡常数',
            value: '10973731.568',
            unit: 'm⁻¹',
            category: 'chemistry',
            description: '原子光谱常数'
        });
        ConstantLib.initialized = true;
        getMathLogger().info('[ConstantLib] 常数库初始化完成，共加载 ' + ConstantLib.constants.size + ' 个常数');
    }
    /**
     * 添加常数到库中
     */
    public static addConstant(entry: ConstantEntry): void {
        // 检查重复符号
        if (ConstantLib.constants.has(entry.symbol)) {
            getMathLogger().warn(`[ConstantLib] 符号 "${entry.symbol}" 已存在，将被覆盖`);
        }
        // 检查重复 ID
        if (ConstantLib.idMap.has(entry.id)) {
            getMathLogger().warn(`[ConstantLib] ID "${entry.id}" 已存在，将被覆盖`);
        }
        ConstantLib.constants.set(entry.symbol, entry);
        ConstantLib.idMap.set(entry.id, entry);
    }
    /**
     * 从库中删除常数
     */
    public static removeConstant(symbol: string): boolean {
        const entry = ConstantLib.constants.get(symbol);
        if (entry) {
            ConstantLib.constants.delete(symbol);
            ConstantLib.idMap.delete(entry.id);
            return true;
        }
        return false;
    }
    /**
     * 根据符号获取常数条目
     */
    public static getConstant(symbol: string): ConstantEntry | undefined {
        return ConstantLib.constants.get(symbol);
    }
    /**
     * 根据 ID 获取常数条目
     */
    public static getConstantById(id: string): ConstantEntry | undefined {
        return ConstantLib.idMap.get(id);
    }
    /**
     * 获取所有常数符号列表
     */
    public static getAllSymbols(): string[] {
        return Array.from(ConstantLib.constants.keys());
    }
    /**
     * 获取所有常数条目
     */
    public static getAllConstants(): ConstantEntry[] {
        return Array.from(ConstantLib.constants.values());
    }
    /**
     * 按分类获取常数条目
     */
    public static getConstantsByCategory(category: string): ConstantEntry[] {
        return ConstantLib.getAllConstants().filter(entry => entry.category === category);
    }
    /**
     * 检查符号是否为常数
     */
    public static isConstant(symbol: string): boolean {
        return ConstantLib.constants.has(symbol);
    }
    /**
     * 获取常数值（数值字符串）
     */
    public static getConstantValue(symbol: string): string | undefined {
        const entry = ConstantLib.getConstant(symbol);
        return entry?.value;
    }
    /**
     * 在表达式中替换所有常数符号为数值
     */
    public static replaceConstantsInExpression(expr: string): string {
        let result = expr;
        // 按符号长度从长到短排序，避免部分匹配问题
        const symbols = ConstantLib.getAllSymbols().sort((a, b) => b.length - a.length);
        // 对于每个常数符号，构建正确的边界匹配
        for (const symbol of symbols) {
            const value = ConstantLib.getConstantValue(symbol);
            if (value) {
                const escaped = symbol.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
                // 构建边界：符号前不能是字母数字（除非是运算符或空格）
                // 符号后不能是字母数字（除非是运算符或空格）
                // 使用负向预测确保完整匹配
                let boundaryPattern = `(?<![a-zA-Z0-9.])${escaped}(?![a-zA-Z0-9])`;
                try {
                    const regex = new RegExp(boundaryPattern, 'g');
                    result = result.replace(regex, value);
                }
                catch (e) {
                    getMathLogger().warn(`[ConstantLib] 正则表达式错误 for ${symbol}: ${e}`);
                }
            }
        }
        return result;
    }
    /**
     * 获取所有常数分类
     */
    public static getAllCategories(): string[] {
        const categories = new Set<string>();
        for (const entry of ConstantLib.getAllConstants()) {
            categories.add(entry.category);
        }
        return Array.from(categories);
    }
    /**
     * 清理常数库
     */
    public static clear(): void {
        ConstantLib.constants.clear();
        ConstantLib.idMap.clear();
        ConstantLib.initialized = false;
    }
}
