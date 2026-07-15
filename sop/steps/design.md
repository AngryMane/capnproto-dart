* Global Design
  * 必須: false
  * 種別: 対話
  * 内容: ユースケースを実現する際に関連するソフトウェアモジュールとそれらの全体的な関係をAIと対話して明確化する
  * 指示: ./docs/usecase.md、./docs/scope.md、./docs/constraint.md を参照し、ユースケースを実現する際に関連する外部モジュール・サービス・システムとこのリポジトリとの全体的な関係を明確にします。関係図と説明を ./docs/global-design.md に出力します。
  * 出力: ./docs/global-design.md
  * 完了条件: ./docs/global-design.md が生成され、ユーザーがレビューして承認した。
* Boundary Design
  * 必須: true
  * 種別: 提案
  * 内容: 対象のリポジトリが外部に提供するIFをAIが提案する。提案した内容はAIに出力させる。
  * 指示: ./docs/usecase.md、./docs/scope.md、./docs/constraint.md を参照し、このリポジトリが外部に提供するAPI・インターフェースを提案してください。エンドポイント・メソッドシグネチャ・データ型・エラーハンドリングを含む形で ./docs/boundary-design.md に出力してください。
  * 出力: ./docs/boundary-design.md
  * 完了条件: ./docs/boundary-design.md が生成され、ユーザーがレビューして承認した。
* Internal Design
  * 必須: true
  * 種別: 提案
  * 内容: 対象のリポジトリで開発するソフトウェアのアーキテクチャをAIが提案する。提案した内容はAIに出力させる。
  * 指示: ./docs/boundary-design.md を参照し、このリポジトリ内部のアーキテクチャを提案してください。レイヤー構造・モジュール分割・データフロー・主要なデザインパターンを含む形で ./docs/internal-design.md に出力してください。
  * 出力: ./docs/internal-design.md
  * 完了条件: ./docs/internal-design.md が生成され、ユーザーがレビューして承認した。