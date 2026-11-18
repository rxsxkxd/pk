"""公開元と AWS CLI を模擬し、実際のシェルと成果物だけで最後まで流す。"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import yaml
from test_stack import ROOT, load_template

MOCK = r'''
import json, os, shutil, sys
from pathlib import Path
root = Path(os.environ['MOCK_ROOT'])
args = sys.argv[1:]
if Path(sys.argv[0]).name == 'curl':
    output = Path(args[args.index('-o') + 1])
    if args[-1].endswith('delegated-apnic-latest'):
        rows = ['2|apnic|20261117|0|0|0|0']
        rows += [f'apnic|JP|ipv4|10.{i//256}.{i%256}.0|256|20261117|allocated' for i in range(1000)]
        rows += [f'apnic|JP|ipv6|2001:db8:{i:x}::|48|20261117|allocated' for i in range(200)]
        output.write_text('\n'.join(rows) + '\n')
    else:
        ranges = {'createDate': '2026-11-17-00-00-00'}
        for key, count, address in [('prefixes', 100, 'ip_prefix'), ('ipv6_prefixes', 50, 'ipv6_prefix')]:
            ranges[key] = [{address: f'192.0.{i}.0/24' if address == 'ip_prefix' else f'2001:db8:{i+1000:x}::/48',
                            'region': 'ap-northeast-1', 'service': 'AMAZON',
                            'network_border_group': 'ap-northeast-1'} for i in range(count)]
        output.write_text(json.dumps(ranges, indent=2))
    sys.exit(0)
with (root / 'aws.jsonl').open('a') as log:
    log.write(json.dumps(args) + '\n')
while args and args[0] in ('--region', '--profile'):
    args = args[2:]
s3 = root / 's3'
if args[:3] == ['configure', 'get', 'region']: print('ap-northeast-1')
elif args[:2] == ['sts', 'get-caller-identity']: print('111122223333')
elif args[:2] == ['s3api', 'list-objects-v2']:
    base = s3 / args[args.index('--bucket') + 1]
    prefix = args[args.index('--prefix') + 1]
    keys = sorted(str(p.relative_to(base)) for p in base.rglob('*') if p.is_file() and str(p.relative_to(base)).startswith(prefix)) if base.exists() else []
    print('\t'.join(keys) if keys else 'None')
elif args[:2] == ['sns', 'publish']: pass
elif args[:2] == ['s3', 'cp']:
    src, dst = [a for a in args[2:] if a != '--only-show-errors']
    src = s3 / src[5:] if src.startswith('s3://') else Path(src)
    dst = s3 / dst[5:] if dst.startswith('s3://') else Path(dst)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dst)
else: raise SystemExit('Unexpected AWS call: ' + repr(args))
'''


class ScriptsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='port guard ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        binaries = self.root / 'bin'
        binaries.mkdir()
        for name in ('aws', 'curl'):
            executable = binaries / name
            executable.write_text(f'#!{sys.executable}\n' + MOCK)
            executable.chmod(0o755)
        self.environment = {k: v for k, v in os.environ.items()
                            if not k.startswith(('AWS_', 'PORT_GUARD_', 'MOCK_')) and k != 'FORCE'}
        self.environment.update(PATH=str(binaries) + ':' + os.environ['PATH'], MOCK_ROOT=str(self.root))

    def copy_project(self, destination):
        shutil.copytree(ROOT, destination, ignore=shutil.ignore_patterns('work', '.venv', '__pycache__', 'cdk.out'))
        for name in ('development', 'staging', 'production'):
            (destination / 'allow-lists' / name / 'allow-ipv4.txt').write_text('10.9.0.0/16\n')
        return destination

    def run_shell(self, command, cwd, extra=None):
        result = subprocess.run(['bash', '-euo', 'pipefail', '-c', command], cwd=cwd,
                                env=self.environment | (extra or {}), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def calls(self):
        return [json.loads(line) for line in (self.root / 'aws.jsonl').read_text().splitlines()]

    def check_publish(self, uri):
        remote = self.root / 's3' / uri.removeprefix('s3://')
        hashes = (remote / 'SHA256SUMS').read_text().splitlines()
        self.assertEqual(len(hashes), 10)
        for line in hashes:
            digest, name = line.split(None, 1)
            self.assertEqual(hashlib.sha256((remote / name.strip()).read_bytes()).hexdigest(), digest)
        self.assertTrue(self.calls()[-1][-1].endswith('/SHA256SUMS'))
        self.assertEqual((remote / 'port_guard_whitelists/allow-ipv4.txt').read_text(), '10.9.0.0/16\n')
        for path in remote.glob('command/port_guard/*.sh'):
            self.run_shell(f'bash -n "{path}"', self.root)

    def test_region_and_profile_reach_all_aws_commands(self):
        project = self.copy_project(self.root / 'copied project')
        for script in ('build-rules.sh', 'deploy-rules.sh'):
            self.run_shell(f'bash "{project / script}" staging --region ap-northeast-3 --profile selected-profile',
                           self.root, {'AWS_REGION': 'us-west-2', 'AWS_PROFILE': 'other-profile'})
        for call in self.calls():
            self.assertEqual(call[:4], ['--profile', 'selected-profile', '--region', 'ap-northeast-3'])
        self.check_publish('s3://ip-port-guard-rules-111122223333-ap-northeast-3-an/port-guard/staging/current')

    def test_pipeline_artifact_is_sufficient_for_publish(self):
        template = load_template('list-refresh-pipeline.yml')
        specs = [yaml.safe_load(template['Resources'][name]['Properties']['Source']['BuildSpec'])
                 for name in ('MakeProject', 'PublishProject')]
        make, publish = specs
        for directory, name in (('.', 'development'), ('nested project', 'staging')):
            with self.subTest(directory=directory):
                repo = self.root / ('repo-' + name)
                project = self.copy_project(repo if directory == '.' else repo / directory)
                uri = f's3://rules/port-guard/{name}/current'
                environment = {'CODEBUILD_SRC_DIR': str(repo), 'SOURCE_DIRECTORY': directory,
                               'ENVIRONMENT_NAME': name, 'PORT_GUARD_S3_URI': uri, 'AWS_REGION': 'ap-northeast-1'}
                self.run_shell('\n'.join(make['phases']['build']['commands']), repo, environment)
                self.assertFalse((self.root / 's3' / 'rules' / 'port-guard' / name).exists())
                artifact = self.root / ('artifact-' + name)
                artifact.mkdir()
                # 成果物は決まった名前のフォルダ handoff/ の中身。SourceDirectory に関係なく、CODEBUILD_SRC_DIR の直下にある
                self.assertEqual(make['artifacts'], {'base-directory': 'handoff', 'files': ['**/*']})
                handoff = repo / 'handoff'
                for path in handoff.rglob('*'):
                    if path.is_file():
                        target = artifact / path.relative_to(handoff)
                        target.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copyfile(path, target)
                self.assertTrue((artifact / 'deploy-rules.sh').is_file())
                self.assertTrue((artifact / 'work' / name / 'command' / 'port_guard' / 'refresh-ipv4.sh').is_file())
                repo.rename(self.root / ('finished-' + name))
                self.run_shell('\n'.join(publish['phases']['build']['commands']), artifact,
                               {'ENVIRONMENT_NAME': name, 'PORT_GUARD_S3_URI': uri, 'AWS_DEFAULT_REGION': 'ap-northeast-1'})
                self.check_publish(uri)
                moved = self.root / ('finished-' + name)
                if directory != '.': moved /= directory
                output = self.run_shell(f'bash "{moved / "build-rules.sh"}" {name}', self.root,
                                        {'PORT_GUARD_S3_URI': uri, 'AWS_REGION': 'ap-northeast-1'})
                self.assertIn('前回分の IP の一覧: 6 件のファイルを取った', output)
                self.assertIn('増 0 件、減 0 件', output)

    def test_make_failure_is_notified_with_reason_and_changes(self):
        template = load_template('list-refresh-pipeline.yml')
        make = yaml.safe_load(template['Resources']['MakeProject']['Properties']['Source']['BuildSpec'])
        topic = 'arn:aws:sns:ap-northeast-1:111122223333:port-guard-alerts'
        uri = 's3://rules/port-guard/staging/current'
        for given in (topic, ''):
            with self.subTest(topic=given):
                repo = self.root / ('repo-notify-' + str(bool(given)))
                self.copy_project(repo)
                # 前回分の一覧を、今回と大きく違うものにしておく（5% の確認に当たる）
                last = self.root / 's3/rules/port-guard/staging/current/port_guard_whitelists/last-refresh'
                last.mkdir(parents=True, exist_ok=True)
                (last / 'jp-ipv4.txt').write_text(''.join(f'172.16.{i % 256}.{i // 256}/32\n' for i in range(1000)))
                environment = {'CODEBUILD_SRC_DIR': str(repo), 'SOURCE_DIRECTORY': '.', 'ENVIRONMENT_NAME': 'staging',
                               'PORT_GUARD_S3_URI': uri, 'AWS_REGION': 'ap-northeast-1'}
                if given:
                    environment['NOTIFICATION_TOPIC_ARN'] = given
                result = subprocess.run(['bash', '-euo', 'pipefail', '-c', '\n'.join(make['phases']['build']['commands'])],
                                        cwd=repo, env=self.environment | environment, capture_output=True, text=True)
                # ビルドは失敗で終わり、ルールのデプロイ先には何も上げない
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse((self.root / 's3/rules/port-guard/staging/current/SHA256SUMS').exists())
                published = [c for c in self.calls() if c[:2] == ['sns', 'publish']]
                if not given:
                    self.assertEqual(published, [])
                    continue
                self.assertEqual(len(published), 1)
                call = published[0]
                self.assertEqual(call[call.index('--topic-arn') + 1], topic)
                self.assertIn('増減の確認でルールの作成が止まった', call[call.index('--subject') + 1])
                message = call[call.index('--message') + 1]
                self.assertIn('jp-ipv4: 1000 件（前回 1000 件、増 1000 件、減 1000 件）', message)
                self.assertIn('増減が大きい一覧があるので止める', message)
                self.assertIn('--variables name=FORCE,value=1', message)
                (self.root / 'aws.jsonl').unlink()

    def test_default_profile_and_region(self):
        project = self.copy_project(self.root / 'default project')
        for script in ('build-rules.sh', 'deploy-rules.sh'):
            self.run_shell(f'bash "{project / script}" production', self.root)
        self.assertIn(['configure', 'get', 'region'], self.calls())
        self.check_publish('s3://ip-port-guard-rules-111122223333-ap-northeast-1-an/port-guard/production/current')


if __name__ == '__main__':
    unittest.main()
