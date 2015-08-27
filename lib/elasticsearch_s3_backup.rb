require 'elasticsearch_s3_backup/version'
require 'active_support/time'
require 'unirest'
require 'logger'
require 'pagerduty'
require 'yaml'
require 'sentry-raven'
require 'ostruct'
require 'elasticsearch'

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

    attr_reader :conf, :backup_repo

    def initialize
      @conf = OpenStruct.new(YAML.load_file('/etc/s3_backup.yml'))
      Raven.configure { config.dsn = sentry_dsn } if sentry_dsn

      now                 = Time.new.utc
      @backup_test_index  = "backup_test_#{now.to_i}"
      @restore_test_index = "restore_test_#{now.to_i}"
      @backup_repo        = now.strftime '%m-%Y'
      @snapshot_label     = now.strftime '%m-%d_%H%M'
    end

    def logger
      @logger ||= Logger.new(conf['log']).tap { |l| l.progname = 's3_backup' }
    end

    def pagerduty
      @pagerduty ||= Pagerduty.new pagerduty_api_key
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

    def auth
      File.read(elasticsearch_auth_file).strip
    end

    def es_api
      @es_api ||= begin
        es_host = @conf['es_host'] || 'localhost'
        Elasticsearch::Client.new URI "http://#{auth}@#{es_host}:9200"
      end
    end

    def master?
      es_api.nodes.info['nodes'][es_api.cluster.state['master_node']]['node'] == node_name
    end

    def pseudo_random_string
      'a' + rand(10**100).to_s
    end

    def insert_test_data
      logger.info 'Generating test data using math…'
      test_size.times do |i|
        es_api.create(
          index: @backup_test_index,
          type: 'dummy',
          id: i,
          body: { test_value: pseudo_random_string }
        )
      end
    end

    def create_repo
      new_repo_params = new_repo_params.merge(
        type: 's3',
        settings: {
          base_path: "/elasticsearch/#{cluster_name}/#{conf['env']}/#{@backup_repo}",
          server_side_encryption: true
        }
      )

      logger.info 'Creating a new monthly ES backup repo…'
      es_api.snapshot.create_repository repository: @backup_repo,
                                        body: new_repo_params
    end

    def valid_date?(date)
      # rubocop:disable Style/RescueModifier
      Time.strptime(date, '%m-%Y') rescue false
      # rubocop:enable Style/RescueModifier
    end

    def dated_repos
      es_api.snapshot.get_repository.keys.select { |r| valid_date? r }
    end

    def remove_expired_backups
      # Remove 3 month old repos
      logger.info "Removing backups older than #{3.months.ago.strftime '%m-%Y'}"
      dated_repos.select { |b| Time.strptime(b, '%m-%Y') < 3.months.ago }.each do |repo|
        logger.info "Removing #{repo}"
        es_api.snapshot.delete_repository repository: repo
      end
    end

    def create_snapshot
      # Make a backup (full on new month, incremental otherwise)
      logger.info "Starting a new backup (#{backup_repo}/#{@snapshot_label})…"
      r = es_api.snapshot.create repository: @backup_repo,
                                 snapshot: @snapshot_label,
                                 wait_for_completion: true
      logger.info 'Snapshot complete. Time: ' \
                  "#{r['snapshot']['duration_in_millis']}. " \
                  "Results: #{r['snapshot']['shards'].inspect}"
      fail "Snapshot failed! #{r.inspect}" if r['snapshot']['failures'].any?
    end

    def restore_test_index
      # Restore just the backup_test index to a new index
      logger.info 'Restoring the backup_test index…'
      es_api.snapshot.restore repository: @backup_repo,
                              snapshot: @snapshot_label,
                              wait_for_completion: true,
                              body: {
                                indices: @backup_test_index,
                                rename_pattern: @backup_test_index,
                                rename_replacement: @restore_test_index
                              }
    end

    def index_item(index, id)
      es_api.get(index: index, type: 'dummy', id: id)['_source']['test_value']
    end

    def compare_index_item!(i)
      backup_item  = index_item(@backup_test_index, i)
      restore_item = index_item(@restore_test_index, i)

      (backup_item == restore_item) ||
        fail("Item #{i} in test restore doesn’t match.\n" \
             "Original: #{backup_item}\n" \
             "Restored: #{restore_item}")
    end

    def delete_test_indexes
      [@restore_test_index, @backup_test_index].each do |test_index|
        es_api.indices.delete index: test_index
      end
    end

    # rubocop:disable Metrics/AbcSize, Lint/RescueException
    def run
      unless master?
        logger.info 'This node is not the currently elected master. Exiting.'
        exit 0
      end

      insert_test_data

      # Create a new repo if none exists (typically at beginning of month)
      create_repo unless es_api.snapshot.get_repository[backup_repo]
      create_snapshot
      restore_test_index
      # Compare each doc in the original backup_test index to the restored index
      logger.info "Verifying the newly-restored #{@backup_test_index}…"
      test_size.times { |i| compare_index_item! i }
      logger.info 'Successfully verified the test data!'
      delete_test_indexes

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
