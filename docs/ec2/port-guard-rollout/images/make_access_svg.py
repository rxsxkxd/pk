"""アクセス制限の構成の図（access-architecture.svg）を作る。

    cd port-guard-rollout && python3 images/make_access_svg.py images

VPC・サブネット・セキュリティグループ・OS の iptables ＋ ipset・httpd・Rails・SSM の関係を 1 枚に描く。
今の構成では、80・443 番は OS の iptables ＋ ipset で国内と許可した IP に絞り、22 番はセキュリティグループで弾き、
外からのログインは SSM（Session Manager）で行う。構成を変えたら、この図と iptables-ipset.md をそろえて直す。
"""

import sys
from xml.sax.saxutils import escape

STYLE = """
  <style>
    .bg { fill: #ffffff; }
    text { font-family: "Hiragino Sans", "Noto Sans JP", "Yu Gothic", sans-serif; fill: #111827; }
    .title { font-size: 20px; font-weight: bold; }
    .h { font-size: 15px; font-weight: bold; }
    .t { font-size: 14px; }
    .s { font-size: 12.5px; fill: #374151; }
    .lbl { font-size: 12.5px; font-weight: bold; }
    .aws { fill: #fffaf0; stroke: #d97706; stroke-width: 1.5; }
    .vpc { fill: #f5f3ff; stroke: #7c3aed; stroke-width: 1.5; }
    .subnet { fill: #eef6ff; stroke: #2563eb; stroke-width: 1.2; stroke-dasharray: 6 4; }
    .sg { fill: #fff5f5; stroke: #dc2626; stroke-width: 2.2; stroke-dasharray: 10 5; }
    .ec2 { fill: #ffffff; stroke: #374151; stroke-width: 1.5; }
    .os { fill: #fef3c7; stroke: #b45309; stroke-width: 1.5; }
    .app { fill: #e0f2fe; stroke: #0369a1; stroke-width: 1.2; }
    .agent { fill: #ecfdf3; stroke: #15803d; stroke-width: 1.2; }
    .actor { fill: #f9fafb; stroke: #6b7280; stroke-width: 1.2; }
    .ssm { fill: #ecfdf3; stroke: #15803d; stroke-width: 1.5; }
    .ok { stroke: #16a34a; stroke-width: 2.4; fill: none; marker-end: url(#ok); }
    .ng { stroke: #dc2626; stroke-width: 2.4; fill: none; }
    .ssmline { stroke: #15803d; stroke-width: 2.2; fill: none; stroke-dasharray: 7 4; marker-end: url(#ssm); }
    .okt { fill: #15803d; }
    .ngt { fill: #b91c1c; }
    .x { stroke: #dc2626; stroke-width: 4; }
  </style>
  <defs>
    <marker id="ok" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
      <path d="M 0 0 L 10 5 L 0 10 z" fill="#16a34a"/>
    </marker>
    <marker id="ssm" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
      <path d="M 0 0 L 10 5 L 0 10 z" fill="#15803d"/>
    </marker>
  </defs>
"""


class Svg:
    def __init__(self, width, height):
        self.w, self.h = width, height
        self.parts = [f'<rect class="bg" x="0" y="0" width="{width}" height="{height}"/>']

    def rect(self, x, y, w, h, cls, rx=10):
        self.parts.append(f'<rect class="{cls}" x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}"/>')

    def text(self, x, y, s, cls="t", anchor="start"):
        self.parts.append(f'<text class="{cls}" x="{x}" y="{y}" text-anchor="{anchor}">{escape(s)}</text>')

    def lines(self, x, y, rows, step=19, anchor="start"):
        for i, (s, cls) in enumerate(rows):
            self.text(x, y + i * step, s, cls, anchor)

    def path(self, points, cls):
        d = "M " + " L ".join(f"{px} {py}" for px, py in points)
        self.parts.append(f'<path class="{cls}" d="{d}"/>')

    def cross(self, x, y, r=9):
        self.parts.append(f'<line class="x" x1="{x - r}" y1="{y - r}" x2="{x + r}" y2="{y + r}"/>')
        self.parts.append(f'<line class="x" x1="{x - r}" y1="{y + r}" x2="{x + r}" y2="{y - r}"/>')

    def render(self):
        body = "\n  ".join(self.parts)
        return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.w}" height="{self.h}" '
                f'viewBox="0 0 {self.w} {self.h}" role="img">\n{STYLE}\n  {body}\n</svg>\n')


def build():
    s = Svg(1260, 980)
    s.text(20, 34, "port-guard: アクセス制限の構成（今の構成）", "title")

    # ---- AWS（右の大きな枠）
    s.rect(310, 60, 930, 900, "aws", 14)
    s.text(330, 88, "AWS（対象のインスタンスのリージョン）", "h")

    # VPC・サブネット・セキュリティグループ
    s.rect(330, 100, 630, 780, "vpc", 12)
    s.text(350, 126, "VPC", "h")
    s.rect(350, 138, 590, 724, "subnet", 10)
    s.text(370, 162, "公開のサブネット（パブリック IP）", "h")
    s.rect(370, 176, 550, 670, "sg", 10)
    s.text(390, 202, "セキュリティグループ（インスタンスの外の壁）", "h")
    s.lines(390, 224, [
        ("受信: 22 番 → インターネットからは許可しない（ここで弾く）", "s"),
        ("受信: 80・443 番 → 0.0.0.0/0 を許可", "s"),
        ("送信: 443 番（SSM の窓口など）を許可", "s"),
    ], step=18)

    # EC2 インスタンス
    s.rect(400, 290, 500, 540, "ec2", 10)
    s.text(420, 316, "EC2 インスタンス（Amazon Linux 2）", "h")

    # OS: iptables ＋ ipset
    s.rect(420, 330, 460, 196, "os", 8)
    s.text(438, 354, "OS: iptables ＋ ipset（port-guard）", "h")
    s.lines(438, 378, [
        ("80・443 番 → PORT_GUARD のチェーンで判定", "t"),
        ("・日本の IP の範囲（port_guard_jp）→ 受け付ける", "s"),
        ("・許可する IP（port_guard_allow）→ 受け付ける", "s"),
        ("・それ以外 → 破棄（記録: port-guard drop:）", "s"),
        ("22 番などほかのポート → 何もしない（今までどおり）", "t"),
        ("一覧は install を実行した時点のもの", "s"),
    ], step=21)

    # httpd・Rails・SSM Agent
    s.rect(420, 546, 460, 70, "app", 8)
    s.lines(650, 572, [("httpd（Apache 2.4.56）", "h"), ("mod_ssl（443 番の TLS）・mod_passenger 6.0.18", "s")], anchor="middle")
    s.rect(420, 634, 460, 64, "app", 8)
    s.lines(650, 660, [("Rails 4.2（Ruby 2.7.7）", "h"), ("Passenger が起動するアプリのプロセス", "s")], anchor="middle")
    s.rect(420, 726, 460, 84, "agent", 8)
    s.lines(650, 752, [("SSM Agent", "h"), ("インスタンスから AWS の窓口へ、送信の 443 番で接続を張る", "s"),
                       ("（受信の口は要らない）", "s")], anchor="middle")

    # AWS Systems Manager（VPC の外の AWS のサービス）
    s.rect(990, 690, 230, 130, "ssm", 10)
    s.lines(1105, 720, [("AWS Systems Manager", "h"), ("Session Manager・Run Command", "s"),
                        ("（AWS のサービス。VPC の外）", "s")], anchor="middle")
    s.lines(1105, 662, [("SSM Agent から", "s"), ("送信の 443 番で接続", "s")], step=16, anchor="middle")

    # ---- 外の相手（左の列。届く先の層の高さに並べる）
    actors = [
        (200, "インターネット（だれでも）", ["SSH（22 番）での接続"]),
        (360, "日本の利用者", ["日本の IP、または許可する IP"]),
        (450, "海外からの接続", ["海外の確認の拠点を含む"]),
        (716, "作業者の PC", ["AWS CLI・Session Manager"]),
    ]
    for y, head, sub in actors:
        s.rect(20, y, 270, 64, "actor")
        s.lines(155, y + 27, [(head, "h")] + [(x, "s") for x in sub], anchor="middle")

    # ---- 通り道
    # インターネットからの SSH: セキュリティグループで弾く
    s.path([(290, 232), (362, 232)], "ng")
    s.cross(370, 232)
    s.text(298, 224, "22 番", "lbl ngt")
    s.text(155, 288, "→ セキュリティグループで弾く", "lbl ngt", "middle")

    # 日本の利用者: セキュリティグループを通り、iptables で受け付け、httpd → Rails
    s.path([(290, 392), (420, 392)], "ok")
    s.text(298, 384, "80・443", "lbl okt")
    s.path([(650, 526), (650, 546)], "ok")
    s.path([(650, 616), (650, 634)], "ok")

    # 海外からの接続: セキュリティグループは通るが、iptables で破棄
    s.path([(290, 482), (412, 482)], "ng")
    s.cross(420, 482)
    s.text(298, 474, "80・443", "lbl ngt")
    s.text(155, 538, "→ OS で破棄（相手には時間切れ）", "lbl ngt", "middle")

    # 作業者の PC → Systems Manager ← SSM Agent
    s.path([(155, 780), (155, 905), (1105, 905), (1105, 822)], "ssmline")
    s.text(330, 935, "ログイン・操作は SSM で行う（aws ssm start-session / send-command。HTTPS）。22 番は開けない", "lbl okt")
    s.path([(880, 768), (988, 768)], "ssmline")

    # 凡例
    s.text(20, 600, "凡例", "h")
    s.path([(20, 624), (70, 624)], "ok")
    s.text(80, 629, "受け付ける", "s")
    s.path([(20, 650), (62, 650)], "ng")
    s.cross(66, 650, 6)
    s.text(80, 655, "弾く・破棄する", "s")
    s.path([(20, 676), (70, 676)], "ssmline")
    s.text(80, 681, "SSM の経路", "s")
    return s.render()


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "images"
    with open(f"{out}/access-architecture.svg", "w", encoding="utf-8") as f:
        f.write(build())
