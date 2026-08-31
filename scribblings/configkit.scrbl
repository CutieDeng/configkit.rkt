#lang scribble/manual
@(require (for-label racket/base racket/contract))

@title{configkit：可组合配置框架}
@author{runspeccpu project}

@defmodule[configkit]

以部分记录为核心的配置框架：字段级声明轴、顺序无关合一、provenance、
求解管线与 @filepath{.rktd} 规范形诊断报告。上手与示例见随包
@filepath{README.zh.md}（英文 @filepath{README.en.md}）；模块地图、设计
原则与陷阱清单见 @filepath{contribute.zh.md}（英文 @filepath{contribute.en.md}）；
完整设计语义见上层仓库 @filepath{docs/config-refactor.md}。

@table-of-contents[]

@section{心智模型}

@itemlist[
 @item{config 是@bold{部分记录}：未填字段是一等状态，由消费者按需裁决（noneager）。}
 @item{两种组合：@racket[#:extends] 继承链（链内改值建议声明
       @racket[override]：表态换空覆盖检查；裸 @racket[()] 亦有覆盖许可，
       @racket[sealed] 同拦）；
       @racket[(config a b ...)] 并列（无序可交换，具体值冲突即错，无 force）。}
 @item{六轴默认：@racket[{introduce provide override}]、singlenew、open、noneager。}
 @item{求解管线五段带门控：合并 → 计算默认 → 立即验证 → 字段后验 → 全局后验。
       验证的执行时机在全部 default（字面与计算）处理完之后——验证器检查
       成形后的记录；计算默认与立即验证同组累积（计算失败不遮蔽对其输入
       的验证），阶段出错后续不跑，警告全保留。}
 @item{语义层不推送：provenance、读集、未读字段、跳过的验证器皆为被动记录，按需查询。}]

@section{内核（configkit/config）}

@defform[(define-config id maybe-extends maybe-global-validator ... row ...)
         #:grammar
         ([maybe-extends (code:line) (code:line #:extends parent-expr)]
          [maybe-global-validator (code:line #:validate/post proc-expr)]
          [row [field-id (prop ...) maybe-value]]
          [prop introduce provide override sealed required eager removed
                multi-introducer env
                (default expr) (validate expr) (validate/post expr)
                (probe expr) (help string)])]{
定义一个具名 config。属性组强制存在（可为空 @racket[()] 即全默认）；
值位在 @filepath{.rkt} 中为任意表达式。绑定名即标识，逐行捕获源位置入 provenance。}

@defproc[(config [part (or/c config-object? hash? any/c)] ...) any/c]{
并列组合。@racket[hash] 被强转为最宽松声明的匿名 config（provenance 降为整体粒度）。}

@defproc[(resolve [composition any/c]
                  [#:probes probes (or/c probe-record? #f) #f]) resolved?]{
求解：合一、六轴检查、验证管线、provenance。错误累积于
@racket[resolved-issues]，警告于 @racket[resolved-warnings]，从不抛出配置类
错误。@racket[#:probes] 注入探测记录供后验验证器经
@racket[config-probe-ref] 查询（环境求值器）；纯性承诺相应为
"同一（配置, 探测记录）恒得同一结果"。}

@deftogether[(@defproc[(resolved? [v any/c]) boolean?]
              @defproc[(resolved-ok? [r resolved?]) boolean?]
              @defproc[(resolved-value [r resolved?] [field symbol?]
                                       [fail any/c source-missing]) any/c]
              @defproc[(resolved-issues [r resolved?]) (listof issue?)]
              @defproc[(resolved-warnings [r resolved?]) (listof issue?)]
              @defproc[(resolved-skipped [r resolved?]) list?]
              @defproc[(resolved-id [r resolved?]) (or/c symbol? (listof symbol?))]
              @defproc[(resolved-class [r resolved?]) any/c]
              @defproc[(resolved-probers [r resolved?]) hash?]
              @defproc[(resolved-probes [r resolved?])
                       (or/c probe-record? #f)]
              @defproc[(resolved-probe-reads [r resolved?])
                       (listof (list/c symbol? boolean?))])]{
查询面。@racket[resolved-ok?] 只看错误，警告不阻断。

@racket[resolved-id] 与 @racket[resolved-class] 分属两个层面，勿混：
@racket[resolved-id] 是@bold{非字段的特殊标识}——不在字段空间、不参与合一、
不沿 @racket[#:extends] 继承、不受声明轴管辖；每个 config 的 id 就是它自己的
名字，互不干扰，@racket[resolve] 报告的是被求解之根（并列多根为名字列表），
父链名字永不混入。@racket[resolved-class] 则读@bold{普通字段}约定
@racket['class]——参与合一、可被链内覆盖、六轴全适用，未声明时为 @racket[#f]。}

@deftogether[(@defproc[(unfilled-fields [r resolved?]) hash?]
              @defproc[(provenance-ref [r resolved?] [field symbol?]) (listof origin?)]
              @defproc[(inoperative-declarations [r resolved?]) list?]
              @defproc[(config-env-ref [r any/c] [field symbol?]
                                       [fail any/c source-missing]) any/c])]{
未填字段（含原因）；字段定义链；不生效的链内再声明；验证环境读取
（仅 @racket[env] 标记字段，后验验证器与计算默认闭包内可用）。}

@deftogether[(@defstruct*[issue ([kind symbol?] [field symbol?]
                                 [message string?] [data hash?]) #:omit-constructor]
              @defstruct*[origin ([kind symbol?] [config-name symbol?]
                                  [srcloc any/c] [info any/c]) #:omit-constructor])]{
诊断与定义链条目。验证器失败的 @racket[data] 含
@racket['expected]/@racket['given]/@racket['hint]/@racket['validator-at]/
@racket['value-from]/@racket['value-at]。}

@deftogether[(@defproc[(fail [#:reason reason string?]
                             [#:expected expected any/c #f]
                             [#:given given any/c #f]
                             [#:hint hint any/c #f]) verdict-fail?]
              @defproc[(warn [#:reason reason string?]) verdict-warn?]
              @defproc[(skip [#:reason reason string?]) verdict-skip?])]{
验证器富裁决。另接受 @racket[#t]/@racket[(void)] 通过、字符串为失败原因、
列表逐条累积；@racket[skip] 仅后验有意义；非协议返回值记
@racket['validator-protocol] 警告。}

@section{协议（configkit/source）}

@deftogether[(@defidform[gen:config-source]
              @defproc[(config-source? [v any/c]) boolean?]
              @defproc[(config-source-suite [s config-source?]) any/c]
              @defproc[(config-source-ref [s config-source?] [key symbol?]
                                          [fail any/c source-missing]) any/c]
              @defproc[(config-source-explicit? [s config-source?] [key symbol?]) boolean?]
              @defproc[(config-source-keys [s config-source?]) (listof symbol?)]
              @defproc[(config-source-ref-group [s config-source?]
                                                [pattern (or/c symbol? string? regexp?)])
                       hash?]
              @defproc[(config-source-ref/fallback [s config-source?]
                                                   [names (listof symbol?)]
                                                   [fail any/c source-missing])
                       any/c]
              @defthing[source-missing symbol?])]{
消费者面向的取值协议。显式 @racket[#f] 是值不是缺失；缺失依 @racket[fail]
（值原样返回、过程调用之、缺省返回哨兵 @racket[source-missing]）。

@racket[config-source-ref-group] 是通配读取：按前缀（符号/字符串，如
@racket['env:]）或 regexp 匹配可枚举字段名，逐成员@bold{真实} ref
（录制源如实入读集），返回已填匹配的 @racket[hasheq]。未填字段不可枚举、
不被扫掠触碰——族的完备性检查走 @racket[require-filled] 后验，不走读取面。

@racket[config-source-ref/fallback] 是作用域回退查找——子选项约定
（如 @racket['bench:710:coptimize] 回退到 @racket['coptimize]）的承载：
按特异度顺序尝试名字，第一个可枚举者应答，全缺走普通 fail 契约。
缺席判定查键集而非 ref：录制源只记真正消费的名字，预期缺席的特异名
不进未填读取名单。分层名字就是普通字段，六轴/provenance/守卫照常适用。}

@section{验证器组合子（configkit/validators）}

@deftogether[(@defproc[(one-of [choice any/c] ...) procedure?]
              @defproc[(number-between [lo real?] [hi real?]) procedure?]
              @defproc[(integer-between [lo real?] [hi real?]) procedure?]
              @defproc[(nonempty-string [v any/c]) any/c]
              @defproc[(string-matching [pattern (or/c string? regexp?)]) procedure?]
              @defproc[(list-where [pred procedure?]) procedure?]
              @defproc[(all-of [validator procedure?] ...) procedure?]
              @defproc[(require-filled [field symbol?] ...) procedure?]
              @defproc[(warn-unfilled [field symbol?] ...) procedure?]
              @defproc[(require-known [pattern (or/c symbol? string? regexp?)]
                                      [member symbol?] ...) procedure?]
              @defproc[(warn-unknown [pattern (or/c symbol? string? regexp?)]
                                     [member symbol?] ...) procedure?])]{
常用检查，富裁决内建（@racket[one-of] 含 did-you-mean 与类型不符提示）。
后四个为后验组合子（收已解析视图）：filled 对查"该有的有没有"（无初始
化值快检）；known 对查反方向"有的是不是都认识"——扫掠名字匹配
@racket[pattern]（前缀或 regexp，同 @racket[config-source-ref-group]）的
可枚举字段，不在 @racket[member] 白名单中的逐个 fail/warn，附对白名单的
did-you-mean 提示。准则：@bold{建议缺省用警告版}（@racket[warn-unknown]/
@racket[warn-unfilled]），require 版留给自觉收紧的场合。
全部注入 @filepath{.config} 沙箱，配置文件中免写 lambda。}

@section{加载器（configkit/loader）}

@deftogether[(@defparam[current-config-search-heads heads hash?]
              @defparam[current-config-registry registry hash?]
              @defproc[(load-config [ref (or/c string? symbol?)]) any/c]
              @defproc[(load-config-file [path path-string?]) any/c])]{
@filepath{.config} 加载。引用三形态：@racket["子路径"]（本文件目录向下）、
@racket["@头/子路径"]（宿主定义根向下）、符号（注册表代码 config）。
禁 @litchar{..} 与绝对路径；二段包含检查（词法 + 符号链接解析后）。
装载零执行：值位只读；封闭位置在 @racketmodname[racket/sandbox] 内求值，
闭包调用期重入沙箱。头表与注册表由宿主持有，非配置数据。}

@section{宿主探测（configkit/probe）}

@deftogether[(@defproc[(probe-fields [r resolved?]) probe-record?]
              @defproc[(probe-record? [v any/c]) boolean?]
              @defproc[(probe-record-fields [pr probe-record?]) (listof symbol?)]
              @defproc[(probe-record-failures [pr probe-record?]) list?]
              @defproc[(probe-ref [pr probe-record?] [field symbol?]
                                  [fail any/c source-missing]) any/c]
              @defproc[(config-probe-ref [r resolved?] [field symbol?]
                                         [fail any/c source-missing]) any/c]
              @defproc[(make-probes [m (or/c hash? list?)]
                                    [#:prober prober symbol? 'injected]
                                    [#:at at real? 0]) probe-record?]
              @defproc[(probes-set [pr probe-record?] [field symbol?]
                                   [value any/c]
                                   [#:prober prober symbol? 'injected]
                                   [#:at at real? 0]) probe-record?]
              @defproc[(with-probes [src config-source?] [pr probe-record?])
                       config-source?])]{
@racket[resolve] 保持纯，只携带各字段声明的探测器（@racket[(probe p)]
属性；@racket[resolved-probers] 查询）；@racket[probe-fields] 是唯一的
显式不纯步：对@bold{未填且有探测器}的字段逐个执行探测器（custodian
围栏、时刻戳、失败降级为记录条目而非中断）。没有标记值：显式值天然
压过探测，@racket[removed] 掩值即重开探测。探测记录是一等值——
@racket[make-probes] 手工构造假记录注入，@racket[probes-set] 函数式
更新（半真半假），@racket[with-probes] 包装任意源使探测值走普通 ref
路径（消费者免改；recording 叠在外层），@racket[make-report] 的
@racket[#:probes] 归档为 @racket['probes]/@racket['probe-failures] 键。
@filepath{.config} 不得声明 @racket[(probe ...)]：探测器是宿主受信
代码，不经沙箱。

后验验证器作@bold{环境求值器}：@racket[(resolve _ #:probes pr)] 注入
记录，验证器经 @racket[config-probe-ref] 查询（镜像
@racket[config-env-ref]；无记录时缺失，验证器典型地自决 @racket[skip]；
计算默认所在的纯半段不可查）。典型两段式：纯求解 → 实探/注入 →
带记录复解——@racket[call-renderer] 对未求解输入自动走这条路。

@bold{查询被感知}：@racket[config-probe-ref] 的每次查询（含未命中）记入
resolved 的首查序名单（@racket[resolved-probe-reads]，条目为
@racket[(list 字段 命中?)]），报告归档为 @racket['probe-reads] 与
@racket['probe-misses]——沙箱验证器的查询同样被看见。结果固定
（记录即缓存），查询本身是数据。}

@section{渲染驱动（configkit/render）}

@deftogether[(@defproc[(call-renderer [c any/c] [renderer procedure?]
                                      [#:mode mode (or/c 'lenient 'checked) 'lenient]
                                      [#:writer w (or/c render-writer? #f) #f]
                                      [#:probes pr (or/c probe-record? #f) #f]
                                      [#:function function symbol? 'render])
                       render-result?]
              @defstruct*[render-result ([verdict (or/c 'ok 'failed)]
                                         [product any/c]
                                         [report hash?]) #:omit-constructor]
              @defproc[(make-string-writer) render-writer?]
              @defproc[(make-file-writer [path path-string?]) render-writer?]
              @defproc[(no-op-writer) render-writer?]
              @defproc[(render-writer? [v any/c]) boolean?]
              @defproc[(unfilled-placeholder [field symbol?]) unfilled-placeholder?]
              @defproc[(unfilled-placeholder? [v any/c]) boolean?])]{
渲染驱动：应用的渲染器只经协议取值、经 writer 发文本
（@racket[(renderer src emit)]，三元额外收 record），驱动负责失败路径。
探测记录缺省当场实探，@racket[#:probes] 注入假记录。

宽档（缺省，同严重度准则）：未填读取返回占位对象
（格式化为 @litchar{<unfilled:字段>}），verdict 恒 @racket['ok]，缺失入
报告。严档 @racket['checked]：首个未填读取处捕获可组合续延挂起——驱动
删除半成品、writer 换 no-op、策略翻"记录并继续"——以占位恢复，渲染器
@bold{单遍}跑完剩余模板：完整读集与全部缺失一次收齐，前缀不重做，
且绝不留下半成品。调用方显式传 @racket[fail] 参数的读取保留普通 ref
契约：不触发挂起、不影响 verdict——已表态的读取归消费者裁决
（@racket[record-flag!]，软警告方案的承载），严档只对未表态的未填判败；
未填读取名单仍如实在档。

实现纪律：写出接口与策略位在跨提示符共享的 box 中。parameter 方案可行
但位置敏感——绑定须在提示符之外、换挡须以包裹恢复表达，绑定落入被捕获
范围即被弹回，且换挡不覆盖逃逸闭包；box 使不变式结构化、失败后写出口
全局死透。annotated 档暂留应用侧。}

@section{记录与报告（configkit/record）}

@deftogether[(@defproc[(make-recording-source [s config-source?])
                       (values config-source? record?)]
              @defproc[(record-reads [rec record?]) (listof symbol?)]
              @defproc[(record-unfilled [rec record?]) (listof symbol?)]
              @defproc[(record-note! [rec record?] [field symbol?] [msg string?]) void?]
              @defproc[(record-mark-read! [rec record?] [field symbol?]
                                          [reason string?]) void?]
              @defproc[(record-marks [rec record?]) (listof (list/c symbol? string?))]
              @defproc[(record-flag! [rec record?] [field symbol?] [message string?]
                                     [#:severity severity (or/c 'warning 'error)
                                      'warning]) void?]
              @defproc[(record-flags [rec record?])
                       (listof (list/c symbol? symbol? string?))]
              @defproc[(unread-fields/record [s config-source?] [rec record?])
                       (listof symbol?)])]{
读集记录：首读序去重；未填读取是@bold{名单}（读到未填这一事实是信号，
次数无信息）；应用侧注记。@racket[record-mark-read!] 是应用对真实使用
情形的声明——某字段经录制源看不见的路径被消费（整体 dump、运行期探测）
或被有意忽略：标记字段离开未读集，理由进报告可审计，不是静默豁免。
未读字段即笔误探测，真实读取与标记均计为消费。
@racket[record-flag!] 是消费期裁决：使用值时才发现的问题（路径不存在、
本机承载不了）当场标注，入报告 @racket['flags] 键；严重度只有两级，
@bold{缺省 warning}——升级 @racket['error] 是自觉动作，不是省事默认。}

@defproc[(consume/record [c any/c] [proc procedure?]
                         [#:function function symbol? 'consume])
         (values any/c hash?)]{
生产消费循环的一体化调用：必要时代为 @racket[resolve]，把 @racket[proc]
跑在录制视图上，返回其结果与规范形消费者报告。@racket[proc] 一元收录制源，
二元额外收 record（可 @racket[record-mark-read!]/@racket[record-flag!]）。
静默；@racket[debug-consume] 是它的打印外壳。}

@deftogether[(@defproc[(make-report [#:function function symbol?]
                                    [#:resolved r (or/c resolved? #f) #f]
                                    [#:record rec (or/c record? #f) #f]
                                    [#:source s (or/c config-source? #f) #f]
                                    [#:probes pr (or/c probe-record? #f) #f]) hash?]
              @defproc[(write-report [report hash?] [path path-string?]) path?]
              @defthing[report-format-version exact-integer?]
              @defproc[(explain-resolved [r resolved?]) string?]
              @defproc[(explain-issue [i issue?]) string?])]{
@filepath{.rktd} 规范形报告（单一可 @racket[read] 数据，无闭包；
@racket['values] 只含已填字段）与人类可读展开视图。}

@section{应用态调测（configkit/debug）}

@deftogether[(@defproc[(resolve-summary [c any/c]) hash?]
              @defproc[(peek [c any/c] [#:out out output-port? (current-output-port)]) resolved?]
              @defproc[(peek-field [c any/c] [field symbol?]
                                   [#:out out output-port? (current-output-port)]) resolved?]
              @defproc[(check-config [c any/c]
                                     [#:out out output-port? (current-output-port)]) boolean?]
              @defproc[(debug-consume [c any/c] [proc procedure?]
                                      [#:function function symbol? 'debug-consume]
                                      [#:out out output-port? (current-output-port)])
                       (values any/c hash?)]
              @defproc[(list-configs [#:heads heads hash? (current-config-search-heads)]) hash?]
              @defproc[(dump-report [c any/c] [path path-string?]
                                    [#:function function symbol? 'dev-check]) path?])]{
开发回路：健康度一行、展开+值表、单字段定义链、布尔门、消费者录制运行、
头表枚举、一步落盘。全部为公共查询面的薄封装，@bold{不属于生产路径}——
生产消费循环用 @racket[consume/record]（记录与报告一节），
@racket[debug-consume] 正是它的打印外壳。
@racket[debug-consume] 的 @racket[proc] 一元时收录制源；二元时额外收
record，可在消费过程中 @racket[record-mark-read!]/@racket[record-note!]/
@racket[record-flag!]。}
