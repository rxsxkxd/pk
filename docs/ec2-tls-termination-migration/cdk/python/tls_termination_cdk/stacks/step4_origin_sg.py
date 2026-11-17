"""ステップ 4（ルーティングができた後に付ける）: オリジン用のセキュリティグループ。

CloudFront のオリジン向けのアドレスの一覧（AWS が管理するプレフィックスリスト）から、稼働サーバーの 443 番への
接続だけを許可するグループを作る。稼働サーバーへの付け替え（今のグループに足す）と、今のグループの全公開の許可の
削除は、このスタックに含めず AWS CLI で行う（step4-origin-restriction.md）。

ステップ 2 の CloudFront とは関係なく作れる（ほかのスタックの出力を使わない）。今の稼働サーバーは 80・443 番を
全公開しているので、このグループがなくても CloudFront から届く。ルーティングを先に作るため、ステップ 2 から分けた。
"""

from __future__ import annotations

from constructs import Construct

from ..configuration import Configuration
from .common import TerminationStack, define_origin_security_group


class Step4OriginSecurityGroupStack(TerminationStack):
    """オリジン用のセキュリティグループだけを持つスタック。出力は OriginSecurityGroupId。"""

    def __init__(self, scope: Construct, stack_name: str, configuration: Configuration) -> None:
        # 説明（英語）はテンプレートに出る。日本語のコメントはテンプレートに出ない
        super().__init__(
            scope,
            stack_name,
            "Step 4 of CloudFront -> EC2: security group that allows HTTPS only from CloudFront origin-facing servers. "
            "Add it to the instance, then remove the public 80/443 rules from the existing security group.",
            configuration,
        )

        origin_security_group = define_origin_security_group(self, configuration)

        # ステップ 4 の 4-2 で、稼働サーバーに足すセキュリティグループ
        self.output(
            "OriginSecurityGroupId",
            origin_security_group.security_group_id,
            "Add this security group to the instance (step 4), then remove the public 80/443 rules.",
        )
