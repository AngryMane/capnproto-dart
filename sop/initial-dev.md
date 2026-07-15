## Overview

このファイルは人間とAIが協力してソフトウェアを新規に開発する際の手続きを定める

## Trigger

* ソフトウェアを新規に開発するとき

## Workflow

1. [Setup](./steps/setup.md)
1. [Request](./steps/request.md)
1. [Design](./steps/design.md)
1. [Build](./steps/build.md)
1. （任意）[Validate](./steps/validate.md)
1. [Release](./steps/release.md)

### 種別（AIの裁量レベル）

| 種別 | AIの振る舞い |
|---|---|
| 対話 | 必ずユーザー合意を取りながら進める |
| 提案 | AIが初稿を作り、レビューを受ける |
| 指示 | 既存文書を入力として自律実行する |

### 必須

| 必須 | 意味 |
|---|---|
| true | このステップは必ず実施する |
| false | 状況に応じてスキップ可能 |
