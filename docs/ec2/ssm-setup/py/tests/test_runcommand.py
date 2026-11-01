"""SSM の Run Command のテスト。AWS には接続せず、偽物の AWS CLI で応答を返す。"""

import base64
import json
import unittest

from ssm_setup.awscli import AwsCliError
from ssm_setup.runcommand import RunCommandClient


class FakeAws:
    def __init__(self, invocations):
        self.invocations = list(invocations)  # get-command-invocation の応答を順に返す
        self.sent = None

    def available(self):
        return True

    def run(self, *args):
        if args[1] == "send-command":
            self.sent = json.loads(next(a for a in args if a.startswith("--parameters=")).split("=", 1)[1])
            return {"Command": {"CommandId": "cmd-1"}}
        value = self.invocations.pop(0)
        if isinstance(value, Exception):
            raise value
        return value


def client(invocations):
    aws = FakeAws(invocations)
    return aws, RunCommandClient(aws, sleep=lambda s: None)


class RunScriptTest(unittest.TestCase):
    def test_sends_script_as_base64_and_reads_values(self):
        not_yet = AwsCliError(["aws"], 254, "An error occurred (InvocationDoesNotExist) when calling the X operation: x")
        aws, rc = client([not_yet, {"Status": "InProgress"},
                          {"Status": "Success", "ResponseCode": 0, "StandardOutputContent": "PGSTEP a\nPG os=AL2\n"}])
        result = rc.run_script("i-00000001", "echo 'quoted' \"double\"\n")
        command = aws.sent["commands"][0]
        encoded = command.split("'")[1]
        self.assertEqual(base64.b64decode(encoded).decode(), "echo 'quoted' \"double\"\n")
        self.assertEqual((result.returncode, result.values, result.steps), (0, {"os": "AL2"}, ["a"]))

    def test_failed_command_keeps_exit_code(self):
        _, rc = client([{"Status": "Failed", "ResponseCode": 1, "StandardOutputContent": "PGSTEP b\n",
                         "StandardErrorContent": "boom"}])
        result = rc.run_script("i-00000001", "false")
        self.assertEqual((result.returncode, result.steps, result.connection_failed), (1, ["b"], False))

    def test_undeliverable_is_connection_failure(self):
        _, rc = client([{"Status": "Undeliverable", "ResponseCode": -1}])
        self.assertTrue(rc.run_script("i-00000001", "true").connection_failed)


if __name__ == "__main__":
    unittest.main()
