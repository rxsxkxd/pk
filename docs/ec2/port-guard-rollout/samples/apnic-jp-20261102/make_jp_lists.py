"""APNIC の割り当ての統計から、日本の IPv4・IPv6 の範囲の一覧を作る（サンプルを作った Python の処理）。

    python3 make_jp_lists.py delegated-apnic-latest jp-ipv4.txt jp-ipv6.txt

IPv4 は「先頭のアドレスと個数」を ipaddress.summarize_address_range で CIDR に分ける。
IPv6 は「先頭のアドレスと長さ」を、そのまま CIDR にする（strict に読めることを確かめる）。
"""

import ipaddress
import sys


def main(source, ipv4_out, ipv6_out):
    ipv4, ipv6 = [], []
    for line in open(source, encoding="utf-8"):
        fields = line.strip().split("|")
        if len(fields) < 7 or fields[1] != "JP" or fields[6] not in ("allocated", "assigned"):
            continue
        if fields[2] == "ipv4":
            start = ipaddress.IPv4Address(fields[3])
            end = start + int(fields[4]) - 1
            ipv4 += [str(network) for network in ipaddress.summarize_address_range(start, end)]
        elif fields[2] == "ipv6":
            ipv6.append(str(ipaddress.ip_network(f"{fields[3]}/{fields[4]}", strict=True)))
    for path, networks in ((ipv4_out, ipv4), (ipv6_out, ipv6)):
        with open(path, "w", encoding="utf-8") as f:
            f.write("".join(f"{network}\n" for network in networks))
    print(f"IPv4: {len(ipv4)} 件、IPv6: {len(ipv6)} 件")


if __name__ == "__main__":
    main(*sys.argv[1:4])
