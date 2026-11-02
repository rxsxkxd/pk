# サンプル: 日本の IP の範囲の一覧（APNIC、2026-11-02）

[踏み台サーバーから入れるコマンド](../../bastion-install-commands.md) の手順を確かめるときに、Python で作った一覧を、そのまま残したもの。踏み台サーバーのステップ 0（`make-jp-lists.sh`。`awk` で作る）の結果と、中身が 1 文字も違わないことを確かめた（`cmp`）。

**これはサンプル**。対象のサーバーに入れる一覧は、作業のときに踏み台サーバーで取り直す（APNIC の割り当ては少しずつ変わる）。手順の検証や、取り直した一覧と比べて大きく変わっていないかを見るのに使う。

| ファイル | 内容 | 件数 | 大きさ |
|---|---|---|---|
| `jp-ipv4.txt` | 日本の IPv4 の範囲（CIDR、1 行 1 件）。対象のサーバーでは `/etc/port-guard/jp.txt`、ipset の集合 `port_guard_jp`（`family inet`） | 4,738 | 73,762 バイト |
| `jp-ipv6.txt` | 日本の IPv6 の範囲（CIDR、1 行 1 件）。対象のサーバーでは `/etc/port-guard/jp6.txt`、ipset の集合 `port_guard_jp6`（`family inet6`） | 766 | 12,187 バイト |
| `make_jp_lists.py` | 一覧を作った Python の処理（標準のライブラリの `ipaddress` だけ） | — | — |

## 元のデータ

| 項目 | 内容 |
|---|---|
| 出どころ | APNIC の割り当ての統計 `https://ftp.apnic.net/stats/apnic/delegated-apnic-latest` |
| 版の行 | `2|apnic|20261102|89635|19830613|20261030|+1000`（2026-11-02 の版） |
| 取得した日 | 2026-11-02 |
| SHA-256 | `dbe5a8294bb0f885499c4e9464be2046be273f9a1daee8acff2cd3c363f47c5b`（元のデータは大きい（約 4.3 MB）ので、ここには置いていない） |
| 取り出した行 | 国が `JP`、種類が `ipv4` か `ipv6`、状態が `allocated` か `assigned` の行 |

| ファイル | SHA-256 |
|---|---|
| `jp-ipv4.txt` | `5deb31775faa19e2eb837d82d5d36b61be3da957027fbe2ec04f826be39cafab` |
| `jp-ipv6.txt` | `1fb9cb8ca21ab503db75495bfe221b2683e09206485c4667c9930991db39f77f` |

## 作り直し方

```bash
curl -fsS -o delegated-apnic-latest https://ftp.apnic.net/stats/apnic/delegated-apnic-latest
python3 make_jp_lists.py delegated-apnic-latest jp-ipv4.txt jp-ipv6.txt
```

同じ日の版なら、同じ一覧になる。日が違えば、件数や中身が少し変わる。

## 確かめたこと

| 確かめたこと | 結果 |
|---|---|
| 踏み台サーバーの `awk` の処理（ステップ 0）との一致 | IPv4・IPv6 とも、中身が同じ |
| IPv6 の範囲が正しい CIDR として読めるか | 全件読める（`ipaddress.ip_network(..., strict=True)`） |
| 入るはずの IP・入らないはずの IP | `1.0.16.1` は IPv4 の一覧に入る。`8.8.8.8` は入らない |
| CIDR の長さの種類 | IPv4 は 16 種類（ipset の `hash:net` の照合の重さは、件数より長さの種類の数で決まる）。IPv6 は 20 種類（/20〜/64） |
