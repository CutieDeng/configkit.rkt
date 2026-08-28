# configkit：应用态接口与配置安全性

应用无关的配置框架库。**接手上手请读 `GUIDE.md`**。
（本文与 GUIDE 引用的 `docs/config-*.md` 设计文档位于上层 runspeccpu 仓库；
独立发布本库时需一并携带或改写这些链接。）（一分钟上手、心智模型、
食谱、应用态调测、陷阱清单）。设计全文见仓库 `docs/config-refactor.md`（语义）、
`docs/config-examples.md`（语法）、`docs/render-flow.md`（执行流）。
本文只讲两件事：**应用程序如何消费本库**，与**配置的安全边界**。

状态标注：〔已实现〕当前代码可用；〔规划〕接口已定稿、实现在对应迁移阶段。

## 1. 定位与边界

- 库不知道任何具体应用的存在。**库内模块不得 require 应用侧代码**；依赖方向恒为
  应用 → 库。`tests/` 以玩具表示实现协议，即此纪律的执行检查。
- 应用侧持有：各配置表示的适配器、基片段（承担 schema 角色的普通片段）、渲染模板、执行器。

## 2. 应用态接口总览

| 模块 | 接口 | 状态 |
|---|---|---|
| `source.rkt` | `gen:config-source` 协议：`suite` / `ref`（带 fail 参数）/ `explicit?` / `keys`；`source-missing` 哨兵 | 〔已实现〕 |
| ~~fragment.rkt~~ | 并入 `config.rkt`（术语弃用：无独立"片段"机制） | — |
| ~~resolve.rkt~~ | 并入 `config.rkt` 的 `resolve` | — |
| `record.rkt` | 读取记录、诊断、`.rktd` 规范形报告、`explain-resolved` 人类可读展开 | 〔已实现〕 |
| `probe.rkt` | 探测记录（构造、注入、dump） | 〔规划〕 |
| `render.rkt` | 通用渲染骨架：writer 接口、失败路径的挂起/恢复（定界续延） | 〔规划〕 |
| `config.rkt` | 配置内核：`define-config`、六轴、合一、求解管线、provenance、富裁决、`resolved-id`/`resolved-class` 自我声明查询 | 〔已实现〕 |
| `loader.rkt` | `.config` 加载器：向下引用/`@头`/注册表、沙箱封闭位置 | 〔已实现〕 |
| `debug.rkt` | 应用态调测：`peek`/`peek-field`/`check-config`/`debug-consume`/`list-configs`/`dump-report` | 〔已实现〕 |
| `main.rkt` | 一站式汇总导出全部模块 | 〔已实现〕 |
| `validators.rkt` | 验证器组合子：`one-of`/`integer-between`/`string-matching`/`list-where`/`all-of`/`require-filled`/`warn-unfilled` 等，富裁决内建，全部注入 `.config` 沙箱 | 〔已实现〕 |

### 2.1 消费协议（当前唯一已实现面）

应用的每种配置表示写一个适配器；引擎函数只面向协议：

```racket
(require configkit/source)   ; 或相对路径 require

(struct my-source (data)
  #:methods gen:config-source
  [(define (config-source-suite s) 'my-app)
   (define (config-source-ref s key [fail source-missing])
     (cond [(hash-has-key? (my-source-data s) key) (hash-ref (my-source-data s) key)]
           [(procedure? fail) (fail)]
           [else fail]))
   (define (config-source-explicit? s key) (hash-has-key? (my-source-data s) key))
   (define (config-source-keys s) (hash-keys (my-source-data s)))])
```

`ref` 的三条契约：显式的 `#f`/`false` 是值不是缺失；缺失时依 `fail`（值原样返回、过程调用之、缺省返回 `source-missing` 哨兵）；消费者的每次 `ref` 会进入读集（record.rkt 就绪后）。**未填的处理策略属于消费者**——渲染器传返回占位对象的 fail，严格检查传抛错的 fail。

## 3. 配置安全性

### 3.1 加载模型：解析，零执行

`.config` 的文法没有"顶层代码"位置；表达式仅出现在**封闭位置**——
`(validate ...)`/`(validate/post ...)` 与 `(default ...)`。值位是数据字面量
（数、串、`true`/`false`、列表；只读不求值——lambda 形状的列表也只是数据）。

封闭位置的契约是"**表达式 → 过程**"，机制是**沙箱内求值**（无宏、无展开）：

- payload 为 `(lambda ...)`：求值 = 构造闭包，零效应；
- payload 为组合子应用（如 `(one-of "txt" "csv")`）：求值 = 当场调用注入沙箱的
  受信宿主组合子，返回其内部闭包——**装载期会执行这一步**，但它在沙箱 guard 与
  限额之下；参数中夹带的恶意调用（如 `(delete-file ...)`）在装载期即被 guard 拦截。

因此准确的承诺是：**装载期不执行任何不受沙箱约束的代码**。

一处有意的不对称：`validate` 位置接受任意求值为过程的表达式；`default` 位置只接受
数据字面量或 `(lambda ...)`——default 的合法值本就常是列表数据（如 `("1 GB")`），
按内容区分"字面列表"与"待求值应用"会重新引入内容判定歧义（与属性组强制存在同一
教训），故以形状（`lambda` 头）判定，组合子工厂不适用于 default 位置。

实现〔已落地〕：**加载器直接解析，无 `#lang`、无模块展开**——`read-syntax` 逐
datum 读入（逐行 srcloc 即 provenance），字段行/`#:extends`/`#:validate/post`
由加载器解析。曾考虑 `#lang configkit/config` 路线，已否决：配置文件的"展开"
只产出一个构造调用，动用模块塔无谓——文法约束由解析器承担、限制由沙箱承担、
srcloc 由 `read-syntax` 白拿。

`.rkt`（应用/库代码：引擎、渲染器、基片段、适配器）走正常模块系统，受信、代码评审。

### 3.2 执行模型：封闭位置的闭包在沙箱中、于规定阶段运行

`.config` 携带的闭包只在求解管线的规定阶段被框架调用（验证器于①③、计算默认于②），
且受两层限制：

- **词法层**：闭包在沙箱求值器的独立命名空间中构造，可名的绑定仅为纯计算与
  注入的框架接口（`config-source-ref`、`config-env-ref`、`fail`/`warn`/`skip`）；
- **运行层**：`racket/sandbox` 的时间/内存上限与 security guard，且闭包每次调用
  都经 `call-in-sandbox-context` 重入沙箱——限制在**调用期**生效，不只在装载期。
  仓库现有 `call-controlled-callback`（专属 custodian）是其雏形，内核对一切验证
  器仍保留该围栏。

### 3.3 搜索路径表：包含范围与信任卫生〔已实现〕

`#:extends` 目标写 `头/余部` 模式引用，经宿主持有的表解析：

```racket
(parameterize ([current-config-search-heads
                (hash 'site     "/etc/speccpu/site"
                      'profiles "/etc/speccpu/profiles"
                      'jobs     "/srv/spec/jobs")]
               [current-config-registry
                (hash 'suite/cpu2026 cpu2026-base)])   ; 宿主注册的代码片段值
  (load-config "jobs/nightly"))
```

- 引用只有两种形态：`子路径`——从**本 `.config` 文件所在目录向下**解析；
  `@头/子路径`——从宿主定义的（可为假的）根向下解析。无 `..`、无绝对路径、
  **向上不可达**；未定义的头即错。
- **二段包含检查**：先查路径本身（词法规范化后须在根内），再查文件系统解析后
  的路径（逐组件跟随符号链接后仍须在同样解析过的根内）——根内指向根外的
  symlink 无法作为逃逸通道。
- 表守的是**包含范围与 provenance 可信度**（谁能被继承进来、值与验证器来自谁），
  代码执行安全由 3.1/3.2 的文法与沙箱承担。
- 注册表供引用宿主注册的代码片段值（基片段等），不触发新文件加载。

### 3.4 fake 路径头〔已实现〕

- **测试沙箱**：`site` 头指向临时目录中的替身 `.config`——配置文本零修改换基座；
- **注册表换绑**：同名代码片段解析到替身实现（CI 用精简基片段）；
- **封禁**：头映射为空，引用即拒载。

与探测记录注入、no-op writer 同属"数据层换根，不在代码层打桩"。

### 3.5 边界与不变式

- **头表与注册表不属于配置数据**（防自提权）；加载器持有，站点经宿主接口注册，
  下游配置只能使用、不能扩表。
- 验证器规则：`.config` 追加验证器合法（下游收紧）；替换在语义层不存在，放松只经
  env 开关——语义规则，与封闭位置文法相互独立地成立。
- 字段值里的路径字符串（`spec-src` 等）是惰性数据；其消费属应用侧能力管理，
  不在本节威胁面。

### 3.6 既有对应

`racket/sandbox`（标准库沙箱求值器：内存/时间上限、security guard）；
Racket collection path（头即 collection，"入表即受信"同 `PATH` 的信任模型）。
（稳定语言事实，按仓库调研惯例：未核规范原文。）

## 4. 稳定性承诺

对外接口遵循 `docs/config-refactor.md` §3.5 的 vN 契约：已发布接口关键字只增不减、
默认值不变、语义不变；报告格式以 `format-version` 字段独立演化。
