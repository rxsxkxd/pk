# Railsのテーブル検索コマンド

`grep_rails_tables.sh` にCSVファイルとテーブル名を指定して、各Railsプロジェクトの `db/` 配下にある `.rb`・`.sql` ファイルを検索します。Python 3が必要です。

## 基本の書き方

```sh
./grep_rails_tables.sh <CSVファイル> <テーブル名> [追加のテーブル名 ...]
```

| 引数 | 指定する内容 |
| --- | --- |
| 第1引数 | CSVファイル（例：`services.csv`） |
| 第2引数以降 | 検索するテーブル名（複数の場合はスペースで区切る） |

## 1つのテーブルを探す場合

`users` テーブルを検索します。

```sh
./grep_rails_tables.sh services.csv users
```

## 複数のテーブルを一度に探す場合

`users` と `orders` テーブルをまとめて検索します。

```sh
./grep_rails_tables.sh services.csv users orders
```

## 実行する場所

上記の例は、`grep_rails_tables.sh` と `services.csv` があるディレクトリで実行します。

同梱の `services.csv` は検索用サンプルを指しているので、そのまま上記のコマンドを試せます。

## CSVの形式

```csv
service,path
shop,./sample-services/shop
accounts,./sample-services/accounts
```

- `service`：結果に表示するサービス名。
- `path`：Railsプロジェクトのルート。相対パスはCSVファイルのあるディレクトリを基準に解決します。絶対パスも指定できます。
- カンマを含む値はCSVのルールに従ってダブルクォートで囲んでください。

実際のプロジェクトを検索するときは、CSVのサービス名とパスを書き換えてください。

## 検索結果

サービス名、テーブル名、プロジェクト内のファイルパス、行番号、一致した行をタブ区切りで表示します。

```text
service table file line content
shop users db/schema.rb 3 create_table "users", force: :cascade do |t|
accounts users db/schema.rb 3 create_table "users", force: :cascade do |t|
```

上記は表示イメージです。`users` は `admin_users` には一致しません。大文字・小文字は区別します。テーブル名は英数字とアンダースコアで指定し、先頭は英字またはアンダースコアにしてください。

文字列としてテーブル名を検索するため、コメントやSQLの参照も対象になります。Railsのモデル名からテーブル名を推測する機能はありません。

終了コードは、一致ありなら `0`、一致なしなら `1`、引数・CSV・ファイル読み込みなどのエラーなら `2` です。
