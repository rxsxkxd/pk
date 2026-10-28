# port-guard-rollout — 国内だけに絞る設定（iptables ＋ ipset）を複数台に入れる道具

> 状態: **未実装**（設計まで）。試す相手になる、今の構成に近いインスタンスの Docker の定義（`al2-instance/`）だけがある。

## 役割

今の環境（Amazon Linux 2・Apache・Passenger・Rails 4.2）の運用中のインスタンスに、特定のポートを国内（日本）だけに絞る設定（iptables ＋ ipset）を、**複数台まとめて**入れる。作業者の PC で動き、AWS の API と SSM の Run Command（SSM の準備の段階だけ SSH）で各インスタンスを操作する。

AL2023 での作り直し（[今の構成を AL2023 で作り直す検討](../initial-image-build/existing-system-rebuild-on-al2023.md)）とは別の、**暫定対応**のための道具である。

## 流れ（チェックポイント）

| 段階 | 内容 |
|---|---|
| チェックポイント 1 | バックアップまで（インスタンスの外の設定の記録、AMI の作成） |
| SSM の準備 | 全台の SSM Agent と権限の確認 → 一覧の表示と確認 → インストール・有効化・権限の付与 → 動作の確認 |
| チェックポイント 2 | 制限の設定の前まで（既存のファイアウォールの確認、ipset の導入、ファイルの配置、日本の IP の範囲の取得、集合の確認） |
| チェックポイント 3 | 制限の有効化と確認（自動で元に戻る予約を入れてから有効化し、確認に合格したものだけ確定） |
| （任意）チェックポイント 4 | 再起動しても戻るかの確認 |

## 実装の方針

| 項目 | 内容 |
|---|---|
| 言語 | **Go**（AWS SDK for Go）。作業者の PC で動く道具は Go、という方針（[決定事項 D10](../ami-publish-development-plan.md)）に合わせる |
| モジュール | このフォルダを 1 つの Go のモジュールにする（`ami-publish/` とは別）。Go の版は `ami-publish/` にそろえる |
| サーバーに入れる中身 | 設定・スクリプト・systemd のユニット・cron の雛形はシェルのまま、`go:embed` で道具に埋め込む |
| 進め方 | 骨組み（コマンドの形、状態のファイル、全台の確認）から作る |

## フォルダの中身

| フォルダ | 内容 |
|---|---|
| [`al2-instance/`](./al2-instance/README.md) | 今の構成（AL2・Apache 2.4.56・Passenger 6.0.18・Ruby 2.7.7・Rails 4.2）に近いインスタンスを手元で再現する Docker の定義。道具を試す相手にする |

## 関連ドキュメント

- [設計: 国内だけに絞る設定（iptables ＋ ipset）を複数台に入れるスクリプト](../notes/ec2-operations/access-restriction-rollout-script-design.md)（チェックポイント、状態の管理、権限、決めること C1〜C9）
- [作業計画: OS（iptables ＋ ipset）で特定のポートを国内だけに絞る](../notes/ec2-operations/access-restriction-os-firewall-work-plan.md)（1 台を手で行う場合の計画）
- [暫定対応: OS（iptables ＋ ipset、または firewalld）で特定のポートを国内と特定の IP に絞る](../notes/ec2-operations/access-restriction-os-firewall.md)（サーバーに入れる設定・スクリプト・ユニットの中身）
