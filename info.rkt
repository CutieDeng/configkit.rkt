#lang info

;; configkit: composable configuration framework — partial-record configs,
;; unification-based resolve with provenance, a consumer-facing source
;; protocol, read recording, and .rktd diagnostic reports.
;; Working name; renaming touches this file and the directory only.

(define collection "configkit")
(define deps '("base" "sandbox-lib"))
(define build-deps '("rackunit-lib"))

;; 文档刻意不进包元数据：不声明 scribblings，build-deps 里不列 scribble-lib
;; 与 racket-doc。理由是 raco pkg install 把 build-deps 无条件并进待装集合
;; （pkg/private/metadata.rkt 的 get-all-deps = (append deps build-deps)），
;; -D/--no-docs 只跳过编译、不跳过下载——声明一次 scribblings 就等于让每个
;; 最小安装去拉 scribble-lib（闭包约 37M，含 draw-lib、compatibility-lib）
;; 和 racket-doc（39M）。目标发行版不带任何文档库，这笔开销无处摊销。
;;
;; 手册改为在完整 Racket 的构建机上预渲染，见 build-docs.sh：--redirect-main
;; 把 for-label 交叉引用重写成 docs.racket-lang.org 的绝对地址，产出自包含
;; HTML，读者本地无需 racket-doc 也能点开这些链接。
;;
;; 不要按 `raco pkg new` 的模板把 scribble-lib / racket-doc 加回来——那三项
;; 逐字来自 collects/pkg/private/new.rkt 的脚手架默认值，不是本包的选择。
(define compile-omit-paths '("scribblings"))

(define pkg-desc "Composable configuration framework (configs, unification, provenance)")
(define version "0.1")
(define license 'MIT)
