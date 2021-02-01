require 'dockly/util'
require 'dockly/util/tar'
require 'dockly/util/git'
require 'foreman/cli_fix'
require 'foreman/export/base_fix'
require 'minigit'
require 'aws-sdk-core'
require 'aws-sdk-s3'
require 'aws-sdk-ecr'
require 'open3'

module Dockly
  LOAD_FILE = 'dockly.rb'

  class << self
    attr_writer :load_file
  end

  autoload :Foreman, 'dockly/foreman'
  autoload :BashBuilder, 'dockly/bash_builder'
  autoload :BuildCache, 'dockly/build_cache'
  autoload :Docker, 'dockly/docker'
  autoload :Deb, 'dockly/deb'
  autoload :History, 'dockly/history'
  autoload :Rpm, 'dockly/rpm'
  autoload :S3Writer, 'dockly/s3_writer'
  autoload :TarDiff, 'dockly/tar_diff'
  autoload :VERSION, 'dockly/version'

  module_function

  def load_file
    @load_file || LOAD_FILE
  end

  def instance
    @instance ||= load_inst
  end

  def load_inst
    setup.tap do |state|
      if File.exists?(load_file)
        instance_eval(IO.read(load_file), load_file)
      end
    end
  end

  def setup
    {
      :debs => Dockly::Deb.instances,
      :rpms => Dockly::Rpm.instances,
      :dockers => Dockly::Docker.instances,
      :foremans => Dockly::Foreman.instances
    }
  end

  def git_sha
    @git_sha ||= Dockly::Util::Git.sha
  end

  def assume_role(role_name = nil)
    @assume_role = role_name if role_name
    @assume_role
  end

  def perform_role_assumption
    return if assume_role.nil?
    Aws.config.update(
      credentials: Aws::AssumeRoleCredentials.new(
        role_arn: assume_role, role_session_name: 'dockly',
        client: Aws::STS::Client.new(region: aws_region)
      ),
      region: aws_region
    )
  end

  def aws_region(region = nil)
    @aws_region = region unless region.nil?
    @aws_region || 'us-east-1'
  end

  def s3
    @s3 ||= Aws::S3::Client.new(region: aws_region)
  end

  [:debs, :rpms, :dockers, :foremans].each do |method|
    define_method(method) do
      instance[method]
    end

    module_function method
  end

  {
    :deb => Dockly::Deb,
    :rpm => Dockly::Rpm,
    :docker => Dockly::Docker,
    :foreman => Dockly::Foreman
  }.each do |method, klass|
    define_method(method) do |sym, &block|
      if block.nil?
        instance[:"#{method}s"][sym]
      else
        klass.new!(:name => sym, &block)
      end
    end

    module_function method
  end
end

require 'dockly/rake_task'
