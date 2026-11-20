# ロールの付与だけ・ロールの確認だけを行う

> 位置付け: [手順](./steps.md)（正本）の「1. SSM 用の IAM ロールの関連付け」のうち、ロールの付与だけ、またはロールの確認だけを単独で行うときの道具の使い方。道具は `ssm-setup/` で実行する。
>
> 更新日: 2026-11-20

## ロールの付与だけ

`rb/ssm_role_force.rb` を使う。渡した台に、確かめずに関連付けだけを行う。

```bash
ruby rb/ssm_role_force.rb --instance-profile <インスタンスプロファイル> < role-targets.txt
```

## ロールの確認だけ

どれも読み取りだけで、何も変えない。

| 確かめたいこと | 道具 |
|---|---|
| 付与の前: どの台にロールが付いていて、どの台に付いていないか | `rb/ssm_role_targets.rb`（付与できる台の一覧も書き出せる）。または `rb/ssm_role.rb --check-only` |
| 付与の後: 関連付けがあるか、そのロールに `AmazonSSMManagedInstanceCore` が付いているか | `rb/ssm_role_verify.rb` |

```bash
ruby rb/ssm_role_targets.rb --out role-targets.txt < instance-ids.txt   # 付与の前
ruby rb/ssm_role_verify.rb < instance-ids.txt                            # 付与の後
```
