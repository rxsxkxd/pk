"""作業者とのやり取り。"""


def confirm(question, tty_path="/dev/tty"):
    """端末から y / n を読む（標準入力はインスタンスの一覧に使っているため）。端末がなければ None。"""
    try:
        with open(tty_path, "r+") as tty:
            tty.write(question)
            tty.flush()
            answer = tty.readline().strip().lower()
    except OSError:
        return None
    return answer in ("y", "yes")
