# coding: UTF-8

require "steno"
require "steno/core_ext"
require "nats/client"

module Dea
  class Nats
    attr_reader :bootstrap
    attr_reader :config
    attr_reader :sids

    def initialize(bootstrap, config)
      @bootstrap = bootstrap
      @config    = config
      @sids      = {}
      @client    = nil
    end

    def start
      subscribe("dea.#{bootstrap.uuid}.create.container") do |message|
        bootstrap.handle_dea_create_container(message)
      end
      subscribe("dea.#{bootstrap.uuid}.destroy.container") do |message|
        bootstrap.handle_dea_destroy_container(message)
      end
      subscribe("dea.#{bootstrap.uuid}.info.container") do |message|
        bootstrap.handle_dea_info_container(message)
      end
      subscribe("dea.#{bootstrap.uuid}.addport.container") do |message|
        bootstrap.handle_dea_addport_container(message)
      end
    end

    def stop
      @sids.each { |_, sid| client.unsubscribe(sid) }
      @sids = {}
    end

    def publish(subject, data)
      client.publish(subject, Yajl::Encoder.encode(data))
    end

    def request(subject, data = {})
      client.request(subject, Yajl::Encoder.encode(data)) do |raw_data, respond_to|
        begin
          yield handle_incoming_message("response to #{subject}", raw_data, respond_to)
        rescue => e
          logger.error "Error \"#{e}\" raised while processing #{subject.inspect}: #{raw_data}"
        end
      end
    end

    def subscribe(subject, opts={})
      # Do not track subscription option is used with responders
      # since we want them to be responsible for subscribe/unsubscribe.
      do_not_track_subscription = opts.delete(:do_not_track_subscription)

      sid = client.subscribe(subject, opts) do |raw_data, respond_to|
        begin
          yield handle_incoming_message(subject, raw_data, respond_to)
        rescue => e
          logger.error "Error \"#{e}\" raised while processing #{subject.inspect}: #{raw_data}"
        end
      end

      @sids[subject] = sid unless do_not_track_subscription
      sid
    end

    def unsubscribe(sid)
      client.unsubscribe(sid)
    end

    def client
      @client ||= create_nats_client
    end

    def create_nats_client
      logger.info "Connecting to NATS on #{config["nats_uri"]}"
      # NATS waits by default for 2s before attempting to reconnect, so a million reconnect attempts would
      # save us from a NATS outage for approximately 23 days - which is large enough.
      ::NATS.connect(:uri => config["nats_uri"], :max_reconnect_attempts => 999999)
    end

    class Message
      def self.decode(nats, subject, raw_data, respond_to)
        data = Yajl::Parser.parse(raw_data)
        new(nats, subject, data, respond_to)
      end

      attr_reader :nats
      attr_reader :subject
      attr_reader :data
      attr_reader :respond_to

      def initialize(nats, subject, data, respond_to)
        @nats       = nats
        @subject    = subject
        @data       = data
        @respond_to = respond_to
      end

      def respond(data)
        message = response(data)
        message.publish
      end

      def response(data)
        self.class.new(nats, respond_to, data, nil)
      end

      def publish
        nats.publish(subject, data)
      end
    end

    private

    def handle_incoming_message(subject, raw_data, respond_to)
      message = Message.decode(self, subject, raw_data, respond_to)
      logger.debug "Received on #{subject.inspect}: #{message.data.inspect}"
      message
    end

    def logger
      @logger ||= @bootstrap.logger
    end
  end
end
