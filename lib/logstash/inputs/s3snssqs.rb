# encoding: utf-8
#
require "logstash/inputs/threadable"
require "logstash/namespace"
require "logstash/timestamp"
require "logstash/plugin_mixins/aws_config"
require "logstash/errors"
require 'logstash/inputs/s3sqs/patch'
require "aws-sdk"
require "stud/interval"
require 'cgi'
require 'logstash/inputs/mime/MagicgzipValidator'

require 'java'
java_import java.io.InputStream
java_import java.io.InputStreamReader
java_import java.io.FileInputStream
java_import java.io.BufferedReader
java_import java.util.zip.GZIPInputStream
java_import java.util.zip.ZipException

Aws.eager_autoload!

# Get logs from AWS s3 buckets as issued by an object-created event via sqs.
#
# This plugin is based on the logstash-input-sqs plugin but doesn't log the sqs event itself.
# Instead it assumes, that the event is an s3 object-created event and will then download
# and process the given file.
#
# Some issues of logstash-input-sqs, like logstash not shutting down properly, have been
# fixed for this plugin.
#
# In contrast to logstash-input-sqs this plugin uses the "Receive Message Wait Time"
# configured for the sqs queue in question, a good value will be something like 10 seconds
# to ensure a reasonable shutdown time of logstash.
# Also use a "Default Visibility Timeout" that is high enough for log files to be downloaded
# and processed (I think a good value should be 5-10 minutes for most use cases), the plugin will
# avoid removing the event from the queue if the associated log file couldn't be correctly
# passed to the processing level of logstash (e.g. downloaded content size doesn't match sqs event).
#
# This plugin is meant for high availability setups, in contrast to logstash-input-s3 you can safely
# use multiple logstash nodes, since the usage of sqs will ensure that each logfile is processed
# only once and no file will get lost on node failure or downscaling for auto-scaling groups.
# (You should use a "Message Retention Period" >= 4 days for your sqs to ensure you can survive
# a weekend of faulty log file processing)
# The plugin will not delete objects from s3 buckets, so make sure to have a reasonable "Lifecycle"
# configured for your buckets, which should keep the files at least "Message Retention Period" days.
#
# A typical setup will contain some s3 buckets containing elb, cloudtrail or other log files.
# These will be configured to send object-created events to a sqs queue, which will be configured
# as the source queue for this plugin.
# (The plugin supports gzipped content if it is marked with "contend-encoding: gzip" as it is the
# case for cloudtrail logs)
#
# The logstash node therefore must have sqs permissions + the permissions to download objects
# from the s3 buckets that send events to the queue.
# (If logstash nodes are running on EC2 you should use a ServerRole to provide permissions)
# [source,json]
#   {
#       "Version": "2012-10-17",
#       "Statement": [
#           {
#               "Effect": "Allow",
#               "Action": [
#                   "sqs:Get*",
#                   "sqs:List*",
#                   "sqs:ReceiveMessage",
#                   "sqs:ChangeMessageVisibility*",
#                   "sqs:DeleteMessage*"
#               ],
#               "Resource": [
#                   "arn:aws:sqs:us-east-1:123456789012:my-elb-log-queue"
#               ]
#           },
#           {
#               "Effect": "Allow",
#               "Action": [
#                   "s3:Get*",
#                   "s3:List*",
#                   "s3:DeleteObject"
#               ],
#               "Resource": [
#                   "arn:aws:s3:::my-elb-logs",
#                   "arn:aws:s3:::my-elb-logs/*"
#               ]
#           }
#       ]
#   }
#
class LogStash::Inputs::S3SNSSQS < LogStash::Inputs::Threadable
  include LogStash::PluginMixins::AwsConfig::V2

  BACKOFF_SLEEP_TIME = 1
  BACKOFF_FACTOR = 2
  MAX_TIME_BEFORE_GIVING_UP = 60
  EVENT_SOURCE = 'aws:s3'
  EVENT_TYPE = 'ObjectCreated'

  config_name "s3snssqs"

  default :codec, "plain"

  # Name of the SQS Queue to pull messages from. Note that this is just the name of the queue, not the URL or ARN.
  config :queue, :validate => :string, :required => true
  config :s3_key_prefix, :validate => :string, :default => ''
  #Sometimes you need another key for s3. This is a first test...
  config :s3_access_key_id, :validate => :string
  config :s3_secret_access_key, :validate => :string
  config :delete_on_success, :validate => :boolean, :default => false
  config :sqs_explicit_delete, :validate => :boolean, :default => false
  # Whether the event is processed though an SNS to SQS. (S3>SNS>SQS = true |S3>SQS=false)
  config :from_sns, :validate => :boolean, :default => true
  # To run in multiple threads use this
  config :consumer_threads, :validate => :number
  config :temporary_directory, :validate => :string, :default => File.join(Dir.tmpdir, "logstash")
  # The AWS IAM Role to assume, if any.
  # This is used to generate temporary credentials typically for cross-account access.
  # See https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRole.html for more information.
  config :s3_role_arn, :validate => :string
  # Session name to use when assuming an IAM role
  config :s3_role_session_name, :validate => :string, :default => "logstash"
  config :visibility_timeout, :validate => :number, :default => 600


  attr_reader :poller
  attr_reader :s3


  def set_codec (folder)
    begin
      @logger.debug("Automatically switching from #{@codec.class.config_name} to #{set_codec_by_folder[folder]} codec", :plugin => self.class.config_name)
      LogStash::Plugin.lookup("codec", "#{set_codec_by_folder[folder]}").new("charset" => @codec.charset)
    rescue Exception => e
      @logger.error("Failed to set_codec with error", :error => e)
    end
  end

  public
  def register
    require "fileutils"
    require "digest/md5"
    require "aws-sdk-resources"

    @runner_threads = []
    @logger.info("Registering SQS input", :queue => @queue)
    setup_queue

    FileUtils.mkdir_p(@temporary_directory) unless Dir.exist?(@temporary_directory)
  end

  def setup_queue
    aws_sqs_client = Aws::SQS::Client.new(aws_options_hash)
    queue_url = aws_sqs_client.get_queue_url({ queue_name: @queue })[:queue_url]
    @poller = Aws::SQS::QueuePoller.new(queue_url, :client => aws_sqs_client)
    get_s3client
    @s3_resource = get_s3object
  rescue Aws::SQS::Errors::ServiceError => e
    @logger.error("Cannot establish connection to Amazon SQS", :error => e)
    raise LogStash::ConfigurationError, "Verify the SQS queue name and your credentials"
  end

  def polling_options
    {
        # we will query 1 message at a time, so we can ensure correct error handling if we can't download a single file correctly
        # (we will throw :skip_delete if download size isn't correct to process the event again later
        # -> set a reasonable "Default Visibility Timeout" for your queue, so that there's enough time to process the log files)
        :max_number_of_messages => 1,
        # we will use the queue's setting, a good value is 10 seconds
        # (to ensure fast logstash shutdown on the one hand and few api calls on the other hand)
        :skip_delete => false,
        :visibility_timeout => @visibility_timeout,
        :wait_time_seconds => nil,
    }
  end

  def handle_message(message, queue, instance_codec)
    hash = JSON.parse message.body
    @logger.debug("handle_message", :hash => hash, :message => message)
    #If send via sns there is an additional JSON layer
    if @from_sns then
      hash = JSON.parse(hash['Message'])
    end
    # there may be test events sent from the s3 bucket which won't contain a Records array,
    # we will skip those events and remove them from queue
    if hash['Records'] then
      # typically there will be only 1 record per event, but since it is an array we will
      # treat it as if there could be more records
      hash['Records'].each do |record|
        @logger.debug("We found a record", :record => record)
        # in case there are any events with Records that aren't s3 object-created events and can't therefore be
        # processed by this plugin, we will skip them and remove them from queue
        if record['eventSource'] == EVENT_SOURCE and record['eventName'].start_with?(EVENT_TYPE) then
          @logger.debug("It is a valid record")
          bucket = CGI.unescape(record['s3']['bucket']['name'])
          key    = CGI.unescape(record['s3']['object']['key'])
          size   = record['s3']['object']['size']
          folder = get_object_folder(key)
          # try download and :skip_delete if it fails
          process_s3_file(bucket, key, folder, instance_codec, queue, message, size)
        end
      end
    end
  end

  private
  def process_s3_file(bucket , key, folder, instance_codec, queue, message, size)
    s3bucket = @s3_resource.bucket(bucket)
    @logger.debug("Lets go reading file", :bucket => bucket, :key => key)
    object = s3bucket.object(key)
    filename = File.join(temporary_directory, File.basename(key))
    if download_remote_file(object, filename)
      if process_local_file( filename, key, folder, instance_codec, queue, bucket, message, size)
        begin
          FileUtils.remove_entry_secure(filename, true) if File.exists? filename
          delete_file_from_bucket(object)
        rescue Exception => e
          @logger.debug("We had problems to delete your file", :file => filename, :error => e)
        end
      end
    else
      begin
        FileUtils.remove_entry_secure(filename, true) if File.exists? filename
      rescue Exception => e
        @logger.debug("We had problems clean up your tmp dir", :file => filename, :error => e)
      end
    end
  end

  private
  # Stream the remove file to the local disk
  #
  # @param [S3Object] Reference to the remove S3 objec to download
  # @param [String] The Temporary filename to stream to.
  # @return [Boolean] True if the file was completely downloaded
  def download_remote_file(remote_object, local_filename)
    completed = false
    @logger.debug("S3 input: Download remote file", :remote_key => remote_object.key, :local_filename => local_filename)
    File.open(local_filename, 'wb') do |s3file|
      return completed if stop?
      begin
        remote_object.get(:response_target => s3file)
      rescue Aws::S3::Errors::ServiceError => e
        @logger.error("Unable to download file. We´ll requeue the message", :file => remote_object.inspect)
        throw :skip_delete
      end
    end
    completed = true

    return completed
  end

  private

  # Read the content of the local file
  #
  # @param [Queue] Where to push the event
  # @param [String] Which file to read from
  # @return [Boolean] True if the file was completely read, false otherwise.
  def process_local_file(filename, key, folder, instance_codec, queue, bucket, message, size)
    @logger.debug('Processing file', :filename => filename)
    start_time = Time.now
    # Currently codecs operates on bytes instead of stream.
    # So all IO stuff: decompression, reading need to be done in the actual
    # input and send as bytes to the codecs.
    read_file(filename) do |line|
      if (Time.now - start_time) >= (@visibility_timeout.to_f / 100.0 * 90.to_f)
        @logger.info("Increasing the visibility_timeout ... ", :timeout => @visibility_timeout, :filename => filename, :filesize => size, :start => start_time )
        poller.change_message_visibility_timeout(message, @visibility_timeout)
        start_time = Time.now
      end
      if stop?
        @logger.warn("Logstash S3 input, stop reading in the middle of the file, we will read it again when logstash is started")
        return false
      end
      line = line.encode('UTF-8', 'binary', invalid: :replace, undef: :replace, replace: "\u2370")
      #@logger.debug("read line", :line => line)
      instance_codec.decode(line) do |event|
        @logger.debug("decorate event")
        # The line need to go through the codecs to replace
        # unknown bytes in the log stream before doing a regexp match or
        # you will get a `Error: invalid byte sequence in UTF-8'
        local_decorate_and_queue(event, queue, key, folder, bucket)
      end
    end
    @logger.debug("end if file #{filename}")
    #@logger.info("event pre flush", :event => event)
    # #ensure any stateful codecs (such as multi-line ) are flushed to the queue
    instance_codec.flush do |event|
      local_decorate_and_queue(event, queue, key, folder, bucket)
      @logger.debug("We´e to flush an incomplete event...", :event => event)
    end

    return true
  end # def process_local_file

  private
  def local_decorate_and_queue(event, queue, key, folder, bucket)
    @logger.debug('decorating event', :event => event.to_s)
	decorate(event)

	event.set("[@metadata][s3][object_key]", key)
	event.set("[@metadata][s3][bucket_name]", bucket)
	event.set("[@metadata][s3][object_folder]", folder)
	@logger.debug('add metadata', :object_key => key, :bucket => bucket, :folder => folder)
	queue << event
  end


  private
  def get_object_folder(key)
    if match=/#{s3_key_prefix}\/?(?<type_folder>.*?)\/.*/.match(key)
      return match['type_folder']
    else
      return ""
    end
  end

  private
  def read_file(filename, &block)
    if gzip?(filename)
      read_gzip_file(filename, block)
    else
      read_plain_file(filename, block)
    end
  end

  def read_plain_file(filename, block)
    File.open(filename, 'rb') do |file|
      file.each(&block)
    end
  end

  private
  def read_gzip_file(filename, block)
    file_stream = FileInputStream.new(filename)
    gzip_stream = GZIPInputStream.new(file_stream)
    decoder = InputStreamReader.new(gzip_stream, "UTF-8")
    buffered = BufferedReader.new(decoder)

    while (line = buffered.readLine())
      block.call(line)
    end
  rescue ZipException => e
    @logger.error("Gzip codec: We cannot uncompress the gzip file", :filename => filename, error => e)
  ensure
    buffered.close unless buffered.nil?
    decoder.close unless decoder.nil?
    gzip_stream.close unless gzip_stream.nil?
    file_stream.close unless file_stream.nil?
  end

  private
  def gzip?(filename)
    return true if filename.end_with?('.gz','.gzip')
    MagicGzipValidator.new(File.new(filename, 'r')).valid?
  rescue Exception => e
    @logger.debug("Problem while gzip detection", :error => e)
  end

  private
  def delete_file_from_bucket(object)
    if @delete_on_success
      object.delete()
    end
  end


  private
  def get_s3client
    if s3_access_key_id and s3_secret_access_key
      @logger.debug("Using S3 Credentials from config", :ID => aws_options_hash.merge(:access_key_id => s3_access_key_id, :secret_access_key => s3_secret_access_key) )
      @s3_client = Aws::S3::Client.new(aws_options_hash.merge(:access_key_id => s3_access_key_id, :secret_access_key => s3_secret_access_key))
    elsif @s3_role_arn
      @s3_client = Aws::S3::Client.new(aws_options_hash.merge!({ :credentials => s3_assume_role }))
      @logger.debug("Using S3 Credentials from role", :s3client => @s3_client.inspect, :options => aws_options_hash.merge!({ :credentials => s3_assume_role }))
    else
      @s3_client = Aws::S3::Client.new(aws_options_hash)
    end
  end

  private
  def get_s3object
    s3 = Aws::S3::Resource.new(client: @s3_client)
  end

  private
  def s3_assume_role()
    Aws::AssumeRoleCredentials.new(
        client: Aws::STS::Client.new(region: @region),
        role_arn: @s3_role_arn,
        role_session_name: @s3_role_session_name
    )
  end

  public
  def run(queue)
    if @consumer_threads
      # ensure we can stop logstash correctly
      @runner_threads = consumer_threads.times.map { |consumer| thread_runner(queue) }
      @runner_threads.each { |t| t.join }
    else
      #Fallback to simple single thread worker
      # ensure we can stop logstash correctly
      poller.before_request do |stats|
        if stop? then
          @logger.warn("issuing :stop_polling on stop?", :queue => @queue)
          # this can take up to "Receive Message Wait Time" (of the sqs queue) seconds to be recognized
          throw :stop_polling
        end
      end
      # poll a message and process it
      run_with_backoff do
        poller.poll(polling_options) do |message|
          begin
            handle_message(message, queue, @codec.clone)
            poller.delete_message(message)
          rescue Exception => e
            @logger.info("Error in poller block ... ", :error => e)
          end
        end
      end
    end
  end

  public
  def stop
    if @consumer_threads
      @runner_threads.each do |c|
        begin
          @logger.info("Stopping thread ... ", :thread => c.inspect)
          c.wakeup
        rescue
          @logger.error("Cannot stop thread ... try to kill him", :thread => c.inspect)
          c.kill
        end
      end
    else
      @logger.warn("Stopping all threads?", :queue => @queue)
    end
  end

  private
  def thread_runner(queue)
    Thread.new do
      @logger.info("Starting new thread")
      begin
        poller.before_request do |stats|
          if stop? then
            @logger.warn("issuing :stop_polling on stop?", :queue => @queue)
            # this can take up to "Receive Message Wait Time" (of the sqs queue) seconds to be recognized
            throw :stop_polling
          end
        end
        # poll a message and process it
        run_with_backoff do
          poller.poll(polling_options) do |message|
            begin
              handle_message(message, queue, @codec.clone)
              poller.delete_message(message) if @sqs_explicit_delete
            rescue Exception => e
              @logger.info("Error in poller block ... ", :error => e)
            end
          end
        end
      end
    end
  end

  private
  # Runs an AWS request inside a Ruby block with an exponential backoff in case
  # we experience a ServiceError.
  #
  # @param [Integer] max_time maximum amount of time to sleep before giving up.
  # @param [Integer] sleep_time the initial amount of time to sleep before retrying.
  # @param [Block] block Ruby code block to execute.
  def run_with_backoff(max_time = MAX_TIME_BEFORE_GIVING_UP, sleep_time = BACKOFF_SLEEP_TIME, &block)
    next_sleep = sleep_time
    begin
      block.call
      next_sleep = sleep_time
    rescue Aws::SQS::Errors::ServiceError => e
      @logger.warn("Aws::SQS::Errors::ServiceError ... retrying SQS request with exponential backoff", :queue => @queue, :sleep_time => sleep_time, :error => e)
      sleep(next_sleep)
      next_sleep =  next_sleep > max_time ? sleep_time : sleep_time * BACKOFF_FACTOR
      retry
    end
  end
end # class
