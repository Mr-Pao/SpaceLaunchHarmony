/**
 * constants/ZhMaps.ets —— 中文译名映射表（翻译层数据）
 *
 * 逐条对位原项目 `utils/format.js` 的映射表常量，**条数与源文件完全一致**：
 *   CORE_STATUS 5 / NATION_ZH 61 / CHINA_ASTRO_ZH 31 / ROCKET_ZH 95 /
 *   CN_NUM 12 / CN_TAIL 5 / SERIES_ZH 27 / TERM_FIX 3 / ORBIT_ZH 18 /
 *   MISSION_TYPE_ZH 26 / CRAFT_TYPE_ZH 12 / CRAFT_STATUS_ZH 7 / DEST_ZH 24 /
 *   EVENT_TYPE_ZH 15 / COUNTRY_ZH 38 / AGENCY_ZH 30 / FINAL_STATUS 4 /
 *   PLACE_ZH 32 / STATION_ZH 8 / EVENT_TERM_FIX 19 / FLAG_RULES 20
 * （WEEK_ZH 不在这里：它一直是 utils/Format.ets 的模块内私有常量，见 todayLabel）
 *
 * 为什么用 Map 而不是对象字面量：
 *   ArkTS 禁止索引签名，`Record<string, string>` 只能做类型注解、不能 `new`，
 *   而 `obj[key]` 这种动态取值在 ArkTS 里也不允许 —— 一律 Map.get。
 *
 * 为什么还要类（PlaceRule / TermFix / FlagRule）：
 *   源文件里这几张表是「成对数组」且**顺序有意义**（PLACE_ZH 是子串优先级，
 *   FLAG_RULES 是首个命中生效），必须保序迭代，不能用无序 Map。
 *
 * ⚠ 本文件是纯数据，不含任何逻辑；取值函数在 utils/Format.ets。
 * ⚠ 改这里的条目必须同时改原项目 utils/format.js，两边条数要对得上（见 REPORT）。
 */

// ============ 表元素类型 ============
// ArkTS 禁索引签名、也不接受元组数组类型，所以「成对数组」用类承载。
// 这几个类只会被本文件与 utils/Format.ets 使用，字段全是 public。

/** 芯级状态：展示文案 + 样式类（对应源 CORE_STATUS 的 {text, cls}） */
export class CoreStatusEntry {
  text: string;
  /** ok / dim / bad —— 源项目 CSS 类名，鸿蒙侧由调用方映射到色调 */
  cls: string;

  constructor(text: string, cls: string) {
    this.text = text;
    this.cls = cls;
  }
}

/** 术语修正规则：正则 → 替换串（源 TERM_FIX / EVENT_TERM_FIX） */
export class TermFix {
  re: RegExp;
  to: string;

  constructor(re: RegExp, to: string) {
    this.re = re;
    this.to = to;
  }
}

/** 地点子串规则：命中小写 key 即返回中文（源 PLACE_ZH，**顺序即优先级**） */
export class PlaceRule {
  key: string;
  zh: string;

  constructor(key: string, zh: string) {
    this.key = key;
    this.zh = zh;
  }
}

/**
 * 国旗规则：正则 → ISO 两位小写码（源 FLAG_RULES，**首个命中生效**，顺序有意义）。
 *
 * 源文件注释交代了顺序的三个坑，改顺序前先读一遍：
 *   1. 朝鲜必须排在韩国前面，否则 "Korean Committee" 会被 🇰🇷 吃掉；
 *   2. 乌克兰排在俄罗斯前面，Yuzhnoye / Yuzhmash 是乌克兰的；
 *   3. "Rocket Lab USA" 要在美国组先拦掉，剩下的 Rocket Lab 才是新西兰。
 */
export class FlagRule {
  re: RegExp;
  code: string;

  constructor(re: RegExp, code: string) {
    this.re = re;
    this.code = code;
  }
}

/**
 * 芯级个体状态中文化。
 *
 * LL2 /launchers/ 的 status 是固定枚举（实测全库只出现 5 种）：
 * active 现役 / retired 退役 / expended 已消耗（设计上不回收，飞完即弃）/
 * lost 坠毁（回收失败）/ destroyed 炸毁（地面事故等）。查表不走翻译。
 */
export const CORE_STATUS: Map<string, CoreStatusEntry> = new Map<string, CoreStatusEntry>([
  ['active', new CoreStatusEntry('现役', 'ok')],
  ['retired', new CoreStatusEntry('退役', 'dim')],
  ['expended', new CoreStatusEntry('已消耗', 'dim')],
  ['lost', new CoreStatusEntry('坠毁', 'bad')],
  ['destroyed', new CoreStatusEntry('炸毁', 'bad')],
]);

/**
 * 宇航员国籍中文化。LL2 的 nationality_name 是 France / USA / Russia
 * 这类英文国名，只收航天员出过或常出的国家，未收录保留原文。
 */
export const NATION_ZH: Map<string, string> = new Map<string, string>([
  ['France', '法国'],
  ['USA', '美国'],
  ['United States', '美国'],
  ['Russia', '俄罗斯'],
  ['China', '中国'],
  ['Japan', '日本'],
  ['Italy', '意大利'],
  ['Germany', '德国'],
  ['Canada', '加拿大'],
  ['United Kingdom', '英国'],
  ['Sweden', '瑞典'],
  ['Netherlands', '荷兰'],
  ['Spain', '西班牙'],
  ['Belgium', '比利时'],
  ['Denmark', '丹麦'],
  ['Norway', '挪威'],
  ['Finland', '芬兰'],
  ['Poland', '波兰'],
  ['Czechia', '捷克'],
  ['Australia', '澳大利亚'],
  ['India', '印度'],
  ['Brazil', '巴西'],
  ['Israel', '以色列'],
  ['Kazakhstan', '哈萨克斯坦'],
  ['Ukraine', '乌克兰'],
  ['UAE', '阿联酋'],
  ['Saudi Arabia', '沙特阿拉伯'],
  ['South Korea', '韩国'],
  ['Vietnam', '越南'],
  ['Cuba', '古巴'],
  ['Mongolia', '蒙古'],
  ['Syria', '叙利亚'],
  ['Afghanistan', '阿富汗'],
  ['South Africa', '南非'],
  ['Mexico', '墨西哥'],
  ['Switzerland', '瑞士'],
  ['Austria', '奥地利'],
  ['Bulgaria', '保加利亚'],
  ['Romania', '罗马尼亚'],
  ['Hungary', '匈牙利'],
  ['Slovakia', '斯洛伐克'],
  // 形容词兜底：LL2 的 nationality_name 是这一形态，slim 优先取国名，
  // 但国名缺失或旧数据只有形容词时也能命中
  ['American', '美国'],
  ['French', '法国'],
  ['Russian', '俄罗斯'],
  ['Chinese', '中国'],
  ['British', '英国'],
  ['Swiss', '瑞士'],
  ['Swedish', '瑞典'],
  ['Italian', '意大利'],
  ['German', '德国'],
  ['Japanese', '日本'],
  ['Canadian', '加拿大'],
  ['Spanish', '西班牙'],
  ['Dutch', '荷兰'],
  ['Belgian', '比利时'],
  ['Danish', '丹麦'],
  ['Norwegian', '挪威'],
  ['Finnish', '芬兰'],
  ['Polish', '波兰'],
  ['Australian', '澳大利亚'],
  ['United States of America', '美国'],
]);

/**
 * 中国航天员的中文名。
 *
 * LL2 全站只给拼音（Zhu Yangzhu），中国用户看到「Zhu Yangzhu」基本认不出是谁，
 * 而拼音转汉字有大量同音字，程序推不出来，只能查表。
 *
 * 全表已按神舟一号至神舟二十三号的乘组名单逐个核对（2026-10-25）。
 * 香港用粤语拼音（Lai Ka-ying），与普通话拼音规律不同。
 * LL2 里还有一位 'Justin Sun' 标为中国籍，身份无法确认，故意不收录 ——
 * 表里没有的中国人保留拼音原文：宁可显示拼音，也不要编一个错的名字。
 *
 * 表里没有的中国人保留拼音原文：宁可显示拼音，也不要编一个错的名字。
 */
export const CHINA_ASTRO_ZH: Map<string, string> = new Map<string, string>([
  ['Yang Liwei', '杨利伟'],
  ['Fei Junlong', '费俊龙'],
  ['Nie Haisheng', '聂海胜'],
  ['Zhai Zhigang', '翟志刚'],
  ['Liu Boming', '刘伯明'],
  ['Jing Haipeng', '景海鹏'],
  ['Liu Wang', '刘旺'],
  ['Liu Yang', '刘洋'],
  ['Wang Yaping', '王亚平'],
  ['Zhang Xiaoguang', '张晓光'],
  ['Chen Dong', '陈冬'],
  ['Deng Qingming', '邓清明'],
  ['Zhang Lu', '张陆'],
  ['Ye Guangfu', '叶光富'],
  ['Tang Hongbo', '汤洪波'],
  ['Cai Xuzhe', '蔡旭哲'],
  ['Zhu Yangzhu', '朱杨柱'],
  ['Gui Haichao', '桂海潮'],
  ['Tang Shengjie', '唐胜杰'],
  ['Jiang Xinlin', '江新林'],
  ['Li Cong', '李聪'],
  ['Li Guangsu', '李广苏'],
  ['Song Lingdong', '宋令东'],
  ['Wang Haozhe', '王浩泽'],
  ['Chen Zhongrui', '陈中瑞'],
  // —— 神舟二十一号及以后（LL2 新录入批次，已核对） ——
  ['Wang Jie', '王杰'],
  ['Chen Quan', '陈全'],
  ['Wu Fei', '武飞'],
  ['Zhang Hongzhang', '张洪章'],
  ['Zhang Zhiyuan', '张志远'],
  ['Lai Ka-ying', '黎家盈'],
]);

/**
 * 中国运载火箭的中文名。
 *
 * 只收「确定无疑」的型号：朱雀、谷神星、快舟。
 * Kinetica / Pallas / Gravity 这类英文译名在不同资料里对不上具体中文名，
 * 与其猜错不如保留英文原文 —— 译错了比不译更糟。
 *
 * 长征系列不写在这里：型号库里有 44 个 Long March 变体（含上面级组合），
 * 一条条列既列不全又容易漏改，改成下面的规则推导。
 * 型号名属于固定枚举，走本地查表，不占翻译额度。
 */
export const ROCKET_ZH: Map<string, string> = new Map<string, string>([
  // ---- 美国 ----
  ['Falcon 9', '猎鹰 9 号'],
  ['Falcon Heavy', '猎鹰重型'],
  ['Falcon 1', '猎鹰 1 号'],
  ['Starship', '星舰'],
  ['Space Launch System (SLS)', '太空发射系统'],
  ['Space Launch System', '太空发射系统'],
  ['Electron', '电子号'],
  ['Atlas V', '宇宙神 5 号'],
  ['Atlas V N22', '宇宙神 5 号'],
  ['Atlas III', '宇宙神 3 号'],
  ['Delta IV', '德尔塔 4 号'],
  ['Delta IV Heavy', '德尔塔 4 重型'],
  ['Delta II', '德尔塔 2 号'],
  ['Vulcan', '火神'],
  ['Vulcan VC2S', '火神 VC2S'],
  ['Vulcan VC4L', '火神 VC4L'],
  ['New Glenn', '新格伦'],
  ['Antares', '心宿二'],
  ['Pegasus', '飞马座'],
  ['Minotaur I', '牛头怪 1 号'],
  ['Minotaur IV', '牛头怪 4 号'],
  ['Minotaur V', '牛头怪 5 号'],
  ['Minotaur-C', '牛头怪 C'],
  ['Alpha', '阿尔法'],
  ['Terran 1', '人族 1 号'],
  ['Neutron', '中子'],
  ['SpaceShipTwo', '太空船二号'],
  ['Space Shuttle', '航天飞机'],
  ['Saturn V', '土星五号'],
  ['Titan', '泰坦'],
  // ---- 欧洲 ----
  ['Ariane 1', '阿丽亚娜 1 号'],
  ['Ariane 2', '阿丽亚娜 2 号'],
  ['Ariane 3', '阿丽亚娜 3 号'],
  ['Ariane 4', '阿丽亚娜 4 号'],
  ['Ariane 5', '阿丽亚娜 5 号'],
  ['Ariane 6', '阿丽亚娜 6 号'],
  ['Ariane 62', '阿丽亚娜 62'],
  ['Ariane 64', '阿丽亚娜 64'],
  ['Vega', '织女星'],
  ['Vega-C', '织女星 C'],
  // ---- 俄罗斯 ----
  ['Soyuz', '联盟号'],
  ['Soyuz 2', '联盟 2 号'],
  ['Soyuz-FG', '联盟 FG'],
  ['Soyuz-U', '联盟 U'],
  ['Proton-M', '质子 M'],
  ['Proton-M Briz-M', '质子 M'],
  ['Proton', '质子号'],
  ['Angara A5', '安加拉 A5'],
  ['Angara A5/Briz-M', '安加拉 A5'],
  ['Angara', '安加拉'],
  ['Soyuz 2.1a', '联盟 2.1a'],
  ['Soyuz 2.1b', '联盟 2.1b'],
  ['Soyuz-5', '联盟 5 号'],
  ['Soyuz-2', '联盟 2 号'],
  ['Zenit', '天顶号'],
  ['Rokot', '轰鸣'],
  ['Energia', '能源号'],
  // ---- 日本 ----
  ['Epsilon', '艾普西龙'],
  // ---- 印度 ----
  ['PSLV', '极地卫星运载火箭'],
  ['LVM-3 (GSLV Mk III)', 'LVM-3'],
  ['GSLV', '地球同步卫星运载火箭'],
  // ---- 中国商业航天（长征走 zhLongMarch 规则推导，这里只钉特例）----
  ['Long March 5B', '长征五号B'],
  ['Long March 5B/YZ-2', '长征五号B/YZ-2'],
  ['Zhuque-2', '朱雀二号'],
  ['Zhuque-2E', '朱雀二号E'],
  ['Zhuque-2E Block 2', '朱雀二号E'],
  ['Zhuque-3', '朱雀三号'],
  ['Ceres-1', '谷神星一号'],
  ['Ceres-1S', '谷神星一号S'],
  ['Ceres-2', '谷神星二号'],
  ['Kuaizhou 1A', '快舟一号甲'],
  ['Kuaizhou 11', '快舟十一号'],
  ['Kinetica 1', '力箭一号'],
  ['Firefly Alpha', '萤火虫阿尔法'],
  ['Miura 5', '米乌拉 5 号'],
  ['Astra Rocket 4', '阿斯特拉火箭 4 号'],
  ['Nova', '新星'],
  ['Nuri', '世界号'],
  ['KSLV-2 Nuri', '世界号'],
  ['Hyperbola-1', '双曲线一号'],
  ['Hyperbola-2', '双曲线二号'],
  ['Hyperbola-3', '双曲线三号'],
  ['Gravity-1', '引力一号'],
  ['Gravity-2', '引力二号'],
  ['Tianlong-2', '天龙二号'],
  ['Tianlong-3', '天龙三号'],
  ['Lijian-1', '力箭一号'],
  ['Kinetica-1', '力箭一号'],
  ['Kinetica 2', '力箭二号'],
  ['Kaituo-1A', '开拓一号甲'],
  ['Jielong-3', '捷龙三号'],
  ['Smart Dragon 1', '捷龙一号'],
  ['Smart Dragon 3', '捷龙三号'],
  ['Pallas-1', '帕拉斯一号'],
  ['Nebula-1', '星云一号'],
]);

/**
 * 长前缀优先的 key 列表（"Atlas V" 先于 "Atlas"）。
 *
 * 源文件是运行时 `Object.keys(ROCKET_ZH).sort((a,b)=>b.length-a.length)`；
 * 这里改成生成期排好序的常量数组：ArkTS 里 Map 没有稳定的 keys() 迭代保证，
 * 而且每次调用都重排一遍也浪费（原项目 P2-2 就是为这个改的）。
 * 排序稳定性与源一致（同长度保持表内顺序，V8 的 sort 是稳定的）。
 */
export const ROCKET_ZH_PREFIX_KEYS: string[] = [
  'Space Launch System (SLS)',
  'Space Launch System',
  'LVM-3 (GSLV Mk III)',
  'Long March 5B/YZ-2',
  'Zhuque-2E Block 2',
  'Angara A5/Briz-M',
  'Proton-M Briz-M',
  'Delta IV Heavy',
  'Astra Rocket 4',
  'Smart Dragon 1',
  'Smart Dragon 3',
  'Space Shuttle',
  'Long March 5B',
  'Firefly Alpha',
  'Falcon Heavy',
  'SpaceShipTwo',
  'Atlas V N22',
  'Vulcan VC2S',
  'Vulcan VC4L',
  'Minotaur IV',
  'Kuaizhou 1A',
  'Kuaizhou 11',
  'KSLV-2 Nuri',
  'Hyperbola-1',
  'Hyperbola-2',
  'Hyperbola-3',
  'Minotaur I',
  'Minotaur V',
  'Minotaur-C',
  'Soyuz 2.1a',
  'Soyuz 2.1b',
  'Kinetica 1',
  'Tianlong-2',
  'Tianlong-3',
  'Kinetica-1',
  'Kinetica 2',
  'Atlas III',
  'New Glenn',
  'Ariane 62',
  'Ariane 64',
  'Angara A5',
  'Zhuque-2E',
  'Gravity-1',
  'Gravity-2',
  'Kaituo-1A',
  'Jielong-3',
  'Falcon 9',
  'Falcon 1',
  'Starship',
  'Electron',
  'Delta IV',
  'Delta II',
  'Terran 1',
  'Saturn V',
  'Ariane 1',
  'Ariane 2',
  'Ariane 3',
  'Ariane 4',
  'Ariane 5',
  'Ariane 6',
  'Soyuz-FG',
  'Proton-M',
  'Zhuque-2',
  'Zhuque-3',
  'Ceres-1S',
  'Lijian-1',
  'Pallas-1',
  'Nebula-1',
  'Atlas V',
  'Antares',
  'Pegasus',
  'Neutron',
  'Soyuz 2',
  'Soyuz-U',
  'Soyuz-5',
  'Soyuz-2',
  'Energia',
  'Epsilon',
  'Ceres-1',
  'Ceres-2',
  'Miura 5',
  'Vulcan',
  'Vega-C',
  'Proton',
  'Angara',
  'Alpha',
  'Titan',
  'Soyuz',
  'Zenit',
  'Rokot',
  'Vega',
  'PSLV',
  'GSLV',
  'Nova',
  'Nuri',
];

export const CN_NUM: Map<string, string> = new Map<string, string>([
  ['1', '一'],
  ['2', '二'],
  ['3', '三'],
  ['4', '四'],
  ['5', '五'],
  ['6', '六'],
  ['7', '七'],
  ['8', '八'],
  ['9', '九'],
  ['10', '十'],
  ['11', '十一'],
  ['12', '十二'],
]);

export const CN_TAIL: Map<string, string> = new Map<string, string>([
  ['A', '甲'],
  ['B', '乙'],
  ['C', '丙'],
  ['D', '丁'],
  ['E', '戊'],
]);

/**
 * 系列名的中文显示。
 *
 * 和 rocketName 一样只收确定的译名：译错比不译更糟。
 * 长征走规则推导（"Long March 2" → 长征二号），其余查表，未命中保留英文。
 */
export const SERIES_ZH: Map<string, string> = new Map<string, string>([
  ['Falcon', '猎鹰'],
  ['Falcon 1', '猎鹰1号'],
  ['Falcon 9', '猎鹰9号'],
  ['Falcon Heavy', '猎鹰重型'],
  ['Starship', '星舰'],
  ['Electron', '电子号'],
  ['Neutron', '中子号'],
  ['Soyuz 2', '联盟二号'],
  ['Soyuz', '联盟号'],
  ['Proton / UR-500', '质子号'],
  ['Ariane 1', '阿丽亚娜1号'],
  ['Ariane 2', '阿丽亚娜2号'],
  ['Ariane 3', '阿丽亚娜3号'],
  ['Ariane 4', '阿丽亚娜4号'],
  ['Ariane 5', '阿丽亚娜5号'],
  ['Ariane 6', '阿丽亚娜6号'],
  ['Vulcan', '火神'],
  ['New Glenn', '新格伦'],
  ['Atlas V', '宇宙神五号'],
  ['Delta II', '德尔塔二号'],
  ['Delta IV', '德尔塔四号'],
  ['Zhuque', '朱雀'],
  ['Zhuque-2', '朱雀二号'],
  ['Zhuque-3', '朱雀三号'],
  ['Ceres-1', '谷神星一号'],
  ['Kuaizhou 1', '快舟一号'],
  ['Kuaizhou 11', '快舟十一号'],
]);

/**
 * 机翻术语修正
 *
 * 任务名走的是通用翻译接口，几个高频词固定译错：
 *   Starlink Group 15-15 → 「星链集团 15-15」（Group 是「组」不是「集团」）
 *   Unknown Payload      → 「未知有效负载」（航天标准说法是「有效载荷」）
 * 只修这两种最常见的，不追求逐条人工润色。
 */
export const TERM_FIX: TermFix[] = [
  new TermFix(new RegExp('星链集团', 'g'), '星链'),
  new TermFix(new RegExp('有效负载', 'g'), '有效载荷'),
  new TermFix(new RegExp('未知负载', 'g'), '未知载荷'),
];

/**
 * 目标轨道的中文名
 *
 * LL2 的 orbit 是固定枚举（约 15 个），本地查表最稳：
 * 走翻译接口反而会把 LEO 翻成乱七八糟的东西。
 * 查不到就原样返回，别瞎编。
 */
export const ORBIT_ZH: Map<string, string> = new Map<string, string>([
  ['low earth orbit', '近地轨道'],
  ['medium earth orbit', '中地球轨道'],
  ['geostationary orbit', '地球同步轨道'],
  ['geostationary transfer orbit', '地球同步转移轨道'],
  ['geosynchronous orbit', '地球同步轨道'],
  ['geosynchronous transfer orbit', '地球同步转移轨道'],
  ['highly elliptical orbit', '高椭圆轨道'],
  ['elliptical orbit', '椭圆轨道'],
  ['polar orbit', '极地轨道'],
  ['sun-synchronous orbit', '太阳同步轨道'],
  ['solar synchronous orbit', '太阳同步轨道'],
  ['lunar orbit', '月球轨道'],
  ['heliocentric orbit', '日心轨道'],
  ['suborbital', '亚轨道'],
  ['suborbital trajectory', '亚轨道'],
  ['unknown', '未知'],
  ['retrograde orbit', '逆行轨道'],
  ['equatorial orbit', '赤道轨道'],
]);

/**
 * 任务类型的中文名
 *
 * LL2 的 mission.type 是英文枚举（"Communications" / "Government/Top Secret"…），
 * 同步阶段没翻它（只翻了任务名和描述），本地表兜住常见的，
 * 表外的保留英文 —— 总比翻错了强。
 */
export const MISSION_TYPE_ZH: Map<string, string> = new Map<string, string>([
  ['communications', '通信'],
  ['earth observation', '对地观测'],
  ['navigation', '导航'],
  ['science', '科学'],
  ['astrophysics', '天体物理'],
  ['planetary science', '行星科学'],
  ['human exploration', '载人探索'],
  ['lunar exploration', '月球探索'],
  ['robotic exploration', '机器人探索'],
  ['solar physics', '太阳物理'],
  ['government/top secret', '政府/保密'],
  ['government', '政府'],
  ['military', '军事'],
  ['test flight', '试飞'],
  ['test', '试验'],
  ['resupply', '货运补给'],
  ['crew', '载人'],
  ['dedicated rideshare', '专享拼车'],
  ['rideshare', '拼车'],
  ['technology', '技术验证'],
  ['materials science', '材料科学'],
  ['biology', '生物'],
  ['education', '教育'],
  ['engineering', '工程'],
  ['demonstration', '演示验证'],
  ['other', '其他'],
]);

/**
 * 航天器（飞船 / 载荷本体）的三个封闭枚举
 *
 * 只在单条详情里才有（rocket.spacecraft_stage），由 scripts/timeline.js 顺路抓。
 * 名称本身（Crew Dragon C204 / 长征 XX）保留原文：航天器的官方代号没有约定俗成的
 * 中译，硬翻反而认不出来。只翻「类型 / 状态 / 目的地」这种有限集合。
 */
export const CRAFT_TYPE_ZH: Map<string, string> = new Map<string, string>([
  ['capsule', '载人舱'],
  ['spaceplane', '航天飞机'],
  ['lander', '着陆器'],
  ['rover', '巡视器'],
  ['satellite', '卫星'],
  ['probe', '探测器'],
  ['space station', '空间站'],
  ['station module', '空间站舱段'],
  ['tug', '太空拖船'],
  ['cargo spacecraft', '货运飞船'],
  ['manned spacecraft', '载人飞船'],
  ['unmanned spacecraft', '无人飞船'],
]);

export const CRAFT_STATUS_ZH: Map<string, string> = new Map<string, string>([
  ['active', '在役'],
  ['retired', '已退役'],
  ['destroyed', '已损毁'],
  ['lost', '已失联'],
  ['preserved', '封存展示'],
  ['under construction', '建造中'],
  ['in development', '研制中'],
]);

export const DEST_ZH: Map<string, string> = new Map<string, string>([
  ['international space station', '国际空间站'],
  ['moon', '月球'],
  ['lunar orbit', '月球轨道'],
  ['lunar surface', '月面'],
  ['mars', '火星'],
  ['mars orbit', '火星轨道'],
  ['mercury', '水星'],
  ['mercury orbit', '水星轨道'],
  ['venus', '金星'],
  ['venus orbit', '金星轨道'],
  ['jupiter', '木星'],
  ['jupiter orbit', '木星轨道'],
  ['saturn', '土星'],
  ['saturn orbit', '土星轨道'],
  ['ganymede', '木卫三'],
  ['ganymede orbit', '木卫三轨道'],
  ['europa', '木卫二'],
  ['titan', '土卫六'],
  ['sun-earth l1', '日地 L1 点'],
  ['sun-earth l2', '日地 L2 点'],
  ['trans-lunar injection', '地月转移轨道'],
  ['low earth orbit', '近地轨道'],
  ['suborbital trajectory', '亚轨道'],
  ['heliocentric orbit', '日心轨道'],
]);

/**
 * 活动类型中文名（events.json 里的 type.name）。
 *
 * 实测 27 条活动只有 9 种类型，全是「航天器正在做什么」这类描述：
 * Orbital Insertion / Spacecraft Berthing / Flyby —— 直接摆英文，
 * 中文用户读不出重点。命中不到就回英文原串，不硬归成「其他」。
 */
export const EVENT_TYPE_ZH: Map<string, string> = new Map<string, string>([
  ['eva', '舱外活动'],
  ['flyby', '飞掠'],
  ['docking', '对接'],
  ['undocking', '分离'],
  ['landing', '着陆'],
  ['launch', '发射'],
  ['orbital insertion', '入轨'],
  ['spacecraft landing', '航天器着陆'],
  ['spacecraft docking', '航天器对接'],
  ['spacecraft undocking', '航天器分离'],
  ['spacecraft berthing', '航天器停靠'],
  ['spacecraft release', '航天器释放'],
  ['spacecraft event', '航天器事件'],
  ['deep space maneuver', '深空机动'],
  ['trajectory correction maneuver', '轨道修正'],
]);

/**
 * 发射所在国家/地区的中文名。
 *
 * 快照里的国家信息只有一个来源：`pad.location.name`，形如
 * "Vandenberg SFB, CA, USA" / "Jiuquan, People's Republic of China"，
 * 取最后一个逗号后面的那一段。没有独立的 country 字段（LL2 有，但瘦身后没留）。
 *
 * 这一段的取值并不总是国家名：
 *   - "Andøya Spaceport" / "Esrange Space Center" 是发射场名（挪威 / 瑞典）；
 *   - "Sea Launch" 是海上平台，没有国家；
 *   - "Moon" 是目的地，出现在月球任务上。
 * 所以既要有映射表，也要有无命中时的原文兜底 —— 宁可显示英文，也不要瞎归因。
 */
export const COUNTRY_ZH: Map<string, string> = new Map<string, string>([
  ['USA', '美国'],
  ['United States', '美国'],
  ['United States of America', '美国'],
  ['People\'s Republic of China', '中国'],
  ['China', '中国'],
  ['Haiyang Oriental Spaceport', '中国'],
  ['Russian Federation', '俄罗斯'],
  ['Russia', '俄罗斯'],
  ['USSR', '苏联'],
  ['Republic of Kazakhstan', '哈萨克斯坦'],
  ['Kazakhstan', '哈萨克斯坦'],
  ['New Zealand', '新西兰'],
  ['India', '印度'],
  ['Japan', '日本'],
  ['South Korea', '韩国'],
  ['Republic of Korea', '韩国'],
  ['French Guiana', '法属圭亚那'],
  ['Andøya Spaceport', '挪威'],
  ['Norway', '挪威'],
  ['Esrange Space Center', '瑞典'],
  ['Sweden', '瑞典'],
  ['Sea Launch', '海上发射'],
  ['Kenya', '肯尼亚'],
  ['Iran', '伊朗'],
  ['Israel', '以色列'],
  ['Brazil', '巴西'],
  ['Alcantara', '巴西'],
  ['Australia', '澳大利亚'],
  ['Marshall Islands', '马绍尔群岛'],
  ['Kwajalein', '马绍尔群岛'],
  ['Wallops Island', '美国'],
  ['Mexico', '墨西哥'],
  ['Argentina', '阿根廷'],
  ['Spain', '西班牙'],
  ['Italy', '意大利'],
  ['Germany', '德国'],
  ['United Kingdom', '英国'],
  ['Moon', '月球'],
]);

/**
 * 常见发射机构的中文短名。
 *
 * LL2 给的是官方长名，比如 "China Aerospace Science and Technology Corporation"，
 * 在筛选抽屉的横向 chip 里一行都放不下一个，一排英文长句看着就是一团乱。
 * 这里只收常见的大机构，其余保留原文 —— 译错机构名比不译更糟。
 * 只影响显示，筛选用的值始终是原始英文名。
 */
export const AGENCY_ZH: Map<string, string> = new Map<string, string>([
  ['China Aerospace Science and Technology Corporation', '中国航天科技'],
  ['China Aerospace Science and Industry Corporation', '中国航天科工'],
  ['China Rocket Co. Ltd.', '中国火箭'],
  ['ExPace', '航天科工火箭'],
  ['Landspace', '蓝箭航天'],
  ['Galactic Energy', '星河动力'],
  ['Space Pioneer', '天兵科技'],
  ['i-Space', '星际荣耀'],
  ['Deep Blue Aerospace', '深蓝航天'],
  ['Orienspace', '东方空间'],
  ['United Launch Alliance', 'ULA'],
  ['Rocket Lab', '火箭实验室'],
  ['Indian Space Research Organization', '印度空间研究组织'],
  ['Russian Federal Space Agency (ROSCOSMOS)', '俄罗斯航天局'],
  ['European Space Agency', '欧空局'],
  ['Japan Aerospace Exploration Agency', 'JAXA'],
  ['National Aeronautics and Space Administration', 'NASA'],
  ['Agency for Defense Development', '韩国国防科学研究所'],
  ['Korea Aerospace Research Institute', '韩国航空宇宙研究院'],
  ['Mitsubishi Heavy Industries', '三菱重工'],
  ['Firefly Aerospace', '萤火虫航天'],
  ['Relativity Space', '相对论空间'],
  ['Blue Origin', '蓝色起源'],
  ['Rocket Factory Augsburg', 'RFA'],
  ['Isar Aerospace', 'Isar'],
  ['ArianeGroup', '阿丽亚娜集团'],
  ['Space One', '太空一号'],
  ['Interstellar Technologies', '星际科技'],
  ['Virgin Galactic', '维珍银河'],
  ['Sea Launch', '海上发射'],
]);

export const FINAL_STATUS: string[] = [
  'Success',
  'Failure',
  'Deployed',
  'Partial',
];

/**
 * 发射场地名中文化。
 *
 * pad.location 是「场地, 州, 国」的整串（"Cape Canaveral SFS, FL, USA"），
 * 和机构那种精确 key 不同，只能拿已知地名的子串去比。
 * 命不中就原样返回 —— 宁可不翻，也不要把地点翻错。
 */
export const PLACE_ZH: PlaceRule[] = [
  new PlaceRule('cape canaveral', '卡纳维拉尔角'),
  new PlaceRule('kennedy space center', '肯尼迪航天中心'),
  new PlaceRule('vandenberg', '范登堡'),
  new PlaceRule('starbase', '星际基地'),
  new PlaceRule('boca chica', '博卡奇卡'),
  new PlaceRule('wallops', '沃洛普斯'),
  new PlaceRule('pacific spaceport', '太平洋航天港'),
  new PlaceRule('mojave', '莫哈韦'),
  new PlaceRule('jiuquan', '酒泉卫星发射中心'),
  new PlaceRule('taiyuan', '太原卫星发射中心'),
  new PlaceRule('xichang', '西昌卫星发射中心'),
  new PlaceRule('wenchang', '文昌航天发射场'),
  new PlaceRule('hainan commercial', '海南商业航天发射场'),
  new PlaceRule('baikonur', '拜科努尔航天发射场'),
  new PlaceRule('plesetsk', '普列谢茨克航天发射场'),
  new PlaceRule('vostochny', '东方航天发射场'),
  new PlaceRule('kapustin yar', '卡普斯京亚尔'),
  new PlaceRule('kourou', '库鲁航天中心'),
  new PlaceRule('tanegashima', '种子岛宇宙中心'),
  new PlaceRule('uchinoura', '内之浦宇宙空间观测所'),
  new PlaceRule('satish dhawan', '萨迪什·达万航天中心'),
  new PlaceRule('sriharikota', '斯里哈里科塔'),
  new PlaceRule('mahia', '马希亚半岛'),
  new PlaceRule('naro', '罗老宇宙中心'),
  new PlaceRule('semnan', '塞姆南'),
  new PlaceRule('imam khomeini', '伊玛目霍梅尼航天中心'),
  new PlaceRule('palmachim', '帕勒马希姆'),
  new PlaceRule('alcantara', '阿尔坎塔拉发射中心'),
  new PlaceRule('esrange', '埃斯兰奇'),
  new PlaceRule('andoya', '安岛航天港'),
  new PlaceRule('woomera', '伍默拉'),
  new PlaceRule('sutherland', '萨瑟兰'),
];

/**
 * 空间站中文名。
 *
 * LL2 的空间站数据只有简介（descZh）中文化了，名称本身没有译文字段，
 * 一共 15 个站，手写对照表最准：Salyut 1-7 用规则推导，其余逐个钉住。
 */
export const STATION_ZH: Map<string, string> = new Map<string, string>([
  ['International Space Station', '国际空间站'],
  ['Tiangong space station', '中国空间站'],
  ['Tiangong 1', '天宫一号'],
  ['Tiangong 2', '天宫二号'],
  ['Mir', '和平号空间站'],
  ['Skylab', '天空实验室'],
  ['Genesis I', '创世纪一号'],
  ['Genesis II', '创世纪二号'],
]);

/**
 * 活动名术语纠正。
 *
 * 机翻在几个航天专名上会翻车：
 *   JUICE（木星冰月探测器）→ 「果汁」
 *   Europa Clipper → 「欧罗巴快艇」（官方是「欧罗巴快船」）
 *   Orbit Insertion → 「轨道插入」（应作「入轨」）
 *   Reentry → 「重返」（应作「再入」）
 * 数据层的 nameZh 是批量生成的，改一次要重跑整轮，所以在展示层做后处理，
 * 新增活动也自动生效。
 */
export const EVENT_TERM_FIX: TermFix[] = [
  new TermFix(new RegExp('果汁', 'g'), 'JUICE '),
  new TermFix(new RegExp('欧罗巴快艇', 'g'), '欧罗巴快船'),
  new TermFix(new RegExp('木星冰冷卫星探测器', 'g'), '木星冰月探测器'),
  new TermFix(new RegExp('木星冰卫星探测器', 'g'), '木星冰月探测器'),
  new TermFix(new RegExp('轨道插入', 'g'), '入轨'),
  new TermFix(new RegExp('释放和重返', 'g'), '释放与再入'),
  new TermFix(new RegExp('重返大气', 'g'), '再入大气'),
  new TermFix(new RegExp('重新进入地球大气层', 'g'), '再入地球大气层'),
  new TermFix(new RegExp('脱轨燃烧', 'g'), '离轨点火'),
  new TermFix(new RegExp('发动机燃烧', 'g'), '发动机点火'),
  new TermFix(new RegExp('重力辅助', 'g'), '引力助推'),
  new TermFix(new RegExp('贝皮科伦坡(?!号)', 'g'), '贝皮科伦坡号'),
  new TermFix(new RegExp('隼鸟二号', 'g'), '隼鸟 2 号'),
  new TermFix(new RegExp('露西(?:·)?特洛伊', 'g'), '露西号 · 特洛伊'),
  new TermFix(new RegExp('波音\\s*Starliner', 'g'), '波音星际客机'),
  new TermFix(new RegExp('SNC-1追梦者', 'g'), 'SNC-1 追梦者'),
  new TermFix(new RegExp('美国EVA', 'g'), '美国 EVA'),
  new TermFix(new RegExp('冲击$', 'g'), '撞击'),
  new TermFix(new RegExp('的的', 'g'), '的'),
];

/**
 * 机构国籍 → 国旗 emoji。
 *
 * 数据里没有国别字段：launcher 只有 manufacturer 字符串，
 * launch_service_provider 只有 id + name，所以只能靠名字认。
 * 认不出返回空串，模板里对应节点直接不渲染，不会留空位。
 *
 * 顺序有讲究：
 *   · 朝鲜必须排在韩国前面，否则 "Korean Committee" 会被 🇰🇷 吃掉；
 *   · 乌克兰排在俄罗斯前面，Yuzhnoye / Yuzhmash 是乌克兰的；
 *   · 具体国家排在「欧洲」前面，否则 ArianeGroup 会全落到 🇪🇺；
 *   · "Rocket Lab USA" 要在中国 / 美国组里先拦掉，剩下的 Rocket Lab 才是新西兰。
 */
export const FLAG_RULES: FlagRule[] = [
  new FlagRule(new RegExp('china|casc|casic|land ?space|galactic energy|i-?space|cas space|expace|orienspace|space pioneer|deep blue|one ?space|kuaizhou|zhuque|ceres|hyperbola|gravity|tianlong|jielong|kinetica|pallas|lijian|kaituo|chinese', 'i'), 'cn'),
  new FlagRule(new RegExp('spacex|united launch|\\bula\\b|blue origin|northrop|orbital (sciences|atk)|firefly|astra space|relativity|stoke|masten|lockheed|martin marietta|mcdonnell|convair|vought|chrysler|boeing|general dynamics|nasa|national aeronautics|air force|virgin (orbit|galactic)|abl space|phantom space|kodiak|rocket lab usa|space systems', 'i'), 'us'),
  new FlagRule(new RegExp('yuzhnoye|yuzhmash|ukrain', 'i'), 'ua'),
  new FlagRule(new RegExp('khrunichev|progress rocket|energia|roskosmos|russian|makeyev|strategic rocket|soviet|moscow institute|chemical automatics', 'i'), 'ru'),
  new FlagRule(new RegExp('dprk|north korea|korean committee of space', 'i'), 'kp'),
  new FlagRule(new RegExp('korea|kari|innospace|perigee', 'i'), 'kr'),
  new FlagRule(new RegExp('mitsubishi|jaxa|japan aerospace|isas|institute of space and astronautical|interstellar technologies|ihi|japanese', 'i'), 'jp'),
  new FlagRule(new RegExp('indian space|isro|skyroot|agnikul|dhruva|india', 'i'), 'in'),
  new FlagRule(new RegExp('rocket lab', 'i'), 'nz'),
  new FlagRule(new RegExp('israel|\\biai\\b', 'i'), 'il'),
  new FlagRule(new RegExp('iran', 'i'), 'ir'),
  new FlagRule(new RegExp('brazil|conae|argentina', 'i'), 'br'),
  new FlagRule(new RegExp('aérospatiale|aerospatiale|latitude|maia space|hyprspace', 'i'), 'fr'),
  new FlagRule(new RegExp('hyimpulse|isar aerospace|rocket factory|ohb|augsburg', 'i'), 'de'),
  new FlagRule(new RegExp('avio', 'i'), 'it'),
  new FlagRule(new RegExp('skyrora|orbex', 'i'), 'gb'),
  new FlagRule(new RegExp('pld space|payload aerospace', 'i'), 'es'),
  new FlagRule(new RegExp('andøya|andoya|nammo', 'i'), 'no'),
  new FlagRule(new RegExp('swedish space|esrange', 'i'), 'se'),
  new FlagRule(new RegExp('\\besa\\b|european (space|launcher)|arianespace|arianegroup|eldo', 'i'), 'eu'),
];
