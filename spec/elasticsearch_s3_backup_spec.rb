require 'spec_helper'

describe EverTools::ElasticsearchS3Backup do
  it 'has a version number' do
    expect(EverTools::ElasticsearchS3Backup::VERSION).not_to be nil
  end

  let(:node_name) { 'test_node' }

  let(:ets3b) do
    conf = {
      'env' => 'dev',
      'pagerduty_api_key' => 'BOGUS_API_KEY',
      'test_size' => 100,
      'log' => './s3_backup.log',
      'new_repo_params' => {
        'bucket' => 'backups.s3.bucket',
        'max_snapshot_bytes_per_sec' => '100mb',
        'max_restore_bytes_per_sec' => '500mb'
      },
      'node_fqdn' => 'spec-test-node',
      'cluster_name' => 'spec_test_cluster'
    }

    allow(YAML).to receive(:load_file).with(any_args).and_return(conf)

    e = EverTools::ElasticsearchS3Backup.new

    allow(e).to receive(:pagerduty).and_return(
      object_double(
        'pagerduty',
        trigger: true
      )
    )

    e
  end

  # describe '.logger' do
  # end

  describe '.master?' do
    let(:master_node_id) { 'AbCdEfGh012345' }
    let(:nodes_object) do
      object_double(
        'nodes_object',
        info: {
          'nodes' => {
            master_node_id => {
              'name' => node_name
            },
            'some_other_node' => {
              'name' => 'some_other_node_name'
            }
          }
        }
      )
    end

    context 'node is a master' do
      it 'should return true' do
        allow(ets3b).to receive(:node_name).and_return(node_name)
        allow(ets3b).to receive(:es_api).and_return(
          object_double(
            'elasticsearch_connection',
            nodes: nodes_object,
            cluster: object_double(
              'cluster_object',
              state: {
                'master_node' => master_node_id
              }
            )
          )
        )
        expect(ets3b.master?).to eq true
      end
    end

    context 'node is not a master' do
      it 'should return false' do
        allow(ets3b).to receive(:node_name).and_return(node_name)
        allow(ets3b).to receive(:es_api).and_return(
          object_double(
            'elasticsearch_connection',
            nodes: nodes_object,
            cluster: object_double(
              'cluster_object',
              state: {
                'master_node' => 'some_other_node'
              }
            )
          )
        )
        expect(ets3b.master?).to eq false
      end
    end
  end

  describe '.pseudo_random_string' do
    it 'returns a string' do
      expect(ets3b.pseudo_random_string).to be_kind_of(String)
    end

    it 'returns a very large random number' do
      expect(ets3b.pseudo_random_string[1..-1].to_i).to be >= 10**90
    end

    it 'returns a string with a letter' do
      expect(ets3b.pseudo_random_string).to match(/\D/)
    end
  end

  describe '.insert_test_data' do
    let(:test_size) { 100 }

    before(:each) do
      allow(ets3b).to receive(:test_size).and_return(test_size)
      allow(ets3b).to receive(:pseudo_random_string).and_return('big_random_string')
    end

    it 'log about it' do
      allow(ets3b).to receive(:es_api).and_return(
        object_double(
          'elasticsearch_connection',
          create: true
        )
      )
      expect(ets3b.logger).to receive(:info).with('Generating test data using math…')
    end

    it 'creates a bunch of test data' do
      expect(ets3b).to receive(:es_api).exactly(test_size).times.and_return(
        object_double(
          'elasticsearch_connection',
          create: true
        )
      )
    end

    after(:each) do
      ets3b.insert_test_data
    end
  end

  describe '.notify' do
    let(:test_exception) do
      object_double(
        'exception_object',
        message: 'message',
        backtrace: 'backtrace'
      )
    end

    before(:each) do
      allow(ets3b).to receive(:node_name).and_return(node_name)
    end

    context 'Env: prod' do
      it 'send a trigger to PagerDuty' do
        allow(ets3b).to receive(:conf).and_return('env' => 'prod')
        expect(ets3b.pagerduty).to receive(:trigger).with(
          'prod Elasticsearch S3 failed',
          client: node_name,
          details: "#{test_exception.message}\n\n#{test_exception.backtrace}"
        )
      end
    end

    context 'Env: stage' do
      it 'does not send a trigger to PagerDuty' do
        allow(ets3b).to receive(:conf).and_return('env' => 'stage')
        expect(ets3b.pagerduty).to_not receive(:trigger)
      end
    end

    after(:each) do
      ets3b.notify(test_exception)
    end
  end

  describe '.index_item' do
    it 'returns the test value' do
      index = 'test_index'
      doc_id = '99'

      allow(ets3b).to(
        receive_message_chain(:es_api, :get).with(index: index, type: 'dummy', id: doc_id)
          .and_return(
            '_source' => {
              'test_value' => 'some_value'
            }
          )
      )
      expect(ets3b.index_item(index, doc_id)).to eq('some_value')
    end
  end

  describe '.remove_expired_backups' do
    let(:old_repo) { 6.months.ago.strftime('%m-%Y') }
    let(:recent_repo) { 1.months.ago.strftime('%m-%Y') }
    let(:repos) { [old_repo, recent_repo] }

    before(:each) do
      allow(ets3b).to receive_message_chain(:logger, :info)
      allow(ets3b).to receive(:dated_repos).and_return(repos)
      allow(ets3b).to receive(:es_api).and_return(
        object_double(
          'elasticsearch_connection',
          snapshot: object_double(
            'snapshot_object',
            delete_repository: true
          )
        )
      )
    end

    it 'deletes backups more than 3 months old' do
      expect(ets3b.es_api.snapshot).to receive(:delete_repository).with(repository: old_repo)
    end

    it 'does not delete backups less than 3 months old' do
      expect(ets3b).to_not receive(:delete_repository).with(repository: recent_repo)
    end

    after(:each) do
      ets3b.remove_expired_backups
    end
  end
end
