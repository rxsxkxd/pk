"""ssm-setup の流れの図（SVG）を作る。

    cd ssm-setup && python3 images/make_flow_svg.py images

で images/flow-ssm-setup.svg を作り直す。mermaid の道具（mermaid-cli やブラウザー）を使わずに済むよう、座標を計算して描いている。
描き方の部品は ../port-guard-rollout/images/make_svg.py の写し（フォルダを分けたため、読み込まずに写して持つ）。

同じ図を steps.md に Mermaid でも埋め込んでいる。どちらかを直したら、もう一方も同じ中身・同じ言葉にそろえて直すこと。
"""
import sys
from xml.sax.saxutils import escape

STYLE = """
  <style>
    .bg { fill: #ffffff; }
    .box { stroke-width: 1.5; rx: 8; }
    .command { fill: #e8f0fe; stroke: #1a56db; }
    .check { fill: #fff4e5; stroke: #c2410c; }
    .manual { fill: #ecfdf3; stroke: #15803d; stroke-dasharray: 6 4; }
    .done { fill: #f1f5f9; stroke: #475569; }
    .ok { fill: #dcfce7; stroke: #15803d; }
    .ng { fill: #fee2e2; stroke: #b91c1c; }
    .note { fill: #fafafa; stroke: #9ca3af; stroke-dasharray: 3 3; }
    text { font-family: "Hiragino Sans", "Noto Sans JP", "Yu Gothic", sans-serif; fill: #111827; }
    .t { font-size: 15px; }
    .s { font-size: 12.5px; fill: #374151; }
    .lbl { font-size: 12.5px; fill: #1f2937; }
    .title { font-size: 18px; font-weight: bold; }
    .edge { stroke: #374151; stroke-width: 1.6; fill: none; marker-end: url(#arrow); }
    .bracket { stroke: #6b7280; stroke-width: 1.4; fill: none; }
  </style>
  <defs>
    <marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse">
      <path d="M 0 0 L 10 5 L 0 10 z" fill="#374151"/>
    </marker>
  </defs>
"""


class Svg:
    def __init__(self, width, height, title):
        self.w, self.h = width, height
        self.parts = [f'<rect class="bg" x="0" y="0" width="{width}" height="{height}"/>',
                      f'<text class="title" x="20" y="30">{escape(title)}</text>']

    def box(self, x, y, w, h, lines, cls, small=()):
        self.parts.append(f'<rect class="box {cls}" x="{x}" y="{y}" width="{w}" height="{h}"/>')
        rows = [(l, "t") for l in lines] + [(l, "s") for l in small]
        step = 19
        top = y + h / 2 - (len(rows) - 1) * step / 2 + 5
        for i, (text, kind) in enumerate(rows):
            self.parts.append(f'<text class="{kind}" x="{x + w / 2}" y="{top + i * step}" text-anchor="middle">{escape(text)}</text>')

    def edge(self, points, label=None, at=None, anchor="start"):
        d = "M " + " L ".join(f"{px} {py}" for px, py in points)
        self.parts.append(f'<path class="edge" d="{d}"/>')
        if label:
            lx, ly = at
            self.parts.append(f'<text class="lbl" x="{lx}" y="{ly}" text-anchor="{anchor}">{escape(label)}</text>')

    def bracket(self, points):
        d = "M " + " L ".join(f"{px} {py}" for px, py in points)
        self.parts.append(f'<path class="bracket" d="{d}"/>')

    def text(self, x, y, s, cls="s", anchor="start"):
        self.parts.append(f'<text class="{cls}" x="{x}" y="{y}" text-anchor="{anchor}">{escape(s)}</text>')

    def legend(self, x, y, items):
        for i, (cls, label) in enumerate(items):
            yy = y + i * 24
            self.parts.append(f'<rect class="box {cls}" x="{x}" y="{yy}" width="28" height="16"/>')
            self.text(x + 36, yy + 13, label)

    def render(self):
        body = "\n  ".join(self.parts)
        return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.w}" height="{self.h}" '
                f'viewBox="0 0 {self.w} {self.h}" role="img">\n{STYLE}\n  {body}\n</svg>\n')


def flow():
    s = Svg(1030, 790, "ssm-setup: SSM の有効化の流れ")
    X, W, H = 260, 420, 58
    cx = X + W / 2
    R = X + W + 70  # 右の列
    rows = {"prep": 60, "role": 150, "ssmcheck": 240, "backup": 340, "check": 430, "agent": 530}
    s.box(X, rows["prep"], W, H, ["0. 準備"], "done", ["対象の一覧・インスタンスプロファイルを用意する"])
    s.box(X, rows["role"], W, H, ["1. ssm-role（AWS の API だけ）"], "command",
          ["IAM ロールが未設定の台にインスタンスプロファイルを関連付ける"])
    s.box(X, rows["ssmcheck"], W, H, ["2. ssm-check"], "check", ["ポリシー・Online・SSM でつながるかを確かめる"])
    s.box(X, rows["backup"], W, H, ["3. backup（入れない台だけ）"], "command", ["AMI を作る（再起動しない・完了は待たない）"])
    s.box(X, rows["check"], W, H, ["backup-check（補助）"], "check", ["作成済み（available）で 12 時間以内か"])
    s.box(X, rows["agent"], W, H, ["4. ssm-agent（SSH）"], "command", ["SSM Agent を入れて Online にする"])
    order = ["prep", "role", "ssmcheck", "backup", "check", "agent"]
    labels = {"ssmcheck": "入れない（--ng-out の一覧）", "check": "そろった"}
    for a, b in zip(order, order[1:]):
        s.edge([(cx, rows[a] + H), (cx, rows[b])], labels.get(a), (cx + 8, rows[a] + H + 26))
    # 入れる台はフェーズ 2 へ
    s.box(R, rows["ssmcheck"], 260, H, ["フェーズ 2 へ（port-guard-rollout）"], "done", ["SSM で入れる台に iptables ＋ ipset"])
    s.edge([(X + W, rows["ssmcheck"] + 29), (R, rows["ssmcheck"] + 29)], "入れる", (X + W + 12, rows["ssmcheck"] + 21))
    # まだ作成中なら待つ
    s.box(R, rows["check"], 180, H, ["作成を待つ"], "done", ["（pending）"])
    s.edge([(X + W, rows["check"] + 20), (R, rows["check"] + 20)], "まだ", (X + W + 8, rows["check"] + 14))
    s.edge([(R, rows["check"] + 40), (X + W, rows["check"] + 40)])
    # 12 時間を過ぎたら 3 からやり直す
    s.edge([(X, rows["check"] + 29), (200, rows["check"] + 29), (200, rows["backup"] + 29), (X, rows["backup"] + 29)])
    s.text(192, rows["backup"] + 64, "12 時間を", anchor="end")
    s.text(192, rows["backup"] + 82, "過ぎたら", anchor="end")
    s.text(192, rows["backup"] + 100, "作り直す", anchor="end")
    # ssm-agent の後に、もう一度確かめる
    s.edge([(X, rows["agent"] + 29), (40, rows["agent"] + 29), (40, rows["ssmcheck"] + 29), (X, rows["ssmcheck"] + 29)])
    s.text(48, rows["agent"] + 22, "5. もう一度確かめる")
    # それでも入れない台
    s.box(R, rows["agent"], 260, H, ["5 の後も入れない台"], "manual", ["理由を見て手で直す（道具では行わない）"])
    s.legend(R, 60, [("command", "道具のコマンド"), ("check", "確認（道具）"), ("manual", "作業者が手で行う"),
                     ("done", "準備・待ち・次のフェーズ")])
    s.text(20, 650, "ほとんどの台は、SSM Agent は入って動いていて、IAM ロールがないだけと見込んでいる。まずインスタンスプロファイルを関連付けて確かめ、")
    s.text(20, 672, "それでも入れない台だけに SSM Agent を入れる。バックアップが要るのは、インスタンスの中を変える ssm-agent だけなので、")
    s.text(20, 694, "ssm-check で入れなかった台だけに取る（ssm-role はインスタンスプロファイルを関連付けるだけ、ssm-check は確かめるだけ）。")
    s.text(20, 716, "ssm-check --ng-out で書き出した一覧を、そのまま backup・backup-check・ssm-agent の標準入力に渡す。どの手順も、OS の再起動は要らない。")
    return s.render()

out = sys.argv[1]
open(f"{out}/flow-ssm-setup.svg", "w").write(flow())
