#!/usr/bin/env ruby

require 'aws-sdk-s3'
require 'logger'
require 'sequel'
require 'optparse'
require 'digest'
require 'yaml'

# rsync -avz yla@sudo.ch:/home/iterate.ch/trac.cyberduck.io/files/attachments/ticket --no-relative /Users/yla/workspace/trac-hub/trac/
# flatten: find . -type f -name \* | rsync -avz --files-from - --no-relative . ~/workspace/trac-hub/trac/flatten/

# cd /home/iterate.ch/trac.cyberduck.io/files/attachments/ticket
# find . -type f -name \* | rsync -avz --files-from - --no-relative sudo.ch:/home/iterate.ch/trac.cyberduck.io/files/attachments/ticket /home/yla/trac/

class Migrator
  def initialize(trac)
    @trac = trac
  end

  def migrate(start_ticket = -1)

    bucket_name = 'github-cyberduck-assets'
    basepath_tickets = '/Users/yla/workspace/trac-hub/trac/flatten'

    region = 'eu-west-1'
    s3_client = Aws::S3::Client.new(
      region: region,
      access_key_id: 'AKIASYJA6R34DJXQHKUU',
      secret_access_key: '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',
      http_wire_trace: false
    )

    @trac.attachments.order(:id).where { id >= start_ticket }.all.each do |attachment|

      ticket = attachment[:id]
      filename = attachment[:filename]
      $logger.info("Processing #{ticket} and attachment with filename #{filename}")

      hash = Digest::SHA1.hexdigest filename

      hfilename = basepath_tickets + '/' + hash + File.extname(filename)
      object_key = ticket + '/' + filename

      if File.file?(hfilename)
        response = s3_client.put_object(
          body: File.open(hfilename, 'rb').read,
          bucket: bucket_name,
          key: object_key,
          acl: 'public-read'
        )
      else
        $logger.warn "File #{hfilename} does not exist"
      end
    end
  end
end

class Trac
  attr_reader :tickets, :changes, :sessions, :attachments, :milestones

  def initialize(db)
    $logger.info('Loading attachments')
    @db = db
    @attachments = @db[:attachment]
  end
end

class Options < Hash
  def initialize(argv)
    super()
    opts = OptionParser.new do |opts|
      opts.banner = "#{$0}, available options:"
      opts.on('-c config', '--config', 'set the configuration file') do |c|
        self[:config] = c
      end
      opts.on_tail('-h', '--help', 'display this help and exit') do |help|
        puts(opts)
        exit
      end
      opts.on('-s', '--start-at ID', 'start migration from ticket with number <ID>') do |id|
        self[:start] = id
      end
      opts.on('-r', '--rev-map-file FILE',
              'allows to specify a commit revision mapping FILE') do |file|
        self[:revmapfile] = file
      end
      opts.on('-a', '--attachment-url URL',
              'if attachment files are reachable via a URL we reference this here') do |url|
        self[:attachurl] = url
      end
      opts.on('-S', '--single-post',
              'Put all issue comments in the first message.') do |single|
        self[:singlepost] = single
      end
      opts.on('-F', '--fast-import',
              'Import without safety-checking issue numbers.') do |fast|
        self[:fast] = fast
      end
      opts.on('-o', '--opened-only', 'Skips the import of closed tickets') do |o|
        self[:openedonly] = o
      end
      opts.on('-v', '--verbose', 'verbose mode') do |v|
        self[:verbose] = v
      end
      begin
        opts.parse!(argv)
        if not self[:config]
          default = File.join(File.dirname(__FILE__), 'config.yaml')
          raise 'missing configuration file' unless File.exists?(default)
          self[:config] = default
        end
        self[:start] = -1 unless self[:start]
      rescue => e
        STDERR.puts(e)
        STDERR.puts('run with -h to see available options')
        exit 1
      end
    end
  end
end

if __FILE__ == $0
  opts = Options.new(ARGV)
  cfg = YAML.load_file(opts[:config])

  # Setup logger.
  $logger = Logger.new(STDERR)
  $logger.level = opts[:verbose] ? Logger::DEBUG : Logger::INFO
  $logger.formatter = proc do |severity, datetime, progname, msg|
    time = datetime.strftime('%Y-%m-%d %H:%M:%S')
    "[#{time}] #{severity}#{' ' * (5 - severity.size + 1)}| #{msg}\n"
  end

  # Setup database.
  db = nil
  if db_url = cfg['trac']['database']
    db = Sequel.connect(db_url)
  end
  if not db
    $logger.error('could not connect to trac databse')
    exit 1
  end

  # load revision mapping file and convert it to a hash.
  # This revmap file allows to map between SVN revisions (rXXXX)
  # and git commit sha1 hashes.
  revmap = nil
  if opts[:revmapfile]
    File.open(opts[:revmapfile], "r") do |f|
      $logger.info(opts[:revmapfile])
      revmap = Hash[f.lines
                     .map { |line| line.split(/\s+/) }
                     .map { |rev, sha| [rev.gsub(/^r/, ''), sha] } # remove leading "r" if present
      ]
    end
  end

  trac = Trac.new(db)

  migrator = Migrator.new(trac)
  migrator.migrate(opts[:start])
end
