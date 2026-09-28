# 検索用サンプルです。Railsアプリとしての実行は想定していません。
ActiveRecord::Schema.define(version: 20260928000000) do
  create_table "users", force: :cascade do |t|
    t.string "email"
  end

  create_table "orders", force: :cascade do |t|
    t.bigint "user_id"
    t.integer "total_amount"
  end
end
