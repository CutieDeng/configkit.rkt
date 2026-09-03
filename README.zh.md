# configkit

[English](README.en.md) | 中文

configkit 是极简、易用、人体工程学的配置文件框架。

## 极简：一个完整的例子

`jobs/nightly.config`——一行一个字段，值位是数据，不求值：

```racket
[spec-src () "/opt/cpu2026"]
[copies  ((default 2) (validate (integer-between 1 64)))]
[tune    ((default "base") (validate (one-of "base" "peak")))]
```

应用层加载并读取：

```racket
(require configkit/main)

(parameterize ([current-config-search-heads (hash 'jobs "/srv/myapp/jobs")])
  (define r (resolve (load-config "@jobs/nightly")))
  (resolved-value r 'spec-src)   ; => "/opt/cpu2026"
  (resolved-value r 'copies))    ; => 2（默认值生效）
```

## 易用：配置写错时

`jobs/bad.config` 继承上面的文件，写错两处：

```racket
#:extends "nightly"
[tune   (override) "peek"]
[copies (override) 128]
```

应用层的错误出口：

```racket
(define r (resolve (load-config "@jobs/bad")))
(unless (resolved-ok? r)
  (display (explain-resolved r))
  (exit 1))
```

用户看到（真实输出）——错误一次报全，值与验证器各带行级来源，拼错的
枚举附提示：

```text
错误 (2):
  ✗ copies: 超出闭区间
    给定:     128
    期望:     (1 .. 64)
    值来自:   bad @ @jobs/bad.config:3
    验证器于: @jobs/nightly.config:2
  ✗ tune: 不在枚举集内
    给定:     peek
    期望:     ("base" "peak")
    提示:     是否想要 "peak"？
    值来自:   bad @ @jobs/bad.config:2
    验证器于: @jobs/nightly.config:3
```

## 人体工程学：不算错、但不对劲的配置

`jobs/sloppy.config`——必填字段没填、`env:` 族混进一个拼错的成员、
`copies` 拼成 `copise`：

```racket
#:extends "nightly"
[hw-avail (introduce required)]
[env:OMP_NUM_THREADS  (introduce) "8"]
[env:GOMP_CPU_AFFINITY (introduce) "0-63"]
[env:OMP_NUM_THREAD  (introduce) "4"]
[copise (introduce) 16]
```

未填不是错误，是一等状态，裁决权在应用。把消费者跑在录制视图上，
读取与使用的真实情形全部入档：

```racket
(define r (resolve (load-config "@jobs/sloppy")))
(resolved-ok? r)          ; => #t
(unfilled-fields r)       ; => #hasheq((hw-avail . required))

(debug-consume r
  (lambda (src rec)
    (define (ref k) (config-source-ref src k (lambda () (format "<unfilled:~a>" k))))
    (define envs (config-source-ref-group src 'env:))   ; 通配：env: 族一次读全
    (record-mark-read! rec 'tune "由运行期探测决定，渲染器有意不读")
    (format "run --src=~a --copies=~a --hw=~a ~a"
            (ref 'spec-src) (ref 'copies) (ref 'hw-avail)
            (string-join (for/list ([k (in-list (sort (hash-keys envs) symbol<?))])
                           (format "--env ~a=~a" k (hash-ref envs k))))))
  #:function 'render-cmdline)
```

打印出（真实输出）：

```text
―― render-cmdline
读集: (env:OMP_NUM_THREADS env:GOMP_CPU_AFFINITY env:OMP_NUM_THREAD spec-src copies hw-avail)
未填读取: (hw-avail)
标记: ((tune 由运行期探测决定，渲染器有意不读))
未读字段: (copise)
```

据此可逐条告知用户：`hw-avail` 读到但无值（输出里已是占位）；`env:`
三个成员被扫掠真实读走；`tune` 不读是声明过的，理由进报告；`copise`
填了没人读——是不是想写 `copies`？值的来历随手可查：

```racket
(peek-field r 'copies)
;; copies = 2
;;   defaulted  nightly @ @jobs/nightly.config:2
```

扫掠只认前缀，拼错的 `env:OMP_NUM_THREAD` 也被当真用掉。声明白名单
守卫，与任意配置并列组合，不支持的成员进警告（`require-known` 为
错误版）：

```racket
(define-config env-guard
  #:validate/post (warn-unknown 'env: 'env:OMP_NUM_THREADS 'env:GOMP_CPU_AFFINITY))

(display (explain-resolved (resolve (config (load-config "@jobs/sloppy") env-guard))))
```

```text
警告 (1):
  ✗ %config: 族内字段 env:OMP_NUM_THREAD 不受支持；是否想要 env:OMP_NUM_THREADS？
    验证器于: app.rkt:4
未填字段 (1):
  hw-avail（required）
```

消费中当场发现的问题用 `record-flag!` 标注，进报告 `'flags` 键，
缺省警告级。

## 应用层实践清单

- **生产消费循环**：`consume/record` 跑消费者，返回结果与规范形报告；
  `write-report` 归档：

  ```racket
  (define-values (output report) (consume/record r render #:function 'render))
  (write-report report "run.rktd")
  ```

  开发时换 `debug-consume`：同样约定，多打印读集/标记/消费问题
  （上一节的输出即来自它）。
- **未填 fail 选型**：渲染器传返回占位的过程；严格检查传抛错的过程；
  只探测存在用缺省哨兵 `source-missing`。
- **测试注入**：假 `.config` 树 = `current-config-search-heads` 指向
  替身目录；假代码基配置 = 头表里把同名头换绑到替身注册表命名空间。
  配置文本零修改，各一层 `parameterize`。
- **规模选型**：`(config c (hash 'k v))` 只用于测试与简单覆盖；
  成规模写 `define-config` 或 `.config`。
- **报告下游**：`.rktd` 是单个可 `read` 数据，测试端读回直接断言；
  CI 用 `(check-config c)` 做门，不健康时打印展开并返回 `#f`。
- **严重度准则**：守卫与 `record-flag!` 缺省标警告；升级错误
  （`require-known`、`#:severity 'error`）是自觉动作。

---

深入（模块地图、六轴语义、安全模型、陷阱清单）见
[contribute.zh.md](contribute.zh.md)；跑测试：`raco test tests/`。
