require 'spec_helper'

describe EverTools::ElasticsearchS3Backup do
  it 'has a version number' do
    expect(EverTools::ElasticsearchS3Backup::VERSION).not_to be nil
  end

  let(:es_url) { 'http://localhost:9200' }
  let(:node_name) { 'test_node' }

  let(:ets3b) do
    conf = {
      'env' => 'dev',
      'pagerduty_api_key' => 'BOGUS_API_KEY',
      'notification_email' => 'testemail@domain.com',
      'test_size' => 100,
      'log' => './s3_backup.log',
      'new_repo_params' => {
        'bucket' => 'backups.s3.bucket',
        'max_snapshot_bytes_per_sec' => '100mb',
        'max_restore_bytes_per_sec' => '500mb'
      },
      'node_fqdn' => 'spec-test-node',
      'elasticsearch_auth_file' => 'elasticsearch-htaccess',
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

  describe '#auth' do
    auth_file_content = "user:pass\n"

    before(:each) do
      allow(ets3b).to receive(:elasticsearch_auth_file).and_return('/path/to/file')
    end

    it 'should try to load the auth file' do
      expect(File).to receive(:read).and_return(auth_file_content)
      ets3b.auth
    end

    it 'should return an array with no newline chars' do
      allow(File).to receive(:read).and_return(auth_file_content)
      expect(ets3b.auth).to eq(%w(user pass))
    end
  end

  # describe '#logger' do
  # end

  describe '#es_api' do
    before(:each) do
      allow(ets3b).to receive(:logger).and_return(
        object_double('logger', debug: true, info: true, warn: true, fatal: true)
      )
    end

    context '200 response' do
      before(:each) do
        @success_http_object = object_double(
          'http_object',
          code: 200,
          body: 'SUCCESSFUL REPLY BODY'
        )
        allow(Unirest).to receive(:send).and_return(@success_http_object)
      end

      it 'does not call the logger' do
        expect(ets3b).to_not receive(:logger)
        ets3b.es_api(:get, 'http://goodurl:9200/stuff', foo: 'bar')
      end

      it 'return the response object' do
        expect(
          ets3b.es_api(:get, 'http://goodurl:9200/stuff', foo: 'bar')
        ).to eq(@success_http_object)
      end
    end

    context '400 response' do
      before(:each) do
        @not_found_http_object = object_double(
          'http_object',
          code: 400,
          body: 'NOT FOUND REPLY BODY'
        )
        allow(Unirest).to receive(:send).and_return(@not_found_http_object)
      end

      it 'log to debug about it' do
        expect(ets3b.logger).to receive(:debug)
        ets3b.es_api(:get, 'http://notounfurl:9200/stuff', foo: 'bar')
      end

      it 'return the response object' do
        expect(ets3b.es_api(:get, 'http://notounfurl:9200/stuff', foo: 'bar'))
          .to eq(@not_found_http_object)
      end
    end

    context '500 response' do
      it 'raises an exception' do
        allow(Unirest).to receive(:send).and_return(
          object_double(
            'http_object',
            code: 500,
            body: 'ERROR REPLY BODY'
          )
        )
        test_method = :get
        test_uri = 'http://notounfurl:9200/stuff'
        expect { ets3b.es_api(test_method, test_uri, foo: 'bar') }
          .to raise_exception(
            RuntimeError,
            "GET request to #{test_uri} failed (params: {:foo=>\"bar\"})\n" \
            "Response code: 500\n" \
            "Body:\n" \
            "ERROR REPLY BODY\n"
          )
      end
    end

    context 'exception response' do
      context 'some random exception (not a timeout)' do
        it 'raises the exception right away' do
          expect(Unirest).to receive(:send).once.and_raise(RuntimeError, 'Request Failed')
          expect { ets3b.es_api(:get, 'http://uri') }.to raise_exception(
            RuntimeError,
            'Request Failed'
          )
        end
      end

      context 'connection timeout' do
        it 'retries three times before throwing an exception' do
          expect(Unirest).to receive(:send)
            .exactly(3).times
            .and_raise(RuntimeError, 'Request Timeout')
          expect { ets3b.es_api(:get, 'http://uri') }.to raise_exception(
            RuntimeError,
            'Request Timeout'
          )
        end
      end
    end
  end

  describe '#master?' do
    context 'node is a master' do
      it 'should return true' do
        allow(ets3b).to receive(:node_name).and_return(node_name)
        allow(ets3b).to receive(:es_api).with(:get, "#{es_url}/_cat/master").and_return(
          object_double(
            'http_object',
            code: 200,
            body: [{ 'node' => node_name }]
          )
        )
        expect(ets3b.master?).to eq true
      end
    end

    context 'node is not a master' do
      it 'should return false' do
        allow(ets3b).to receive(:node_name).and_return(node_name)
        allow(ets3b).to receive(:es_api).with(:get, "#{es_url}/_cat/master").and_return(
          object_double(
            'http_object',
            code: 200,
            body: [{ 'node' => 'some_other_node' }]
          )
        )
        expect(ets3b.master?).to eq false
      end
    end
  end

  describe '#index?' do
    index_name = 'index_exists_test'

    context 'index exists' do
      it 'returns true' do
        allow(ets3b).to receive(:es_api).with(:get, "#{es_url}/#{index_name}").and_return(
          object_double(
            'http_object',
            code: 200
          )
        )
        expect(ets3b.index?(index_name)).to eq true
      end
    end

    context 'index does not exist' do
      it 'returns false' do
        allow(ets3b).to receive(:es_api).with(:get, "#{es_url}/#{index_name}").and_return(
          object_double(
            'http_object',
            code: 404
          )
        )
        expect(ets3b.index?(index_name)).to eq false
      end
    end
  end

  describe '#repo?' do
    context 'repo exists' do
      it 'returns true' do
        allow(ets3b).to receive(:es_api).and_return(
          object_double(
            'http_object',
            code: 200
          )
        )
        expect(ets3b.repo?).to eq true
      end
    end

    context 'repo does not exist' do
      it 'returns false' do
        allow(ets3b).to receive(:es_api).and_return(
          object_double(
            'http_object',
            code: 404
          )
        )
        expect(ets3b.repo?).to eq false
      end
    end
  end

  describe '#notify' do
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

  describe '#index_item' do
    context 'shard has some other problem' do
      it 'returns false' do
        allow(Unirest).to receive(:send).and_return(
          object_double(
            'http_object',
            code: 503,
            body: 'EVERYTHING IS HORRIBLE'
          )
        )

        expect { ets3b.index_item('test_index', 0) }
          .to raise_exception(
            RuntimeError,
            "GET request to http://localhost:9200/test_index/dummy/0 failed (params: {})\n" \
            "Response code: 503\n" \
            "Body:\n" \
            "EVERYTHING IS HORRIBLE\n"
          )
      end
    end
  end

  describe '#index_online?' do
    context 'index shard exists' do
      context "but isn't ready" do
        it 'returns false' do
          allow(Unirest).to receive(:send).and_return(
            object_double(
              'http_object',
              code: 200,
              body: {
                'indices' => {
                  'restore_test' => {
                    'shards' => {
                      '0' => [
                        { 'state' => 'STARTED' },
                        { 'state' => 'STARTED' }
                      ],
                      '1' => [
                        { 'state' => 'STARTED' },
                        { 'state' => 'RECOVERING' }
                      ]
                    }
                  }
                }
              }
            )
          )
          expect(ets3b.index_online?('restore_test')).to eq(false)
        end
      end

      context 'and is ready' do
        it 'returns true' do
          allow(Unirest).to receive(:send).and_return(
            object_double(
              'http_object',
              code: 200,
              body: {
                'indices' => {
                  'restore_test' => {
                    'shards' => {
                      '0' => [{ 'state' => 'STARTED' }],
                      '1' => [{ 'state' => 'STARTED' }]
                    }
                  }
                }
              }
            )
          )
          expect(ets3b.index_online?('restore_test')).to eq(true)
        end
      end
    end
  end

  describe '#remove_expired_backups' do
    let(:old_repo) { 6.months.ago.strftime('%m-%Y') }
    let(:recent_repo) { 1.months.ago.strftime('%m-%Y') }
    let(:repos) { [old_repo, recent_repo] }

    before(:each) do
      allow(ets3b).to receive(:logger).and_return(
        object_double('logger', debug: true, info: true, warn: true, fatal: true)
      )
      allow(ets3b).to receive(:dated_repos).and_return(repos)
    end

    it 'deletes backups more than 3 months old' do
      expect(ets3b).to receive(:es_api).with(:delete, "#{es_url}/_snapshot/#{old_repo}")
    end

    it 'does not delete backups less than 3 months old' do
      expect(ets3b).to_not receive(:es_api).with(:delete, "#{es_url}/_snapshot/#{recent_repo}")
    end

    after(:each) do
      ets3b.remove_expired_backups
    end
  end
end
