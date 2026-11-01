"""SSM で実際に入れるかを、害のないコマンド（echo）を 1 回だけ流して確かめる（設定は変えない）。

事前の確認（状態・インスタンスプロファイル・ロール・登録）はしない。ssm-check の --ok-out（SSM 有効の台）を渡す想定
（Ruby 版の rb/ssm_connect_check.rb と同じ役割）。

接続の確かめ方:
- session（既定）: Session Manager（`aws ssm start-session` の AWS-StartNonInteractiveCommand）。
  人がログインするときと同じ経路を通る。作業者の PC に session-manager-plugin が要る
- run-command: Run Command（`aws ssm send-command` の AWS-RunShellScript）。port-guard-rollout の install・enable の
  `--via ssm` と同じ経路

--ok-out で入れた台の一覧を、--ng-out で入れなかった台の一覧を理由と一緒に書き出す（1 行に 1 台）。
--ng-out の行は # で消していないので、直した後にそのまま渡し直せる。
セッションやコマンドの履歴は AWS の側に残る。
"""

import secrets
import shutil

from .targets import read_targets

SESSION_PLUGIN = "session-manager-plugin"
VIA_CHOICES = ("session", "run-command")
HINT = "ssmmessages・ec2messages への送信の 443 番、作業者の権限（ssm:StartSession・ssm:SendCommand）、SSM Agent の版を見る"


def try_session(aws, instance_id, timeout, marker):
    """Session Manager で echo を流す。戻り値は問題（空ならつながった）。"""
    parameters = f'{{"command":["echo {marker}"]}}'
    code, stdout, stderr = aws.run_text(
        "ssm", "start-session", "--target", instance_id,
        "--document-name", "AWS-StartNonInteractiveCommand", f"--parameters={parameters}",
        timeout=timeout,
    )
    if marker in stdout:
        return ""
    detail = (stderr.strip() or stdout.strip() or f"終了コード {code}").splitlines()[-1]
    return f"Session Manager でつながらない（{detail}）"


def try_run_command(runner, instance_id, timeout, marker):
    """Run Command で echo を流す。戻り値は問題（空ならつながった）。"""
    result = runner.run_script(instance_id, f"echo 'PG connect_check={marker}'\n", timeout=timeout)
    if result.values.get("connect_check") == marker:
        return ""
    detail = (result.stderr.strip() or f"終了コード {result.returncode}").splitlines()[-1]
    return f"Run Command でつながらない（{detail}）"


def write_list(path, header, lines):
    with open(path, "w", encoding="utf-8") as f:
        f.write(f"{header}\n")
        for line in lines:
            f.write(f"{line}\n")


def run(aws, runner, stdin, out, via="session", timeout=60, ok_out=None, ng_out=None, plugin_available=None,
        make_marker=lambda: f"ssm-setup-connect-{secrets.token_hex(4)}"):
    """終了コードを返す（0: すべての台に入れる、1: 入れない台がある、2: 入力・道具の問題）。"""
    if not aws.available():
        print("aws のコマンドが見つからない（AWS CLI を入れて、PATH を通す）", file=out)
        return 2
    if via == "session":
        found = plugin_available if plugin_available is not None else shutil.which(SESSION_PLUGIN) is not None
        if not found:
            print(f"{SESSION_PLUGIN} が見つからない（Session Manager の確認に要る。入れて PATH を通すか、"
                  "--via run-command で Run Command の経路を確かめる）", file=out)
            return 2
    targets, invalid = read_targets(stdin)
    for value in invalid:
        print(f"形式が正しくないので無視する: {value}", file=out)
    if not targets:
        print("インスタンスの ID が 1 つもない（標準入力に 1 行 1 つで渡す）", file=out)
        return 2

    route = "Session Manager" if via == "session" else "Run Command"
    print(f"{len(targets)} 台に {route} で echo を流す（事前の確認はしない。設定は変えない）", file=out)
    problems = {}
    for target in targets:
        marker = make_marker()
        if via == "session":
            problem = try_session(aws, target.instance_id, timeout, marker)
        else:
            problem = try_run_command(runner, target.instance_id, timeout, marker)
        problems[target.instance_id] = problem
        print(f"  入れない  {target.instance_id}  {problem}" if problem else f"  入れる    {target.instance_id}", file=out)

    connected = [i for i, problem in problems.items() if not problem]
    failed = [i for i, problem in problems.items() if problem]
    print(f"\n== 結果: 入れる {len(connected)} 台、入れない {len(failed)} 台", file=out)
    if failed:
        print(f"入れない台は、{HINT}", file=out)
    if ok_out:
        write_list(ok_out, "# ssm-connect-check で実際に入れた台（フェーズ 2 の port-guard-rollout の標準入力に渡せる）", connected)
        print(f"入れる台の一覧を書き出した: {ok_out}（{len(connected)} 台）", file=out)
    if ng_out:
        write_list(ng_out, f"# ssm-connect-check で入れなかった台（直した後に、もう一度渡せる）。{HINT}",
                   [f"{i}  # {problems[i]}" for i in failed])
        print(f"入れない台の一覧を書き出した: {ng_out}（{len(failed)} 台）", file=out)
    return 0 if not failed else 1
