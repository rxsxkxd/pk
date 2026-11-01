"""IAM ロールが未設定のインスタンスに、SSM 用のインスタンスプロファイルを関連付ける。

流れ: インスタンスの存在チェック → ロールの状態チェック → ロールの付与 → 権限状態の確認（Ruby 版の rb/ssm_role.rb と同じ）
確かめる（plan）: 1. インスタンスの存在チェック（running・stopped でない、見つからない台は対象外）
  2. ロールの状態チェック（すでにロールがある台は何もしない。ない台を「付与する」にする）
  付与する台があれば、インスタンスプロファイルがあることも確かめる（用意しておく前提。なければ止まる）
行う（apply）: 3. ロールの付与（1 台ずつ関連付ける）
後（finish）: 4. 権限状態の確認（関連付けが残っていて、そのロールに AmazonSSMManagedInstanceCore が付いているか）

入力・表示・確認・失敗の扱いは flow の共通の流れ。すでにロールがある台には何もしない（ロールに権限を足すこともしない）。
確かめた後にほかの人が関連付けていたら、AWS の側が拒む（失敗と表示される）。関連付けは OS のディスクを変えず、
再起動も要らない。SSM に登録される（Online）まで数分かかることがあるので、少し時間を置いてから ssm-check で確かめる。
"""

from .awscli import AwsCliError
from .console import confirm
from .flow import Item, Plan, execute, require_aws

DEFAULT_PROFILE = "port-guard-ssm"
CORE_POLICY = "AmazonSSMManagedInstanceCore"


def instance_filter(ids):
    """まとめて読むためのフィルター（AWS のフィルターの値は 200 個まで）。"""
    return "Name=instance-id,Values=" + ",".join(ids)


def check_instances_exist(aws, ids):
    """1. インスタンスの存在チェック。インスタンスの ID → (名前, 状態)（見つからないインスタンスは入らない）。"""
    reservations = aws.run("ec2", "describe-instances", "--filters", instance_filter(ids))["Reservations"]
    return {i["InstanceId"]: ({t["Key"]: t["Value"] for t in i.get("Tags", [])}.get("Name", ""), i["State"]["Name"])
            for r in reservations for i in r["Instances"]}


def associated_profile_arns(aws, ids):
    """2. ロールの状態チェック。インスタンスの ID → 関連付けられているインスタンスプロファイルの ARN。"""
    if not ids:
        return {}
    associations = aws.run("ec2", "describe-iam-instance-profile-associations", "--filters", instance_filter(ids))
    return {a["InstanceId"]: a["IamInstanceProfile"]["Arn"] for a in associations["IamInstanceProfileAssociations"]
            if a["State"] in ("associating", "associated")}


def core_policy_attached(aws, profile_name):
    """インスタンスプロファイルのロールに AmazonSSMManagedInstanceCore が付いているか。"""
    roles = aws.run("iam", "get-instance-profile", "--instance-profile-name", profile_name)["InstanceProfile"]["Roles"]
    for role in roles:
        policies = aws.run("iam", "list-attached-role-policies", "--role-name", role["RoleName"])["AttachedPolicies"]
        if any(p["PolicyName"] == CORE_POLICY for p in policies):
            return True
    return False


def plan(aws, targets, profile_name):
    require_aws(aws)
    ids = [t.instance_id for t in targets]
    instances = check_instances_exist(aws, ids)
    profiles = associated_profile_arns(aws, [i for i in ids if i in instances])
    p = Plan(title=f"付与する（IAM ロールが未設定）→ {profile_name}",
             question=f"インスタンスプロファイル {profile_name} を関連付けますか？",
             finish=lambda done, out: verify_permissions(aws, done, profile_name, out))
    for instance_id in ids:
        name, state = instances.get(instance_id, ("", ""))
        if state not in ("running", "stopped"):
            p.excluded.append(f"{instance_id}  {name}  理由: {f'状態が {state}' if state else '見つからない'}")
        elif instance_id in profiles:
            p.keep.append(f"{instance_id}  {name}  すでに IAM ロールがある: {profiles[instance_id]}")
        else:
            p.todo.append(Item(instance_id, f"{instance_id}  {name}"))
    if p.todo:
        aws.run("iam", "get-instance-profile", "--instance-profile-name", profile_name)  # なければ止まる
    return p


def apply(aws, item, profile_name):
    """3. ロールの付与。"""
    aws.run("ec2", "associate-iam-instance-profile", "--instance-id", item.instance_id,
            "--iam-instance-profile", f"Name={profile_name}")


def verify_permissions(aws, done, profile_name, out):
    """4. 権限状態の確認。関連付けが残っていて、ロールに AmazonSSMManagedInstanceCore が付いていれば True。"""
    print("\n== 権限状態の確認", file=out)
    try:
        associated = associated_profile_arns(aws, [item.instance_id for item in done])
        core = core_policy_attached(aws, profile_name)
    except AwsCliError as error:
        print(f"  確かめられない（{error}）", file=out)
        return False
    for item in done:
        print(f"  関連付け: {item.instance_id}  {'あり' if item.instance_id in associated else 'なし'}", file=out)
    print(f"  権限: {profile_name} のロールに {CORE_POLICY} が"
          f"{'付いている' if core else '付いていない（このままでは Online にならない）'}", file=out)
    print("SSM に登録される（Online）まで数分かかることがある。少し時間を置いてから ssm-check で確かめる", file=out)
    return core and len(associated) == len(done)


def run(aws, stdin, out, profile_name=DEFAULT_PROFILE, assume_yes=False, check_only=False, confirm_func=confirm):
    return execute(stdin, out, lambda targets: plan(aws, targets, profile_name),
                   lambda item: apply(aws, item, profile_name), heading="ロールの付与（1 台ずつ順に行う）",
                   assume_yes=assume_yes, check_only=check_only, confirm_func=confirm_func)
