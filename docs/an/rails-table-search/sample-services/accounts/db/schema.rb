# 検索用サンプルです。Railsアプリとしての実行は想定していません。
ActiveRecord::Schema.define(version: 20260928000000) do
  create_table "users", force: :cascade do |t|
    t.string "name"
  end

  create_table "admin_users", force: :cascade do |t|
    t.string "email"
  end
end
