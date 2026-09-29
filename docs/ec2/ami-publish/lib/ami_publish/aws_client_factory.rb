# frozen_string_literal: true

module AmiPublish
  # AWS SDK for Ruby のクライアントを作る。テストでは client_options に stub_responses: true を渡して差し替える。
  class AwsClientFactory
    def initialize(region:, client_options: {})
      @region = region
      @client_options = client_options
    end

    def ec2
      @ec2 ||= Aws::EC2::Client.new(region: @region, **@client_options)
    end

    def ssm
      @ssm ||= Aws::SSM::Client.new(region: @region, **@client_options)
    end

    def iam
      @iam ||= Aws::IAM::Client.new(region: @region, **@client_options)
    end

    def cloudformation
      @cloudformation ||= Aws::CloudFormation::Client.new(region: @region, **@client_options)
    end
  end
end
