"""IAM ロールが未設定のインスタンスに、SSM 用のインスタンスプロファイルを関連付ける。

流れ（ほかのコマンドと同じ形）:
1. 標準入力からインスタンスの ID の一覧を読む（2 列目に SSH の接続先があっても使わない）
2. 指定したインスタンスプロファイルがあることを確かめる（なければ、作るためのコマンドを表示して止まる）
3. 1 台ずつ、IAM ロール（インスタンスプロファイル）が関連付けられているかを確かめ（読み取りだけ）、
   「関連付ける（未設定）」「何もしない（すでにロールがある）」「対象外（理由つき）」に分けて表示する
4. 試行するかを確かめる
5. 1 台ずつ順に関連付け、関連付けが終わった（associated）ことを確かめる

すでにロールがあるインスタンスには何もしない（ロールに権限を足すこともしない）。
関連付けは OS のディスクを変えず、再起動も要らない。SSM Agent が新しい権限を拾って登録される（Online）まで、数分かかることがある。
"""

import time
from dataclasses import dataclass

from .awscli import AwsCliError
from .console import confirm
from .ssm_agent import fetch_ping_status
from .targets import read_targets

DEFAULT_PROFILE = "port-guard-ssm"

# 関連付けられるインスタンスの状態（止まっていても関連付けられる）
ASSOCIATE_STATES = {"running", "stopped"}

ATTACH, KEEP = "関連付ける", "何もしない"


@dataclass
class Host:
    instance_id: str
    name: str = ""
    state: str = ""
    current_profile: str = ""  # 関連付けられているインスタンスプロファイルの ARN（なければ空）
    action: str = ""
    reason: str = ""  # 対象外の理由


def profile_exists(aws, profile_name):
    """インスタンスプロファイルがあるか。戻り値は (ある, ロールの名前の一覧, 問題)。"""
    try:
        response = aws.run("iam", "get-instance-profile", "--instance-profile-name", profile_name)
    except AwsCliError as error:
        if error.code == "NoSuchEntity":
            return False, [], ""
        return False, [], f"インスタンスプロファイルを確かめられない（{error}）"
    roles = [r.get("RoleName", "") for r in response.get("InstanceProfile", {}).get("Roles", [])]
    return True, roles, ""


def creation_commands(profile_name):
    """SSM 用のインスタンスプロファイルを作るための AWS CLI のコマンド（作業者が確かめてから実行する）。"""
    return f"""aws iam create-role --role-name {profile_name} \\
  --assume-role-policy-document '{{"Version":"2012-10-17","Statement":[{{"Effect":"Allow","Principal":{{"Service":"ec2.amazonaws.com"}},"Action":"sts:AssumeRole"}}]}}'
aws iam attach-role-policy --role-name {profile_name} \\
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam create-instance-profile --instance-profile-name {profile_name}
aws iam add-role-to-instance-profile --instance-profile-name {profile_name} --role-name {profile_name}"""


def current_association(aws, instance_id):
    """関連付けられているインスタンスプロファイル。戻り値は (ARN, 関連付けの ID)。なければ ("", "")。"""
    response = aws.run(
        "ec2", "describe-iam-instance-profile-associations",
        "--filters", f"Name=instance-id,Values={instance_id}",
    )
    for association in response.get("IamInstanceProfileAssociations", []) if response else []:
        if association.get("State") in ("associating", "associated"):
            return association.get("IamInstanceProfile", {}).get("Arn", ""), association.get("AssociationId", "")
    return "", ""


def inspect(aws, instance_id):
    host = Host(instance_id)
    try:
        response = aws.run("ec2", "describe-instances", "--instance-ids", instance_id)
    except AwsCliError as error:
        if error.code in ("InvalidInstanceID.NotFound", "InvalidInstanceID.Malformed"):
            host.reason = "インスタンスが見つからない"
        else:
            host.reason = f"情報を取れない（{error}）"
        return host
    instances = [i for r in response.get("Reservations", []) for i in r.get("Instances", [])]
    if not instances:
        host.reason = "インスタンスが見つからない"
        return host
    instance = instances[0]
    host.name = {t["Key"]: t["Value"] for t in instance.get("Tags", [])}.get("Name", "")
    host.state = instance.get("State", {}).get("Name", "")
    if host.state not in ASSOCIATE_STATES:
        host.reason = f"状態が {host.state}（running か stopped のときだけ関連付けられる）"
        return host
    try:
        host.current_profile, _ = current_association(aws, instance_id)
    except AwsCliError as error:
        host.reason = f"関連付けを確かめられない（{error}）"
        return host
    host.action = KEEP if host.current_profile else ATTACH
    return host


def print_hosts(hosts, out, profile_name):
    attach = [h for h in hosts if h.action == ATTACH]
    keep = [h for h in hosts if h.action == KEEP]
    ng = [h for h in hosts if h.reason]
    print(f"\n== 関連付ける（IAM ロールが未設定。{len(attach)} 台）→ {profile_name}", file=out)
    for h in attach:
        print(f"  {h.instance_id}  {h.name}  {h.state}", file=out)
    print(f"\n== 何もしない（すでに IAM ロールがある。{len(keep)} 台）", file=out)
    for h in keep:
        print(f"  {h.instance_id}  {h.name}  {h.current_profile}", file=out)
    print(f"\n== 対象外（{len(ng)} 台）", file=out)
    for h in ng:
        print(f"  {h.instance_id}  {h.name}  理由: {h.reason}", file=out)
    return attach


def associate(aws, host, profile_name, sleep, tries=10, interval=3):
    """関連付けて、associated になるのを待つ。戻り値は問題（空なら成功）。"""
    try:
        aws.run(
            "ec2", "associate-iam-instance-profile",
            "--instance-id", host.instance_id,
            "--iam-instance-profile", f"Name={profile_name}",
        )
    except AwsCliError as error:
        return f"関連付けに失敗（{error}）"
    for _ in range(tries):
        sleep(interval)
        try:
            response = aws.run(
                "ec2", "describe-iam-instance-profile-associations",
                "--filters", f"Name=instance-id,Values={host.instance_id}",
            )
        except AwsCliError as error:
            return f"関連付けを確かめられない（{error}）"
        states = [a.get("State") for a in response.get("IamInstanceProfileAssociations", [])]
        if "associated" in states:
            return ""
    return f"関連付けが {tries * interval} 秒で終わらなかった（{', '.join(states) or '状態なし'}）"


def run(aws, stdin, out, profile_name=DEFAULT_PROFILE, wait_seconds=0, assume_yes=False, check_only=False,
        confirm_func=confirm, sleep=time.sleep):
    """終了コードを返す（0: すべて関連付けた・何もしなくてよい、1: 失敗・対象外あり、2: 入力・確認・道具の問題）。"""
    if not aws.available():
        print("aws のコマンドが見つからない（AWS CLI を入れて、PATH を通す）", file=out)
        return 2
    targets, invalid = read_targets(stdin)
    for value in invalid:
        print(f"形式が正しくないので無視する: {value}", file=out)
    if not targets:
        print("インスタンスの ID が 1 つもない（標準入力に 1 行 1 つで渡す）", file=out)
        return 2

    exists, roles, problem = profile_exists(aws, profile_name)
    if problem:
        print(problem, file=out)
        return 2
    if not exists:
        print(f"インスタンスプロファイル {profile_name} がない。作るなら、次のコマンドを確かめてから実行する:\n", file=out)
        print(creation_commands(profile_name), file=out)
        return 2
    print(f"インスタンスプロファイル: {profile_name}（ロール: {', '.join(roles) or 'なし'}）", file=out)
    if not roles:
        print("インスタンスプロファイルにロールが入っていない（aws iam add-role-to-instance-profile で入れる）", file=out)
        return 2

    print(f"{len(targets)} 台を確かめる（IAM ロールが関連付けられているかを読むだけ）", file=out)
    hosts = []
    for target in targets:
        print(f"  確認中: {target.instance_id}", file=out)
        hosts.append(inspect(aws, target.instance_id))

    attach = print_hosts(hosts, out, profile_name)
    excluded = len([h for h in hosts if h.reason])
    if check_only:
        return 0
    if not attach:
        print("\n関連付ける台がないので、終わる", file=out)
        return 1 if excluded else 0

    if not assume_yes:
        answer = confirm_func(f"\n上の {len(attach)} 台に、インスタンスプロファイル {profile_name} を関連付けますか？ [y/N]: ")
        if answer is None:
            print("確認のための端末がない。確かめずに進めるなら --yes を付ける", file=out)
            return 2
        if not answer:
            print("中止した", file=out)
            return 0

    print(f"\n== 関連付け（1 台ずつ順に行う）", file=out)
    done, failed = [], 0
    for index, host in enumerate(attach, start=1):
        print(f"  [{index}/{len(attach)}] {host.instance_id}  {host.name}", file=out)
        # 確かめてから時間がたっているので、関連付けられていないことをもう一度見る（二重の関連付けを避ける）
        try:
            now_profile, _ = current_association(aws, host.instance_id)
        except AwsCliError as error:
            failed += 1
            print(f"      失敗: 関連付けを確かめられない（{error}）", file=out)
            continue
        if now_profile:
            print(f"      何もしない: すでに関連付けられている（{now_profile}）", file=out)
            continue
        problem = associate(aws, host, profile_name, sleep)
        if problem:
            failed += 1
            print(f"      失敗: {problem}", file=out)
        else:
            done.append(host)
            print(f"      完了: {profile_name} を関連付けた（associated）", file=out)

    not_online = []
    if wait_seconds and done:
        print(f"\n== SSM の登録（Online）を待つ（最大 {wait_seconds} 秒）", file=out)
        pending = {h.instance_id for h in done}
        deadline = time.monotonic() + wait_seconds
        while pending:
            for instance_id in sorted(pending):
                if fetch_ping_status(aws, instance_id) == "Online":
                    pending.discard(instance_id)
                    print(f"  Online: {instance_id}", file=out)
            if not pending or time.monotonic() >= deadline:
                break
            sleep(15)
        not_online = sorted(pending)
        for instance_id in not_online:
            print(f"  Online にならなかった: {instance_id}（SSM Agent が動いているか、送信の 443 番が通るかを見る）", file=out)

    print(f"\n== 結果: 関連付けた {len(done)} 台、失敗 {failed} 台、何もしない {len(hosts) - len(attach) - excluded} 台、"
          f"対象外 {excluded} 台", file=out)
    if done and not wait_seconds:
        print("SSM に登録されるまで数分かかることがある。確かめるには --wait-online を付けるか、次を実行する:", file=out)
        print("  aws ssm describe-instance-information --query 'InstanceInformationList[].[InstanceId,PingStatus]' --output table",
              file=out)
    return 1 if failed or excluded or not_online else 0
