#!/bin/sh
# CSVに記載されたRailsプロジェクトのdb配下を検索する。
set -eu

if ! command -v python3 >/dev/null 2>&1; then
  echo 'エラー: Python 3が必要です。' >&2
  exit 2
fi

exec python3 - "$@" <<'PY'
import csv
import re
import sys
from pathlib import Path


def main():
    if len(sys.argv) < 3:
        print('使い方: ./grep_rails_tables.sh <CSVファイル> <テーブル名> [テーブル名 ...]', file=sys.stderr)
        return 2

    csv_path = Path(sys.argv[1]).resolve()
    tables = list(dict.fromkeys(sys.argv[2:]))
    if any(not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', table) for table in tables):
        raise ValueError('テーブル名は英数字とアンダースコアで指定してください（先頭は英字または_）。')

    services = []
    with csv_path.open(encoding='utf-8-sig', newline='') as stream:
        reader = csv.DictReader(stream)
        if reader.fieldnames != ['service', 'path']:
            raise ValueError('CSVのヘッダーは service,path にしてください。')
        for row in reader:
            if None in row or not row['service'] or not row['path']:
                raise ValueError(f'CSV {reader.line_num}行目: serviceとpathを指定してください。')
            root = Path(row['path']).expanduser()
            if not root.is_absolute():
                root = csv_path.parent / root
            root = root.resolve()
            if not (root / 'db').is_dir():
                raise ValueError(f'{row["service"]}: dbディレクトリがありません: {root / "db"}')
            services.append((row['service'], root))
    if not services:
        raise ValueError('CSVに検索対象のサービスがありません。')

    patterns = [(table, re.compile(r'(?<![A-Za-z0-9_])' + re.escape(table) + r'(?![A-Za-z0-9_])')) for table in tables]
    found = False
    for service, root in services:
        for path in sorted((root / 'db').rglob('*')):
            if not path.is_file() or path.suffix not in ('.rb', '.sql'):
                continue
            with path.open(encoding='utf-8') as stream:
                for number, line in enumerate(stream, 1):
                    for table, pattern in patterns:
                        if pattern.search(line):
                            if not found:
                                print('service\ttable\tfile\tline\tcontent')
                            found = True
                            print(f'{service}\t{table}\t{path.relative_to(root)}\t{number}\t{line.strip()}')
    if not found:
        print('一致するテーブル名は見つかりませんでした。', file=sys.stderr)
        return 1
    return 0


try:
    sys.exit(main())
except (OSError, UnicodeError, ValueError, csv.Error) as error:
    print(f'エラー: {error}', file=sys.stderr)
    sys.exit(2)
PY
