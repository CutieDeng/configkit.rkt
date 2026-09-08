#!/bin/sh
# 预渲染 configkit 手册（scribblings/configkit.scrbl → 自包含 HTML）。
#
# 在**完整 Racket** 的构建机上跑，不在目标发行版上跑：configkit 的 info.rkt
# 刻意不声明 scribblings，所以 raco setup 不会碰文档，最小安装也就不会被拖去
# 下载 scribble-lib / racket-doc（合计约 76M）。理由见 info.rkt 的注释。
#
# --redirect-main 让 for-label 交叉引用（racket/base、racket/contract、
# racket/sandbox）解析后重写成 docs.racket-lang.org 的绝对地址；产物因此是
# 自包含的，读者本地没有任何文档库也能点开这些链接。
#
# 用法：./build-docs.sh [输出目录]   缺省输出到 doc/

set -eu

dest="${1:-doc}"
here="$(cd "$(dirname "$0")" && pwd)"

if ! racket -e '(require scribble/manual)' >/dev/null 2>&1; then
    echo "build-docs: 缺 scribble-lib，请在完整 Racket 发行版上构建文档" >&2
    exit 1
fi

# racket-doc 不是硬性的：缺了照样出 HTML，只是那 112 处 for-label 引用会退化
# 成纯文本，并打印一片 "undefined tags" 警告。提前说清楚，免得当成故障。
if ! racket -e '(void (collection-path "scribblings/reference"))' >/dev/null 2>&1; then
    echo "build-docs: 警告——未找到 racket-doc，交叉引用将渲染为纯文本" >&2
fi

mkdir -p "$dest"
raco scribble \
    +m --redirect-main https://docs.racket-lang.org/ \
    --dest "$dest" \
    "$here/scribblings/configkit.scrbl"

echo "build-docs: $dest/configkit.html"
