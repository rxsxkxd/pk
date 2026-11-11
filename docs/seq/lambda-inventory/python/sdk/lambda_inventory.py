#!/usr/bin/env python3
"""棚卸しツールの入口。使い方は ../../README.md、出力の項目は ../../DATA.md を参照。

正本は docs/seq/_common/python/entry.py。sync-common.sh がツールごとの名前で写す。
"""

import sys

import inventory_common
import service

if __name__ == "__main__":
    inventory_common.main(service, sys.argv[1:])
