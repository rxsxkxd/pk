"""port-guard-rollout のフローの図（SVG）を作る。

    cd port-guard-rollout && python3 images/make_svg.py images

で images/flow-overall.svg（全体の流れ）と images/flow-enable.svg（enable のインスタンスごとの流れ）を作り直す。
mermaid の道具（mermaid-cli やブラウザー）を使わずに済むよう、座標を計算して描いている。

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


def overall():
    s = Svg(860, 930, "port-guard-rollout: 全体の流れ")
    X, W, H = 190, 420, 58
    cx = X + W / 2
    rows = {
        "pre": 60, "prep": 150, "backup": 240, "check": 330, "install": 430,
        "probe1": 520, "enable": 610, "probe2": 700, "watch": 790,
    }
    s.box(X, rows["pre"], W, H, ["前提: SSM の有効化が済んでいる"], "done", ["ssm-setup の ssm-check で「入れる」になった台が対象"])
    s.box(X, rows["prep"], W, H, ["0. 準備"], "done", ["対象の一覧・許可する IP・--backup-label を決める"])
    s.box(X, rows["backup"], W, H, ["1. backup"], "command", ["AMI を作る（再起動しない・完了は待たない）"])
    s.box(X, rows["check"], W, H, ["backup-check（補助）"], "check", ["作成済み（available）で 12 時間以内か"])
    s.box(X, rows["install"], W, H, ["2. install（SSM か SSH）"], "command", ["ipset と設定を入れ、集合を作る（遮断はまだ効かない）"])
    s.box(X, rows["probe1"], W, H, ["拠点から port-guard-probe（手で）"], "manual", ["届く（reachable）ことを確かめる"])
    s.box(X, rows["enable"], W, H, ["3. enable（インスタンスごと）"], "command", ["自動で戻る予約 → 遮断 → 確かめて確定（別の図）"])
    s.box(X, rows["probe2"], W, H, ["拠点から port-guard-probe（手で）"], "manual", ["時間切れ（timeout）になることを確かめる"])
    s.box(X, rows["watch"], W, H, ["4. 見守りと片付け"], "done", ["破棄の記録を見る・古い AMI を消す"])
    order = ["pre", "prep", "backup", "check", "install", "probe1", "enable", "probe2", "watch"]
    for a, b in zip(order, order[1:]):
        label = "そろった" if a == "check" else None
        s.edge([(cx, rows[a] + H), (cx, rows[b])], label, (cx + 8, rows[a] + H + 22))
    # まだ作成中なら待つ
    wx = 650
    s.box(wx, rows["check"], 180, H, ["作成を待つ"], "done", ["（pending）"])
    s.edge([(X + W, rows["check"] + 20), (wx, rows["check"] + 20)], "まだ", (X + W + 8, rows["check"] + 14))
    s.edge([(wx, rows["check"] + 40), (X + W, rows["check"] + 40)])
    # 12 時間を過ぎたら 1 からやり直す
    s.edge([(X, rows["check"] + 29), (120, rows["check"] + 29), (120, rows["backup"] + 29), (X, rows["backup"] + 29)])
    s.text(112, rows["backup"] + 70, "12 時間を", anchor="end")
    s.text(112, rows["backup"] + 88, "過ぎたら", anchor="end")
    s.text(112, rows["backup"] + 106, "作り直す", anchor="end")
    # install・enable の注記
    top, bottom = rows["install"], rows["enable"] + H
    s.bracket([(X + W + 20, top), (X + W + 30, top), (X + W + 30, bottom), (X + W + 20, bottom)])
    s.parts.append(f'<rect class="box note" x="{X + W + 45}" y="{top + 60}" width="190" height="115"/>')
    lines = ["install・enable は、", "操作の前にバックアップ", "を自動で確かめる", "（台ごと、", "操作の直前にも）"]
    for i, line in enumerate(lines):
        s.text(X + W + 140, top + 86 + i * 19, line, anchor="middle")
    s.legend(650, 60, [("command", "道具のコマンド"), ("check", "確認（道具）"), ("manual", "作業者が手で行う"),
                       ("done", "準備・待ち・片付け")])
    return s.render()


def enable():
    s = Svg(920, 990, "enable: インスタンスごとの流れ")
    X, W, H = 130, 420, 58
    cx = X + W / 2
    R, RW, RH = 650, 250, 42
    y = {"list": 60, "ask": 160, "backup": 260, "revert": 360, "apply": 460,
         "reach": 560, "probe": 660, "confirm": 760, "next": 860}
    s.box(X, y["list"], W, H, ["全台を確かめて、一覧を表示"], "check", ["有効にできる台・できない台（理由つき）"])
    s.box(X, y["ask"], W, H, ["この台を有効にしますか？"], "check", ["y: 進める / n: 飛ばす / q: 残りを止める"])
    s.box(X, y["backup"], W, H, ["バックアップを確かめる"], "check", ["作成済み・12 時間以内か（操作の直前）"])
    s.box(X, y["revert"], W, H, ["自動で元に戻る予約"], "command", ["10 分後に遮断のルールを消す（systemd-run）"])
    s.box(X, y["apply"], W, H, ["遮断のルールを入れる"], "command", ["systemctl enable --now port-guard"])
    s.box(X, y["reach"], W, H, ["インスタンスに引き続き入れるか"], "check", ["SSH または SSM"])
    s.box(X, y["probe"], W, H, ["作業者の PC から 80・443 に応答があるか"], "check", ["80: HTTP の応答 / 443: TLS の接続"])
    s.box(X, y["confirm"], W, H, ["予約を取り消して確定"], "ok", ["予約のプロセスが消えたことも確かめる"])
    s.box(X, y["next"], W, H, ["次の台へ"], "done")
    down = [("list", "ask", None), ("ask", "backup", "y"), ("backup", "revert", "あり"), ("revert", "apply", None),
            ("apply", "reach", None), ("reach", "probe", "入れる"), ("probe", "confirm", "応答あり"), ("confirm", "next", None)]
    for a, b, label in down:
        s.edge([(cx, y[a] + H), (cx, y[b])], label, (cx + 8, y[a] + H + 24))
    side = [
        ("ask", 0, "n", "飛ばす", "done"),
        ("ask", 1, "q", "残りを止めて終わる", "done"),
        ("backup", 0, "なし", "行わない（失敗）", "ng"),
        ("reach", 0, "入れない", "10 分後に予約で自動的に戻る", "ng"),
        ("probe", 0, "応答なし", "すぐに元に戻す", "ng"),
    ]
    for key, idx, label, text, cls in side:
        by = y[key] - 14 + idx * (RH + 6)  # 矢印の出口が、左の箱の高さの中に収まるようにする
        ey = by + RH / 2
        s.box(R, by, RW, RH, [text], cls)
        s.edge([(X + W, ey), (R, ey)], label, (X + W + 8, ey - 6))
    # 次の台へ（左側を通って、確認の問いに戻る）
    s.edge([(X, y["next"] + H / 2), (70, y["next"] + H / 2), (70, y["ask"] + H / 2), (X, y["ask"] + H / 2)])
    s.text(62, y["next"] - 40, "次の台", anchor="end")
    s.text(20, 950, "右の「飛ばす」「行わない」「戻る」「戻す」の後も、次の台へ進む（「残りを止めて終わる」を除く）。")
    s.text(20, 972, "海外からの確認は、確定した後に作業者が拠点で port-guard-probe を手で実行する（この図の外）。")
    return s.render()


out = sys.argv[1]
open(f"{out}/flow-overall.svg", "w").write(overall())
open(f"{out}/flow-enable.svg", "w").write(enable())
