require 'elasticsearch_s3_backup/version'
require 'active_support/time'
require 'unirest'
require 'logger'
require 'faker'
require 'pagerduty'
require 'yaml'
require 'sentry-raven'
require 'ostruct'

module EverTools
  class ElasticsearchS3Backup
    extend Forwardable

    def_delegators :@conf,
                   :pagerduty_api_key,
                   :test_size,
                   :new_repo_params,
                   :sentry_dsn,
                   :node_name,
                   :elasticsearch_auth_file,
                   :cluster_name

    attr_reader :conf

    def pagerduty
      @pagerduty ||= Pagerduty.new pagerduty_api_key
    end

    def auth
      @auth ||= File.read(elasticsearch_auth_file).strip.split ':'
    end

    def initialize
      @conf = OpenStruct.new(YAML.load_file('/etc/s3_backup.yml'))
      Raven.configure { config.dsn = sentry_dsn } if sentry_dsn

      Unirest.default_header 'Accept', 'application/json'
      Unirest.default_header 'Content-Type', 'application/json'
      Unirest.timeout 30

      @url = 'http://localhost:9200'

      test_backup_timestamp = Time.now.to_i
      @backup_index  = "backup_test_#{test_backup_timestamp}"
      @restore_index = "restore_test_#{test_backup_timestamp}"

      now       = Time.new.utc
      @monthly  = now.strftime '%m-%Y'
      @datetime = now.strftime '%m-%d_%H%M'

      @monthly_snap_url = [@url, '_snapshot', @monthly].join('/')

      @backup_timeout = 1.hour
    end

    def logger
      @logger ||= Logger.new(@conf['log']).tap do |l|
        l.level = Logger::INFO
        l.progname = 's3_backup'
        l.formatter = proc do |severity, datetime, progname, msg|
          "#{datetime.utc} [#{progname}] #{severity}: #{msg}\n"
        end
      end
    end

    # rubocop:disable Metrics/AbcSize
    def es_api(method, uri, params = {})
      tries = 3
      begin
        r = Unirest.send(method, uri, params)
        case r.code
        when 200..299
          return r
        when 400..499
          logger.debug "#{method} request to #{uri} received #{r.code} (params: #{params.inspect})\n" \
                      "Body:\n" \
                      "#{r.body}\n"
          return r
        end
        # byebug
        fail "#{method.upcase} request to #{uri} failed (params: #{params.inspect})\n" \
             "Response code: #{r.code}\n" \
             "Body:\n" \
             "#{r.body}\n"
      rescue RuntimeError => e
        tries -= 1
        retry if e.message == 'Request Timeout' && tries > 0
        raise e
      end
    end
    # rubocop:enable Metrics/AbcSize

    def master?
      es_api(:get, "#{@url}/_cat/master").body[0]['node'] == node_name
    end

    # Check if an index exists
    def index?(uri)
      es_api(:get, "#{@url}/#{uri}").code == 200
    end

    # Check if a backup repo exists
    def repo?
      es_api(:get, @monthly_snap_url).code == 200
    end

    def notify(e)
      if conf['env'] == 'prod'
        pagerduty.trigger(
          'prod Elasticsearch S3 failed',
          client: node_name,
          details: "#{e.message}\n\n#{e.backtrace}"
        )
      end

      Raven.capture_exception(e) if sentry_dsn
    end

    def insert_test_data
      # Generate some test data using Faker
      #
      # Uses Bitcoin addresses for their random, hash-like nature
      # Creates the `backup_test` index if necessary
      # Updates the set of `dummy` documents in the `backup_test` on every run

      logger.info 'Generating test data using Faker…'
      test_size.times do |i|
        es_api(
          :put,
          "#{@url}/#{@backup_index}/dummy/#{i}",
          parameters: {
            test_value: Faker::Bitcoin.address
          }.to_json
        )
      end
    end

    def delete_index(index)
      logger.info "Deleting index: #{index}"
      es_api(
        :delete,
        "#{@url}/#{index}",
        auth: { user: auth.first, password: auth.last }
      )
    end

    def create_repo
      new_repo_params = new_repo_params.merge(
        type: 's3',
        settings: {
          base_path: "/elasticsearch/#{cluster_name}/#{conf['env']}/#{@monthly}",
          server_side_encryption: true
        }
      )

      logger.info 'Creating a new monthly ES backup repo…'
      es_api(
        :put,
        @monthly_snap_url,
        parameters: new_repo_params.to_json
      )
    end

    def valid_date?(date)
      Time.strptime(date, '%m-%Y') rescue false
    end

    def dated_repos
      es_api(:get, "#{@url}/_snapshot").body.keys.select { |r| valid_date? r }
    end

    def remove_expired_backups
      # Remove 3 month old repos
      logger.info "Removing backups older than #{3.months.ago.strftime '%m-%Y'}"
      dated_repos.select { |b| Time.strptime(b, '%m-%Y') < 3.months.ago }.each do |repo|
        logger.info "Removing #{repo}"
        es_api :delete, "#{@url}/_snapshot/#{repo}"
      end
    end

    # rubocop:disable Metrics/AbcSize
    def snapshot
      backup_uri = "#{@monthly_snap_url}/#{@datetime}"
      status_req = es_api :get, "#{backup_uri}/_status"
      if status_req.code == 404 ||
         status_req.body['snapshots'].empty?
        fail "Could not find the backup I just created (#{backup_uri})"
      end
      snapshot = status_req.body['snapshots'].first
      logger.info "Backup state: #{snapshot['state']} " \
                  "(finished shard #{snapshot['shards_stats']['done']} of " \
                  "#{snapshot['shards_stats']['total']})"
    end
    # rubocop:enable Metrics/AbcSize

    def backup_complete?
      case snapshot['state']
      when 'IN_PROGRESS', 'STARTED'
        return false
      when 'SUCCESS'
        return true
      end
      fail "Backup failed!\n" \
           "State: #{snapshot['state']}\n" \
           "Response Body: #{status_req.body}"
    end

    def verify_create!
      # Check the status of the backup for up to an hour
      backup_start_time = Time.now.utc
      until Time.now.utc > (backup_start_time + @backup_timeout)
        return true if backup_complete?
        # Don't hammer the status endpoint
        sleep 15
      end

      fail 'Create timed out'
    end

    def make_new_backup
      # Make a backup (full on new month, incremental otherwise)
      logger.info "Starting a new backup (#{@monthly_snap_url}/#{@datetime})…"
      es_api :put, "#{@monthly_snap_url}/#{@datetime}"

      # Give the new backup time to show up
      sleep 5

      verify_create!
    end

    def restore_test_index
      # Restore just the backup_test index to a new index
      logger.info 'Restoring the backup_test index…'
      es_api(
        :post,
        "#{@monthly_snap_url}/#{@datetime}/_restore",
        parameters: {
          indices: @backup_index,
          rename_pattern: @backup_index,
          rename_replacement: @restore_index
        }.to_json
      )
      verify_restored_index!
    end

    def index_shards(index)
      r = es_api(:get, "#{@url}/#{index}/_status")
      fail "Index #{index} not found" if r.code == 404
      r.body.fetch('indices', {}).fetch(index, {})['shards']
    end

    def index_online?(index)
      shards = index_shards(index)
      shards && shards.select { |_k, v| v.find { |n| n['state'] != 'STARTED' } }.empty?
    end

    def index_item(index, id)
      es_api(:get, "#{@url}/#{index}/dummy/#{id}").body
    end

    def wait_for_index(index)
      until index_online? index
        logger.info 'Waiting for restored index to be available…'
        sleep 1
      end
    end

    def compare_index_item!(i)
      # Loop until the restored version is available
      until index_item(@restore_index, i)['found']
        logger.info 'Waiting for restored index to be available…'
        sleep 1
      end

      backup_item  = index_item(@backup_index, i)['_source']['test_value']
      restore_item = index_item(@restore_index, i)['_source']['test_value']

      (backup_item == restore_item) ||
        fail("Item #{i} in test restore doesn’t match.\n" \
             "Original: #{backup_item}\n" \
             "Restored: #{restore_item}")
    end

    def verify_restored_index!
      # Compare each doc in the original backup_test index to the restored index

      logger.info "Verifying the newly-restored #{@backup_index}…"
      wait_for_index @restore_index

      test_size.times { |i| compare_index_item! i }

      logger.info 'Successfully verified the test data!'
    end

    # rubocop:disable Metrics/AbcSize, Lint/RescueException
    def run
      unless master?
        logger.info 'This node is not the currently elected master, aborting ' \
                    'backup.'
        exit 0
      end

      # Remove the previous `restore_test` index, to avoid a race condition
      # with checking the restored copy of this index
      delete_index @restore_index if index? @restore_index

      insert_test_data

      # Create a new repo if none exists (typically at beginning of month)
      create_repo unless repo?
      make_new_backup
      restore_test_index

      remove_expired_backups
      logger.info 'Finished'
    rescue Exception => e # Need to rescue "Exception" so that Sentry gets it
      notify e
      logger.fatal e.message
      logger.fatal e.backtrace
      raise e
    end
    # rubocop:enable Metrics/AbcSize, Lint/RescueException
  end
end
