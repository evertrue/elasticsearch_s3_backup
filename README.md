# ElasticsearchS3Backup

This gem creates a backup of your ElasticSearch cache and uploads it to S3.

## Installation

Install it using:

    $ gem install elasticsearch_s3_backup

## Configuration

Create a YAML file called `/etc/s3_backup.yml` and give it the following contents:

    ---
    notification_email: @@NOTIFICATION_EMAIL_ADDRESS@@
    test_size: 100
    log: "/var/log/s3_backup/s3_backup.log"
    new_repo_params:
      bucket: @@BACKUPS_S3_BUCKET@@
      max_snapshot_bytes_per_sec: 100mb
      max_restore_bytes_per_sec: 500mb
    env: stage
    es_transport_timeout: 2400
    pagerduty_api_key: @@YOUR_PAGERDUTY_API_KEY@@
    node_name: @@THIS_NODE'S_NAME@@
    elasticsearch_auth_file: "/usr/local/elasticsearch/password"
    cluster_name: @@YOUR_CLUSTER_NAME@@

## Usage

Just run the command:

    $ es_s3_backup

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/evertrue/elasticsearch_s3_backup.

## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).

