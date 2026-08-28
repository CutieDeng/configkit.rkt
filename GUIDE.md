# configkit 接手指南

写给第一次接触本库的开发者/agent：按本文即可正确使用与扩展。
定位与安全边界见 `README.md`；设计依据见仓库 `docs/config-refactor.md`（语义）、
`docs/config-examples.md`（语法定稿）、`docs/render-flow.md`（消费者执行流）。
**语义疑问以 `docs/` 为准，用法疑问以本文与测试为准。**

## 0. 一分钟上手

```racket
(require "configkit/main.rkt")   ; 一站式导出全部接口

(define-config base
  [copies   ((default 2) (validate (integer-between 1 8)))]
  [tune     ((default "base"))]
  [hw-avail (introduce required)])          ; noneager：未填是状态，不是错误

(define-config job
  #:extends base                            ; 继承链
  [copies (override) 4])                    ; 链内改值必须 override

(define r (resolve job))                    ; 求解：合一 + 管线 + provenance
(resolved-ok? r)                            ; => #t（警告不影响）
(resolved-value r 'copies)                  ; => 4
(display (explain-resolved r))              ; 人类可读展开
(peek-field r 'copies)                      ; 值 + 定义链（谁在哪行给的）
```

跑库测试：`raco test configkit/tests/`。每个模块的用法在对应
`tests/*-test.rkt` 里都有可运行的最小例子——**读测试是最快的第二入口**。

## 1. 心智模型（五条，记住即可正确使用）

1. **config 是部分记录**。未填字段是一等状态（不是 #f、不是哨兵值）；
   `resolve` 后仍可以有未填，由消费者按需裁决（`noneager`）。
2. **两种组合关系**：`#:extends` 是继承链（链内改值走 `(override)`，再声明
   `introduce` 不生效只入档）；`(config a b ...)` 是并列（无序可交换，
   同字段不同具体值 = 冲突报错，**没有 force**——改源头或一方降级 `(default ...)`）。
3. **六轴默认**：`{introduce,override}` + `singlenew` + `open` + `noneager`。
   写空属性组 `()` 即全默认；写单项声明是自愿换取检查。
4. **求解管线五段带门控**：合并 → ①立即验证 → ②计算默认 → ③字段后验 →
   ④全局后验。阶段内错误累积一次报全；某阶段有 error 则后续阶段不跑，
   已收警告全保留。
5. **语义层不推送**：provenance、读集、未读字段、跳过的验证器都是被动记录，
   要什么自己查（`provenance-ref`、`unread-fields/record`、`resolved-skipped`……）。

## 2. 模块地图

| require | 提供 | 何时用 |
|---|---|---|
| `main.rkt` | 以下全部 | 应用侧默认入口 |
| `config.rkt` | `define-config`/`config`/`resolve`/查询/裁决构造子 | 内核 |
| `source.rkt` | `gen:config-source` 协议 | 写新表示的适配器时 |
| `validators.rkt` | `one-of` 等组合子 | 声明检查 |
| `loader.rkt` | `load-config`/头表/注册表 | 加载 `.config` 文件 |
| `record.rkt` | 记录源/`.rktd` 报告/`explain-resolved` | 消费者与诊断 |
| `debug.rkt` | 应用态调测（§4） | 开发过程 |

注意：`config.rkt` 的 `fail` 与 rackunit 撞名，测试里写
`(require (except-in rackunit fail) ...)`。

## 3. 食谱

**加载 `.config` 树**（引用只有三种形态：`"子路径"` 本文件目录向下、
`"@头/子路径"` 假根向下、符号查注册表；无 `..`、无绝对路径）：

```racket
(parameterize ([current-config-search-heads (hash 'jobs "/srv/spec/jobs"
                                                  'site "/etc/spec/site")]
               [current-config-registry (hash 'my-base my-base)])
  (resolve (load-config "@jobs/nightly")))
```

**写一个消费者**（渲染器等）：只面向协议，未填经 `fail` 参数处理：

```racket
(define-values (src rec) (make-recording-source resolved))
(define (ref k) (config-source-ref src k
                  (lambda () (format "# <unfilled: ~a>" k))))
... 用 (ref 'label) 取值拼输出 ...
(unread-fields/record resolved rec)      ; 笔误探测
(write-report (make-report #:function 'my-render #:resolved resolved
                           #:record rec #:source resolved)
              "report.rktd")             ; 规范形，测试端 read 后断言
```

**验证与放松**：验证器只追加不可替换；上游想授予放松权，用 `env` 字段 +
后验验证器自决 `skip`（见 `tests/config-test.rkt` "guarded" 用例）。

**测试注入**：假值 = 普通片段覆盖（零机制）；假 `.config` 树 = fake 头；
假代码基配置 = 注册表换绑。

**自我声明（id/class）**：每个 config 的名字即其 id——`define-config` 的绑定名、
`.config` 的文件名——不随链继承；`(resolved-id r)` 给出求解根的名字（并列组合
为各部分名字的平铺列表）。`class` 是惯例字段而非机制：链上自动继承、
`(override)` 改写、可 `sealed` 封印，`(resolved-class r)` 查询（未声明为 `#f`）。
两者进 `resolve-summary`/`peek` 头部与 `.rktd` 报告（`'id`/`'class` 键），
用于调试与报告归档时回答"这是谁、哪一类"。

## 4. 应用态调测接口（`debug.rkt`）

开发过程中的检验回路，全部是公共查询面的薄封装，可进 REPL 与 dev 脚本：

| 接口 | 用途 |
|---|---|
| `(resolve-summary c)` | 一行健康度：`id/class/ok?/errors/warnings/skipped/unfilled/fields` |
| `(peek c)` | 求解 + 打印展开与值表，返回 resolved 继续查 |
| `(peek-field c 'f)` | 单字段：值 + 完整定义链（谁、哪行、生效/让位/不生效） |
| `(check-config c)` | 布尔门：健康返回 `#t` 静默，不健康打印展开返回 `#f` |
| `(debug-consume c proc)` | **消费者开发回路**：录制运行 proc，打印读集/未填读取/未读字段，返回 `(values 结果 报告)` |
| `(list-configs #:heads h)` | 枚举头表下全部可引用 `@头/路径`——核对头表指向 |
| `(dump-report c path)` | 一步落 `.rktd` 规范形报告 |

典型回路：改配置 → `check-config`；写渲染器 → `debug-consume`；
查"这个值哪来的" → `peek-field`；配头表 → `list-configs`。

## 5. 陷阱清单（本库开发过程中真实踩过的）

1. **`.rkt` 与 `.config` 的值位语义不同**：`.rkt` 中值位是表达式
   （列表要写 `(list 1 2)` 或引用）；`.config` 中值位只读不求值
   （`(1 2)` 就是列表数据，lambda 形状也只是数据）。
2. **封闭位置的契约是"表达式→过程"**：`(validate (one-of ...))` 在装载期
   会执行组合子应用（沙箱内）；`default` 位置只接受数据字面量或
   `(lambda ...)`（形状判定），组合子工厂不适用于 default。
3. **并列 ≠ 覆盖**：想把链上的 6 改成 100，`(config job (hash 'copies 100))`
   是并列冲突⊥；要写 `(define-config x #:extends job [copies (override) 100])`。
4. **`singlenew` 是默认**：两个互不相关的 config 各自 `introduce` 同一字段，
   即使值相同也报错；确要多引入者，声明 `multi-introducer`。
5. **显式 `false` 是值**：`[dryrun () false]` 之后 `(config-source-ref r 'dryrun 'absent)`
   返回 `#f` 不是 `'absent`。布尔在配置层写 `true`/`false`。
6. **警告不影响 `resolved-ok?`**，在 `resolved-warnings` 单独一张表。
7. **阶段门控会"吃掉"后续阶段的检查**：①有错时②③④不跑——写测试时
   不要把"制造错误"与"验证后续阶段行为"放进同一个配置。
8. **上游仅有默认值时**，`(override)` 合法（默认值是合法覆盖目标），
   下游裸写 `()` 也直接生效（可退让默认不构成"已有提供"）。
9. **hash 强转最宽松**（含 `multi-introducer`），且 provenance 降到片段粒度——
   只用于简单覆盖，成规模配置写 `define-config` 或 `.config`。
10. **加载器引用无向上路径**：`"../x"`、`"/abs"`、`"a//b"` 一律拒绝
    （`string-split` 必须 `#:trim? #f`，这里曾有一个真实的绝对路径静默降级洞）；
    包含检查是二段的——词法 + 符号链接解析后，根内 symlink 指向根外同样被拒。
11. **`.config` 里布尔只有 `true`/`false`**：原始 `#t`/`#f` 字面量在装载期被拒。
12. **报告的 `values` 只含已填字段**：未填在 `unfilled` 键下，没有占位符号，
    值恰为 `'<unfilled>` 的字段不会混淆。
13. **验证器返回非协议值**（如误写 `'fail`）会记 `validator-protocol` 警告，
    不静默放行也不判失败。
14. **`suite` 字段没有内核特殊语义**：它只是普通字段外加协议上的一个便捷
    访问器（缺失时退化为 `'unknown`）；"不能混用两个 suite"是 `singlenew` +
    合一的涌现性质，不是特判——两条链并列组合时 `suite` 字段自然报
    multiple-introducers。

## 6. 边界：尚未实现

- `probe.rkt`（探测记录）与 `render.rkt`（writer 接口、失败路径的
  定界续延挂起/恢复）：设计见 `docs/render-flow.md`，未动工。
- 应用侧（SPEC runner）的基片段蒸馏与渲染器迁移（P1/P2）：
  现状旧实现原样工作，引擎门面（`src/engine.rkt`）委托之。
- 报告格式以 `format-version` 演化；对外接口遵循 vN 契约
  （`docs/config-refactor.md` §3.5）。
- 本目录引用的 `docs/` 设计文档在上层 runspeccpu 仓库；独立发布时需携带。
