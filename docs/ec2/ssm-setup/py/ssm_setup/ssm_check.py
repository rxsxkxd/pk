"""SSM が使える状態かを、権限と AWS の上のインスタンスの状態だけで確かめる（ssm-role の後に使う）。

インスタンスには何も送らない（設定も変えない）。実際につながるかは、--ok-out の一覧を ssm-connect-check に渡して確かめる
（Ruby 版の rb/ssm_check.rb・rb/ssm_connect_check.rb と同じ分け方）。

流れ:
1. 標準入力からインスタンスの ID の一覧を読む（2 列目に SSH の接続先があっても使わない）
2. 1 台ずつ、次の 3 つを確かめる
   1) インスタンスプロファイル: 関連付けがあるか、その中のロール
   2) ポリシー: そのロールに AmazonSSMManagedInstanceCore が付いているか（参考。付いていなくても、
      独自のポリシーで足りていることがあるので、Online ならこれだけで不合格にはしない）
   3) 登録: SSM に登録されて Online か、SSM Agent のバージョン
3. 次の 3 つに分けて表示する（classify）
   - SSM 有効: Online → ssm-connect-check で実際につながるかを確かめる
   - SSM Agent で直す: running で、インスタンスプロファイルがあり、ロールに AmazonSSMManagedInstanceCore が
     付いているのに、Online でない → ssm-agent（入れる・有効にする・起動し直す）で直る見込み
   - 手で直す: それ以外（止まっている、インスタンスプロファイルがない、ロールに権限がない見込み、など）
4. --ok-out で「SSM 有効」の台の一覧を、--ng-out で「SSM Agent で直す」台の一覧を書き出す（1 行に 1 台）。
   --ng-out には「手で直す」台も、行の先頭を # にして理由と一緒に書く（読み飛ばされるので、
   そのまま ssm_setup_backup の backup・check と ssm-agent の標準入力に渡せる）
"""

from dataclasses import dataclass, field

from .awscli import AwsCliError
from .targets import read_targets

CORE_POLICY = "AmazonSSMManagedInstanceCore"

OK, AGENT, MANUAL = "SSM 有効", "SSM Agent で直す", "手で直す"


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
    problems: list = field(default_factory=list)  # SSM 有効でない理由
    category: str = ""  # OK・AGENT・MANUAL（classify で決める）
    hint: str = ""  # 手で直すときに見るところ

    @property
    def ok(self):
        return not self.problems


def classify(host):
    """SSM 有効・SSM Agent で直す・手で直す、に分ける（ssm-agent で直る見込みがあるものだけを AGENT にする）。"""
    if host.ok:
        host.category = OK
        return
    host.category = MANUAL
    if host.state != "running":
        host.hint = "インスタンスの状態を見る（ssm-agent は running の台しか扱えない）"
    elif host.ping_status.startswith("不明"):
        host.hint = "登録の状態を読めない。作業者の権限（ssm:DescribeInstanceInformation）を見る"
    elif not host.profile:
        host.hint = "インスタンスプロファイルがない。ssm-role を見直す"
    elif not host.roles:
        host.hint = "インスタンスプロファイルにロールが入っていない"
    elif host.policy.startswith(f"{CORE_POLICY} が付いていない"):
        host.hint = (f"ロールに {CORE_POLICY} が付いていない（すでにあるロールなら、手で足すかを決める。"
                     "独自のポリシーで足りているのに Online でないなら、SSM Agent を疑い、一覧に戻す）")
    else:
        host.category = AGENT


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


def inspect(aws, instance_id, policy_cache):
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
    for problem in host.problems:
        print(f"      理由: {problem}", file=out)
    if host.hint:
        print(f"      見るところ: {host.hint}", file=out)


def write_ok_list(path, hosts):
    """「SSM 有効」の台の一覧を書き出す（ssm-connect-check の標準入力の形）。"""
    with open(path, "w", encoding="utf-8") as f:
        f.write("# ssm-check で SSM 有効の台（ssm-connect-check の標準入力に渡す）\n")
        for host in hosts:
            f.write(f"{host.instance_id}  # {host.name}\n" if host.name else f"{host.instance_id}\n")


def write_ng_list(path, agent, manual):
    """「SSM Agent で直す」台の一覧を書き出す（ssm_setup_backup の backup と ssm-agent の標準入力の形。理由は # の後ろ）。

    「手で直す」台は、行の先頭を # にして残す（読み飛ばされる）。直した後に ssm-agent に回すなら、# を外す。
    """
    with open(path, "w", encoding="utf-8") as f:
        f.write("# ssm-check で SSM 有効でなく、SSM Agent で直す見込みの台（ssm_setup_backup の backup・check と ssm-agent の標準入力に渡せる）\n")
        for host in agent:
            f.write(f"{host.instance_id}  # {' / '.join(host.problems)}\n")
        if manual:
            f.write("\n# 手で直す台（ssm-agent では直らない見込み。行の先頭が # なので読み飛ばされる）\n")
            for host in manual:
                f.write(f"# {host.instance_id}  # {' / '.join(host.problems)}  見るところ: {host.hint}\n")


def run(aws, stdin, out, ok_out=None, ng_out=None):
    """終了コードを返す（0: すべての台が SSM 有効、1: そうでない台がある、2: 入力・道具の問題）。"""
    if not aws.available():
        print("aws のコマンドが見つからない（AWS CLI を入れて、PATH を通す）", file=out)
        return 2
    targets, invalid = read_targets(stdin)
    for value in invalid:
        print(f"形式が正しくないので無視する: {value}", file=out)
    if not targets:
        print("インスタンスの ID が 1 つもない（標準入力に 1 行 1 つで渡す）", file=out)
        return 2

    print(f"{len(targets)} 台を確かめる（権限と AWS の上の状態だけ。インスタンスには何も送らない）", file=out)
    hosts, policy_cache = [], {}
    for target in targets:
        print(f"  確認中: {target.instance_id}", file=out)
        hosts.append(inspect(aws, target.instance_id, policy_cache))

    for host in hosts:
        classify(host)
    ok = [h for h in hosts if h.category == OK]
    agent = [h for h in hosts if h.category == AGENT]
    manual = [h for h in hosts if h.category == MANUAL]
    print(f"\n== SSM 有効（Online。{len(ok)} 台）→ ssm-connect-check で実際につながるかを確かめる", file=out)
    for host in ok:
        print_host(host, out)
    print(f"\n== SSM 有効でない: SSM Agent で直す見込み（{len(agent)} 台）→ ssm_setup_backup の backup、ssm-agent", file=out)
    for host in agent:
        print_host(host, out)
    print(f"\n== SSM 有効でない: 手で直す（{len(manual)} 台。ssm-agent では直らない見込み）", file=out)
    for host in manual:
        print_host(host, out)

    no_policy = [h for h in hosts if h.policy.startswith(f"{CORE_POLICY} が付いていない")]
    print(f"\n== 結果: SSM 有効 {len(ok)} 台、SSM Agent で直す {len(agent)} 台、手で直す {len(manual)} 台"
          f"（{CORE_POLICY} が付いていないもの {len(no_policy)} 台）", file=out)
    if ok_out:
        write_ok_list(ok_out, ok)
        print(f"SSM 有効の台の一覧を書き出した: {ok_out}（{len(ok)} 台。ssm-connect-check の標準入力に渡す）", file=out)
    if ng_out:
        write_ng_list(ng_out, agent, manual)
        print(f"SSM Agent で直す台の一覧を書き出した: {ng_out}（{len(agent)} 台。ssm_setup_backup の backup と ssm-agent の標準入力に渡せる。"
              f"手で直す {len(manual)} 台は # で残した）", file=out)
    return 0 if not agent and not manual else 1
