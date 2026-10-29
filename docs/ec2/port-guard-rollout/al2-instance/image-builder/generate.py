"""al2-instance の Image Builder の CloudFormation のテンプレート（port-guard-test-al2.yml）を作る。

アプリ（../app/）と Apache の設定（../httpd/）を、コンポーネントの Data にそのまま埋め込むために使う。
アプリや Apache の設定を変えたら、このフォルダで `python3 generate.py` を実行して作り直し、コンポーネントとレシピの版を上げる。
"""
import pathlib, textwrap

base = pathlib.Path(__file__).resolve().parent.parent
app_files = [
    "Gemfile", "Gemfile.lock", "config.ru", "config/boot.rb", "config/application.rb", "config/environment.rb",
    "config/environments/production.rb", "config/environments/development.rb", "config/routes.rb",
    "app/controllers/application_controller.rb", "app/controllers/health_controller.rb", "public/robots.txt",
]

def ind(text, n):
    return textwrap.indent(text, " " * n, lambda line: True)

passenger_conf = (base / "httpd/passenger.conf.template").read_text().replace("@APP_USER@", "centos") \
    .replace("@RUBY_VERSION@", "{{ RubyVersion }}").replace("@RUBY_API_VERSION@", "{{ RubyApiVersion }}") \
    .replace("@PASSENGER_VERSION@", "{{ PassengerVersion }}")
app_conf = (base / "httpd/app.conf").read_text().replace("@APP_USER@", "centos")

system_doc = f"""name: port-guard-test-al2-system
description: Apache, Ruby (rbenv) and Passenger like the current AL2 instances
schemaVersion: 1.0
parameters:
  - HttpdVersion:
      type: string
      default: 2.4.56
      description: Apache の版（今のインスタンスに合わせる）
  - ModHttp2Version:
      type: string
      default: 1.15.19-1.amzn2.0.2
      description: Apache 2.4.56 と組み合わせられる mod_http2 の版
  - RubyVersion:
      type: string
      default: 2.7.7
  - RubyApiVersion:
      type: string
      default: 2.7.0
      description: gem の置き場所の版（Ruby 2.7 系は 2.7.0）
  - PassengerVersion:
      type: string
      default: 6.0.18
  - RbenvRelease:
      type: string
      default: 1.3.2
  - RubyBuildVersion:
      type: string
      default: "20261023"
  - RubygemsVersion:
      type: string
      default: 3.4.22
      description: Ruby 2.7 で使える最後の RubyGems
  - BundlerVersion:
      type: string
      default: 2.4.22
      description: Ruby 2.7 で使える最後の Bundler
phases:
  - name: build
    steps:
      # Apache は版を指定して入れる。mod_http2 は Apache と別の版の番号なので、2.4.56 と組み合わせられる版を指定する。
      # iptables のコマンドは入れ、ipset・iptables-services・firewalld は入れない（今のインスタンスに合わせる）
      - name: InstallPackages
        action: ExecuteBash
        inputs:
          commands:
            - set -euo pipefail
            - |
              yum install -y \\
                sudo cronie iptables iproute procps-ng shadow-utils hostname which findutils \\
                tar gzip bzip2 xz curl openssl \\
                gcc gcc-c++ make patch \\
                openssl-devel zlib-devel readline-devel libyaml-devel libffi-devel \\
                libcurl-devel apr-devel apr-util-devel \\
                "httpd-{{{{ HttpdVersion }}}}" "httpd-tools-{{{{ HttpdVersion }}}}" "httpd-devel-{{{{ HttpdVersion }}}}" \\
                "mod_ssl-{{{{ HttpdVersion }}}}" "mod_http2-{{{{ ModHttp2Version }}}}"
            - yum clean all
      # アプリと rbenv の持ち主（今のインスタンスと同じ centos。sudo をパスワードなしで使える）
      - name: CreateUser
        action: ExecuteBash
        inputs:
          commands:
            - set -euo pipefail
            - id centos >/dev/null 2>&1 || useradd -m centos
            - echo 'centos ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/centos
            - chmod 440 /etc/sudoers.d/centos
            - chmod 711 /home/centos
            - install -d -m 700 -o centos -g centos /home/centos/.ssh
      # rbenv と ruby-build で Ruby を入れる（/home/centos/.rbenv）。centos で実行する
      - name: InstallRuby
        action: ExecuteBash
        inputs:
          commands:
            - set -euo pipefail
            - |
              cat > /tmp/port-guard-test-ruby.sh <<'EOS'
              set -euo pipefail
              cd "$HOME"
              mkdir -p .rbenv/plugins/ruby-build
              curl -fsSL "https://github.com/rbenv/rbenv/archive/refs/tags/v{{{{ RbenvRelease }}}}.tar.gz" | tar -xz --strip-components=1 -C .rbenv
              curl -fsSL "https://github.com/rbenv/ruby-build/archive/refs/tags/v{{{{ RubyBuildVersion }}}}.tar.gz" | tar -xz --strip-components=1 -C .rbenv/plugins/ruby-build
              RUBY_CONFIGURE_OPTS="--disable-install-doc" .rbenv/bin/rbenv install -s "{{{{ RubyVersion }}}}"
              .rbenv/bin/rbenv global "{{{{ RubyVersion }}}}"
              grep -q 'rbenv init' .bashrc || printf '%s\\n' 'export PATH="$HOME/.rbenv/bin:$PATH"' 'eval "$(rbenv init - bash)"' >> .bashrc
              EOS
            - sudo -u centos -H bash /tmp/port-guard-test-ruby.sh
            - rm -f /tmp/port-guard-test-ruby.sh
      # RubyGems と Bundler を Ruby 2.7 で使える最後の版に、Passenger を今のインスタンスと同じ版にし、Apache のモジュールを作る
      - name: InstallPassenger
        action: ExecuteBash
        inputs:
          commands:
            - set -euo pipefail
            - |
              cat > /tmp/port-guard-test-passenger.sh <<'EOS'
              set -euo pipefail
              export PATH="$HOME/.rbenv/shims:$HOME/.rbenv/bin:$PATH"
              gem update --system "{{{{ RubygemsVersion }}}}" --no-document
              gem install bundler -v "{{{{ BundlerVersion }}}}" --no-document
              gem install passenger -v "{{{{ PassengerVersion }}}}" --no-document
              rbenv rehash
              passenger-install-apache2-module --auto --languages ruby
              EOS
            - sudo -u centos -H bash /tmp/port-guard-test-passenger.sh
            - rm -f /tmp/port-guard-test-passenger.sh
      # Passenger の読み込み（今のインスタンスと同じパス）と、HTTP・HTTPS の仮想ホスト
      - name: ConfigureApache
        action: ExecuteBash
        inputs:
          commands:
            - set -euo pipefail
            - |
              cat > /etc/httpd/conf.d/passenger.conf <<'EOS'
{ind(passenger_conf.rstrip(), 14)}
              EOS
            - |
              cat > /etc/httpd/conf.d/app.conf <<'EOS'
{ind(app_conf.rstrip(), 14)}
              EOS
            - |
              if [ ! -f /etc/pki/tls/certs/localhost.crt ]; then
                openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -subj "/CN=localhost" \\
                  -keyout /etc/pki/tls/private/localhost.key -out /etc/pki/tls/certs/localhost.crt
              fi
            - httpd -t
  # スナップショットを撮る前に、ビルド用のインスタンスで確かめる
  - name: validate
    steps:
      - name: CheckSystem
        action: ExecuteBash
        inputs:
          commands:
            - set -euo pipefail
            - httpd -v | grep -F "Apache/{{{{ HttpdVersion }}}}"
            - httpd -V | grep -E "Server MPM. +prefork"
            - ldd /usr/lib64/httpd/modules/mod_ssl.so | grep -F libssl.so.10
            - "sudo -u centos -H /home/centos/.rbenv/versions/{{{{ RubyVersion }}}}/bin/ruby -ropenssl -e 'exit(OpenSSL::OPENSSL_LIBRARY_VERSION.include?(\\"1.0.2k\\"))'"
            - sudo -u centos -H /home/centos/.rbenv/versions/{{{{ RubyVersion }}}}/bin/passenger-config --version | grep -F "{{{{ PassengerVersion }}}}"
            - "! rpm -q ipset iptables-services firewalld"
"""

app_steps = []
for rel in app_files:
    content = (base / "app" / rel).read_text()
    app_steps.append(f"""            - |
              install -d -o centos -g centos "$(dirname /home/centos/app/{rel})"
              cat > /home/centos/app/{rel} <<'EOS'
{ind(content.rstrip(), 14)}
              EOS""")
app_doc = f"""name: port-guard-test-al2-app
description: Minimal Rails 4.2 app served by Apache and Passenger
schemaVersion: 1.0
parameters:
  - BundlerVersion:
      type: string
      default: 2.4.22
phases:
  - name: build
    steps:
      # 最小の Rails 4.2 のアプリ（../app/ と同じ中身）を /home/centos/app に置く
      - name: PlaceApp
        action: ExecuteBash
        inputs:
          commands:
            - set -euo pipefail
{chr(10).join(app_steps)}
            - chown -R centos:centos /home/centos/app
      # x86_64 ではビルド済みの nokogiri が AL2 で動くので、force_ruby_platform は付けない
      - name: BundleInstall
        action: ExecuteBash
        inputs:
          commands:
            - set -euo pipefail
            - |
              cat > /tmp/port-guard-test-bundle.sh <<'EOS'
              set -euo pipefail
              export PATH="$HOME/.rbenv/shims:$HOME/.rbenv/bin:$PATH"
              cd "$HOME/app"
              bundle _{{{{ BundlerVersion }}}}_ install --jobs 4
              mkdir -p log tmp public
              EOS
            - sudo -u centos -H bash /tmp/port-guard-test-bundle.sh
            - rm -f /tmp/port-guard-test-bundle.sh
      - name: EnableHttpd
        action: ExecuteBash
        inputs:
          commands:
            - set -euo pipefail
            - systemctl enable httpd
            - systemctl restart httpd
  - name: validate
    steps:
      - name: CheckApp
        action: ExecuteBash
        inputs:
          commands:
            - set -euo pipefail
            - systemctl is-enabled httpd
            - 'curl -fsS http://localhost/health | grep -F "ruby: 2.7.7"'  # 「: 」を含むので、行全体を引用符で囲む
            - 'curl -fsS http://localhost/health | grep -F "openssl: OpenSSL 1.0.2k"'  # 「: 」を含むので、行全体を引用符で囲む
            - 'curl -fsSk https://localhost/health | grep -F "rails: 4.2.11.3"'  # 「: 」を含むので、行全体を引用符で囲む
  # できた AMI から起動したテスト用のインスタンスで確かめる（起動時に httpd が動いていること）
  - name: test
    steps:
      - name: CheckOnNewInstance
        action: ExecuteBash
        inputs:
          commands:
            - set -euo pipefail
            - systemctl is-active httpd
            - httpd -V | grep -E "Server MPM. +prefork"
            - ldd /usr/lib64/httpd/modules/mod_ssl.so | grep -F libssl.so.10
            - 'curl -fsS http://localhost/health | grep -F "openssl: OpenSSL 1.0.2k"'  # 「: 」を含むので、行全体を引用符で囲む
            - curl -fsSk -o /dev/null -w '%{{http_code}}' https://localhost/health | grep -Fx 200
            - "! rpm -q ipset iptables-services firewalld"
"""

template = f"""AWSTemplateFormatVersion: "2010-09-09"
# 下書き（未検証）。EC2 Image Builder で、今の構成（AL2・Apache 2.4.56・Passenger 6.0.18・Ruby 2.7.7・Rails 4.2）に近い
# テスト用のインスタンスの AMI を作る。開発用のアカウントの、本番とは別の VPC で使う。
# 説明は同じフォルダの README.md。手順は ../Dockerfile と揃えている（アプリは ../app/ と同じ中身を埋め込んでいる）。
# このテンプレートは generate.py で作ったもの（手で直さない）。アプリや Apache の設定を変えたら、generate.py で作り直す。
Description: Test instance AMI like the current AL2 instances for port-guard-rollout (EC2 Image Builder)

Parameters:
  NamePrefix:
    Type: String
    Default: port-guard-test-al2
    Description: Image Builder の資源と AMI の名前の先頭
  ComponentVersion:
    Type: String
    Default: 1.0.0
    Description: コンポーネントの版（2 つ共通）。コンポーネントの中身を変えたら上げる（同じ版のまま中身は変えられない）
  RecipeVersion:
    Type: String
    Default: 1.0.0
    Description: イメージのレシピの版。レシピ・コンポーネントの版・親イメージのどれかを変えたら上げる
  ParentImage:
    Type: AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>
    Default: /aws/service/ami-amazon-linux-latest/amzn2-ami-kernel-5.10-hvm-x86_64-gp2
    Description: 親イメージ（Amazon Linux 2、x86_64）の AMI を指す SSM のパラメーター。デプロイした時点の AMI に決まる
  InstanceType:
    Type: String
    Default: t3a.medium
    Description: ビルドとテストに使うインスタンスタイプ（x86_64。本番の t3a に合わせる）
  SubnetId:
    Type: AWS::EC2::Subnet::Id
    Description: 開発用の VPC の、インターネットに出られるサブネット（yum のリポジトリ、GitHub、rubygems.org、cache.ruby-lang.org から取得する）
  SecurityGroupId:
    Type: AWS::EC2::SecurityGroup::Id
    Description: 受信なし、送信は TCP 80・443 を許可したセキュリティグループ
  LogBucketName:
    Type: String
    Default: ""
    Description: ビルドのログを置く S3 バケット。空ならログを S3 に置かない

Conditions:
  HasLogBucket:
    Fn::Not:
      - Fn::Equals:
          - Ref: LogBucketName
          - ""

Resources:
  # ビルド用・テスト用のインスタンスのロール
  InstanceRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Effect: Allow
            Principal:
              Service: ec2.amazonaws.com
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - Fn::Sub: arn:${{AWS::Partition}}:iam::aws:policy/AmazonSSMManagedInstanceCore
        - Fn::Sub: arn:${{AWS::Partition}}:iam::aws:policy/EC2InstanceProfileForImageBuilder
      Policies:
        Fn::If:
          - HasLogBucket
          - - PolicyName: put-build-logs
              PolicyDocument:
                Version: "2012-10-17"
                Statement:
                  - Effect: Allow
                    Action: s3:PutObject
                    Resource:
                      Fn::Sub: arn:${{AWS::Partition}}:s3:::${{LogBucketName}}/image-builder/${{NamePrefix}}/*
          - Ref: AWS::NoValue

  InstanceProfile:
    Type: AWS::IAM::InstanceProfile
    Properties:
      Roles:
        - Ref: InstanceRole

  # Apache・Ruby・Passenger（今のインスタンスと同じ版と置き場所）
  SystemComponent:
    Type: AWS::ImageBuilder::Component
    Properties:
      Name:
        Fn::Sub: ${{NamePrefix}}-system
      Version:
        Ref: ComponentVersion
      Platform: Linux
      SupportedOsVersions:
        - Amazon Linux 2
      Description: Apache, Ruby (rbenv) and Passenger like the current AL2 instances
      Data: |
{ind(system_doc.rstrip(), 8)}

  # 最小の Rails 4.2 のアプリ（コンポーネントの Data は 16,000 文字までなので、システムとアプリで分けている）
  AppComponent:
    Type: AWS::ImageBuilder::Component
    Properties:
      Name:
        Fn::Sub: ${{NamePrefix}}-app
      Version:
        Ref: ComponentVersion
      Platform: Linux
      SupportedOsVersions:
        - Amazon Linux 2
      Description: Minimal Rails 4.2 app served by Apache and Passenger
      Data: |
{ind(app_doc.rstrip(), 8)}

  ImageRecipe:
    Type: AWS::ImageBuilder::ImageRecipe
    Properties:
      Name:
        Ref: NamePrefix
      Version:
        Ref: RecipeVersion
      ParentImage:
        Ref: ParentImage
      Components:
        - ComponentArn:
            Fn::GetAtt:
              - SystemComponent
              - Arn
        - ComponentArn:
            Fn::GetAtt:
              - AppComponent
              - Arn
      AdditionalInstanceConfiguration:
        SystemsManagerAgent:
          UninstallAfterBuild: false

  InfrastructureConfiguration:
    Type: AWS::ImageBuilder::InfrastructureConfiguration
    Properties:
      Name:
        Ref: NamePrefix
      InstanceProfileName:
        Ref: InstanceProfile
      InstanceTypes:
        - Ref: InstanceType
      SubnetId:
        Ref: SubnetId
      SecurityGroupIds:
        - Ref: SecurityGroupId
      TerminateInstanceOnFailure: true
      InstanceMetadataOptions:
        HttpTokens: required
      Logging:
        Fn::If:
          - HasLogBucket
          - S3Logs:
              S3BucketName:
                Ref: LogBucketName
              S3KeyPrefix:
                Fn::Sub: image-builder/${{NamePrefix}}
          - Ref: AWS::NoValue

  DistributionConfiguration:
    Type: AWS::ImageBuilder::DistributionConfiguration
    Properties:
      Name:
        Ref: NamePrefix
      Distributions:
        - Region:
            Ref: AWS::Region
          AmiDistributionConfiguration:
            Name:
              Fn::Sub: "${{NamePrefix}}-{{{{ imagebuilder:buildDate }}}}"
            AmiTags:
              Purpose: port-guard-rollout-test-instance
              Environment: development
              Layer: test-instance
              RecipeVersion:
                Ref: RecipeVersion

  ImagePipeline:
    Type: AWS::ImageBuilder::ImagePipeline
    Properties:
      Name:
        Ref: NamePrefix
      ImageRecipeArn:
        Fn::GetAtt:
          - ImageRecipe
          - Arn
      InfrastructureConfigurationArn:
        Fn::GetAtt:
          - InfrastructureConfiguration
          - Arn
      DistributionConfigurationArn:
        Fn::GetAtt:
          - DistributionConfiguration
          - Arn
      ImageTestsConfiguration:
        ImageTestsEnabled: true
        TimeoutMinutes: 60
      EnhancedImageMetadataEnabled: true
      Status: ENABLED

Outputs:
  ImagePipelineArn:
    Value:
      Fn::GetAtt:
        - ImagePipeline
        - Arn
"""
out = base / "image-builder" / "port-guard-test-al2.yml"
out.write_text(template)
print("system data chars:", len(system_doc), " app data chars:", len(app_doc))
