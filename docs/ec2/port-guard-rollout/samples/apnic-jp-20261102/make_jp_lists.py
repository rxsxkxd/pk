"""APNIC の割り当ての統計から、日本の IPv4・IPv6 の範囲の一覧（TSV）を作る（サンプルを作った Python の処理）。

    python3 make_jp_lists.py delegated-apnic-latest jp-ipv4.txt jp-ipv6.txt

1 列目が範囲（CIDR）、2 列目以降が情報（国・割り当ての組織・状態・割り当ての日）。
先頭の 2 行は # で始まるコメント（元の版と、列の名前）。

IPv4 は「先頭のアドレスと個数」を ipaddress.summarize_address_range で CIDR に分ける。
IPv6 は「先頭のアドレスと長さ」を、そのまま CIDR にする（strict に読めることを確かめる）。
"""

import ipaddress
import sys

COLUMNS = "# cidr\tcountry\tregistry\tstatus\tdate\n"


def main(source, ipv4_out, ipv6_out):
    ipv4, ipv6, version = [], [], ""
    for line in open(source, encoding="utf-8"):
        fields = line.strip().split("|")
        if not version and fields[0][:1].isdigit() and len(fields) > 2 and fields[1] == "apnic":
            version = fields[2]
        if len(fields) < 7 or fields[1] != "JP" or fields[6] not in ("allocated", "assigned"):
            continue
        meta = f"\t{fields[1]}\t{fields[0]}\t{fields[6]}\t{fields[5]}"
        if fields[2] == "ipv4":
            start = ipaddress.IPv4Address(fields[3])
            end = start + int(fields[4]) - 1
            ipv4 += [f"{network}{meta}" for network in ipaddress.summarize_address_range(start, end)]
        elif fields[2] == "ipv6":
            ipv6.append(f"{ipaddress.ip_network(f'{fields[3]}/{fields[4]}', strict=True)}{meta}")
    header = f"# source: APNIC delegated-apnic-latest {version}\n" + COLUMNS
    for path, rows in ((ipv4_out, ipv4), (ipv6_out, ipv6)):
        with open(path, "w", encoding="utf-8") as f:
            f.write(header + "".join(f"{row}\n" for row in rows))
    print(f"APNIC の版: {version}、IPv4: {len(ipv4)} 件、IPv6: {len(ipv6)} 件")


if __name__ == "__main__":
    main(*sys.argv[1:4])
