# coding: UTF-8
require "logger"
require "nats"
require "vcap/common"
require "vcap/component"
require "resource_manager"
require "instance_registry"
require "dea_locator"
require "container"
require "box_ip"
require "debugger"

module Dea
  class Bootstrap

    attr_reader :config
    attr_reader :logger
    attr_reader :nats
    attr_reader :resource_manager
    attr_reader :instance_registry
    attr_reader :uuid
    attr_accessor :containers
    attr_accessor :memory

    def initialize(config = {})
      @config=config
      @logger=Logger.new(config['logging']['file'])
      @logger.datetime_format = "%Y-%m-%d %H:%M:%S"
      @logger.formatter = proc do |severity, datetime, progname, msg|
            "[#{datetime}] #{severity} : #{msg}\n"
      end
      @log_counter = Steno::Sink::Counter.new
      @memory=config['resources']["memory_mb"]*config['resources']["memory_overcommit_factor"]
      @containers={}
    end

    def setup
        @nats = Dea::Nats.new(self, config)
        setup_instance_registry
        setup_resource_manager
    end

    def start
        start_component
        start_nats
    end

    def setup_instance_registry
      @instance_registry = Dea::InstanceRegistry.new(config)
    end

    def setup_resource_manager
      @resource_manager = Dea::ResourceManager.new(
        instance_registry,
        config["resources"]
      )
    end

    def local_ip
      @local_ip = BoxIp.get_box_ip ||= VCAP.local_ip
    end

    def start_component
         VCAP::Component.register(
            :type => "Lightagent",
            :host => local_ip,
            :index => config["index"],
            :nats => self.nats.client,
            :port => config["status"]["port"],
            :user => config["status"]["user"],
            :password => config["status"]["password"],
            :logger => logger,
            :log_counter => @log_counter
        )
         @uuid = VCAP::Component.uuid
    end
    def start_nats
      nats.start

      @responders = [
        Dea::Responders::DeaLocator.new(nats, uuid, resource_manager, config,self),
      ].each(&:start)
    end
    
    def handle_dea_create_container(message)
        create_container(message.data,message.respond_to)
    end

    def handle_dea_destroy_container(message)
        handle=message.data['handle']
        attributes={}
        container = Container.new(self, attributes)
        container.destroy_container(handle,message.respond_to)
    end
    

    def handle_dea_info_container(message)
        handle=message.data['handle']
        attributes={}
        container = Container.new(self, attributes)
        container.info_container(handle,message.respond_to)
    end
    
    def handle_dea_addport_container(message)
        handle=message.data['handle']
        attributes={}
        attributes['port']=message.data['port']
        attributes['warden_handle']=message.data['handle']
        container = Container.new(self, attributes)
        container.addport_container(message.respond_to)
    end
	
    def create_container(attributes,reply)
        if @memory>attributes["limits"]["mem"]
            @memory=@memory-attributes["limits"]["mem"]
            container = Container.new(self, attributes)
            container.promise_container(reply)
        else
            message = "Unable to create container:" 
            message << "container #{attributes} not enough resources available."
            logger.error(message)
	    result['result']='failed'
            result['error']=message
            nats.publish(reply,result.to_json)
            return nil
        end
    end
  end
end
