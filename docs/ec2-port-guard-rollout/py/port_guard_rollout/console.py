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


def ask(question, choices, tty_path="/dev/tty"):
    """端末から選択肢の 1 つを読む。選択肢にない答えなら、聞き直す。端末がなければ None。"""
    try:
        with open(tty_path, "r+") as tty:
            while True:
                tty.write(question)
                tty.flush()
                answer = tty.readline()
                if not answer:
                    return None
                answer = answer.strip().lower()
                if answer in choices:
                    return answer
    except OSError:
        return None
