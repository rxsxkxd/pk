# 作業計画: OS（iptables ＋ ipset）で特定のポートを国内だけに絞る（移した）

> この作業計画は、確定した内容（80・443 番だけを絞る、SSH の 22 番は絞らない、SSM の導入を前提にする、各操作の前にバックアップを確かめる）に合わせて、道具の側の手順に移した。
>
> - 手順の正本: [port-guard-rollout の手順](../../port-guard-rollout/steps.md)（準備、バックアップ、SSM Agent の導入、ipset の導入と設定、遮断の有効化、見守りと片付け、元に戻す方法）
> - 仕組みと手での確認: [iptables ＋ ipset の仕組みと確認](../../port-guard-rollout/iptables-ipset.md)
>
> 移した日: 2026-10-29
