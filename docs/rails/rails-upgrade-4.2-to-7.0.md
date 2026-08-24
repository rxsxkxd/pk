# Rails 4.2 → 7.0 アップグレード 変更事項・修正事項一覧

- 出典: [Rails アップグレードガイド（railsguides.jp）](https://railsguides.jp/upgrading_ruby_on_rails.html)（2026-10-28 取得）
- 対象: 4.2→5.0 / 5.0→5.1 / 5.1→5.2 / 5.2→6.0 / 6.0→6.1 / 6.1→7.0
- 表の「節」はガイドの節番号。各バージョンで、ガイドに載っている項目はすべて表に入れた
- ガイドに載っているのは主な変更だけで、全体はリリースノートにある（ガイド自身が各章の冒頭で「詳しくは Rails X.Y のリリースノートを参照」としている）
- 「補足（ガイド外）」と書いた箇所は、ガイドにない情報を足したもの。使う前に一次資料で確かめること
- 各バージョンの章の「ガイド外の項目」の表は、ガイドに載っていない変更を集めたもの。ID の先頭を `X` にして、ガイドの節番号と区別している（ID の付け方と出典は [2.1](#21-ガイド外の項目の見方) を参照）

---

## 0. Ruby のバージョン

### 0.1 ガイドに書かれている必須バージョン

| Rails | 必須の Ruby（ガイド 1.2 節） |
|---|---|
| Rails 5（5.0〜5.2） | 2.2.2 以上 |
| Rails 6（6.0〜6.1） | 2.5.0 以上 |
| Rails 7.0（と 7.1） | 2.7.0 以上 |
| （参考）Rails 7.2 | 3.1.0 以上 |
| （参考）Rails 8.0 / 8.1 | 3.2.0 以上 |

ガイドの方針:

- Ruby と Rails は別々に上げる。先に Ruby をできるだけ新しくしてから Rails を上げる
- Rails 4.2 の必須 Ruby はガイドに書かれていない。5.0 に上げる前に 2.2.2 以上にしておく必要がある（ガイド 11.1 節）

### 0.2 Ruby 2.7 → 3.0 はいつ必要か

- ガイドによれば、4.2→7.0 の範囲では Ruby 3.0 は必須にならない。Rails 7.0 の下限は 2.7.0
- Ruby 3 系が初めて必須になるのは Rails 7.2（3.1.0 以上）。7.0 の先（7.1→7.2）へ進むなら、どこかで 2.7→3.x に上げる必要がある

補足（ガイド外。一次資料で確かめること）:

- Ruby 3.0 での一番大きい非互換は、キーワード引数の分離（位置引数のハッシュがキーワード引数に自動変換されなくなった）。Ruby 2.7 は該当箇所で非推奨警告を出すので、2.7 のうちに警告をなくしておくと 3.0 へ移りやすい
- 古い Rails（5.2 以前）は Ruby 3.0 に対応していない。目安としては、Rails を 6.1 以降に上げてから Ruby 3.0 に移ると安全。正確な対応範囲は各 Rails の CHANGELOG とリリースノートで確かめること
- Rails 7.0 で Ruby 3.1 を使うなら 7.0.1 以降にする
- サポート終了日: Ruby 2.7 は 2023-03-31、Ruby 3.0 は 2024-04-23。2.7 も 3.0 もすでにサポートが終わっているので、Ruby 3.0 は通過点にして、その先のバージョンまで上げる前提で計画するのがよい

---

## 1. 毎回の共通手順（ガイド 1.3〜1.5 節）

| 手順 | 内容 |
|---|---|
| 1 | テストを書き、すべて通ることを確かめる |
| 2 | 今のバージョンを、そのマイナー系列の最新パッチに上げる |
| 3 | テストと非推奨警告を直す |
| 4 | 次のマイナーバージョンの最新パッチに上げる（バージョンは飛ばさない） |
| 5 | Gemfile の Rails のバージョンを変えて `bundle update rails`。`package.json` の Rails の JS パッケージのバージョンも変える（jsbundling-rails を使っているなら `bin/rails javascript:install`） |
| 6 | `bin/rails app:update` を実行し、差分を確かめながら設定ファイルを更新する（diff/merge ツールは `THOR_DIFF` / `THOR_MERGE` で指定できる） |
| 7 | `config/initializers/new_framework_defaults_X_Y.rb` のコメントを 1 つずつ外し、新しいデフォルトを段階的に有効にする（デプロイを分けてもよい）。すべて有効にできたらこのファイルを消し、`config.load_defaults` を新しいバージョンに変える |
| 8 | テストを流す。1〜8 を目的のバージョンまで繰り返す |

### 1.1 ガイド外の共通事項

| ID | 区分 | 影響 | 内容 | 対応 |
|---|---|---|---|---|
| X00-WEB-01 | 依存 gem | 高 | 依存 gem が新しい Rails に対応しているかで、作業量が大きく変わる（どの事例でも作業の大半を占める） | [RailsBump](https://www.railsbump.org/) や `next_rails` の `bundle_report compatibility --rails-version=X.Y` で、事前に対応状況を調べる（FastRuby.io） |
| X00-WEB-02 | 手順 | 中 | 新旧の Rails を同じブランチで切り替えて動かせる（dual boot）と、差分を少しずつ本流に入れられる | `next_rails` gem の dual boot（`Gemfile.next`）を使う（FastRuby.io） |
| X00-WEB-03 | 手順 | 中 | `app:update` の差分だけでは、新規アプリとの設定の違いが分かりにくい | [RailsDiff](https://railsdiff.org/) で、新規アプリの X.Y と X.Y+1 の差分を見る（FastRuby.io） |
| X00-WEB-04 | 手順 | 中 | 非推奨警告はテストで出ない経路にもある | 本番でも `ActiveSupport::Deprecation` の警告をログに出し、集計してから直す（Money Forward、freee の事例） |
| X00-WEB-05 | 手順 | 中 | 修正をまとめてリリースすると、問題が起きたときに原因を絞りにくい | 新しいバージョンに上げる前に、旧バージョンでも動く修正は先にリリースしておく（Money Forward、AppBrew の事例） |

---

## 2. 一覧（バージョンごとの項目数と難易度）

| アップグレード | 項目数（節） | ガイド外（行数） | 難易度（概算） | 主な論点 | 難易度が上がる条件 |
|---|---|---|---|---|---|
| [4.2 → 5.0](#3-rails-42--rails-50) | 21（表の行は細目込みで 29） | 40 | ★★★★☆ 高<br><sub>決め手: 項目が 21 と最多。Ruby 2.2.2 への更新、ApplicationRecord / ApplicationJob の導入、複数機能の gem への切り出しや削除、`bin/rails` への移行など、どのアプリにも関係する変更が多い</sub> | Ruby 2.2.2、ApplicationRecord / ApplicationJob、`throw(:abort)`、gem への切り出し、`belongs_to` 必須化、Parameters の非 Hash 化 | `protected_attributes`（`attr_accessible`）を使っていて、strong parameters への全面移行が要る（★5）。`false` を返して止めるコールバックが多い。`params` をハッシュとして扱うコードが多い。`belongs_to` の関連先が空のデータがある。依存 gem（認証、管理画面など）が古く、Rails 5 対応版への更新が大きい |
| [5.0 → 5.1](#4-rails-50--rails-51) | 4 | 32 | ★★☆☆☆ 低〜中<br><sub>決め手: ガイドの項目は 4 つだけだが、ガイド外の表を見ると、5.0 で非推奨になった API の多くがここで一斉に削除される（`*_filter`、テストの位置引数、`false` でのコールバック停止、`alias_method_chain`、`uniq`、`xhr`、MIME 定数）。5.0 で警告をなくしてあれば機械的に直せる</sub> | `render :text` / `:nothing` と `redirect_to :back` の削除、secrets のシンボルキー化 | 5.0 の非推奨警告を残したまま来ると★3（`before_filter`、`get :show, id: 1` 形式のテスト、`return false` のコールバックが一度に壊れる）。バージョンなしのマイグレーションの付け替えもここで必須になる。secrets を String キーで読む箇所が多いと少し増える |
| [5.1 → 5.2](#5-rails-51--rails-52) | 2 | 27 | ★☆☆☆☆〜★★☆☆☆ 低<br><sub>決め手: ガイドの項目は 2 つで、Bootsnap の導入は任意。ガイド外の項目も多くは低影響の削除で、`load_defaults 5.2` の値は段階的に有効にできる</sub> | Bootsnap、cookie への有効期限埋め込み | cookie の互換性のために、ロールバックを考えたデプロイ手順を決める必要がある。`halt_callback_chains_on_return_false` の設定行が残っていると起動しない（X52-RN-21）。`default_protect_from_forgery` で API の受け口が CSRF エラーになる。生 SQL の `order` などに `Arel.sql` が必要になる（6.1 でエラーになるので、ここで直しておくと楽） |
| [5.2 → 6.0](#6-rails-52--rails-60) | 10（表の行は細目込みで 25） | 28 | ★★★☆☆〜★★★★☆ 中〜高<br><sub>決め手: Zeitwerk を除いても、cookie の互換性、`config.hosts`、`@rails` への改名、Action Cable の JS API、Active Storage の代入など、外から見える挙動の変更が多い</sub> | Zeitwerk、cookie の purpose メタデータ、`config.hosts`、npm パッケージの `@rails` 移動、Active Storage の代入 | ここで Zeitwerk に移るなら★4。命名規約違反（略語、`Concerns::`、1 ファイルに複数定数）、`require_dependency`、`lib/**` の自動読み込みが多いほど重い。classic のまま進めれば★3 だが、その作業は 7.0 に持ち越しになる。フロントエンドが Rails の npm パッケージに依存していると増える |
| [6.0 → 6.1](#7-rails-60--rails-61) | 7 | 32 | ★★☆☆☆〜★★★☆☆ 低〜中<br><sub>決め手: 項目が 7 つと少ない。`config_for`、`halted_callback_hook`、308 リダイレクト、`helper` の解決方法などは該当箇所が限られ、直し方も決まっている</sub> | `config_for` の String キー廃止、`ActiveModel::Error`、308 リダイレクト、image_processing 必須化 | `errors` をハッシュや配列として直接いじるコード（`errors[:x] << ...`、`errors.messages` の書き換えなど）が多い、またはそれに依存する gem があると★3。ガイド外では、`update_attributes` の削除、生 SQL のエラー化、`where.not` の NAND 化、`service_name` マイグレーション、`load_defaults 6.1`（SameSite=Lax、`form_with` の非 Ajax 化、メールのキュー名）が効く |
| [6.1 → 7.0](#8-rails-61--rails-70) | 15（表の行は細目込みで 23） | 27 | ★★★☆☆〜★★★★★ 中〜最高<br><sub>決め手: 項目が 15 と多く、削除や必須化が集中する（`ActiveSupport::Dependencies` の private API の削除、`config.autoloader=` の削除、spring 3.0 以上、Sprockets の任意化、`button_to` の挙動変更、スキーマダンプの差分確認）。Zeitwerk に移り済みでも一定の作業が残る</sub> | Zeitwerk 必須、SHA256 化（cookie / Digest）、キャッシュ形式 7.0、vips、Sprockets の任意化 | 6.0 / 6.1 で Zeitwerk に移っていないと★5（移行作業がまるごとここに来る）。cookie ローテータとキャッシュ形式の段階的なデプロイを設計する必要がある。初期化中の自動読み込みが多い。vips に移るなら variant の書き換えとキャッシュの無効化が加わる（任意）。ガイド外では、`to_s(:db)` の非推奨、外部リダイレクトのエラー化、cookie シリアライザ（`:marshal` のアプリ）、トランザクションの早期 return のロールバック化、`datetime` の精度が効く |

難易度の目安（ガイドにはない、筆者の概算）:

- ★1: 機械的な置換で済み、半日〜数日
- ★3: 挙動変更の調査とテストの修正が要り、数日〜2 週間
- ★5: 設計の見直しや大規模な書き換え、またはデプロイ手順の設計が要り、数週間以上

日数は、中規模アプリ（モデル数十〜百程度）でテストがそろっている場合のおおまかな目安です。

評価の前提と注意:

- ガイドの項目に加え、ガイド外の表も見て評価している（5.0→5.1 と 5.1→5.2 は、ガイド外の表を作ってから上げた）。それでも実際には **依存 gem の更新**（各 gem の新しい Rails への対応状況、gem 同士の依存の衝突）と、**前の段階から持ち越した非推奨警告の解消** が作業の大半になることが多く、これはプロダクトの事情で大きく変わる
- テストカバレッジが低いと、どの段階でも 1〜2 段階難しくなる（挙動変更を見つけられないため）
- Ruby の更新を同時にやると難易度が上がる（ガイドも Ruby と Rails は別々に上げることを勧めている）。特に Ruby 3.0 のキーワード引数分離（[0.2](#02-ruby-27--30-はいつ必要か)）
- 4.2→7.0 全体の山場は **4.2→5.0** と **Zeitwerk 移行（6.0 か 7.0）** の 2 か所。5.0→5.2 と 6.0→6.1 は比較的軽い

区分の意味: **必須** = 対応しないと動かない、または壊れる / **削除** = 機能や API の削除 / **非推奨** = 将来削除される / **挙動変更** = 同じコードの結果が変わる / **新設定** = 任意で有効にできる設定 / **環境** = 依存やツールの要件

### 2.1 ガイド外の項目の見方

各章の「ガイド外の項目」の表は、次の 4 つの情報源から集めた。ID は `X<移行先のバージョン>-<出典>-<連番>` の形（例: `X51-RN-05` は、5.1 に上げるときのリリースノート由来の 5 番目）。

| ID の出典部分 | 情報源 | 集め方 |
|---|---|---|
| `RN` | 各バージョンのリリースノート（railsguides.jp。6.1 は日本語版に「準備中」が多いため英語版と照合） | 「非互換性」「削除されたもの」「非推奨」のすべてと、「主な変更点」のうち既存の挙動が変わるものを入れた。ガイドの項目と同じ内容は除いた |
| `CL` | 各フレームワークの CHANGELOG（`rails/rails` の `X-Y-stable`） | 削除と非推奨の記述を機械的に抜き出してリリースノートと突き合わせ、リリースノートにないものを入れた |
| `LD` | `config.load_defaults` の実装（`railties/lib/rails/application/configuration.rb` の 6-0 / 6-1 / 7-0-stable） | 新しいデフォルト値のうち、ガイドに書かれていないもの |
| `WEB` | 事例やアップグレード解説（ruby-jp の Upgrade Knowledge に載っている記事、FastRuby.io） | 一次資料にない、実際に起きた問題とその対処。一次資料で確かめられたものはその旨を書いた |

- 細かい API の削除や非推奨は、フレームワークごとに 1 行にまとめた（名前はすべて書いてある）。影響の大きいものは別の行にした
- 「影響」は、ふつうのアプリで当たりやすいかどうかの目安（高 / 中 / 低）
- CHANGELOG には不具合修正や新機能も大量にあるが、それらは対象にしていない。網羅したのは、削除・非推奨・デフォルトの変更・事例で報告された非互換まで

---

## 3. Rails 4.2 → Rails 5.0

| 節 | 区分 | 変更事項 | 修正事項（対応） |
|---|---|---|---|
| 11.1 | 環境 | Ruby 2.2.2 以上が必須 | 先に Ruby を 2.2.2 以上に上げる |
| 11.2 | 必須 | モデルは `ApplicationRecord` を継承するのがデフォルトになった | `app/models/application_record.rb` を作る（`class ApplicationRecord < ActiveRecord::Base` / `self.abstract_class = true`）。全モデルの継承元を `ApplicationRecord` に変える |
| 11.3 | 挙動変更 | Active Record / Active Model の before 系コールバックで `false` を返しても、チェインが止まらなくなった。止めるには `throw(:abort)` を使う | 止めたいコールバックを `throw(:abort)` に書き換える。アップグレード直後は `false` でも従来どおり止まるが、非推奨警告が出る。影響を理解したうえで警告を消すなら `config/application.rb` に `ActiveSupport.halt_callback_chains_on_return_false = false` を書く。Active Support のコールバックはこの設定の影響を受けない（どの値を返しても止まらない）（#17227） |
| 11.4 | 必須 | ジョブは `ApplicationJob` を継承するのがデフォルトになった | `app/jobs/application_job.rb` を作る（`class ApplicationJob < ActiveJob::Base`）（#19034） |
| 11.5.1 | 削除 | `assigns` と `assert_template` が `rails-controller-testing` gem に切り出された | 使い続けるなら Gemfile に `gem "rails-controller-testing"` を足す。RSpec を使っているなら、gem のドキュメントにある追加設定も行う |
| 11.5.2 | 挙動変更 | ファイルアップロードのテストで使うクラスが変わった | `ActionDispatch::Http::UploadedFile` を `Rack::Test::UploadedFile` に変える（#26404） |
| 11.6 | 挙動変更 | production では起動後の自動読み込みが無効になった（eager load は起動処理に含まれる） | ほとんどのアプリは対応不要。production でどうしても自動読み込みが要るなら `Rails.application.config.enable_dependency_loading = true` |
| 11.7 | 削除 | `ActiveModel::Serializers::Xml` が `activemodel-serializers-xml` gem に切り出された | XML シリアライズを使うなら `gem "activemodel-serializers-xml"` を足す |
| 11.8 | 削除 | 古い `mysql` アダプタのサポートが終わった | `mysql2` に移る |
| 11.9 | 削除 | `debugger` のサポートが終わった（Ruby 2.2 で動かない） | `byebug` に移る |
| 11.10 | 挙動変更 | タスクやテストは `bin/rails` で実行する（一部は `bin/rails` にしかない） | テストは `bin/rails test`、`rake dev:cache` は `bin/rails dev:cache`。CI やスクリプトの呼び出しを直す |
| 11.11 | 挙動変更 | `ActionController::Parameters` が `HashWithIndifferentAccess` を継承しなくなった（`params` はハッシュでなくオブジェクトを返す） | `permitted?` に関係なくハッシュとして読める前提の処理（`slice` など）は、`params.permit([:proceed_to, :return_to]).to_h` のように `permit` してから `to_h` で変換する |
| 11.12 | 挙動変更 | `protect_from_forgery` のデフォルトが `prepend: false` になった（呼び出した位置でチェインに入る） | いつも最初に実行させたいなら `protect_from_forgery prepend: true` |
| 11.13 | 挙動変更 | 拡張子がテンプレートハンドラでないファイルは、ERB でなく raw ハンドラで出力されるようになった | ERB などで処理させたいファイルには拡張子を明示する |
| 11.14 | 新機能 | テンプレート依存関係の指定でワイルドカードが使えるようになった（`<% # Template Dependency: recordings/threads/events/* %>`） | 任意。複数行の依存指定を 1 行にまとめられる |
| 11.15 | 削除 | `content_tag_for` と `div_for`（`RecordTagHelper`）が削除され、`record_tag_helper` gem に移った | `content_tag` に書き換える。使い続けるなら `gem "record_tag_helper", "~> 1.0"`（#18411） |
| 11.16 | 削除 | `protected_attributes` gem のサポートが終わった | 使うのをやめる |
| 11.17 | 削除 | `activerecord-deprecated_finders` gem のサポートが終わった | 使うのをやめる |
| 11.18 | 挙動変更 | `ActiveSupport::TestCase` のテストの実行順が `:sorted` から `:random` になった | 順序に依存するテストを直す。戻すなら `config/environments/test.rb` に `config.active_support.test_order = :sorted` |
| 11.19 | 挙動変更 | `ActionController::Live` が Concern になった | `ActionController::Live` を include している自作モジュール（コントローラに include するもの）には `extend ActiveSupport::Concern` を足す。または、`self.included` フックでコントローラに直接 `ActionController::Live` を include する。そうしないと production で正しく動かないことがある |
| 11.20.1 | 新設定 | `belongs_to` の関連先がないとバリデーションエラーになるのがデフォルトになった（新規アプリ） | 既存アプリはイニシャライザで `config.active_record.belongs_to_required_by_default = true`。モデルごとに `self.belongs_to_required_by_default = false/true` で上書きできる。関連ごとに外すなら `optional: true` |
| 11.20.2 | 新設定 | フォームごとの CSRF トークン | `config.action_controller.per_form_csrf_tokens = true` |
| 11.20.3 | 新設定 | `Origin` ヘッダを使った CSRF チェック | `config.action_controller.forgery_protection_origin_check = true` |
| 11.20.4 | 新設定 | Action Mailer のキュー名を変えられるようになった（デフォルトは `mailers`） | `config.action_mailer.deliver_later_queue_name = :new_queue_name` |
| 11.20.5 | 新設定 | Action Mailer のビューでフラグメントキャッシュが使えるようになった | `config.action_mailer.perform_caching = true` |
| 11.20.6 | 新設定 | `db:structure:dump` の出力を指定できるようになった（PostgreSQL の `schema_search_path` など） | `config.active_record.dump_schemas = :all`（または `:schema_search_path`） |
| 11.20.7 | 新設定 | サブドメインにも HSTS をかけられるようになった | `config.ssl_options = { hsts: { subdomains: true } }` |
| 11.20.8 | 新設定 | `to_time` がレシーバのタイムゾーンを保つかどうか（Ruby 2.4 以降） | ガイドの記載: `ActiveSupport.to_time_preserves_timezone = false`。ただし `load_defaults 5.0` が設定するのは `true`（タイムゾーンを保つ）で、ガイドの記載と逆になっている（[X50-LD-01](#31-ガイド外の項目42--50)） |
| 11.21 | 挙動変更 | JSON / JSONB 属性のシリアライズ方法が変わった。`String` を代入すると `Hash` に変換されず、その文字列のまま返る。`db/schema.rb` の `:default` にも影響する | JSON / JSONB カラムには `String` でなく `Hash` を渡す（JSON 文字列との相互変換は自動で行われる） |

### 3.1 ガイド外の項目（4.2 → 5.0）

| ID | 区分 | 影響 | 変更事項 | 修正事項（対応） |
|---|---|---|---|---|
| X50-RN-01 | 削除 | 中 | Railties: `test:all` / `test:all:db` タスク、`Rails::Rack::LogTailer`、定数 `RAILS_CACHE`、設定 `serve_static_assets`、タスク `doc:app` / `doc:rails` / `doc:guides` が削除された | 使っている箇所を置き換える（`RAILS_CACHE` は `Rails.cache`、テストは `bin/rails test`） |
| X50-RN-02 | 挙動変更 | 低 | `Rack::ContentLength` がデフォルトのミドルウェアから外れた | `Content-Length` に依存しているなら、`config.middleware.use Rack::ContentLength` を足す |
| X50-RN-03 | 非推奨 | 中 | `config.serve_static_files` と `config.static_cache_control` が非推奨になった（5.1 で削除） | `config.public_file_server.enabled` と `config.public_file_server.headers = { "Cache-Control" => "..." }` に置き換える（[X51-RN-02](#41-ガイド外の項目50--51)） |
| X50-RN-04 | 非推奨 | 低 | `rails:` 名前空間のタスク（`rails:update`、`rails:template` など）が非推奨になった（5.1 で削除） | `app:update`、`app:template` に変える |
| X50-RN-05 | 挙動変更 | 低 | `tmp/sessions` ディレクトリと、それを消すタスクが削除された | スクリプトで参照しているなら外す |
| X50-RN-06 | 削除 | 高 | `respond_to` / `respond_with` のクラスレベルの仮実装が削除され、responders gem に移った | `respond_with` やクラスレベルの `respond_to` を使っているなら `gem "responders"`（4.2 のガイド 12.2 と同じ対応） |
| X50-RN-07 | 削除 | 中 | Action Pack の非推奨 API の削除: `ActionController::HideActions`、`deep_munge`（`Request::Utils` / `Request#`）、`*_path` ヘルパーの `only_path`、URL ヘルパーの文字列キー、`NamedRouteCollection#helpers`、`#` を含まない `:to`、`Response#to_ary`、`symbolized_path_parameters`、コントローラテストの `use_route`、非推奨のアサーションファイル | 該当箇所を直す（例: ルーティングは `to: "controller#action"` の形にする） |
| X50-RN-08 | 非推奨 | 高 | `before_filter` などの `*_filter` 系コールバックと、`skip_action_callback` が非推奨になった（5.1 で削除: [X51-RN-05](#41-ガイド外の項目50--51)） | `*_filter` を `*_action` に置き換える（`skip_before_filter` → `skip_before_action` など） |
| X50-RN-09 | 非推奨 | 中 | 結合テストの `*_via_redirect`（`get_via_redirect` など）が非推奨になった（5.1 で削除） | リクエストの後に `follow_redirect!` を呼ぶ |
| X50-RN-10 | 非推奨 | 中 | `render nothing: true` と、`head` の第 1 引数にハッシュを渡す書き方・ステータスを省略する書き方が非推奨になった | `head :ok` のようにステータスを明示する（`render :nothing` は 5.1 で削除: ガイド 10.3） |
| X50-RN-11 | 非推奨 | 中 | ミドルウェアを文字列やシンボルで指定する書き方が非推奨になった（5.1 で削除） | `config.middleware.use "Foo"` を `config.middleware.use Foo` のようにクラスで指定する |
| X50-RN-12 | 非推奨 | 中 | MIME タイプの定数（`Mime::HTML` など）が非推奨になった（5.1 で削除） | `Mime[:html]` に変える |
| X50-RN-13 | 非推奨 | 高 | `ActionController::TestCase` と `ActionDispatch::IntegrationTest` のリクエストメソッドに、位置引数で値を渡す書き方が非推奨になった（5.1 で削除） | `get :show, id: 1` を `get :show, params: { id: 1 }` のように、`params:` / `headers:` / `xhr:` などのキーワード引数に変える（RSpec でも同じ） |
| X50-RN-14 | 非推奨 | 中 | ルーティングで、パスパラメータに `:controller` / `:action` を使う書き方が非推奨になった | 動的なコントローラやアクションの指定をやめ、ルートを明示的に書く |
| X50-RN-15 | 非推奨 | 低 | コントローラのインスタンスメソッド `env` が非推奨になった | `request.env` に変える |
| X50-RN-16 | 非推奨 | 低 | `ActionDispatch::ParamsParser` が非推奨になり、ミドルウェアスタックから外れた | パーサーを設定するなら `ActionDispatch::Request.parameter_parsers=` を使う |
| X50-RN-17 | 挙動変更 | 中 | Rails が生成する ETag が、強い ETag から弱い ETag（`W/"..."`）に変わった | CDN やクライアントが強い ETag を前提にしていないか確かめる |
| X50-RN-18 | 挙動変更 | 中 | `render` を呼ばず、対応するテンプレートもないアクションが、エラーでなく `head :no_content`（204）を返すようになった | テンプレートがないときのエラーを期待しているテストを直す |
| X50-RN-19 | 挙動変更 | 低 | 破棄された flash メッセージは、セッションに保存せずに除くようになった | ― |
| X50-RN-20 | 挙動変更 | 中 | submit ボタンに `data-disable-with` が付くのがデフォルトになった（送信中はボタンが無効になる） | E2E テストや独自の JS を確かめる。外すなら `data: { disable_with: false }` |
| X50-RN-21 | 挙動変更 | 低 | `datetime_tag` が `type="datetime-local"` の input を生成するようになった | 表示や JS を確かめる |
| X50-RN-22 | 削除 | 低 | Action View: `AbstractController::Base::parent_prefixes` と、`translate` の `:rescue_format` オプションが削除された | 使っている箇所を直す |
| X50-RN-23 | 削除 | 中 | Action Mailer: 非推奨の `deliver` / `deliver!` と、メールビューでの `*_path` ヘルパーが削除された | `deliver_now` / `deliver_later` と `*_url` に変える |
| X50-RN-24 | 挙動変更 | 低 | メーラーのテンプレートを探すとき、デフォルトロケールにフォールバックするようになった | ― |
| X50-RN-25 | 削除 | 中 | Active Record の非推奨機能の削除: クエリ値にネストした配列を渡す、`serialized_attributes`、`has_many :through` のカウンタキャッシュの自動適用、`sanitize_sql_hash_for_conditions`、`Reflection#source_macro`、`symbolized_base_class` / `symbolized_sti_name`、`disable_implicit_join_references=`、文字列アクセサでの接続指定（文字列はすべて URL 扱い）、インスタンスに依存する関連のプリロード、PostgreSQL の下限を含まない範囲、キャッシュ済みの Arel を持つリレーションの変更（`ImmutableRelation` になる）、`DatabaseTasks#load_schema` | 該当箇所を直す（`load_schema` は `load_schema_for` に変える） |
| X50-RN-26 | 環境 | 中 | PostgreSQL 9.1 以前のサポートが終わった | DB を上げる |
| X50-RN-27 | 非推奨 | 高 | Active Record の非推奨（多くは 5.1 で削除）: `Relation#uniq`、`use_transactional_fixtures`、関連の強制再読み込み `user.posts(true)`、`belongs_to` の `required:`、クエリ値にクラスを渡す、`errors_in_transactional_callbacks=`、PostgreSQL の `:point`、`restrict_dependent_destroy` のエラーキー、`#tables` / `table_exists?` の挙動、`SchemaCache#tables` など、`find_nth` の offset 引数、`{insert,update,delete}_sql`、`connection#quote` にカラムを渡す | `distinct`、`use_transactional_tests`、`user.posts.reload`（単数の関連は `reload_author` など）、`optional:`、文字列を渡す、`data_sources` / `data_source_exists?` に置き換える |
| X50-RN-28 | 挙動変更 | 中 | 5.0 のマイグレーションでは `timestamps` が `null: false` になるのがデフォルトになった | `[4.2]` 指定の既存マイグレーションには影響しない。新しいマイグレーションで NULL を許すなら明示する |
| X50-RN-29 | 削除 | 低 | Active Model: `Dirty#reset_#{attr}`、`reset_changes`、`ActionController::ModelNaming` が削除された | `restore_#{attr}!`、`clear_changes_information` などに置き換える |
| X50-RN-30 | 非推奨 | 中 | Active Model: `Errors#get` / `#set` / `#[]=`、`validates_length_of` の `:tokenizer`、`Errors#add_on_empty` / `#add_on_blank` が非推奨になった（5.1 で削除） | `errors.add` / `errors[:attr]` に変える。tokenizer は Ruby で前処理する |
| X50-RN-31 | 挙動変更 | 高 | Active Job のデフォルトのアダプタが `:inline` から `:async` になった（ジョブがリクエストと別スレッドで非同期に動く） | アダプタを設定していないアプリは、`config.active_job.queue_adapter` を明示する。テストでは `:test` アダプタや `perform_enqueued_jobs` を使う |
| X50-RN-32 | 削除 | 中 | Active Support の非推奨 API の削除: `JSON::Encoding::CircularReferenceError`、`encode_big_decimal_as_string`、`SafeBuffer#prepend`、`Kernel#silence_stderr` / `silence_stream` / `capture` / `quietly`、`big_decimal/yaml_conversions`、`Cache::Store.instrument`、`Class#superclass_delegating_accessor`、`ThreadSafe::Cache`、`Object#itself`（Ruby 本体のものを使う） | `class_attribute`、`Concurrent::Map` などに置き換える。gem が使っていないかも確かめる |
| X50-RN-33 | 非推奨 | 高 | Active Support の非推奨（5.1 で削除）: `alias_method_chain`、`MissingSourceFile`、`Concurrency::Latch`、`number_to_human_size` の `:prefix`、`Module#qualified_const_*`、コールバック定義に文字列を渡す、`Cache::Store#namespaced_key` など、`assert_nothing_raised` に引数を渡す、`Module.local_constants` | `Module#prepend`、`LoadError`、`Concurrent::CountDownLatch`、`const_get` など、`normalize_key`、`Module.constants(false)` に置き換える |
| X50-RN-34 | 挙動変更 | 低 | `parse_json_times` が有効なとき、`ActiveSupport::JSON.decode` が日付の文字列（`YYYY-MM-DD`）を `Date` に、`Z` のない時刻をローカル時刻に変換するようになった | `parse_json_times` を有効にしている場合だけ確かめる |
| X50-CL-01 | 非推奨 | 中 | `delete_all` / `destroy_all` に条件を渡す書き方が非推奨になった（5.1 で削除） | `where(...).delete_all` に変える |
| X50-CL-02 | 非推奨 | 低 | ルーティングでパスを省略する書き方（`get action: :show`）が非推奨になった（5.0.1） | `get "", action: :show` のようにパスを明示する |
| X50-CL-03 | 必須 | 高 | マイグレーションクラスに、Rails のバージョンを付けるようになった（`ActiveRecord::Migration[5.0]`）。4.2 と 5.0 では文字列カラムなどのデフォルトが違う（FastRuby.io） | 既存のマイグレーションを `ActiveRecord::Migration[4.2]` に書き換える（5.1 では、バージョンなしで継承するとエラーになる: [X51-RN-18](#41-ガイド外の項目50--51)） |
| X50-LD-01 | 新設定 | 中 | `load_defaults 5.0` が設定する値: `per_form_csrf_tokens`、`forgery_protection_origin_check`、`belongs_to_required_by_default`、`ssl_options = { hsts: { subdomains: true } }`（以上はガイド 11.20）に加えて、`ActiveSupport.to_time_preserves_timezone = true` | ガイド 11.20.8 は `false` と書いているが、`load_defaults` が設定する新しい値は `true`（タイムゾーンを保つ） |
| X50-WEB-01 | 環境 | 低 | Ruby 2.2 に上げると、`cannot load such file -- test/unit/assertions` になることがある | Gemfile に `gem "test-unit"` を足す（FastRuby.io） |
| X50-WEB-02 | 必須 | 高 | `protected_attributes`（`attr_accessible`）は 5.0 で使えない（ガイド 11.16） | 5.0 に上げる前に strong parameters に移る。`protected_attributes_continued` での延命は勧められていない（FastRuby.io） |

---

## 4. Rails 5.0 → Rails 5.1

| 節 | 区分 | 変更事項 | 修正事項（対応） |
|---|---|---|---|
| 10.1 | 非推奨 | トップレベルの `HashWithIndifferentAccess` がゆるやかに非推奨になった（警告は出ないが、将来削除される） | `ActiveSupport::HashWithIndifferentAccess` に置き換える。このオブジェクトをダンプした古い YAML があるなら、読み込んでダンプし直し、正しい定数を参照させる |
| 10.2 | 挙動変更 | `config/secrets.yml` のネストしたキーがすべてシンボルで読み込まれるようになった | `Rails.application.secrets[:smtp_settings]["address"]` を `[:smtp_settings][:address]` に変える |
| 10.3 | 削除 | `render :text` と `render :nothing` が削除された | `render :plain`（`text/plain`）に変える。ヘッダーだけ返すなら `head :ok` など |
| 10.4 | 削除 | `redirect_to :back` が削除された（5.0 で非推奨） | `redirect_back(fallback_location: root_path)` に変える |

### 4.1 ガイド外の項目（5.0 → 5.1）

| ID | 区分 | 影響 | 変更事項 | 修正事項（対応） |
|---|---|---|---|---|
| X51-RN-01 | 非互換 | 中 | トランザクションテストで、Active Record のすべての接続がトランザクションに包まれるようになった。テスト中に作ったスレッドも同じ接続を共有する（fixture が見えるようになる） | スレッドが別の接続を使う前提のテストは、接続を明示的に管理する。明示的なトランザクションに変えるとデッドロックすることがある。影響するテストケースだけ `self.use_transactional_tests = false` にするのが簡単 |
| X51-RN-02 | 削除 | 中 | Railties: `config.static_cache_control`、`config.serve_static_files`、`rails/rack/debugger`、タスク `rails:update` / `rails:template` / `rails:template:copy` / `rails:update:configs` / `rails:update:bin`、`routes` タスクの `CONTROLLER` 環境変数、`rails new -j` が削除された | `config.public_file_server.enabled` と `config.public_file_server.headers` に変える。タスクは `app:*`、ルートは `rails routes -c` |
| X51-RN-03 | 挙動変更 | 低 | 新規アプリのデフォルトから jquery-rails が外れた（rails-ujs が Action View に入った） | 既存アプリは Gemfile の jquery-rails をそのまま使える |
| X51-RN-04 | 削除 | 高 | テストのリクエストメソッドで、キーワード引数でない書き方ができなくなった（`#process`、`#get`、`#post`、`#patch`、`#put`、`#delete`、`#head`） | `post :create, params: { ... }` に変える（[X50-RN-13](#31-ガイド外の項目42--50)） |
| X51-RN-05 | 削除 | 高 | **`*_filter` 系のメソッドが削除された**: `before_filter`、`after_filter`、`around_filter`、`skip_before_filter` など、`prepend_*` / `append_*` の各 filter、`skip_filter`、`skip_action_callback` | `before_action`、`skip_before_action` などに置き換える。gem が使っていないかも確かめる |
| X51-RN-06 | 削除 | 中 | `ActionController::Parameters` で、`HashWithIndifferentAccess` のメソッドを呼べなくなった（5.0 では非推奨警告付きで動いていた） | `permit(...).to_h` してからハッシュのメソッドを使う（ガイド 11.11） |
| X51-RN-07 | 削除 | 低 | `ActionDispatch::Callbacks.to_prepare` / `.to_cleanup` が削除された（CHANGELOG では `ActionDispatch::Reloader` の `to_prepare` / `to_cleanup` / `prepare!` / `cleanup!` も削除） | `ActiveSupport::Reloader.to_prepare` か `Rails.application.config.to_prepare` を使う |
| X51-RN-08 | 非推奨 | 低 | `config.action_controller.raise_on_unfiltered_parameters`（5.1 ではもう効かない）と、パスパラメータの `:controller` / `:action` が非推奨になった | 設定の行を消す |
| X51-RN-09 | 削除 | 低 | Action View: `ActionView::Template::Error#original_exception` が削除され、`strip_tags` の `encode_special_chars` の名前の誤りが直された | `cause` を使う |
| X51-RN-10 | 非推奨 | 中 | テンプレートエンジンの Erubis が非推奨になり、Erubi に移った（5.2 で削除） | Erubis 固有の設定や、`Erubis` 定数を参照するコードがないか確かめる |
| X51-RN-11 | 挙動変更 | 低 | raw テンプレートハンドラが HTML セーフな文字列を出力するようになった | ― |
| X51-RN-12 | 挙動変更 | 中 | メーラーのアクション、メッセージの配信、遅延配信ジョブで上がった例外が、`rescue_from` で処理されるようになった | `rescue_from` を定義したメーラーで、例外の伝わり方が変わらないか確かめる |
| X51-RN-13 | 削除 | 中 | Active Record の非推奨機能の削除: `select` に引数とブロックを同時に渡す、`restrict_dependent_destroy.one` / `.many` の i18n スコープ、関連 reader の強制再読み込み引数、`#quote` にカラムを渡す、`#tables` の `name` 引数、**`table_exists?` がビューを含まなくなった**、`StatementInvalid#original_exception`、クエリ値にクラスを渡す、LIMIT にカンマを使う、`destroy_all` / `delete_all` の条件、`load_schema_for`、`raise_in_transactional_callbacks`、`use_transactional_fixtures` | `user.posts.reload`、`use_transactional_tests`、`cause`、`view_exists?` などに置き換える（設定ファイルの行も消す） |
| X51-RN-14 | 非推奨 | 中 | Active Record の非推奨: `error_on_ignored_order_or_limit`、`sanitize_conditions`、`supports_migrations?`、`Migrator.schema_migrations_table_name`、`#quoted_id`、`index_name_exists?` に default を渡す。CHANGELOG ではさらに: `supports_primary_key?`、`ColumnDumper#migration_keys`、`initialize_schema_migrations_table`、`class_name:` にクラスを渡す、`indexes` に name を渡す、**未保存の変更があるレコードのロック（`lock!`）** | `error_on_ignored_order`、`sanitize_sql`、`SchemaMigration.table_name` に変える。`class_name: "Foo"` は文字列で渡す。`lock!` は保存してから、または `reload` してから呼ぶ |
| X51-RN-15 | 挙動変更 | 中 | 5.1 のマイグレーションでは、主キーのデフォルトの型が BIGINT になった | 既存の INT の主キーを参照する外部キーを作るときは、型を合わせる（`references ..., type: :integer`） |
| X51-RN-16 | 挙動変更 | 低 | `mysqldump` の出力のコメントをスキップするようになった。`psql` に `-v ON_ERROR_STOP=1` を渡すようになった | `structure.sql` の差分と、SQL 読み込みがエラーで止まるようになる点を確かめる |
| X51-RN-17 | 挙動変更 | 中 | `Relation#count` にブロックを渡すと、無視されずに `Enumerable#count` で数えるようになった（全件読み込む） | `count { ... }` を使っている箇所の性能と結果を確かめる |
| X51-RN-18 | 必須 | 高 | `ActiveRecord::Migration` をバージョンなしで直接継承すると、エラーになるようになった | 既存のマイグレーションに `[4.2]` などを付ける（[X50-CL-03](#31-ガイド外の項目42--50)） |
| X51-RN-19 | 挙動変更 | 低 | `through` 関連で reflection の名前があいまいなとき、エラーになるようになった | `source:` を明示する |
| X51-RN-20 | 削除 | 中 | Active Model: `Errors` の非推奨メソッド（`get` / `set` / `[]=` / `add_on_empty` / `add_on_blank`）と、length バリデータの `:tokenizer` が削除された | [X50-RN-30](#31-ガイド外の項目42--50) の置き換えをする |
| X51-RN-21 | 削除 | 高 | **コールバックで `false` を返すとチェーンが止まる動作が削除された**（Active Model / Active Record / Active Support）。`ActiveSupport.halt_callback_chains_on_return_false` も非推奨になった（5.2 で削除） | ガイド 11.3 の非推奨期間は 5.0 だけで終わる。5.1 に上げる前に `throw(:abort)` に書き換える（FastRuby.io も `before_destroy` で `throw :abort` が必須になる点を挙げている） |
| X51-RN-22 | 削除 | 低 | Active Job: `.queue_adapter` にアダプタのクラスを渡す書き方と、`DeserializationError#original_exception` が削除された | シンボルかインスタンスを渡す。`cause` を使う |
| X51-RN-23 | 削除 | 中 | Active Support の非推奨 API の削除（`Concurrency::Latch` は リリースノート、ほかは CHANGELOG）: `MissingSourceFile`、`Module.qualified_const_defined?` / `_get` / `_set`、`number_to_human_size` の `:prefix`、`HashWithIndifferentAccess.new_from_hash_copying_default`、`core_ext` の `time/marshal.rb` / `struct.rb` / `module/method_transplanting.rb` / `kernel/debugger.rb`、`Module.local_constants`、`Cache::Store#namespaced_key`、`LocalStore#set_cache_value`、`MemCacheStore#escape_key`、`FileStore#key_file_path`、`assert_nothing_raised` の引数、`Numeric#to_formatted_s`（非推奨のもの） | [X50-RN-33](#31-ガイド外の項目42--50) の置き換えをする。gem の対応版も確かめる |
| X51-RN-24 | 非推奨 | 中 | `set_callback` / `skip_callback` と、`before_action` などの `:if` / `:unless` に文字列を渡す書き方が非推奨になった（5.2 で削除） | `unless: "foo?"` を `unless: :foo?` かラムダに変える（FastRuby.io にも同じ例がある） |
| X51-RN-25 | 挙動変更 | 低 | `travel` / `travel_to` を入れ子で呼ぶとエラーになるようになった。期間の計算が夏時間の切り替えをまたいでも一貫するようになった | 入れ子の `travel_to` をやめる |
| X51-CL-01 | 削除 | 中 | Action Pack の削除（CHANGELOG のみ）: `ActionController::Metal.call` / `#env`、`IntegrationTest#*_via_redirect`、**`xml_http_request` / `xhr`**（IntegrationTest と TestCase）、`match` の `:path` を文字列で渡す・パスを `nil` で渡す、`ActionDispatch::Static` の `cache_control` 引数、ミドルウェアを文字列やシンボルで指定する、ssl の `host` / `port` オプション、`SessionRestoreError` の引数と `#original_exception`、`ActionDispatch::ParamsParser`（`ParseError` は `ActionDispatch::Http::Parameters::ParseError` に）、**MIME 定数（`Mime::HTML`）**、`BadRequest#original_exception` | `xhr :get, ...` を `get ..., xhr: true` に、`Mime::HTML` を `Mime[:html]` に、ミドルウェアはクラスで指定する（[X50-RN-09〜16](#31-ガイド外の項目42--50)） |
| X51-CL-02 | 削除 | 高 | `#uniq` / `#uniq!` / `#uniq_value` が削除された（リレーション） | `distinct` に置き換える（FastRuby.io にも同じ指摘がある） |
| X51-CL-03 | 削除 | 中 | `#insert_sql` / `#update_sql` / `#delete_sql` と、タスク `db:test:clone` / `db:test:clone_schema` / `db:test:clone_structure` が削除された | `insert` / `update` / `delete` と `db:test:prepare` を使う |
| X51-CL-04 | 削除 | 高 | `alias_method_chain` が削除された | `Module#prepend` か `alias_method` に書き換える。古い gem やモンキーパッチがよく使っている |
| X51-LD-01 | 新設定 | 中 | `load_defaults 5.1`: `assets.unknown_asset_fallback = false`（存在しないアセットを参照するとエラーになる）、`action_view.form_with_generates_remote_forms = true` | 参照先のないアセットをなくす。`form_with` が `data-remote` のフォームになる点を確かめる（6.1 で `false` に戻る: [X61-LD-01](#71-ガイド外の項目60--61)） |
| X51-WEB-01 | 必須 | 中 | `has_many :through` は、経由する関連の宣言より後に書かなければならない（逆だと `ActiveRecord::HasManyThroughOrderError`） | 関連の宣言を、経由する関連 → `through` の順に並べ替える（FastRuby.io。`HasManyThroughOrderError` は 5.1 で入ったことをソースで確認） |
| X51-WEB-02 | 必須 | 低 | `config/application.rb` などの `require "rails/commands/server"` で LoadError になる | `require "rails/commands/server/server_command"` に変える（FastRuby.io） |

---

## 5. Rails 5.1 → Rails 5.2

| 節 | 区分 | 変更事項 | 修正事項（対応） |
|---|---|---|---|
| 9.1 | 環境 | 新規アプリの Gemfile に bootsnap が入るようになった | 使うなら Gemfile に `gem "bootsnap", require: false` を足す。`app:update` で `config/boot.rb` に設定が入る。使わないなら `boot.rb` で外す |
| 9.2 | 挙動変更 | 暗号化 cookie と署名付き cookie に有効期限が埋め込まれるようになった。5.1 以前とは互換がない | 5.1 以前でも新しい cookie を読む必要があるとき、またはロールバックできるようにしておきたいときは、`Rails.application.config.action_dispatch.use_authenticated_cookie_encryption = false` |

### 5.1 ガイド外の項目（5.1 → 5.2）

| ID | 区分 | 影響 | 変更事項 | 修正事項（対応） |
|---|---|---|---|---|
| X52-RN-01 | 非推奨 | 低 | Railties: `capify!`、`rails dbconsole` / `rails console` に環境名を位置引数で渡す、`Rails::Application` のサブクラスでサーバーを起動する、プラグインテンプレートの `after_bundle` が非推奨になった（6.0 で削除） | 環境は `-e` で渡す |
| X52-RN-02 | 挙動変更 | 低 | development と test の `secret_key_base` を、アプリ名から生成するようになった | 開発環境のセッションが変わるだけ |
| X52-RN-03 | 削除 | 低 | Action Cable の evented Redis アダプタが削除された | `adapter: redis` に変える |
| X52-RN-04 | 削除 | 低 | `ActionController::ParamsParser::ParseError` が削除された | `ActionDispatch::Http::Parameters::ParseError` を使う |
| X52-RN-05 | 非推奨 | 中 | `ActionDispatch::TestResponse` の `#success?` / `#missing?` / `#error?` が非推奨になった（6.0 で削除） | `#successful?` / `#not_found?` / `#server_error?` に変える（RSpec の `be_success` も `be_successful` に） |
| X52-RN-06 | 挙動変更 | 中 | フラグメントキャッシュのキーの形式が変わった（リサイクルできるキー） | デプロイ直後はフラグメントキャッシュが当たらないことを見込む |
| X52-RN-07 | 挙動変更 | 中 | デフォルトで CSRF 保護が有効になった（`load_defaults 5.2` の `action_controller.default_protect_from_forgery = true`） | `ActionController::Base` を継承した API や Webhook 受け口で `InvalidAuthenticityToken` にならないか確かめる。不要なら `skip_forgery_protection` |
| X52-RN-08 | 挙動変更 | 低 | デフォルトのヘッダに `X-Download-Options`、`X-Permitted-Cross-Domain-Policies`、`Referrer-Policy` が加わった。HSTS のデフォルトの `max-age` が 1 年になった | ヘッダに依存する連携や埋め込みを確かめる |
| X52-RN-09 | 挙動変更 | 低 | `ActionController::Parameters#each` の動作が `Hash#each` と同じになった | ブロック引数の受け取り方を確かめる |
| X52-RN-10 | 挙動変更 | 低 | システムテストのスクリーンショット出力のデフォルトが `inline` から `simple` になった | ― |
| X52-RN-11 | 削除 | 中 | Erubis の ERB ハンドラが削除された | Erubi で動くことを確かめる |
| X52-RN-12 | 非推奨 | 低 | `image_tag` に alt を自動で付ける `image_alt` が非推奨になった（6.0 で削除） | 必要なら `alt:` を明示する |
| X52-RN-13 | 挙動変更 | 低 | `form_with` がデフォルトで id を生成するようになった（`load_defaults 5.2` の `form_with_generates_ids`） | id を前提にした JS や CSS を確かめる |
| X52-RN-14 | 削除 | 低 | Active Record の削除: `#migration_keys`、`quoted_id`、`index_name_exists?` の default 引数、`:class_name` にクラスを渡す、`initialize_schema_migrations_table` / `initialize_internal_metadata_table`、`supports_migrations?`、`supports_primary_key?`、`Migrator.schema_migrations_table_name`、`#indexes` の `name`、`#verify!` の引数、`.error_on_ignored_order_or_limit`、`#scope_chain`、`#sanitize_conditions` | [X51-RN-14](#41-ガイド外の項目50--51) の置き換えをする。`class_name:` は文字列にする |
| X52-RN-15 | 非推奨 | 高 | リレーションのクエリメソッド（`order` / `pluck` など）に生の SQL 断片を渡すときは、`Arel.sql` で明示しないといけなくなった（"Dangerous query method" の非推奨警告。6.1 で削除: [X61-RN-10](#71-ガイド外の項目60--61)） | `order(params[:sort])` のようなコードは、許可リストで値を確かめてから `Arel.sql(...)` で包む（freee の事例） |
| X52-RN-16 | 非推奨 | 低 | Active Record の非推奨: `supports_statement_cache?`、`count` / `sum` に引数とブロックを同時に渡す、`Relation` から `arel` への委譲、`TransactionState#set_state`、`expand_hash_conditions_for_aggregates` | 該当箇所を直す |
| X52-RN-17 | 挙動変更 | 中 | `cache_versioning`（`load_defaults 5.2`）が有効だと、`cache_key` にタイムスタンプが入らなくなった（`cache_version` に分かれる） | `cache_key` の変化に頼った独自キャッシュを確かめる。キャッシュストアがバージョン付きエントリに対応しているか確かめる |
| X52-RN-18 | 挙動変更 | 中 | SQLite の boolean を `t` / `f` でなく `1` / `0` で保存するようになった（`represent_boolean_as_integer`） | SQLite を使っているなら、既存データを変換してから `represent_boolean_as_integer = true`（6.0 で非推奨、6.1 で削除） |
| X52-RN-19 | 挙動変更 | 中 | Active Record のその他の挙動変更: 未保存の変更があるレコードで `lock!` するとエラー、`save` 後に destroy 済みオブジェクトを変更できない、`limit` / `offset` 付きの `delete_all` はサブクエリを使う、`first(n)` が `limit` を考慮する、`Relation` のメソッドと衝突するスコープを定義するとエラー、ジェネレータが `ApplicationRecord` を作らない、ネストした JOIN を merge しても LEFT OUTER JOIN にならない、ポリモーフィック関連の `reflection.klass` はエラー、`update_all` が型変換する、アイドル接続が reaper で回収される、外側のトランザクションのロールバックが内側に伝わる、`where` に `Set` を渡すと配列と同じ扱い | テストで差分を確かめる |
| X52-RN-20 | 挙動変更 | 低 | Active Model: `Errors#keys` / `#values` が空でないものだけを返すようになった。`_confirmation` が `false` のときも確認のバリデーションが動くようになった | ― |
| X52-RN-21 | 削除 | 高 | コールバックの `:if` / `:unless` に文字列を渡す書き方と、`halt_callback_chains_on_return_false` オプションが削除された | `config/initializers/new_framework_defaults.rb` などに残っている `ActiveSupport.halt_callback_chains_on_return_false = ...` の行を消す（残すと起動時にエラーになる） |
| X52-RN-22 | 非推奨 | 低 | `Module#reachable?` と `secrets.secret_token` が非推奨になった | `secret_key_base` に移る（6.0 で `config.secret_token` が削除される） |
| X52-RN-23 | 挙動変更 | 中 | `MessageEncryptor` のデフォルトが AES-256-GCM になった（`load_defaults 5.2` の `use_authenticated_message_encryption`）。ETag などのダイジェストは SHA1 を使う（`hash_digest_class = SHA1`） | アプリで `MessageEncryptor` を直接使って暗号化したデータがあるなら、`cipher:` を明示して読めるようにする |
| X52-RN-24 | 挙動変更 | 低 | Active Support のその他: `TimeZone.all` は `MAPPING` にあるゾーンだけを返す、`HashWithIndifferentAccess#transform_keys` が HWIA を返す、1KB を超えるキャッシュをデフォルトで圧縮する、`secure_compare` が長さを漏らさないようになった（長さが違うとエラーになる版は `fixed_length_secure_compare` という名前になった） | ― |
| X52-LD-01 | 新設定 | 中 | `load_defaults 5.2` が設定する値: `active_record.cache_versioning`、`action_dispatch.use_authenticated_cookie_encryption`（ガイド 9.2）、`active_support.use_authenticated_message_encryption`、`active_support.hash_digest_class = OpenSSL::Digest::SHA1`、`action_controller.default_protect_from_forgery`、`action_view.form_with_generates_ids` | X52-RN-07 / 13 / 17 / 23 を確かめてから有効にする |
| X52-WEB-01 | 任意 | 低 | Active Storage と credentials（`config/credentials.yml.enc`）が入った。Paperclip は非推奨になった（FastRuby.io） | Paperclip を使っているなら、メンテナが公開している移行ガイドに沿って Active Storage へ移ることを検討する。secrets から credentials への移行は任意 |
| X52-WEB-02 | 依存 gem | 中 | 5.2 対応で非推奨警告が出なくなった gem のバージョンの例（記事の時点）: friendly_id 5.2.4、activeadmin 1.3.0、acts-as-taggable-on 6.0.0、awesome_nested_set 3.1.4 | gem をこれら以上に上げる（FastRuby.io） |

---

## 6. Rails 5.2 → Rails 6.0

| 節 | 区分 | 変更事項 | 修正事項（対応） |
|---|---|---|---|
| 8.1 | 環境 | Webpacker がデフォルトの JS コンパイラになった。ただしアップグレードしたアプリでは自動では有効にならない | 使うなら `gem "webpacker"` を足し、`bin/rails webpacker:install` |
| 8.2 | 非推奨 | コントローラの `force_ssl` が非推奨になった（6.1 で削除予定） | `config.force_ssl` でアプリ全体を HTTPS にする。リダイレクトしたくないエンドポイントは `config.ssl_options` で外す |
| 8.3 | 挙動変更 | 署名付き cookie と暗号化 cookie に purpose と expiry のメタデータが埋め込まれるようになった（別の cookie への値の流用を防ぐ）。6.0 より前とは互換がない | 5.2 以前でも読めるようにしたいとき、またはロールバックできるようにしておきたいときは、`Rails.application.config.action_dispatch.use_cookies_with_metadata = false` |
| 8.4 | 必須 | npm パッケージが `@rails` スコープに移った | `actioncable` → `@rails/actioncable`、`activestorage` → `@rails/activestorage`、`rails-ujs` → `@rails/ujs`（6.0.0 に上げる前に依存名を変える） |
| 8.5 | 挙動変更 | Action Cable の JS が CoffeeScript から ES2015 になり、API の一部が変わった | `ActionCable.WebSocket` → `ActionCable.adapters.WebSocket`、`ActionCable.logger` → `ActionCable.adapters.logger`。`ActionCable.startDebugging()` / `stopDebugging()` は削除されたので `ActionCable.logger.enabled = true / false` に変える |
| 8.6 | 挙動変更 | `ActionDispatch::Response#content_type` が charset を含めた Content-Type をそのまま返すようになった | MIME タイプだけ欲しいところは `#media_type` に変える |
| 8.7 | 新設定 | `config.hosts` が追加された。development のデフォルトは `localhost`、それ以外の環境は空（ホストを検証しない） | 開発で別のドメインを使うなら `config.hosts << "dev.myapp.com"`（正規表現も使える）。production で検証したいなら、許可するホストを足す |
| 8.8 | 挙動変更 | `config.load_defaults "6.0"` で、CRuby では Zeitwerk モードの自動読み込みが有効になる（読み込み、再読み込み、eager load を Zeitwerk が管理する） | 旧デフォルトのまま有効にするなら `config.autoloader = :zeitwerk`。以下 8.8.1〜8.8.15 を確かめる |
| 8.8.1 | 情報 | Zeitwerk の API はふつう直接は使わない。ローダーには `Rails.autoloaders.main` でアクセスできる | STI のプリロードやカスタム inflector の設定に使う |
| 8.8.2 | 必須 | classic はファイル名を定数名から推測し（`underscore`）、zeitwerk は定数名をファイル名から推測する（`camelize`）。略語では両者が一致しないことがある（例: `"FOO".underscore` は `"foo"` だが、`"foo".camelize` は `"Foo"`） | `bin/rails zeitwerk:check` で確かめ、出た問題を直す |
| 8.8.3 | 必須 | `require_dependency` の用途はすべてなくなった | プロジェクトを grep して `require_dependency` を消す。STI があるなら、Zeitwerk ガイドの STI の節を参照 |
| 8.8.4 | 必須 | `class Foo::Bar` のような完全修飾名の定義が Ruby のセマンティクスどおりに動く。classic で読み込めていた `Foo::Bar` 内の `Wadus`（実体は `Foo::Wadus`）は読み込めない | `Foo::Wadus` と完全修飾名で書くか、`module Foo; class Bar` とネストして書く |
| 8.8.5 | 必須 | `app/models/concerns` はルートディレクトリとして扱われ、名前空間にならない | `Concerns::Foo` を `Foo` に名前を変える |
| 8.8.6 | 必須 | 自動読み込みパスに `app` を足すと、ルートディレクトリがネストした状態になって動かない（例: `app/api/base.rb` → `API::Base`） | 構成を残すなら、イニシャライザで `ActiveSupport::Dependencies.autoload_paths.delete("#{Rails.root}/app/api")` |
| 8.8.7 | 必須 | 明示的な名前空間（例: `Hotel` と `Hotel::Pricing`）は `class` か `module` キーワードで定義しなければならない | `Hotel = Class.new` や `Hotel = Struct.new` を `class Hotel ... end` に変える（名前空間でない定数なら前者のままでよい） |
| 8.8.8 | 必須 | 1 ファイルのトップレベルには定数を 1 つだけ置く | `app/models/foo.rb` にある `Bar` を `bar.rb` に移す（ネストした内側のクラスは影響を受けない） |
| 8.8.9 | 必須 | spring を使う場合、test 環境で再読み込みが有効になっている必要がある | `config/environments/test.rb` に `config.cache_classes = false`（ないと `reloading is disabled because config.cache_classes is true`） |
| 8.8.10 | 環境 | Bootsnap 1.4.2 以上が必須 | Bootsnap を上げる。Ruby 2.5 ではインタプリタのバグのため iseq キャッシュを無効にする必要があり、その場合は 1.4.4 以上にする |
| 8.8.11 | 新設定 | `config.add_autoload_paths_to_load_path`（後方互換のためデフォルトは `true`） | `false` にすると `$LOAD_PATH` の探索が減り、Bootsnap が軽くなってメモリも減る（自動読み込みパスのファイルを `require` していないことが前提） |
| 8.8.12 | 情報 | zeitwerk モードの自動読み込みはスレッドセーフ（`runner` のマルチスレッドでも使える） | ― |
| 8.8.13 | 必須 | `config.autoload_paths` の各要素はトップレベルの名前空間を表すので、ネストできない | `config.autoload_paths += Dir["#{config.root}/lib/**/"]` を `config.autoload_paths << "#{config.root}/lib"` に変える（ワイルドカードを外す） |
| 8.8.14 | 挙動変更 | eager load と自動読み込みの結果が一致するようになった（失敗するときは同じファイルで失敗する） | ― |
| 8.8.15 | 新設定 | Rails 6 でも classic を使える（`config.load_defaults 6.0` に加えて `config.autoloader = :classic`） | classic を使うなら、スレッドセーフでないため、development では Web サーバーとバックグラウンド処理の並行度を 1 にすることを勧める |
| 8.9 | 挙動変更 | `has_many_attached` のコレクションに代入すると、追加でなく置き換えになる（6.0 のデフォルト） | 既存を残して追加するなら `#attach` を使う。新しい挙動は `config.active_storage.replace_on_assign_to_many = true` で有効になる。古い挙動は 7.0 で非推奨、7.1 で削除予定 |
| 8.10 | 挙動変更 | 不正な `Accept` / `Content-Type` ヘッダーで例外が上がるようになった | カスタムの `config.exceptions_app` でもこのエラーを処理する（しないとフォールバックが使われ 500 になる） |

### 6.1 ガイド外の項目（5.2 → 6.0）

| ID | 区分 | 影響 | 変更事項 | 修正事項（対応） |
|---|---|---|---|---|
| X60-RN-01 | 削除 | 中 | Railties: プラグインテンプレートの `after_bundle`、`config.ru` の `run` にアプリケーションクラスを渡す書き方、`rails` コマンドの環境の位置引数、`capify!`、`config.secret_token` が削除された | `config.ru` は `run Rails.application` に、環境は `-e` に、`secret_token` は `secret_key_base` に移す |
| X60-RN-02 | 非推奨 | 中 | Railties: `rails server` に Rack サーバー名を位置引数で渡す、サーバー IP の指定に `HOST` 環境変数を使う、`config_for` の結果にシンボル以外のキーでアクセスする（ガイド 7.1）が非推奨になった。CHANGELOG ではさらに: `rake routes` / `rake initializers` / `rake dev:cache` / `rake notes`、`SOURCE_ANNOTATION_DIRECTORIES`、`rails notes:custom` などのサブコマンド（いずれも 6.1 で削除） | `rails server -u puma`、`-b`、`rails routes` などの `rails` コマンド、`config.annotations.register_directories`、`rails notes -a` に変える（CI のスクリプトも） |
| X60-RN-03 | 挙動変更 | 中 | test 環境のデフォルトのキャッシュストアが `null_store` になった（`app:update` で `test.rb` を更新した場合） | キャッシュの動作を前提にしたテストは、そのテストでストアを差し替える |
| X60-RN-04 | 挙動変更 | 低 | `db:seed` が inline アダプタでジョブを実行するようになった | seeds でジョブを使っているなら、同期で動くことを前提にする |
| X60-RN-05 | 削除 | 中 | Action Pack: `fragment_cache_key` と、`TestResponse#success?` / `#missing?` / `#error?` が削除された | `combined_fragment_cache_key` と、`#successful?` / `#not_found?` / `#server_error?` に変える |
| X60-RN-06 | 非推奨 | 低 | `ActionDispatch::Http::ParameterFilter` が非推奨になった（6.1 で削除） | `ActiveSupport::ParameterFilter` を使う |
| X60-RN-07 | 挙動変更 | 中 | Action Pack: リソースの param にコロンを含めると `ArgumentError`、同じコンテキストに `as:` のない root ルートが複数あると `ArgumentError`、`respond_to` の呼び出しが衝突すると `RespondToMismatchError`、リクエストのフォーマットに合うテンプレートがないときは専用のエラーページ、`send_data` / `send_file` が Content-Disposition のファイル名をエンコードする、CSP の nonce はリクエストごとに 1 つ | ルーティングの定義と、ファイル名をダウンロードする側（クライアント）を確かめる |
| X60-RN-08 | 削除 | 低 | Action View: `image_alt` と、空の `RecordTagHelper` モジュールが削除された | `alt:` を明示する |
| X60-RN-09 | 非推奨 | 中 | Action View: `finalize_compiled_template_methods`（メソッドと設定）と、`options_from_collection_for_select` などからモデルの private メソッドを呼ぶことが非推奨になった（6.1 で削除） | 設定の行を消す。ヘルパーに渡すメソッドを public にする |
| X60-RN-10 | 挙動変更 | 中 | Action View: 登録された MIME タイプのフォーマットだけを受け付けるようになった。`default_enforce_utf8 = false`（`load_defaults 6.0`）で、フォームに `utf8=✓` の hidden が付かなくなった。Action View のキャッシュは development でだけクリアする | 未登録のフォーマットでリクエストするクライアントを確かめる。`utf8` パラメータを前提にした処理を確かめる |
| X60-RN-11 | 非推奨 | 中 | Action Mailer: `ActionMailer::Base.receive`（6.1 で削除）と、`DeliveryJob` / `Parameterized::DeliveryJob`（7.0 で削除）が非推奨になった | 受信は Action Mailbox に移る。配信ジョブは `MailDeliveryJob` を使う（`load_defaults 6.0` の `action_mailer.delivery_job`）。切り替えるときは、古いクラスでキューに積まれたジョブを先に処理しきる |
| X60-RN-12 | 削除 | 低 | Active Record の削除: `#set_state`、`#supports_statement_cache?`、`#insert_fixtures`、`SQLite3Adapter#valid_alter_table_type?`、ブロック付きの `sum` / `count` にカラム名を渡す、リレーションから arel への委譲、クラスの private メソッドへの委譲、`#cache_key` のタイムスタンプ名指定、`Migrator.migrations_path=`、`expand_hash_conditions_for_aggregates` | 該当箇所を直す（`insert_fixtures` は `insert_fixtures_set` に） |
| X60-RN-13 | 非推奨 | 高 | `update_attributes` / `update_attributes!` が非推奨になった（6.1 で削除） | `update` / `update!` に一括で置き換える |
| X60-RN-14 | 非推奨 | 中 | Active Record の非推奨: uniqueness バリデータで照合順序（collation）が合わない比較（6.1 で挙動が変わる）、スコープが漏れているときのクラスレベルのクエリ、`sqlite3.represent_boolean_as_integer`、`assume_migrated_upto_version` に `migrations_paths` を渡す、`Result#to_hash`、`DatabaseLimits` の各メソッド。CHANGELOG ではさらに: `where.not` が NOR として動く（6.1 で NAND になる） | 大文字小文字を区別したいなら `case_sensitive: true` を明示する。漏れるスコープは `klass.unscoped` で囲む。`to_hash` は `to_a` に。`where.not` に複数の条件を渡している箇所を洗い出す（[X61-RN-12](#71-ガイド外の項目60--61)） |
| X60-RN-15 | 環境 | 中 | 最低バージョン: sqlite3 gem 1.4、PostgreSQL 9.3、MySQL 5.5.8、SQLite 3.8 | DB とドライバを上げる |
| X60-RN-16 | 挙動変更 | 中 | Active Record のその他: MySQL のデフォルトの文字セットが utf8mb4 になり、`create_table` で `ROW_FORMAT=DYNAMIC` が付くようになった。6.0 のマイグレーションでは timestamps が `precision: 6` になった。enum の値が frozen になった。`ActiveRecord::Base.configurations` がハッシュでなくオブジェクトを返すようになった。カウンタキャッシュは実際に保存されたときだけ更新する。ポリモーフィック関連の `dependent: :nullify` は type カラムも NULL にする。マイグレーションでカラムの定義が重複するとエラーになる | 新しいテーブルの文字セットとインデックス長を確かめる。`configurations["production"]` のようなアクセスは `configs_for` に変える |
| X60-RN-17 | 非推奨 | 中 | Active Storage: `config.active_storage.queue`、`ActiveStorage::Downloading`、variant での `mini_magick` の直接利用、`:combine_options` が非推奨になった（6.1 で削除） | `queues.analysis` / `queues.purge`、`Blob#open`、image_processing を使う（ガイド 7.6） |
| X60-RN-18 | 挙動変更 | 中 | Active Storage: 添付したファイルは代入したときでなく、レコードを保存したときにストレージへアップロードされるようになった。ファイルがないと `Blob#download` / `#open` が `ActiveStorage::FileNotFoundError` を上げ、`DiskController#show` は 404 を返す | 保存前に blob を読むコードや、例外処理を確かめる |
| X60-RN-19 | 挙動変更 | 低 | Active Model: numericality バリデータは型変換前の値を使う（Active Record 以外）、`BigDecimal` / `Float` の等値比較を直した、boolean 属性で falsy なシンボルを `false` に変換する、エラーの訳文は親のロケールにフォールバックしてから `:errors` 名前空間にフォールバックする | ― |
| X60-RN-20 | 削除 | 低 | Active Support: `Inflections#acronym_regex`、`Module#reachable?`、`` Kernel#` `` の上書きが削除された | ― |
| X60-RN-21 | 非推奨 | 中 | Active Support の非推奨: `String#first` / `#last` に負の整数を渡す、`Multibyte::Unicode` の `downcase` / `upcase` / `swapcase` / `normalize` / `pack_graphemes` / `unpack_graphemes`、`Chars.consumes?`、`Module#parent` / `#parents` / `#parent_name`（リリースノートでは「主な変更」に記載）、`Array#without`（エイリアスは残る）。CHANGELOG ではさらに `LoggerSilence` | `String#downcase` など、`unicode_normalize`、`String#is_utf8?`、`module_parent` / `module_parents` / `module_parent_name`、`excluding`、`ActiveSupport::LoggerSilence` に置き換える（6.1 で削除） |
| X60-RN-22 | 挙動変更 | 低 | Active Support のその他: `TaggedLogging.new` は渡したロガーを変更せず、新しいロガーを返す。`delete_prefix` などは HTML セーフでない扱い。HTML セーフ文字列はスライスしても HTML セーフのまま。`fetch_multi` はキーの順を保つ。`safe_constantize` は大文字小文字の誤りで `LoadError` を上げない | ― |
| X60-RN-23 | 削除 | 低 | Active Job: Qu アダプタのサポートが削除された | 別のアダプタに移る |
| X60-RN-24 | 挙動変更 | 低 | Active Job: キューに積んだときのタイムゾーンでジョブを実行するようになった。`enqueue` の通知を `around_enqueue` で包むようになった | ― |
| X60-RN-25 | 挙動変更 | 低 | Action Cable: `reject_unauthorized_connection` で接続を閉じるようになった。Redis アダプタに `id` オプションが加わった | ― |
| X60-LD-01 | 新設定 | 中 | `load_defaults 6.0` が設定する値で、ガイドにないもの: `action_view.default_enforce_utf8 = false`、`action_dispatch.return_only_media_type_on_content_type = false`（ガイド 8.6 の挙動。6.1 で非推奨、7.0 で削除）、`action_mailer.delivery_job = "ActionMailer::MailDeliveryJob"`、`active_job.return_false_on_aborted_enqueue = true`、`active_storage.queues.analysis = :active_storage_analysis` / `purge = :active_storage_purge`、`active_record.collection_cache_versioning = true`、`autoloader = :zeitwerk`（ガイド 8.8） | 6-0-stable の `configuration.rb` で確認した。X60-RN-10 / 11 などを確かめてから有効にする |
| X60-WEB-01 | 依存 gem | 中 | Rails 6.0 に合わせて composite_primary_keys が 12 系に上がると、複合主キーの `update_all` がサブクエリを発行し、大幅に遅くなった事例がある（約 1300 倍） | 複合主キーの一括更新の SQL と実行時間を確かめる（Gunosy の事例） |
| X60-WEB-02 | 環境 | 低 | Action Cable の JS が ES2015 に移ったあと、`LoadError: cannot load such file -- coffee_script` になることがある | `bin/rails tmp:cache:clear` でキャッシュを消す（Qiita の事例） |

---

## 7. Rails 6.0 → Rails 6.1

| 節 | 区分 | 変更事項 | 修正事項（対応） |
|---|---|---|---|
| 7.1 | 削除 | `Rails.application.config_for` の戻り値に String キーでアクセスできなくなった（6.0 で非推奨） | `config_for(:example).with_indifferent_access.dig("options", "key")` のように `with_indifferent_access` を通す |
| 7.2 | 挙動変更 | `respond_to { \|format\| format.any }` のレスポンスの Content-Type が、リクエストのフォーマットでなくブロックの中身で決まるようになった（例: `.csv` へのリクエストで JSON を返すと `application/json`） | 古い挙動に依存しているなら、`format.any(:xml, :json) { render request.format.to_sym => @people }` のように受けるフォーマットを明示する |
| 7.3 | 挙動変更 | `halted_callback_hook` の第 2 引数にコールバック名が渡されるようになった（性能上の理由で非推奨期間なしの破壊的変更） | オーバーライドしているクラスは、引数を 2 つ受け取るように変える（`def halted_callback_hook(filter, callback_name)`） |
| 7.4 | 挙動変更 | コントローラの `helper` が `require_dependency` を使わず、`String#constantize` で解決するようになった | ほとんどのアプリは対応不要。`helpers_path` が自動読み込みパスでない `$LOAD_PATH` 上のディレクトリを指している場合は、`helper` を呼ぶ前にそのモジュールを自分で読み込む |
| 7.5 | 挙動変更 | `ActionDispatch::SSL` が GET / HEAD 以外のリクエストを HTTP から HTTPS へリダイレクトするときのステータスが 308 になった（RFC7538） | 307 / 301 などを前提にしたクライアントやテストを確かめる |
| 7.6 | 環境 | Active Storage で variant を処理するには image_processing gem が必須になった（`mini_magick` を直接使わない） | image_processing を入れる。不要になった `combine_options` を消す。任意で `resize: "100x100"` / `"100x100>"` / `"100x100^"` を `resize_to_fit:` / `resize_to_limit:` / `resize_to_fill: [100, 100]` に変える（サムネイルがシャープになる） |
| 7.7 | 挙動変更 | エラーが `ActiveModel::Error` のインスタンスになり、API が変わった | 新しいエラーや非推奨警告（7.0 で削除）が出る箇所を直す（#32313） |

### 7.1 ガイド外の項目（6.0 → 6.1）

| ID | 区分 | 影響 | 変更事項 | 修正事項（対応） |
|---|---|---|---|---|
| X61-RN-01 | 削除 | 中 | Railties: `rake notes`、`rails dbconsole` の `connection` オプション、`rails notes` の `SOURCE_ANNOTATION_DIRECTORIES`、`rails server` の `server` 引数、`HOST` 環境変数でのサーバー IP 指定、`rake dev:cache` / `rake routes` / `rake initializers` が削除された | `rails notes` / `rails dev:cache` / `rails routes` / `rails initializers`、`rails server -u` / `-b` に変える（[X60-RN-02](#61-ガイド外の項目52--60)） |
| X61-RN-02 | 削除 | 中 | Action Pack: `ActionDispatch::Http::ParameterFilter` と、コントローラの `force_ssl` が削除された | `ActiveSupport::ParameterFilter` と `config.force_ssl` に移る（ガイド 8.2） |
| X61-RN-03 | 非推奨 | 低 | `config.action_dispatch.return_only_media_type_on_content_type` が非推奨になった（7.0 で削除） | 設定の行を消し、MIME タイプは `media_type` で取る |
| X61-RN-04 | 削除 | 中 | Action View のテンプレートとリゾルバまわりの非推奨 API が多数削除された: `escape_whitelist`、`find_all_anywhere`、`Template::HTML` / `RawFile` / `Text` の `formats`、`PathSet#find_file`、`LookupContext#rendered_format`、`ViewPaths#find_file`、`ActionView::Base#initialize` の第 1 引数に `LookupContext` 以外を渡す書き方と `format` 引数、`Template#refresh` / `#original_encoding` / `#variants` / `#formats` / `#virtual_path=` / `#updated_at`、`Template#initialize` の `updated_at` 引数、`finalize_compiled_template_methods`、`with_fallback` にブロックを渡す、引数が 2 つでないテンプレートハンドラ、`PathResolver` の pattern 引数 | `ActionView::Base.new` を直接使っている箇所（PDF 生成など）は `ActionView::Base.new(ActionView::LookupContext.new(paths), assigns, controller)` の形に直す（freee の事例）。テンプレート系の gem を上げる |
| X61-RN-05 | 削除 | 高 | `render template:` に絶対パスを渡す、`render file:` に相対パスを渡す、一部のビューヘルパーからオブジェクトの private メソッドを呼ぶ、がいずれもできなくなった | `render template:` は相対パスに、`render file:` は `Rails.root.join(...)` などの絶対パスにする（freee では layout の絶対パス指定を一括で直した）。ヘルパーに渡すメソッドを public にする |
| X61-RN-06 | 挙動変更 | 低 | Action View: `ActionView::Base` のサブクラスは `#compiled_method_container` を実装しなければならない。`Template#initialize` の `locals` が必須になった。`javascript_include_tag` / `stylesheet_link_tag` がプリロード用の `Link` ヘッダを出すようになった（`load_defaults 6.1` の `preload_links_header`） | 不要なら `config.action_view.preload_links_header = false` |
| X61-RN-07 | 削除 | 中 | Action Mailer: `ActionMailer::Base.receive` が削除された | Action Mailbox に移る |
| X61-RN-08 | 削除 | 中 | Active Record の削除: `DatabaseLimits` のメソッド（`column_name_length` など 7 つ）、`supports_multi_insert?`、`supports_foreign_keys_in_create?`、`supports_ranges?`、`assume_migrated_upto_version` の `migrations_path` 引数、`config.active_record.sqlite3.represent_boolean_as_integer`、`DatabaseConfigurations` の `fetch` / `each` / `first` / `values` / `[]=`、`Result#to_hash` | 設定の行を消す（残すと起動時にエラー）。`configs_for`、`to_a` に変える |
| X61-RN-09 | 削除 | 高 | `update_attributes` / `update_attributes!` が削除された | `update` / `update!` に置き換える（[X60-RN-13](#61-ガイド外の項目52--60)） |
| X61-RN-10 | 削除 | 高 | リレーションのメソッドに安全でない生 SQL を渡すと、警告でなくエラー（`ActiveRecord::UnknownAttributeReference`）になった | `Arel.sql` で包む（[X52-RN-15](#51-ガイド外の項目51--52)）。値は必ず許可リストで確かめる |
| X61-RN-11 | 非推奨 | 中 | Active Record の非推奨: `ActiveRecord::Base.allow_unsafe_raw_sql`、`connected_to` の `database:` キーワード、`legacy_connection_handling` 設定時の `connection_handlers`（7.0 で削除） | `connects_to` / `connected_to(role:)` に変える。英語版のリリースノートは、`connection_handlers` の非推奨を「`legacy_connection_handling` が false のとき」としていて、日本語版（true のとき）と食い違う |
| X61-RN-12 | 挙動変更 | 高 | **`where.not` に複数の条件を渡すと、NOR でなく NAND を生成するようになった**（`NOT (a AND b)`） | 従来どおり NOR にするなら `where.not(a: 1).where.not(b: 2)` に分ける（freee の事例） |
| X61-RN-13 | 挙動変更 | 中 | `relation.create` の初期化ブロックやコールバックの中で、スコープがクラスレベルのクエリに漏れなくなった。名前付きスコープをチェーンしたときも同じ。MySQL の uniqueness バリデータがデフォルトの照合順序に従い、大文字小文字を区別する比較を強制しなくなった | 漏れていたスコープに頼っていた箇所を確かめる（6.0 のうちに `unscoped` を付けると 6.1 と同じ挙動になる: freee の事例）。大文字小文字を区別したいなら `case_sensitive: true` |
| X61-RN-14 | 必須 | 中 | 新しいデータベースごとの接続管理を使うには、`legacy_connection_handling = false`（`load_defaults 6.1`）にして、`connection_handlers` の非推奨アクセサを使うのをやめる必要がある（英語版のリリースノートにだけ記載） | `connects_to` / `connected_to` の公開メソッドはそのままでよい |
| X61-RN-15 | 削除 | 中 | Active Storage: `ImageProcessing` への `:combine_options`、`MiniMagickTransformer`、`config.active_storage.queue`、`ActiveStorage::Downloading` が削除された | ガイド 7.6 の対応をする |
| X61-RN-16 | 非推奨 | 低 | `Blob.create_after_upload` が非推奨になった。CHANGELOG ではさらに、`Variant#service_url` / `Preview#service_url` も非推奨になった（7.0 で削除） | `create_and_upload` と `url` に変える |
| X61-RN-17 | 必須 | 高 | `active_storage_blobs` に `service_name` カラムが加わった。アップグレード後にマイグレーションが必要 | `bin/rails app:update` でマイグレーションを作り、`db:migrate` する。`track_variants`（`load_defaults 6.1`）を有効にするなら、`active_storage_variant_records` テーブルも必要 |
| X61-RN-18 | 削除 | 中 | Active Support: `config.i18n.fallbacks` が空のとき `I18n.default_locale` にフォールバックする挙動、`LoggerSilence`、`LoggerThreadSafeLevel#after_initialize`、`Module#parent` / `#parents` / `#parent_name`、`core_ext` の `module/reachable` / `numeric/inquiry` / `array/prepend_and_append` / `hash/compact` / `hash/transform_values` / `range/include_range`、`Multibyte` の各メソッド、`Instrumenter#end=` が削除された | フォールバックが必要なら `config.i18n.fallbacks` にロケールを明示する。[X60-RN-21](#61-ガイド外の項目52--60) の置き換えをする。`require` しているファイルを消す |
| X61-RN-19 | 非推奨 | 低 | `Multibyte::Unicode.default_normalization_form` が非推奨になった | 使うのをやめる |
| X61-RN-20 | 挙動変更 | 中 | Active Job: キューへの登録が中断されると `false` を返すようになった。`return_false_on_aborted_enqueue` が非推奨になった | `perform_later` の戻り値で成否を判断している箇所を確かめる。設定の行を消す |
| X61-RN-21 | 非推奨 | 低 | Action Mailbox: `credentials.action_mailbox.api_key` / `MAILGUN_INGRESS_API_KEY` が非推奨になった | `signing_key` / `MAILGUN_INGRESS_SIGNING_KEY` に変える |
| X61-CL-01 | 非推奨 | 中 | `config.action_view.raise_on_missing_translations` が非推奨になった（7.0 で削除） | `config.i18n.raise_on_missing_translations` に変える |
| X61-CL-02 | 非推奨 | 中 | `db:structure:load` / `db:structure:dump` が非推奨になった（7.0 で削除） | `config.active_record.schema_format = :sql` にして `db:schema:load` / `dump` を使う（CI やデプロイのスクリプトも） |
| X61-CL-03 | 非推奨 | 中 | Active Record の非推奨（7.0 で削除）: Rails 5.0 より古い形式の YAML の読み込み、`Result#map!` / `#collect!`、`quote` / `type_cast` に AR オブジェクトやカラムを渡す、group の重複フィールドを含む集計、重複したクエリ注釈、`in_clause_length` / `allowed_index_name_length`、`spec_name`、ハンドラの `#remove_connection`、`configurations#default_hash` / `[]` / `to_h`、`"primary"` という接続名、`.reorder(nil).first` | `uniq!(:group)` / `uniq!(:annotate)`、`name`、`#remove_connection_pool`、`configs_for`、`"ActiveRecord::Base"`、`.take` に変える |
| X61-CL-04 | 非推奨 | 高 | 書き込みのあとに `return` / `break` / `throw` でトランザクションのブロックを抜ける書き方が非推奨になった（7.0 ではロールバックになる: [X70-RN-09](#81-ガイド外の項目61--70)） | ブロックの中で早期に抜けないように書き換える |
| X61-CL-05 | 非推奨 | 低 | 日時の範囲で `Range#include?` を使う、`Rails::DBConsole#config`、Active Model の古い属性形式の Marshal 読み込みが非推奨になった | `Range#cover?` と `DBConsole.db_config.configuration_hash` に変える |
| X61-CL-06 | 挙動変更 | 中 | POST リクエストのパラメータに不正な UTF-8 があると、`ActionController::BadRequest` を返すようになった | 非 UTF-8 を受け付けるアクションには `skip_parameter_encoding :action`。rspec-rails の AnonymousController では、定数 `AnonymousController` を作らないと効かない（aruma のブログの事例） |
| X61-CL-07 | 挙動変更 | 低 | `connects_to` は `ActiveRecord::Base` か抽象クラスでしか呼べなくなった | `self.abstract_class = true` を `connects_to` より前に書く（freee の事例） |
| X61-LD-01 | 新設定 | 高 | `load_defaults 6.1` が設定する値で、ガイドにないもの: `active_record.has_many_inversing = true`、`active_record.legacy_connection_handling = false`、`active_storage.track_variants = true`、`active_job.retry_jitter = 0.15`、`active_job.skip_after_callbacks_if_terminated = true`、**`action_dispatch.cookies_same_site_protection = :lax`**、`action_controller.urlsafe_csrf_tokens = true`、**`action_view.form_with_generates_remote_forms = false`**、`action_view.preload_links_header = true`、`active_storage.queues.analysis` / `purge = nil`、`action_mailbox.queues.* = nil`、**`action_mailer.deliver_later_queue_name = nil`**、`ActiveSupport.utc_to_local_returns_utc_offset_times = true`（`ssl_default_redirect_status = 308` はガイド 7.5） | 6-1-stable の `configuration.rb` で確認した。注意点: SameSite=Lax だと、外部サイトから POST で戻ってくる連携（決済など）で cookie が送られない。`form_with` が Ajax（`data-remote`）でなくなる。メールの配信ジョブが `mailers` キューでなくデフォルトのキューに入る（ワーカーのキュー設定を確かめる）。`has_many_inversing` で inverse の設定が変わる |
| X61-WEB-01 | 依存 gem | 中 | activerecord-import の新しいメジャー版では、`on_duplicate_key_update` がデフォルトで付かなくなった | オプションを指定していない呼び出しに、`on_duplicate_key_update: [:updated_at]` などを明示する（freee の事例） |
| X61-WEB-02 | 不具合 | 中 | Rails 6.1.6 では、入れ子のハッシュから作った `ActionController::Parameters` の子要素が、まれに `HashWithIndifferentAccess` になる不具合があった（`#eql?` と `#hash` の不整合。rails/rails#45221 で修正） | 6.1 系の最新パッチを使う（STORES の事例） |
| X61-WEB-03 | 削除 | 低 | `add_template_helper`（private API）が使えなくなった | `helper` に書き換える（freee の事例） |

---

## 8. Rails 6.1 → Rails 7.0

| 節 | 区分 | 変更事項 | 修正事項（対応） |
|---|---|---|---|
| 6.1 | 挙動変更 | `button_to` に永続化済みの AR オブジェクトから URL を作らせると、`patch` のフォームを出力するようになった | 今の挙動を保つなら `method: :post` を明示するか、`my_custom_post_action_on_workshop_workshop_path(...)` のようなパスヘルパーを使う |
| 6.2 | 環境 | spring 3.0.0 以上が必須（古いと `undefined method 'mechanism=' for ActiveSupport::Dependencies:Module`） | spring を上げる。`config/environments/test.rb` を `config.cache_classes = false` にする |
| 6.3 | 環境 | `rails` gem が `sprockets-rails` に依存しなくなった | Sprockets を使い続けるなら `gem "sprockets-rails"` を足す |
| 6.4 | 必須 | zeitwerk モードが必須になった（classic は使えない） | 「クラシックオートローダーから Zeitwerk への移行」ガイドに沿って移る（[6 章 8.8](#6-rails-52--rails-60) も参照） |
| 6.5 | 削除 | `config.autoloader=` が削除された | `config.autoloader = :zeitwerk` などの行を消す |
| 6.6 | 削除 | `ActiveSupport::Dependencies` の private API が削除された（`hook!`、`unhook!`、`depend_on`、`require_or_load`、`mechanism` など。`Reference` や `Blamable` などの補助クラス・モジュールも） | `ActiveSupport::Dependencies.constantize` / `safe_constantize` は `"User".constantize` / `safe_constantize` に変える。`mechanism` とその reader / writer は `config.cache_classes` で置き換える。`verbose=` は `config/application.rb` の `Rails.autoloaders.log!` に変える |
| 6.7 | 必須 | 初期化中に、再読み込みされる定数を `to_prepare` の外で自動読み込みすると `NameError` になる（6.0 以降は非推奨警告 `DEPRECATION WARNING: Initialization autoloaded the constant ...`） | 警告が出ている箇所を「アプリ起動時の自動読み込み」の方法で直す（`to_prepare` など）。once オートローダーは以前より早くセットアップされるので、once オートローダーにカスタムの inflection を認識させたいなら、`config/initializers/inflections.rb` の内容を `config/application.rb` のアプリケーションクラスの本体に移す |
| 6.8 | 挙動変更 | `config.autoload_once_paths` はアプリケーションクラス（またはエンジンクラス）の本体と `config/environments/*` で設定できる。その後は frozen になり、これらのパスは `Rails.autoloaders.once` が管理する（初期化中にも自動読み込みでき、再読み込みはしない） | 環境の設定が終わってから変更して `FrozenError` が出るなら、そのコードを上記の場所に移す |
| 6.9 | 挙動変更 | `ActionDispatch::Request#content_type` が charset を含めた Content-Type をそのまま返すようになった | MIME タイプだけ欲しいところは `#media_type` に変える |
| 6.10 | 必須 | キージェネレータのデフォルトのダイジェストが SHA1 から SHA256 になった。暗号化メッセージ、暗号化 cookie、署名付き cookie すべてに影響する | cookie ローテータを登録する（例: `config/initializers/cookie_rotator.rb` で `after_initialize` 内に、`hash_digest_class: OpenSSL::Digest::SHA1` の `ActiveSupport::KeyGenerator` で古いキーを作り、`cookies.rotate :encrypted` / `:signed`）。しないとアップグレード中にセッションが無効になることがある |
| 6.11 | 挙動変更 | `ActiveSupport::Digest` のダイジェストが SHA1 から SHA256 になった。ETag やキャッシュキーが変わる | キャッシュのヒット率が下がることを見込み、慎重に切り替える |
| 6.12 | 新設定 | `ActiveSupport::Cache` の新しいシリアライズ形式（7.0）。7.0 は新旧どちらも読めるが、6.1 は新形式を読めない | `config.active_support.cache_format_version = 7.0`（または `load_defaults 7.0`）。無停止で移るなら、まず `cache_format_version = 6.1` のまま 7.0 をデプロイし、全プロセスの更新を確かめてから 7.0 にする |
| 6.13 | 環境 | 動画のプレビュー画像を FFmpeg のシーン変化検出で作るようになった | FFmpeg v3.4 以上 |
| 6.14 | 新設定 | Active Storage のデフォルトの variant プロセッサが `:vips` になった（新規アプリ）。`:mini_magick` は非推奨ではない | 既存アプリを移すなら `Rails.application.config.active_storage.variant_processor = :vips` にし、以下 6.14.1〜6.14.8 の書き換えをする |
| 6.14.1 | 必須(vips) | `resize` は使えない | `variant(resize: "100x")` を `variant(resize_to_limit: [100, nil])` に変える（しないと `no implicit conversion to float from string`） |
| 6.14.2 | 必須(vips) | `crop` は配列で指定する | `crop: "1920x1080+0+0"` を `crop: [0, 0, 1920, 1080]` に変える（しないと `unable to call crop: you supplied 2 arguments, but operation needs 5`） |
| 6.14.3 | 必須(vips) | `crop` の値のチェックが厳しい（`x` や `y` が負、または位置とサイズの合計が画像サイズを超えると切り出されない） | 値を画像の範囲内に収める（しないと `extract_area: bad extract area`） |
| 6.14.4 | 挙動変更(vips) | `resize_and_pad` のデフォルトの背景色が白から黒になった | `variant(resize_and_pad: [300, 300, background: [255]])` |
| 6.14.5 | 挙動変更(vips) | EXIF をもとに自動で回転する | 回転値を保存して自前で回転しているなら、`rotate:` を外す |
| 6.14.6 | 必須(vips) | `monochrome` は使えない | `variant(monochrome: true)` を `variant(colourspace: "b-w")` に変える |
| 6.14.7 | 必須(vips) | 画像圧縮のオプションが libvips 形式になった | JPEG: `saver: { strip: true, quality: 80, interlace: true }`。PNG: `saver: { strip: true, compression: 9 }`。WEBP: `saver: { strip: true, quality: 75, lossless: false, alpha_q: 85, reduction_effort: 6, smart_subsample: true }`。GIF: `saver: { optimize_gif_frames: true, optimize_gif_transparency: true }` |
| 6.14.8 | 必須(vips) | 変換の内容が画像 URL にエンコードされるため、URL をキャッシュしているとデプロイ後に画像が壊れる | 該当するキャッシュキーを手で無効にする（例: `cache product` を `cache ["v2", product]` に変える） |
| 6.15 | 挙動変更 | スキーマダンプに Rails のバージョンが入るようになった（`ActiveRecord::Schema[6.1].define`）。7.0 で一部カラム型のデフォルトが変わったため | 7.0 で初めてスキーマを読み込む前に `bin/rails app:update` を実行し、ダンプにバージョンが入っていることを確かめる。7.0 で初めてダンプしたスキーマの差分をよく見てからコミットする |

### 8.1 ガイド外の項目（6.1 → 7.0）

| ID | 区分 | 影響 | 変更事項 | 修正事項（対応） |
|---|---|---|---|---|
| X70-RN-01 | 削除 | 低 | Railties: `dbconsole` の非推奨の `config` が削除された | `Rails::DBConsole.db_config.configuration_hash` を使う |
| X70-RN-02 | 削除 | 中 | Action Pack: `ActionDispatch::Response.return_only_media_type_on_content_type`、`config.action_dispatch.hosts_response_app`、`ActionDispatch::SystemTestCase#host!`、`fixture_file_upload` に `fixture_path` からの相対パスを渡す書き方が削除された | 設定の行を消す（残すと起動時にエラー）。`hosts_response_app` は `config.host_authorization = { response_app: ... }` に移す。`fixture_file_upload` は `file_fixture_path` からの相対パスで渡す |
| X70-RN-03 | 削除 | 中 | `config.action_view.raise_on_missing_translations` が削除された | `config.i18n.raise_on_missing_translations` に変える（[X61-CL-01](#71-ガイド外の項目60--61)） |
| X70-RN-04 | 削除 | 中 | `ActionMailer::DeliveryJob` / `ActionMailer::Parameterized::DeliveryJob` が削除された | `MailDeliveryJob` に移る。デプロイ前に、古いクラスで積まれたジョブを処理しきる |
| X70-RN-05 | 削除 | 中 | Active Record の削除: `connected_to` の `database:`、`allow_unsafe_raw_sql`、`configs_for` の `:spec_name`、Rails 4.2 / 4.1 形式の AR インスタンスの YAML 読み込み、接続名 `"primary"`、`quote` / `type_cast` に AR オブジェクトやカラムを渡す、`DatabaseConfig#config`、`DatabaseTasks` の `schema_up_to_date?` の引数 / `dump_filename` / `schema_file` / `spec` / `current_config`、`allowed_index_name_length`、`in_clause_length`、`DatabaseConfig#spec_name`、`connection_config`、`arel_attribute`、`configurations.default_hash` / `to_h`、`Result#map!` / `#collect!`、`#remove_connection` | [X61-CL-03](#71-ガイド外の項目60--61) の置き換えをする。`connection_config` は `connection_db_config`、`arel_attribute(:x)` は `arel_table[:x]`、`DatabaseConfig#config` は `configuration_hash` |
| X70-RN-06 | 削除 | 高 | タスク `db:structure:dump` / `db:structure:load` / `db:structure:load_if_sql` / `db:structure:dump:#{name}` / `db:structure:load:#{name}` / `db:schema:load_if_ruby` / `db:test:load_structure` / `db:test:load_structure:#{name}` が削除された | `schema_format = :sql` と `db:schema:dump` / `load` に移る（CI やデプロイのスクリプトを直す） |
| X70-RN-07 | 挙動変更 | 中 | PostgreSQL の `:interval` カラムが、文字列でなく `ActiveSupport::Duration` を返すようになった | 文字列のままにするなら、モデルに `attribute :col, :string` |
| X70-RN-08 | 非推奨 | 低 | `Tasks::DatabaseTasks.schema_file_type` が非推奨になった | ― |
| X70-RN-09 | 挙動変更 | 高 | トランザクションのブロックから早期に抜ける（`return` など）と、コミットでなくロールバックするようになった（ブロック内のタイムアウトで不完全なトランザクションがコミットされるのを防ぐため） | ブロックの中の早期 return をやめる（Money Forward の事例でも対応している） |
| X70-RN-10 | 挙動変更 | 高 | 同じカラムに条件を merge すると、両方の条件を保たず、後の条件で置き換えるようになった | 両方の条件を AND で残したいなら、`and` で結合するなどに書き換える（Money Forward の事例でも対応している） |
| X70-RN-11 | 削除 | 高 | Active Model: `ActiveModel::Errors` をハッシュとして列挙する、`#to_h` / `#slice!` / `#values` / `#keys` / `#to_xml`、`#messages` に対する concat / `clear` / `delete` / `[]=` が削除された。Rails 5.x 形式のエラーと `AttributeSet` の Marshal / YAML 読み込みも削除された | `errors.add`、`errors.delete(:attr)`、`errors.each { \|error\| ... }`、`errors.attribute_names`、`errors.to_hash` などに置き換える（ガイド 7.7）。5.x の頃に Marshal でキャッシュしたモデルがあるなら、キャッシュを消す |
| X70-RN-12 | 削除 | 中 | Active Support: `config.active_support.use_sha1_digests`、`URI.parser`、日時の範囲での `Range#include?`、`Multibyte::Unicode.default_normalization_form` が削除された | 設定の行を消し、`hash_digest_class` にする。`URI::DEFAULT_PARSER`、`Range#cover?` を使う |
| X70-RN-13 | 非推奨 | 高 | `Array`、`Range`、`Date`、`DateTime`、`Time`、`BigDecimal`、`Float`、`Integer` の `#to_s` にフォーマットを渡す書き方（`to_s(:db)` など）が非推奨になった。新規アプリ（`load_defaults 7.0` の `disable_to_s_conversion = true`）では `to_s` が上書きされない | `to_fs(:db)`（`to_formatted_s`）に置き換える。`disable_to_s_conversion` を有効にすると `to_s(:db)` がエラーになるので、置き換えを終えてから有効にする |
| X70-RN-14 | 削除 | 中 | Active Job: 前のコールバックが `throw :abort` で中断しても `after_enqueue` / `after_perform` が止まらない挙動と、`:return_false_on_aborted_enqueue` が削除された。`skip_after_callbacks_if_terminated` が非推奨になった | 設定の行を消す。中断時に after 系コールバックが動かないことを前提にする |
| X70-RN-15 | 削除 | 低 | Action Mailbox: `credentials.action_mailbox.mailgun_api_key` と環境変数 `MAILGUN_INGRESS_API_KEY` が削除された | `signing_key` / `MAILGUN_INGRESS_SIGNING_KEY` を使う |
| X70-CL-01 | 挙動変更 | 高 | `datetime` カラムのデフォルトの精度が `precision: 6`（マイクロ秒）になった（7.0 のマイグレーション） | スキーマは `ActiveRecord::Schema[6.1]` のままなら従来どおり（ガイド 6.15）。Ridgepole を使っているなら、Schemafile で未指定のカラムに `precision: nil` を付け、`precision: 6` は外し、`--dry-run` で差分がないことを確かめる（Money Forward の事例） |
| X70-CL-02 | 削除 | 中 | Active Storage: `build_after_upload`、`create_after_upload!`、`service_url` が削除された | `create_and_upload!` と `url` に変える |
| X70-CL-03 | 非推奨 | 中 | Active Storage の非推奨: `ActiveStorage::Current.host`、関連の拡張から `purge` / `purge_later` を呼ぶ、`config.active_storage.replace_on_assign_to_many`（ガイド 8.9。FastRuby.io は「削除」と書いているが、CHANGELOG では非推奨）、不正な content type（`image/jpg`、`image/pjpeg`、`image/bmp`、`text/javascript`。7.1 でデフォルトから外れる） | `ActiveStorage::Current.url_options` を使う。content type を正しい値（`image/jpeg` など）に直す |
| X70-CL-04 | 非推奨 | 低 | Action Pack の非推奨: `config.action_controller.urlsafe_csrf_tokens`（常に有効）、システムテストの poltergeist / webkit ドライバの登録（7.1 で削除）、`config.action_dispatch.trusted_proxies` に単一の値を代入する | 設定の行を消す。ドライバは cuprite などに移る。`trusted_proxies` は配列で渡す |
| X70-CL-05 | 非推奨 | 中 | Active Record の非推奨: `partial_writes`、`legacy_connection_handling` | `partial_inserts` / `partial_updates` を使う。`legacy_connection_handling = false` にしてから設定の行を消す |
| X70-CL-06 | 非推奨 | 低 | Active Support の非推奨: `SafeBuffer` がオブジェクトを暗黙に文字列へ変換する、`ActiveSupport::TimeWithZone.name`、Rails 独自の `Enumerable#sum` / `Array#sum`（数値以外） | `#to_str` を実装するか明示的に変換する。`%w[a b].sum("")` のように初期値を渡す |
| X70-CL-07 | 挙動変更 | 低 | `Rack::Runtime` がデフォルトのミドルウェアから外れた（`X-Runtime` ヘッダが付かない） | 必要なら自分でミドルウェアに足す。足さずに `insert_before` などで参照するのは非推奨 |
| X70-LD-01 | 新設定 | 高 | `load_defaults 7.0` が設定する値で、ガイドにないもの: **`action_controller.raise_on_open_redirects = true`**、`action_controller.wrap_parameters_by_default = true`、**`action_dispatch.cookies_serializer = :json`**、`action_dispatch.default_headers`（`X-XSS-Protection: 0`、`Referrer-Policy: strict-origin-when-cross-origin` など）、`action_view.button_to_generates_button_tag = true`、`action_view.apply_stylesheet_media_default = false`、`active_support.remove_deprecated_time_with_zone_name = true`、`active_support.use_rfc4122_namespaced_uuids = true`、`active_support.executor_around_test_case = true`、`active_support.disable_to_s_conversion = true`、`action_mailer.smtp_timeout = 5`、`active_storage.multiple_file_field_include_hidden = true`、`active_record.verify_foreign_keys_for_fixtures = true`、`active_record.partial_inserts = false`、`active_record.automatic_scope_inversing = true` | 7-0-stable の `configuration.rb` で確認した。注意点: 外部ホストへの `redirect_to` が `UnsafeRedirectError` になる（`allow_other_host: true` で明示する）。cookie のシリアライザが `:marshal` のアプリは、`:hybrid` を挟んでから `:json` にする。`button_to` が `<input>` でなく `<button>` を出す。`Digest::UUID` の結果が変わることがある。外部キー違反がある fixture がエラーになる。INSERT に全カラムが入る。SMTP のタイムアウトが 5 秒になる |
| X70-WEB-01 | 必須 | 中 | 自動読み込みのガイドにある STI のプリロード（`StiPreload`）が 7.0 で動かず、`uninitialized constant` や循環参照になる場合がある | 子孫クラスの一覧を事前に生成しておき、起動時に読み込むなどの方法に変える（Money Forward の事例） |
| X70-WEB-02 | 必須 | 中 | テストで `request.session` を `Hash` でスタブしていると、`undefined method 'enabled?'` になる | `ActionController::TestSession.new(key: :value)` を返すようにする（Money Forward の事例） |
| X70-WEB-03 | 削除 | 中 | `render "shared/show.json"` のように、名前に `.` を含むテンプレートの指定は 6.1 で非推奨、7.0 でエラー（`MissingTemplate`）になる | `render partial: "shared/show", formats: :json, locals: {...}` に変える（Money Forward の事例） |
| X70-WEB-04 | 運用 | 高 | `secret_key_base` を共有して暗号化 cookie を読み書きしている複数のサービスがあると、片方だけ 7.0（SHA256）にした時点で互いの cookie を読めなくなり、ログアウトが繰り返される | 両方に、読み取り用の SHA1 ローテータを先に入れてから書き込みを SHA256 に切り替える（ガイド 6.10 の応用。Wantedly の事例） |

---

## 9. 段階をまたいで関係する項目

| テーマ | 関係する節 | 注意点 |
|---|---|---|
| 自動読み込み（classic → Zeitwerk） | 5.0: 11.6 → 6.0: 8.8 → 7.0: 6.4〜6.8 | 6.0 で Zeitwerk に移り（classic も選べる）、7.0 で Zeitwerk が必須になる。6.0 のうちに `zeitwerk:check` が通る状態にしておく |
| cookie の互換性 | 5.2: 9.2 → 6.0: 8.3 → 7.0: 6.10 | どの段階でも、新しい形式の cookie は旧バージョンで読めない。ロールバックできるように、各段階の設定（`use_authenticated_cookie_encryption` / `use_cookies_with_metadata` / ローテータ）を使って段階的に移る |
| キャッシュ | 7.0: 6.11, 6.12, 6.14.8 | SHA256 化でキャッシュキーが変わる、キャッシュ形式を切り替える、vips 化で画像 URL が変わる。ローリングデプロイの順序に気をつける |
| Content-Type / charset | 6.0: 8.6（Response）→ 7.0: 6.9（Request） | `content_type` で MIME タイプを比べている箇所は `media_type` に変える |
| Active Storage の画像処理 | 6.1: 7.6 → 7.0: 6.13, 6.14 | 6.1 で image_processing が必須になり、7.0 で vips がデフォルトになる（既存アプリは任意） |
| JS パッケージ | 6.0: 8.1, 8.4, 8.5 → 7.0: 6.3 | `@rails/*` への改名、Webpacker の導入は任意、7.0 で Sprockets が任意になる |

---

## 10. 出典

| 種類 | 出典 |
|---|---|
| アップグレードガイド | [Rails アップグレードガイド（railsguides.jp）](https://railsguides.jp/upgrading_ruby_on_rails.html) |
| リリースノート | railsguides.jp の [5.0](https://railsguides.jp/5_0_release_notes.html) / [5.1](https://railsguides.jp/5_1_release_notes.html) / [5.2](https://railsguides.jp/5_2_release_notes.html) / [6.0](https://railsguides.jp/6_0_release_notes.html) / [6.1](https://railsguides.jp/6_1_release_notes.html) / [7.0](https://railsguides.jp/7_0_release_notes.html)、英語版の [6.1](https://guides.rubyonrails.org/6_1_release_notes.html) |
| CHANGELOG | `https://github.com/rails/rails/blob/<X-Y>-stable/<framework>/CHANGELOG.md`（5-0〜7-0 の各フレームワーク） |
| load_defaults | [6-0-stable](https://github.com/rails/rails/blob/6-0-stable/railties/lib/rails/application/configuration.rb) / [6-1-stable](https://github.com/rails/rails/blob/6-1-stable/railties/lib/rails/application/configuration.rb) / [7-0-stable](https://github.com/rails/rails/blob/7-0-stable/railties/lib/rails/application/configuration.rb) の `configuration.rb` |
| 事例の索引 | ruby-jp の [Rails 6.0](https://scrapbox.io/ruby-jp/Rails_6.0_Upgrade_Knowledge) / [6.1](https://scrapbox.io/ruby-jp/Rails_6.1_Upgrade_Knowledge) / [7.0](https://scrapbox.io/ruby-jp/Rails_7.0_Upgrade_Knowledge) Upgrade Knowledge |
| FastRuby.io | [4.2→5.0](https://www.fastruby.io/blog/rails/upgrades/upgrade-rails-from-4-2-to-5-0.html) / [5.0→5.1](https://www.fastruby.io/blog/rails/upgrades/upgrade-rails-from-5-0-to-5-1.html) / [5.1→5.2](https://www.fastruby.io/blog/rails/upgrades/upgrade-rails-from-5-1-to-5-2.html) / [5.2→6.0](https://www.fastruby.io/blog/rails/upgrades/upgrade-rails-from-5-2-to-6-0.html) / [6.0→6.1](https://www.fastruby.io/blog/rails/upgrades/upgrade-rails-from-6-0-to-6-1.html) / [6.1→7.0](https://www.fastruby.io/blog/rails/upgrades/upgrade-rails-6-1-to-7-0.html) |
| 事例 | [Gunosy（6.0 で update_all が遅くなった）](https://tech.gunosy.io/entry/rails_update_all) / [Qiita（5.2→6.0 のハマりどころ）](https://qiita.com/taiteam/items/a37c60fc15c1aa5bb606) / [STORES（6.1 の Parameters の不具合）](https://product.st.inc/entry/2022/06/30/174323) / [aruma（6.1 の非 UTF-8 POST）](https://aruma256.dev/blog/2022/11/17/anonymous-controller.html) / [freee（6.0→6.1）](https://developers.freee.co.jp/entry/update-freee-accounting-to-rails6-1) / [Money Forward（STI と autoloading）](https://moneyforward-dev.jp/entry/2022/11/11/sti-and-autoloading-with-rails7/) / [Money Forward（6.1→7.0）](https://moneyforward-dev.jp/entry/2024/10/15/135316) / [Wantedly（7.0 のダイジェストクラス）](https://www.wantedly.com/companies/wantedly/post_articles/466117) / [AppBrew（4.2→6.1）](https://tech.appbrew.io/entry/2021/09/24/120000) |
