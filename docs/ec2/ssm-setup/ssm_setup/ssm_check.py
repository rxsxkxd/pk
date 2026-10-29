"""SSM でインスタンスに入れるかを確かめる（ssm-role の後に使う。設定は変えない）。

流れ（ほかのコマンドと同じ形）:
1. 標準入力からインスタンスの ID の一覧を読む（2 列目に SSH の接続先があっても使わない）
2. 1 台ずつ、次の 4 つを確かめる
   1) インスタンスプロファイル: 関連付けがあるか、その中のロール
   2) ポリシー: そのロールに AmazonSSMManagedInstanceCore が付いているか（参考。付いていなくても、
      独自のポリシーで足りていることがあるので、これだけで不合格にはしない）
   3) 登録: SSM に登録されて Online か、SSM Agent のバージョン
   4) 接続: 害のないコマンド（echo）を 1 回だけ流して、返ってくるか
      - session（既定）: Session Manager（`aws ssm start-session` の AWS-StartNonInteractiveCommand）。
        人がログインするときと同じ経路を通る。作業者の PC に session-manager-plugin が要る
      - run-command: Run Command（`aws ssm send-command` の AWS-RunShellScript）。install・enable の
        `--via ssm` と同じ経路
3. 「入れる」（Online で、接続できた）と「入れない」（理由つき）に分けて表示する

接続の確認はインスタンスで echo を動かすだけで、設定は変えない（セッションやコマンドの履歴は AWS の側に残る）。
"""

import secrets
import shutil
from dataclasses import dataclass, field

from .awscli import AwsCliError
from .targets import read_targets

CORE_POLICY = "AmazonSSMManagedInstanceCore"
SESSION_PLUGIN = "session-manager-plugin"
VIA_CHOICES = ("session", "run-command")


@dataclass
class Host:
    instance_id: str
    name: str = ""
    state: str = ""
    profile: str = ""  # 関連付けられているインスタンスプロファイルの名前（なければ空）
    roles: list = field(default_factory=list)
    policy: str = ""  # ポリシーの確認の結果（表示用）
    ping_status: str = ""
    agent_version: str = ""
    connection: str = ""  # 接続の確認の結果（表示用）
    problems: list = field(default_factory=list)  # 入れない理由

    @property
    def ok(self):
        return not self.problems


def profile_name_of(arn):
    """インスタンスプロファイルの ARN から名前を取り出す（パスがあっても最後の部分が名前）。"""
    return arn.rsplit("/", 1)[-1] if arn else ""


def fetch_instance(aws, host):
    """名前と状態を読む。戻り値は問題（空なら読めた）。"""
    try:
        response = aws.run("ec2", "describe-instances", "--instance-ids", host.instance_id)
    except AwsCliError as error:
        if error.code in ("InvalidInstanceID.NotFound", "InvalidInstanceID.Malformed"):
            return "インスタンスが見つからない"
        return f"情報を取れない（{error}）"
    instances = [i for r in response.get("Reservations", []) for i in r.get("Instances", [])]
    if not instances:
        return "インスタンスが見つからない"
    instance = instances[0]
    host.name = {t["Key"]: t["Value"] for t in instance.get("Tags", [])}.get("Name", "")
    host.state = instance.get("State", {}).get("Name", "")
    return ""


def fetch_profile(aws, host):
    """関連付けられているインスタンスプロファイルと、その中のロールを読む。"""
    try:
        response = aws.run(
            "ec2", "describe-iam-instance-profile-associations",
            "--filters", f"Name=instance-id,Values={host.instance_id}",
        )
    except AwsCliError as error:
        host.policy = f"確かめられない（関連付けを読めない: {error}）"
        return
    arn = ""
    for association in response.get("IamInstanceProfileAssociations", []) if response else []:
        if association.get("State") in ("associating", "associated"):
            arn = association.get("IamInstanceProfile", {}).get("Arn", "")
            break
    host.profile = profile_name_of(arn)
    if not host.profile:
        host.policy = "インスタンスプロファイルがない"
        return
    try:
        response = aws.run("iam", "get-instance-profile", "--instance-profile-name", host.profile)
    except AwsCliError as error:
        host.policy = f"確かめられない（インスタンスプロファイルを読めない: {error}）"
        return
    host.roles = [r.get("RoleName", "") for r in response.get("InstanceProfile", {}).get("Roles", [])]
    if not host.roles:
        host.policy = "インスタンスプロファイルにロールが入っていない"


def check_policy(aws, role, cache):
    """ロールに AmazonSSMManagedInstanceCore が付いているか（表示用の文）。同じロールは 1 回だけ読む。"""
    if role in cache:
        return cache[role]
    try:
        attached = aws.run("iam", "list-attached-role-policies", "--role-name", role)
        inline = aws.run("iam", "list-role-policies", "--role-name", role)
    except AwsCliError as error:
        cache[role] = f"確かめられない（ロールのポリシーを読めない: {error}）"
        return cache[role]
    names = [p.get("PolicyName", "") for p in (attached or {}).get("AttachedPolicies", [])]
    arns = [p.get("PolicyArn", "") for p in (attached or {}).get("AttachedPolicies", [])]
    inline_names = (inline or {}).get("PolicyNames", [])
    if any(a.endswith(f":policy/{CORE_POLICY}") for a in arns):
        cache[role] = f"{CORE_POLICY} が付いている"
    else:
        others = ", ".join(names) or "なし"
        cache[role] = (f"{CORE_POLICY} が付いていない（要確認。付いているもの: {others}、"
                       f"インライン: {', '.join(inline_names) or 'なし'}）")
    return cache[role]


def fetch_registration(aws, host):
    """SSM の登録の状態と SSM Agent のバージョンを読む。"""
    try:
        response = aws.run(
            "ssm", "describe-instance-information",
            "--filters", f"Key=InstanceIds,Values={host.instance_id}",
        )
    except AwsCliError as error:
        host.ping_status = f"不明（{error.code or error.message}）"
        return
    items = response.get("InstanceInformationList", []) if response else []
    if not items:
        host.ping_status = "未登録"
        return
    host.ping_status = items[0].get("PingStatus", "不明")
    host.agent_version = items[0].get("AgentVersion", "")


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
    result = runner.run_script(instance_id, f"echo 'PG ssm_check={marker}'\n", timeout=timeout)
    if result.values.get("ssm_check") == marker:
        return ""
    detail = (result.stderr.strip() or f"終了コード {result.returncode}").splitlines()[-1]
    return f"Run Command でつながらない（{detail}）"


def inspect(aws, runner, instance_id, via, timeout, policy_cache, make_marker):
    host = Host(instance_id)
    problem = fetch_instance(aws, host)
    if problem:
        host.problems.append(problem)
        return host

    # 1) インスタンスプロファイルと 2) ポリシー（参考）
    fetch_profile(aws, host)
    if host.roles:
        host.policy = check_policy(aws, host.roles[0], policy_cache)

    if host.state != "running":
        host.problems.append(f"状態が {host.state}（running でなければ入れない）")
        return host

    # 3) 登録
    fetch_registration(aws, host)
    if host.ping_status != "Online":
        host.problems.append(f"SSM の登録が {host.ping_status}（Online でない）")
        host.connection = "確かめない（Online でない）"
        return host

    # 4) 接続
    marker = make_marker()
    if via == "session":
        problem = try_session(aws, instance_id, timeout, marker)
    else:
        problem = try_run_command(runner, instance_id, timeout, marker)
    if problem:
        host.problems.append(problem)
        host.connection = "つながらない"
    else:
        host.connection = "つながった（echo が返った）"
    return host


def print_host(host, out):
    print(f"  {host.instance_id}  {host.name}  {host.state}", file=out)
    if host.state:
        roles = f"（ロール: {', '.join(host.roles) or 'なし'}）" if host.profile else ""
        print(f"      インスタンスプロファイル: {host.profile or 'なし'}{roles}", file=out)
        print(f"      ポリシー: {host.policy}", file=out)
    if host.ping_status:
        version = f"（SSM Agent {host.agent_version}）" if host.agent_version else ""
        print(f"      登録: {host.ping_status}{version}", file=out)
    if host.connection:
        print(f"      接続: {host.connection}", file=out)
    for problem in host.problems:
        print(f"      理由: {problem}", file=out)


def run(aws, runner, stdin, out, via="session", timeout=60, plugin_available=None,
        make_marker=lambda: f"ssm-setup-check-{secrets.token_hex(4)}"):
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
    print(f"{len(targets)} 台を確かめる（接続の確認: {route}。設定は変えない）", file=out)
    hosts, policy_cache = [], {}
    for target in targets:
        print(f"  確認中: {target.instance_id}", file=out)
        hosts.append(inspect(aws, runner, target.instance_id, via, timeout, policy_cache, make_marker))

    ok = [h for h in hosts if h.ok]
    ng = [h for h in hosts if not h.ok]
    print(f"\n== 入れる（Online で、{route} でつながった。{len(ok)} 台）", file=out)
    for host in ok:
        print_host(host, out)
    print(f"\n== 入れない（{len(ng)} 台）", file=out)
    for host in ng:
        print_host(host, out)

    no_policy = [h for h in hosts if h.policy.startswith(f"{CORE_POLICY} が付いていない")]
    print(f"\n== 結果: 入れる {len(ok)} 台、入れない {len(ng)} 台"
          f"（{CORE_POLICY} が付いていないもの {len(no_policy)} 台）", file=out)
    if ng:
        print("入れないときに見る場所: インスタンスプロファイルとロールのポリシー、SSM Agent が動いているか、"
              "送信の 443 番が通るか、作業者の権限（ssm:StartSession など）", file=out)
    return 1 if ng else 0
