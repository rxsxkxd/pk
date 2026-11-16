"""AWS の IP アドレスの範囲の一覧（ip-ranges.json）から、東京・大阪のリージョンの範囲の一覧（TSV）を作る（サンプルを作った Python の処理）。

    python3 make_aws_lists.py ip-ranges.json aws-ipv4.txt aws-ipv6.txt

取り出す条件は、踏み台サーバーの make-aws-lists.sh（ステップ 0-3）と同じ。
  リージョンが ap-northeast-1（東京）か ap-northeast-3（大阪）、サービスが AMAZON、
  ネットワークの区画（network_border_group）が ap-northeast-1-tpe-1（台北のローカルゾーン）でないもの。
1 列目が範囲（CIDR）、2 列目以降が情報（リージョン・サービス・network_border_group）。
先頭の 2 行は # で始まるコメント（元の版と、列の名前）。並びは ip-ranges.json に載っている順。
"""

import ipaddress
import json
import sys

REGIONS = {"ap-northeast-1", "ap-northeast-3"}
SERVICE = "AMAZON"
EXCLUDE_BORDER_GROUPS = {"ap-northeast-1-tpe-1"}
COLUMNS = "# cidr\tregion\tservice\tnetwork_border_group\n"


def pick(entries, key):
    rows = []
    for entry in entries:
        if entry["region"] not in REGIONS or entry["service"] != SERVICE:
            continue
        if entry["network_border_group"] in EXCLUDE_BORDER_GROUPS:
            continue
        ipaddress.ip_network(entry[key], strict=True)  # 正しい CIDR として読めることを確かめる
        rows.append(f"{entry[key]}\t{entry['region']}\t{entry['service']}\t{entry['network_border_group']}")
    return rows


def main(source, ipv4_out, ipv6_out):
    with open(source, encoding="utf-8") as f:
        data = json.load(f)
    header = f"# source: AWS ip-ranges.json createDate {data['createDate']}\n" + COLUMNS
    ipv4 = pick(data["prefixes"], "ip_prefix")
    ipv6 = pick(data["ipv6_prefixes"], "ipv6_prefix")
    for path, rows in ((ipv4_out, ipv4), (ipv6_out, ipv6)):
        with open(path, "w", encoding="utf-8") as f:
            f.write(header + "".join(f"{row}\n" for row in rows))
    print(f"ip-ranges.json の版: {data['createDate']}、IPv4: {len(ipv4)} 件、IPv6: {len(ipv6)} 件")


if __name__ == "__main__":
    main(*sys.argv[1:4])
