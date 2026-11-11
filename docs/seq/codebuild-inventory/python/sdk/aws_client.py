"""AWS の呼び出し（Python SDK 版。boto3 を使う）。

正本は docs/seq/_common/python/sdk/aws_client.py。各ツールにあるのは sync-common.sh で写したものなので、直接編集しない。
ページ送りのある API は全ページをまとめ、AWS CLI の JSON 出力と同じ形で返す。
"""

import os

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

# 混み合っているときは SDK が自分で送る速さを落とす
CONFIG = Config(retries={"mode": "adaptive"})


class AwsError(Exception):
    def __init__(self, operation, code, message):
        super().__init__(f"{operation}: {code}: {message}")
        self.operation = operation
        self.code = code
        self.message = message


class Aws:
    def __init__(self):
        # AWS_REGION は boto3 の版によっては読まれないので明示的に渡す（未設定ならプロファイルの設定に従う）
        self.session = boto3.Session(region_name=os.environ.get("AWS_REGION"))
        self.region = self.session.region_name
        self.clients = {}

    def client(self, service, region=None):
        key = (service, region or self.region)
        if key not in self.clients:
            self.clients[key] = self.session.client(service, region_name=key[1], config=CONFIG)
        return self.clients[key]

    def call(self, service, operation, params, region=None, paginate=True):
        client = self.client(service, region)
        try:
            if paginate and client.can_paginate(operation):
                result = client.get_paginator(operation).paginate(**params).build_full_result()
            else:
                result = getattr(client, operation)(**params)
        except ClientError as e:
            err = e.response.get("Error") or {}
            raise AwsError(e.operation_name, err.get("Code", "Unknown"), err.get("Message", str(e))) from e
        result.pop("ResponseMetadata", None)
        return result
