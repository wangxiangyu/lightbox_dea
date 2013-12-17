require "protocol"

module Dea::Responders
  class DeaLocator
    DEFAULT_ADVERTISE_INTERVAL = 5

    attr_reader :nats
    attr_reader :dea_id
    attr_reader :resource_manager
    attr_reader :config

    def initialize(nats, dea_id, resource_manager, config,bootstrap)
      @nats = nats
      @dea_id = dea_id
      @resource_manager = resource_manager
      @config = config
      @bootstrap = bootstrap
    end

    def start
      subscribe_to_dea_locate
      start_periodic_dea_advertise
    end

    def stop
      unsubscribe_from_dea_locate
      stop_periodic_dea_advertise
    end

    def advertise
      nats.publish(
        "dea.advertise",
        Dea::Protocol::V1::AdvertiseMessage.generate({
          :id => dea_id,
          :prod => false,
          :stacks => config["stacks"] || [],
          :available_memory => @bootstrap.memory,
          :app_id_to_count => resource_manager.app_id_to_count,
          :host_ip => @bootstrap.local_ip
        }),
      )
    end

    private

    def subscribe_to_dea_locate
      options = {:do_not_track_subscription => true}
      @dea_locate_sid = nats.subscribe("dea.locate", options) { |_| advertise }
    end

    def unsubscribe_from_dea_locate
      nats.unsubscribe(@dea_locate_sid) if @dea_locate_sid
    end

    # Cloud controller uses dea.advertise to
    # keep track of all deas that it can use to run apps
    def start_periodic_dea_advertise
      advertise_interval =  DEFAULT_ADVERTISE_INTERVAL
      @advertise_timer = EM.add_periodic_timer(advertise_interval) { advertise }
    end

    def stop_periodic_dea_advertise
      EM.cancel_timer(@advertise_timer) if @advertise_timer
    end
  end
end