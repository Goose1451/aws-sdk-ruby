require 'base64'
require 'tempfile'
require 'fileutils'
require 'net/https'
require 'net/http/post/multipart'
require 'uri'

Before("@s3") do
  @s3 = Aws::S3::Resource.new
  @created_buckets = []
end

After("@s3") do
  @created_buckets.each do |bucket|
    bucket.delete!
  end
end

Given(/^I create a bucket$/) do
  @bucket_name = "aws-sdk-resources-#{Time.now.to_i}-#{rand(1000)}"
  @bucket = @s3.create_bucket(bucket: @bucket_name)
  @s3.client.wait_until(:bucket_exists, bucket: @bucket_name)
  @created_buckets << @bucket
end

Given(/^I have a (\d+)MB file$/) do |size|
  @file = Tempfile.new('tempfile')
  @file.write('.' * size.to_i * 1024 * 1024)
  @file.rewind
end

When(/^I upload the file to the "(.*?)" object$/) do |key|
  @bucket.object(key).upload_file(@file)
end

When(/^I upload the file$/) do
  @object = @bucket.object(@file.path)
  @object.upload_file(@file)
end

When(/^I upload the file to the "(.*?)" object with SSE\/CPK$/) do |key|
  require 'openssl'
  cipher = OpenSSL::Cipher::AES256.new(:CBC)
  ecnryption_key = cipher.random_key
  @bucket.object(key).upload_file(@file, {
    sse_customer_key: ecnryption_key,
    sse_customer_algorithm: 'AES256'
  })
  @bucket.object(key).upload_file(@file)
end

Then(/^the file should have been uploaded as a multipart upload$/) do
  expect(ApiCallTracker.called_operations).to include(:create_multipart_upload)
end

Given(/^I have an encryption client$/) do
  @cse = Aws::S3::Encryption::Client.new({
    client: @s3.client,
    encryption_key: Base64.decode64("w1WLio3agRWRTSJK/Ouh8NHoqRQ6fn5WbSXDTHjXMSo="),
  })
end

Given(/^I have an encryption client configured to use KMS$/) do
  @cse = Aws::S3::Encryption::Client.new({
    client: @s3.client,
    kms_key_id: @kms_key_id,
  })
end

Given(/^I have an encryption client configured for :instruction_file$/) do
  @cse = Aws::S3::Encryption::Client.new({
    client: @s3.client,
    encryption_key: Base64.decode64("w1WLio3agRWRTSJK/Ouh8NHoqRQ6fn5WbSXDTHjXMSo="),
    envelope_location: :instruction_file,
  })
end

When(/^I perform an encrypted PUT of the value "(.*?)"$/) do |value|
  @key = 'encrypted'
  @plain_text = value
  @cse.put_object(bucket: @bucket_name, key: @key, body: @plain_text)
end

When(/^I GET the object with a non\-encryption client$/) do
  @cipher_text = @s3.client.get_object(bucket: @bucket_name, key: @key).body.read
end

Then(/^the object data should be encrypted$/) do
  expect(@cipher_text).not_to eq(@plain_text)
end

When(/^I GET the object with an encryption client$/) do
  @plain_text = @cse.get_object(bucket: @bucket_name, key: @key).body.read
end

Then(/^the object data should be "(.*?)"$/) do |value|
  expect(@plain_text).to eq(value)
end

Then(/^the instruction file should exist$/) do
  expect {
    @s3.client.head_object(bucket: @bucket_name, key: @key + '.instruction')
  }.not_to raise_error
end

When(/^I create a presigned post$/) do
  @post = @bucket.object('key').presigned_post({
    success_action_status: '201',
  })
end

Then(/^I should be able to POST an object to the form url$/) do
  uri = URI.parse(@post.url)
  req = Net::HTTP::Post::Multipart.new(uri.request_uri, @post.fields.merge(
    "file" => UploadIO.new(File.open(__FILE__, 'r'), 'text/plain')
  ))
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.verify_mode = OpenSSL::SSL::VERIFY_PEER
  resp = http.request(req)
  expect(resp.code.to_i).to eq(201)
end

Given(/^I have an encryption client configured to read a Java encrypted object$/) do
  step('a "kms_key_id" is set in cfg["java_cse_kms"]["kms_key_id"]')
  step('a "profile" is set in cfg["java_cse_kms"]["profile"]')
  step('a "bucket_name" is set in cfg["java_cse_kms"]["bucket_name"]')
  step('a "key" is set in cfg["java_cse_kms"]["key"]')
  @cse = Aws::S3::Encryption::Client.new(
    profile: @profile,
    kms_key_id: @kms_key_id,
  )
end

Then(/^I should be able to multipart copy the object to a different bucket$/) do
  target_bucket = @s3.bucket(@bucket_name)
  target_object = target_bucket.object("#{@source_key}-copy")
  target_object.copy_from("#{@source_bucket}/#{@source_key}", multipart_copy: true)
  expect(ApiCallTracker.called_operations).to include(:create_multipart_upload)
end

Then(/^I should be able to multipart copy the object$/) do
  target_bucket = @s3.bucket(@bucket_name)
  target_object = target_bucket.object("test object-copy")
  target_object.copy_from("#{@bucket_name}/test object", multipart_copy: true)
  expect(ApiCallTracker.called_operations).to include(:create_multiparty_upload)
end

Given(/^I have a (\d+)M file$/) do |mb|
  @file = Tempfile.new('randomfile')
  File.open(@file, 'wb') {
    |f| f.write(Random.new.bytes(mb.to_i * 1024 * 1024))}
end

Given(/^I upload the file using put_object$/) do
  @object = @s3.bucket(@bucket_name).object(@file.path)
  @object.put(body: @file)
end

Then(/^(\d+) (\w+) requests? should have been made$/) do |expected_count, method_name|
  expect(
    ApiCallTracker.called_operations.count { |name| method_name.to_sym == name }
  ).to eq(expected_count.to_i)
end

Then(/^the downloaded file should match the uploaded file$/) do
  expect(FileUtils.compare_file(@file.path, @download_file_dest)).to be(true)
end

When(/^I download the file with mode "([^"]*)"$/) do |mode|
  # create a temp directory for download
  tempfile = Tempfile.new("sample")
  @download_file_dest = tempfile.path
  tempfile.unlink

  @object.download_file(@download_file_dest, mode: mode)
end

When(/^I download the file with mode "([^"]*)" with (\d+)M chunk size$/) do |mode, mb|
  tempfile = Tempfile.new("sample")
  @download_file_dest = tempfile.path
  tempfile.unlink

  @object.download_file(@download_file_dest, mode: mode, chunk_size: (mb.to_i * 1024 *1024))
end

Then(/^this test file has been cleaned up$/) do
  File.unlink(@download_file_dest)
  expect(File.exist?(@download_file_dest)).to be(false)
end

When(/^I download the file (\d+) times with mode "([^"]*)" with (\d+)M chunk size$/) do |cnt, mode, mb|
  @download_dest = []
  (1..cnt.to_i).each do |e|
    tempfile = Tempfile.new("sample_#{e}")
    @download_dest << tempfile.path
    tempfile.unlink
  end

  (1..cnt.to_i)
    .map { |c| Thread.new { @object.download_file(@download_dest[c - 1], mode: mode, chunk_size: (mb.to_i * 1024 *1024)) } }
    .each(&:join)
end

Then(/^those downloaded files should match the uploaded file$/) do
  @download_dest.each do |download|
    expect(FileUtils.compare_file(@file.path, download)).to be(true)
  end
end

Then(/^these test file has been cleaned up$/) do
  @download_dest.each do |file|
    File.unlink(file)
    expect(File.exist?(file)).to be(false)
  end
end
