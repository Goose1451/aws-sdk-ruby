require 'aws-sdk-code-generator'
require 'build_tools'
require 'fileutils'
require 'json'

services = BuildTools::Services.new
services.identifiers.each do |svc_id|
  desc "Builds the code for Aws::#{services.name(svc_id)}"
  task "build:#{svc_id}" do

    options = {}
    options[:module_names] = ['Aws', services.name(svc_id)]
    services.model_paths(svc_id).each do |option, path|
      options[option] = JSON.load(File.read(path))
    end

    prefix = "aws-sdk-core/#{svc_id}"
    generator = AwsSdkCodeGenerator::Generator.new(options)
    generator.generate_src_files(autoload_prefix: prefix).each do |path, contents|
      path = File.join('aws-sdk-core/lib', path)
      puts path
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, 'wb') do |file|
        file.write(contents)
      end
    end
  end
  task 'build' => "build:#{svc_id}"
end