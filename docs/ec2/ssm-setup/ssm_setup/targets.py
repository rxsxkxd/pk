"""標準入力から、処理の対象のインスタンスを読む。

1 行に 1 台。`<インスタンスの ID> [<SSH の接続先>]` の形。
SSH の接続先（`host`、`host:port`、`user@host:port`）は省略でき、省略すると AWS CLI でインスタンスの IP を引く。
手元の再現の環境（al2-instance）のように、EC2 ではない相手を試すときに書く。
空の行と `#` から後は無視し、同じインスタンスの ID は最初の行だけを使う。
"""

import re
from dataclasses import dataclass

from .awscli import AwsCliError

INSTANCE_ID_PATTERN = re.compile(r"^i-[0-9a-f]{8}([0-9a-f]{9})?$")


@dataclass
class Target:
    instance_id: str
    ssh_target: str = ""


def read_targets(stream):
    """戻り値は (Target の一覧, 形式が正しくない行の一覧)。"""
    targets, invalid, seen = [], [], set()
    for line in stream:
        fields = line.split("#", 1)[0].split()
        if not fields:
            continue
        if not INSTANCE_ID_PATTERN.match(fields[0]) or len(fields) > 2:
            invalid.append(" ".join(fields))
            continue
        if fields[0] in seen:
            continue
        seen.add(fields[0])
        targets.append(Target(fields[0], fields[1] if len(fields) == 2 else ""))
    return targets, invalid


def resolve_ssh_target(aws, host, address):
    """接続先が書かれていなければ、AWS CLI でインスタンスの IP（と Name タグ）を引く。

    host には instance_id・ssh_target・name・reasons があればよい。問題があれば reasons に入れる。
    """
    if host.ssh_target:
        return
    try:
        response = aws.run("ec2", "describe-instances", "--instance-ids", host.instance_id)
    except AwsCliError as error:
        if error.code in ("InvalidInstanceID.NotFound", "InvalidInstanceID.Malformed"):
            host.reasons.append("インスタンスが見つからない")
        else:
            host.reasons.append(f"情報を取れない（{error}）")
        return
    instances = [i for r in response.get("Reservations", []) for i in r.get("Instances", [])]
    if not instances:
        host.reasons.append("インスタンスが見つからない")
        return
    instance = instances[0]
    host.name = {t["Key"]: t["Value"] for t in instance.get("Tags", [])}.get("Name", "")
    state = instance.get("State", {}).get("Name", "")
    if state != "running":
        host.reasons.append(f"状態が {state}（running のときだけ入れられる）")
        return
    public_ip = instance.get("PublicIpAddress", "")
    private_ip = instance.get("PrivateIpAddress", "")
    if address == "private":
        host.ssh_target = private_ip
    else:
        host.ssh_target = public_ip or private_ip
    if not host.ssh_target:
        host.reasons.append("接続先の IP がない")
