module Dea
  # Singleton config used throughout
  class Config
    class << self

      OPTIONS = [
        :nats_uri,
        :logger
      ]

      OPTIONS.each { |option| attr_accessor option }

      # Configures the various attributes
      #
      # @param [Hash] config the config Hash
      def configure(config)
        @nats_uri=config['nats_uri']
        @logger=Logger.new(config['logging']['file'])
        @logger.datetime_format = "%Y-%m-%d %H:%M:%S"
        @logger.formatter = proc do |severity, datetime, progname, msg|
            "[#{datetime}] #{severity} : #{msg}"
        end
      end
    end
  end
end
