"""コマンドの共通の流れ: 一覧を読む → 確かめて分けて表示する → 試行するかを確かめる → 1 台ずつ行う → 結果。

各コマンドは「確かめる（plan）」と「行う（apply）」だけを書き、execute に渡す。次はここで扱う。
- 入力の一覧の読み込みと、形式の誤りの表示
- 前提の問題（Stop、または確かめる途中の AWS CLI の失敗）→ 何もせずに止まる（終了コード 2）
- 分けた結果の表示、--check-only、--dry-run、確認の前の注意、[y/N] の確認
- 1 台ごとの失敗（Failed、または AWS CLI の失敗）→ 失敗として数えて、次の台に進む
- 結果の集計と、実行の後の処理（finish）、終了コード
  （0: すべて済んだ・何もしなくてよい、1: 失敗・対象外・後の確認の問題あり、2: 入力・確認・前提の問題）

1 台ごとに確かめながら進めるコマンド（port-guard-rollout の enable）は、execute を使わず、部品（load_plan・show・run_one）だけを使う。
"""

from dataclasses import dataclass, field

from .awscli import AwsCliError
from .console import confirm
from .targets import read_targets


class Stop(Exception):
    """前提が満たされず、先に進めない（何もせずに止まる）。"""


class Failed(Exception):
    """1 台の操作が失敗した（次の台に進む）。"""


@dataclass
class Item:
    instance_id: str
    label: str  # 表示の 1 行目
    details: list = field(default_factory=list)  # 一覧の表示の 2 行目から（バックアップ、変わること など）
    value: object = None  # コマンドの側の記録（apply・finish で使う）


@dataclass
class Plan:
    title: str  # 行うことの見出し
    question: str  # 試行するかを確かめる問い（「上の n 台に、」に続く）
    todo: list = field(default_factory=list)  # 行う台（Item）
    keep: list = field(default_factory=list)  # 何もしない台の表示の行
    excluded: list = field(default_factory=list)  # 対象外の台の表示の行（理由つき）
    keep_title: str = "何もしない"  # None なら、この区分を出さない
    excluded_title: str = "対象外"
    done_word: str = "完了"  # 1 台が済んだときの言葉（AMI の作成のように、始めただけなら「開始」）
    notice: str = ""  # 確認の前に知らせること
    dry_run: object = None  # dry 実行のときに、行う予定を表示する関数（out を受け取る）
    finish: object = None  # 済んだ台があるときに、後の確認と案内を表示する関数（済んだ Item の一覧と out）。False で終了コード 1


def require(ok, message):
    if not ok:
        raise Stop(message)


def require_aws(aws):
    require(aws.available(), "aws のコマンドが見つからない（AWS CLI を入れて、PATH を通す）")


def load_plan(stdin, out, plan):
    """一覧を読んで plan(targets) を呼ぶ。前提の問題なら表示して None を返す。"""
    targets, invalid = read_targets(stdin)
    for value in invalid:
        print(f"形式が正しくないので無視する: {value}", file=out)
    try:
        require(targets, "対象がない（標準入力に `<インスタンスの ID> [<SSH の接続先>]` を 1 行に 1 台で渡す）")
        return plan(targets)
    except (Stop, AwsCliError) as error:
        print(f"止めた: {error}", file=out)
        return None


def show(p, out):
    print(f"\n== {p.title}（{len(p.todo)} 台）", file=out)
    for item in p.todo:
        print(f"  {item.label}", file=out)
        for line in item.details:
            print(f"      {line}", file=out)
    for title, lines in ((p.keep_title, p.keep), (p.excluded_title, p.excluded)):
        if title is None:
            continue
        print(f"\n== {title}（{len(lines)} 台）", file=out)
        for line in lines:
            print(f"  {line}", file=out)


def ask_go(p, out, assume_yes, confirm_func):
    """試行するかを確かめる。戻り値は None（進める）か、終了コード。"""
    if p.notice:
        print(f"\n注意: {p.notice}", file=out)
    if assume_yes:
        return None
    answer = confirm_func(f"\n上の {len(p.todo)} 台に、{p.question} [y/N]: ")
    if answer is None:
        print("確認のための端末がない。確かめずに進めるなら --yes を付ける", file=out)
        return 2
    if not answer:
        print("中止した", file=out)
        return 0
    return None


def run_one(item, apply, out, done_word="完了"):
    """1 台を行う。apply は済んだときの説明（なくてもよい）を返し、失敗なら Failed か AwsCliError を出す。"""
    try:
        detail = apply(item)
    except (Failed, AwsCliError) as error:
        print(f"      失敗: {error}", file=out)
        return False
    print(f"      {done_word}: {detail}" if detail else f"      {done_word}", file=out)
    return True


def execute(stdin, out, plan, apply, heading="実行（1 台ずつ順に行う）", assume_yes=False, check_only=False, dry_run=False,
            confirm_func=confirm):
    """plan(targets) → Plan、apply(item) → 説明。終了コードを返す。"""
    p = load_plan(stdin, out, plan)
    if p is None:
        return 2
    show(p, out)
    if check_only:
        return 0
    if dry_run:
        if p.dry_run:
            p.dry_run(out)
        return 0
    if not p.todo:
        print("\n行う台がないので、終わる", file=out)
        return 1 if p.excluded else 0
    code = ask_go(p, out, assume_yes, confirm_func)
    if code is not None:
        return code

    print(f"\n== {heading}", file=out)
    done = []
    for index, item in enumerate(p.todo, start=1):
        print(f"  [{index}/{len(p.todo)}] {item.label}", file=out)
        if run_one(item, apply, out, p.done_word):
            done.append(item)
    failed = len(p.todo) - len(done)

    counts = [f"{p.done_word} {len(done)} 台", f"失敗 {failed} 台"]
    if p.keep_title is not None:
        counts.append(f"何もしない {len(p.keep)} 台")
    counts.append(f"対象外 {len(p.excluded)} 台")
    print(f"\n== 結果: {'、'.join(counts)}", file=out)
    finished = p.finish(done, out) if p.finish and done else None
    return 1 if failed or p.excluded or finished is False else 0
