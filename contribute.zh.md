# 参与开发：核心模块与设计原则

[English](contribute.en.md) | 中文

用法请先读 [README.zh.md](README.zh.md)。本文讲代码怎么组织、为什么这么设计。
语义定稿在上层 runspeccpu 仓库的 `docs/config-refactor.md`（语义）、
`docs/config-examples.md`（语法）、`docs/render-flow.md`（执行流）——
**语义疑问以 docs 为准，用法疑问以 README 与测试为准**。

## 1. 模块地图

依赖方向自上而下，无环；`main.rkt` 汇总导出全部。

| 模块 | 职责 | 关键导出 |
|---|---|---|
| `source.rkt` | 消费协议：一切配置表示的最小公约面 | `gen:config-source`（`suite`/`ref`/`explicit?`/`keys`）、`source-missing` 哨兵 |
| `config.rkt` | 内核：定义、组合、求解 | `define-config`、`config`、`resolve`、查询面（`resolved-*`、`provenance-ref`）、裁决构造子（`fail`/`warn`/`skip`） |
| `loader.rkt` | `.config` 文法：解析 + 沙箱 + 包含检查 | `load-config`、`current-config-search-heads`、`current-config-registry` |
| `validators.rkt` | 声明检查组合子（富裁决内建，注入 `.config` 沙箱） | `one-of`、`integer-between`、`require-filled`、... |
| `probe.rkt` | 宿主探测：唯一显式不纯步，探测记录一等值 | `probe-fields`、`make-probes`、`probes-set`、`with-probes` |
| `render.rkt` | 渲染驱动：writer 三实现、失败路径的定界续延挂起/恢复 | `call-renderer`、`make-file-writer`、`make-string-writer`、`no-op-writer` |
| `record.rkt` | 读取记录、`.rktd` 规范形报告、人类可读展开 | `make-recording-source`、`make-report`、`explain-resolved` |
| `debug.rkt` | 应用态调测（全部是查询面的薄封装，零新机制） | `peek`、`peek-field`、`check-config`、`debug-consume`、`list-configs` |
| `main.rkt` | 一站式 re-export | — |

全部模块已实现；annotated 渲染档暂留应用侧（provenance→注释注入器
通用化后入库），设计见 `docs/render-flow.md`。

### 各模块的核心原则

**`source.rkt`——协议先于表示。** 库不知道任何应用的存在，依赖方向恒为
应用 → 库；消费者（渲染器、执行器）只面向 `gen:config-source` 取值。
`ref` 的契约：显式 `false` 是值不是缺失；缺失时依 `fail` 参数处理
（值原样返回、过程调用之、缺省返回 `source-missing` 哨兵）——
**未填的处理策略属于消费者，不属于库**。协议附带通配读取
`config-source-ref-group`（前缀/regexp 扫掠字段族，逐成员真实 ref，
返回已填匹配；未填不可枚举、不被触碰）与作用域回退
`config-source-ref/fallback`（子选项约定 `bench:710:coptimize` → `coptimize`
的查找承载：分层名字住进扁平字段空间，内核零新机制；缺席判定查键集，
预期缺席不入未填读取名单）。

**`config.rkt`——config 是部分记录，声明是自愿的检查。** 未填字段是一等
状态（不是 `#f`、不是哨兵）；`resolve` 之后仍可以有未填（`noneager`）。
字段声明有六轴，全部有默认：`{introduce,provide,override}` 意图轴
（首声明/首供值/改决策；`provide` 表态换"上游确有声明且无人已供"
两查，抓字段名拼错）+ `singlenew`
引入轴 + `open` 封印轴 + `noneager` 急切轴等——空属性组 `()` 即全默认，
写 `(override)`、`(sealed)` 是**自愿换取一项检查**，不是必修语法。
两种组合关系语义不同：`#:extends` 是链（链内改值建议显式 `override`——
表态换 dangling 检查；裸 `()` 亦有覆盖许可，`sealed` 对两者同拦）；
`(config a b)` 是并列合一（无序可交换，同字段不同值 = 冲突报错，
**没有 force**——要改就改源头或一方降级为 `default`）。
求解管线五段带门控：合并 → ①计算默认（惰性 + 循环检测，循环字段被毒化
不回填值）→ ②立即验证 → ③字段后验 → ④全局后验。时序原则：**验证的
执行时机在全部 default（字面与计算）处理完之后**——验证器检查成形后的
记录，不查管线中间态；①②同组累积（计算失败降级为条目，不遮蔽对其
输入的验证，反之亦然），阶段出错后续不跑，已收警告全保留。语义层不推送：
provenance、读集、跳过的验证器都是被动记录，要什么自己查。

**`loader.rkt`——解析，零执行。** `.config` 文法没有顶层代码位置；值位是
数据字面量，只读不求值（lambda 形状的列表也只是数据）。表达式仅存在于
两个封闭位置（`validate`/`default`），契约是"表达式 → 过程"，在
`racket/sandbox`（时间/内存上限 + security guard）内求值，且闭包每次调用
都重入沙箱——限制在调用期生效，不只在装载期。路径引用无 `..`、无绝对
路径，包含检查是二段的（词法规范化 + 逐组件符号链接解析后均须在根内）。
`#:extends` 仅两形态：向下相对路径、`@头/端点`（头映射到目录或注册表
命名空间）；裸注册表符号仅限宿主 API，`.config` 内禁写；
头表与注册表**不属于配置数据**（防自提权），加载器持有、宿主注册，
下游配置只能使用不能扩表。假根（fake 头）与"头换绑到替身注册表命名空间"即是测试注入机制
——数据层换根，不在代码层打桩。

**`probe.rkt`——不纯性集中一处，记录是一等值。** `resolve` 纯、只携带
探测器（`resolved-probers`）；`probe-fields` 是唯一显式不纯步（custodian
围栏、时刻戳、失败是数据不是中断）。探测判定 = 未填 ∧ 声明了 `(probe p)`，
**没有标记值**——显式值压过探测、`removed` 掩值重开探测，与"未填不借助
哨兵值"是同一个设计动作。注入 = `make-probes` 假记录 / `probes-set`
半真半假，仍是数据层换根；`.config` 不得声明探测器（宿主受信代码，
不经沙箱）。后验验证器作环境求值器：`resolve #:probes` 注入、
`config-probe-ref` 查询（纯半段不可查）；纯性承诺相应为"同一
（配置, 探测记录）恒得同一结果"，典型两段式 = 纯求解→实探→带记录复解。
**查询被感知**：每次 `config-probe-ref`（含未命中）入 resolved 的首查序
名单，报告归档 `'probe-reads`/`'probe-misses`——沙箱验证器的查询同样
被看见；结果固定（记录即缓存），查询本身是数据。

**`render.rkt`——失败路径单遍完成，半成品必须死。** 严档在首个未填读取
处以定界续延挂起：删半成品、writer 换 no-op、策略翻"记录并继续"、占位
恢复——前缀不重做，缺失一次收齐。写出接口与策略位在跨提示符共享的 box
中；parameter 方案并非不可行，但有位置性前提（陷阱清单第 14 条），
box 使不变式结构化且失败后写出口对逃逸闭包也死透。宽档是缺省档
（同严重度准则）；显式 `fail` 参数的读取保留普通 ref 契约，引擎策略
只接管"未表态"的读取——verdict 亦然：严档只对未表态的未填判败，
已表态的读取归消费者裁决（`record-flag!` 软警告）。

**`validators.rkt`——富裁决，帮用户猜。** 验证器返回 `#t`/`(void)` 通过，
`(fail #:reason ... #:expected ... #:given ... #:hint ...)` 失败，可返回
列表累积多条；`one-of` 内建编辑距离"是否想要"提示。后验组合子成对成方向：
`require-filled`/`warn-unfilled` 查"该有的有没有"，`require-known`/
`warn-unknown` 查反方向"有的是不是都认识"（族白名单，配通配读取用）。
严重度准则：**建议缺省标警告**，require 版（错误级）留给自觉收紧——
消费期旗标 `record-flag!` 的缺省严重度同守此准则。验证器只追加不可替换
（下游收紧合法）；放松只经 `env` 字段 + 后验验证器自决 `skip`。
返回非协议值（如误写 `'fail` 符号）记 `validator-protocol` 警告，
不静默放行也不判失败。

**`record.rkt`——一个可 read 的 datum 是规范形。** 报告是单个 `.rktd`
数据（无闭包、无不透明结构），人类可读展开（`explain-resolved`）是同一
数据的派生视图，不是另一套事实。错误信息四件套：给定、期望、提示、
provenance（值来自哪行 + 验证器来自哪行）。读取记录三类条目：真实 ref
入读集、未填读取**名单**（读到未填是信号，次数无信息）、应用态标记
（`record-mark-read!`——录制源看不见的消费或有意忽略，带理由进报告，
可审计不豁免）；未读判定把真实读取与标记都计为消费。消费期裁决走
`record-flag!`（使用值时才发现的问题，缺省警告级、升级错误是自觉动作，
入报告 `'flags` 键）。生产消费循环一体化为 `consume/record`（求解、
录制、消费、出报告一个调用），`debug.rkt` 的 `debug-consume` 是其打印
外壳——顺手的路就是正路。报告格式以 `format-version` 字段独立演化。

**`debug.rkt`——薄封装纪律。** 一切调测接口都是公共查询面的组合，
不新增记录、不进生产路径；如果一个调测需求做不到薄封装，说明查询面缺口，
应先补内核查询面。

## 2. 不变式（改代码前须知）

1. 库内模块**不得 require 应用侧代码**；`tests/` 以玩具表示实现协议，
   即此纪律的执行检查。
2. 对外接口遵循 vN 契约：已发布接口关键字只增不减、默认值不变、语义不变
   （`docs/config-refactor.md` §3.5）。
3. `suite` 字段没有内核特殊语义：只是普通字段 + 协议上的便捷访问器
   （缺失退化 `'unknown`）；"不能混用两个 suite"是 `singlenew` + 合一的
   涌现性质，不是特判。
4. `id` 即名字（`define-config` 绑定名 / `.config` 文件名），不随链继承；
   `class` 是惯例字段而非机制（普通字段的继承/override/sealed 全适用）。
5. 每个行为变化都要有 `tests/*-test.rkt` 里的回归用例；
   **读测试是最快的第二入口**，请保持这一点成立。

## 3. 陷阱清单（开发过程中真实踩过的）

1. **`.rkt` 与 `.config` 的值位语义不同**：`.rkt` 值位是表达式（列表要写
   `(list 1 2)`）；`.config` 值位只读不求值（`(1 2)` 就是列表数据）。
2. **封闭位置装载期会执行组合子应用**（沙箱内）：`(validate (one-of ...))`
   在装载期调用 `one-of`；`default` 位置只接受数据字面量或 `(lambda ...)`
   （形状判定），组合子工厂不适用于 default。
3. **并列 ≠ 覆盖**：`(config job (hash 'copies 100))` 是并列冲突⊥；
   要改值写 `#:extends` + `(override)`。
4. **`singlenew` 是默认**：两个不相关 config 各自 `introduce` 同一字段，
   值相同也报错；确要多引入者，声明 `multi-introducer`。
5. **显式 `false` 是值**：`[dryrun () false]` 之后 `ref` 返回 `#f`，
   不是缺失。
6. **警告不影响 `resolved-ok?`**，在 `resolved-warnings` 单独一张表。
7. **阶段门控会"吃掉"后续阶段的检查**：写测试时不要把"制造错误"与
   "验证后续阶段行为"放进同一个配置。
8. **上游仅有默认值时**，`(override)` 合法（默认值是合法覆盖目标），
   下游裸写 `()` 也直接生效。
9. **hash 强转最宽松**（含 `multi-introducer`）且 provenance 降到片段
   粒度——只用于简单覆盖，成规模配置写 `define-config` 或 `.config`。
10. **加载器引用无向上路径**：`"../x"`、`"/abs"`、`"a//b"` 一律拒绝
    （`string-split` 必须 `#:trim? #f`，这里曾有真实的绝对路径静默降级洞）；
    包含检查二段，根内 symlink 指向根外同样被拒。
11. **`.config` 里布尔只有 `true`/`false`**：原始 `#t`/`#f` 装载期即拒。
12. **报告的 `values` 只含已填字段**：未填在 `unfilled` 键下，无占位符号，
    值恰为 `'<unfilled>` 的字段不会混淆。
13. **`config.rkt` 的 `fail` 与 rackunit 撞名**：测试里写
    `(require (except-in rackunit fail) ...)`。
14. **渲染写出口的换挡是位置敏感的**：writer 放 parameter 可行，但绑定
    必须在提示符之外、换挡必须以"包裹恢复"的 parameterize 表达——绑定
    落入被捕获范围即被恢复的续延弹回；且 parameterize 换挡只覆盖被恢复
    的动态范围，对逃逸闭包不生效。库选跨提示符共享的 box：不变式结构化，
    失败后写出口全局死透（render-test 有弹回与逃逸两个回归用例）。

## 4. 开发环

```sh
raco test tests/          # 全量；每个模块一个 *-test.rkt
```

改内核 → 跑 `config-test`；改文法/沙箱/路径 → 跑 `loader-test`；
改报告形状 → 跑 `record-test` 并考虑 `format-version` 是否需要演化。
