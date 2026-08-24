"""IAM ロールとインスタンスプロファイルの関係の図（iam-instance-profile.svg）を作る。

    cd ssm-setup && python3 images/make_iam_svg.py images

- 1 つのインスタンスプロファイルに入れられるロールは 1 つだけ（ポリシーは 1 つのロールに複数付けられる）
- 1 つのインスタンスプロファイルは、何台のインスタンスにでも関連付けられる
- 1 台のインスタンスに関連付けられるインスタンスプロファイルは 1 つだけ
steps.md の「2. SSM 用の IAM ロールの関連付け」の Mermaid の図と中身をそろえて直す。
"""

import sys
from xml.sax.saxutils import escape

STYLE = """
  <style>
    .bg { fill: #ffffff; }
    text { font-family: "Hiragino Sans", "Noto Sans JP", "Yu Gothic", sans-serif; fill: #111827; }
    .title { font-size: 19px; font-weight: bold; }
    .h { font-size: 15px; font-weight: bold; }
    .s { font-size: 12.5px; fill: #374151; }
    .lbl { font-size: 12.5px; font-weight: bold; fill: #1f2937; }
    .ngt { font-size: 12.5px; font-weight: bold; fill: #b91c1c; }
    .policy { fill: #f5f3ff; stroke: #7c3aed; stroke-width: 1.4; }
    .policy2 { fill: #f5f3ff; stroke: #7c3aed; stroke-width: 1.2; stroke-dasharray: 5 4; }
    .role { fill: #fff7ed; stroke: #c2410c; stroke-width: 1.6; }
    .profile { fill: #ecfdf3; stroke: #15803d; stroke-width: 1.8; }
    .profile2 { fill: #f3f4f6; stroke: #6b7280; stroke-width: 1.4; }
    .ec2 { fill: #eff6ff; stroke: #1d4ed8; stroke-width: 1.4; }
    .edge { stroke: #374151; stroke-width: 1.7; fill: none; marker-end: url(#arrow); }
    .edge2 { stroke: #6b7280; stroke-width: 1.4; fill: none; stroke-dasharray: 5 4; marker-end: url(#arrow); }
    .ng { stroke: #dc2626; stroke-width: 2; fill: none; stroke-dasharray: 6 4; }
    .x { stroke: #dc2626; stroke-width: 3.5; }
  </style>
  <defs>
    <marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
      <path d="M 0 0 L 10 5 L 0 10 z" fill="#374151"/>
    </marker>
  </defs>
"""


class Svg:
    def __init__(self, width, height):
        self.w, self.h = width, height
        self.parts = [f'<rect class="bg" x="0" y="0" width="{width}" height="{height}"/>']

    def box(self, x, y, w, h, cls, rows):
        self.parts.append(f'<rect class="{cls}" x="{x}" y="{y}" width="{w}" height="{h}" rx="10"/>')
        step = 19
        top = y + h / 2 - (len(rows) - 1) * step / 2 + 5
        for i, (text, kind) in enumerate(rows):
            self.text(x + w / 2, top + i * step, text, kind, "middle")

    def text(self, x, y, s, cls="s", anchor="start"):
        self.parts.append(f'<text class="{cls}" x="{x}" y="{y}" text-anchor="{anchor}">{escape(s)}</text>')

    def path(self, points, cls="edge"):
        d = "M " + " L ".join(f"{px} {py}" for px, py in points)
        self.parts.append(f'<path class="{cls}" d="{d}"/>')

    def cross(self, x, y, r=8):
        self.parts.append(f'<line class="x" x1="{x - r}" y1="{y - r}" x2="{x + r}" y2="{y + r}"/>')
        self.parts.append(f'<line class="x" x1="{x - r}" y1="{y + r}" x2="{x + r}" y2="{y - r}"/>')

    def render(self):
        body = "\n  ".join(self.parts)
        return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.w}" height="{self.h}" '
                f'viewBox="0 0 {self.w} {self.h}" role="img">\n{STYLE}\n  {body}\n</svg>\n')


def build():
    s = Svg(1120, 570)
    s.text(20, 34, "IAM ロールとインスタンスプロファイルの関係", "title")

    # ポリシー → ロール（ポリシーは複数付けられる）
    s.box(20, 90, 230, 60, "policy", [("ポリシー", "h"), ("AmazonSSMManagedInstanceCore", "s")])
    s.box(20, 170, 230, 60, "policy2", [("ほかのポリシー", "h"), ("（必要なら足せる。複数可）", "s")])
    s.box(310, 120, 220, 80, "role", [("IAM ロール", "h"), ("port-guard-ssm", "s"), ("権限の入れ物", "s")])
    s.path([(250, 120), (308, 150)])
    s.path([(250, 200), (308, 172)], "edge2")
    s.text(255, 100, "複数付けられる", "lbl")

    # ロール → インスタンスプロファイル（1 つだけ）
    s.box(590, 110, 240, 100, "profile", [("インスタンスプロファイル", "h"), ("port-guard-ssm", "s"),
                                           ("ロールを EC2 に渡す入れ物", "s"), ("中のロールは 1 つだけ", "s")])
    s.path([(530, 160), (588, 160)])
    s.text(536, 150, "1 つだけ", "lbl")

    # インスタンスプロファイル → インスタンス（何台でも）
    for i, name in enumerate(["インスタンス A", "インスタンス B", "インスタンス C"]):
        y = 70 + i * 75
        s.box(900, y, 200, 56, "ec2", [(name, "h"), ("IAM ロール: port-guard-ssm", "s")])
        s.path([(830, 160), (865, 160), (865, y + 28), (898, y + 28)])
    s.text(872, 290, "何台にでも関連付けられる", "lbl")

    # 1 台に 1 つだけ（すでに別のインスタンスプロファイルがある台）
    s.box(590, 380, 240, 70, "profile2", [("既存のインスタンスプロファイル", "h"), ("（ほかの用途のロール）", "s")])
    s.box(900, 386, 200, 58, "ec2", [("インスタンス D", "h"), ("IAM ロール: 既存のもの", "s")])
    s.path([(830, 415), (898, 415)])
    s.path([(800, 210), (800, 330), (1000, 330), (1000, 384)], "ng")
    s.cross(1000, 357)
    s.text(1012, 352, "2 つ目は", "ngt")
    s.text(1012, 370, "関連付けられない", "ngt")
    s.text(20, 480, "・1 つのインスタンスプロファイルに入れられるロールは 1 つだけ（ポリシーは 1 つのロールに複数付けられる）", "s")
    s.text(20, 500, "・1 つのインスタンスプロファイルは、何台のインスタンスにでも関連付けられる", "s")
    s.text(20, 520, "・1 台のインスタンスに関連付けられるインスタンスプロファイルは 1 つだけ。権限を増やすときは、そのロールにポリシーを足す", "s")
    s.text(20, 540, "　（ssm-role は、IAM ロールが未設定の台に port-guard-ssm を関連付けるだけで、既存のロールには何もしない）", "s")
    return s.render()


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "images"
    with open(f"{out}/iam-instance-profile.svg", "w", encoding="utf-8") as f:
        f.write(build())
