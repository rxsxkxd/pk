#!/usr/bin/env ruby
# frozen_string_literal: true

# 棚卸しツールの入口。使い方は ../../README.md、出力の項目は ../../DATA.md を参照。
# 正本は docs/seq/_common/ruby/entry.rb。sync-common.sh がツールごとの名前で写す。

require_relative "inventory_common"
require_relative "service"

InventoryCommon.main(Service, ARGV)
