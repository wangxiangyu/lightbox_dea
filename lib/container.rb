# coding: UTF-8

require "steno"
require "steno/core_ext"
require "vcap/common"
require "yaml"
require "pp"

require "promise"
require "em/warden/client/connection"

module Dea
  class Container

    class BaseError < StandardError; end
    class WardenError < BaseError; end
    attr_reader :bootstrap
    attr_accessor :attributes
    attr_reader :logger
    def initialize(bootstrap, attributes)
      @bootstrap = bootstrap
      @attributes = attributes
      @logger=bootstrap.logger
      @warden_connections = {}
    end

    def promise_container(reply)
        container=Promise.new do |p|
            promise_create_container.resolve
            promise_setup_network.resolve
            promise_limit_disk.resolve
            promise_limit_memory.resolve
            p.deliver
        end
        Promise.resolve(container) do |error,_|
            if error.nil?
                result={}
                result['result']='success'
                result['data']=@attributes
                bootstrap.containers["#{@attributes['warden_handle']}"]=@attributes
                bootstrap.nats.publish(reply,result.to_json)
            else
                logger.warn("create container error: #{error}") unless error.nil?
                result={}
                result['result']='failed'
                result['error']=error
                bootstrap.memory=bootstrap.memory+attributes["limits"]["mem"]
                bootstrap.nats.publish(reply,result.to_json)
            end
        end
    end

    def addport_container(reply)
        container=Promise.new do |p|
            promise_new_port.resolve
            p.deliver
        end
        Promise.resolve(container) do |error,_|
            if error.nil?
                result={}
                result['result']='success'
                result['data']=@attributes
                bootstrap.containers["#{@attributes['warden_handle']}"]=@attributes
                bootstrap.nats.publish(reply,result.to_json)
            else
                logger.warn("create container error: #{error}") unless error.nil?
                result={}
                result['result']='failed'
                result['error']=error
                bootstrap.memory=bootstrap.memory+attributes["limits"]["mem"]
                bootstrap.nats.publish(reply,result.to_json)
            end
        end
    end

    def destroy_container(handle,reply)
         destroy=Promise.new do |p|
            promise_destroy_container(handle).resolve
            p.deliver
        end
        Promise.resolve(destroy) do |error,_|
            if error.nil?
                result={}
                result['result']='success'
                bootstrap.memory=bootstrap.memory+bootstrap.containers[handle]['limits']['mem']
                bootstrap.containers.delete(handle)
                bootstrap.nats.publish(reply,result.to_json)
            else
                logger.warn("destroy container error: #{error}") unless error.nil?
                result={}
                result['result']='failed'
                result['error']=error
                bootstrap.nats.publish(reply,result.to_json)
            end
        end
    end

    def info_container(handle,reply)
         info_container=Promise.new do |p|
            @info_response=promise_info_container(handle)
            p.deliver
        end
        Promise.resolve(info_container) do |error,_|
            if error.nil?
                result={}
                result['result']='success'
                bootstrap.nats.publish(reply,result.to_json)
            else
                result={}
                result['result']='failed'
                bootstrap.nats.publish(reply,result.to_json)
            end
        end
    end

    def promise_setup_network
        Promise.new do |p|
            response = get_new_warden_net_in(22)
            @attributes["ssh_port"]=response.host_port
        
            response = get_new_warden_net_in(80)
            @attributes["http_80_port"]=response.host_port

            response = get_new_warden_net_in(8080)
            @attributes["http_8080_port"]=response.host_port
        
            @attributes['port'].each do |port|
                response = get_new_warden_net_in(port)
                @attributes["user_#{port}"]=response.host_port
            end 
            p.deliver
        end
    end

    def promise_new_port
        Promise.new do |p|
            @attributes['port'].each do |port|
                response = get_new_warden_net_in(port)
                @attributes["user_#{port}"]=response.host_port
            end 
            p.deliver
        end
    end

    def promise_limit_disk
        Promise.new do |p|
            request = ::Warden::Protocol::LimitDiskRequest.new
            request.handle = @attributes["warden_handle"]
            request.byte = disk_limit_in_bytes
            promise_warden_call(:app, request).resolve
            p.deliver
        end
    end

    def disk_limit_in_bytes
      #attributes["limits"]["disk"].to_i * 1024 * 1024
      51200
    end
    
    def promise_limit_memory
        Promise.new do |p|
            request = ::Warden::Protocol::LimitMemoryRequest.new
            request.handle = @attributes["warden_handle"]
            request.limit_in_bytes = memory_limit_in_bytes
            promise_warden_call(:app, request).resolve
            p.deliver
        end
    end

    def memory_limit_in_bytes
      attributes["limits"]["mem"].to_i * 1024 * 1024
    end

    def promise_create_container
      Promise.new do |p|
        create_request = ::Warden::Protocol::CreateRequest.new
        response = promise_warden_call(:app, create_request).resolve
        @attributes["warden_handle"] = response.handle
        @attributes["host_ip"] = bootstrap.local_ip
        p.deliver
      end
    end

    def promise_destroy_container(handle)
      Promise.new do |p|
        request = ::Warden::Protocol::DestroyRequest.new
        request.handle = handle
        promise_warden_call(:app, request).resolve
        p.deliver
      end
    end

    def promise_info_container(handle)
        request = ::Warden::Protocol::InfoRequest.new
        request.handle = handle
        promise_warden_call(:app, request).resolve
    end

    def get_new_warden_net_in(host_ip=bootstrap.local_ip, container_port)
        request = ::Warden::Protocol::NetInRequest.new
        request.handle = @attributes["warden_handle"]
        request.host_ip = host_ip
        request.container_port = container_port
        promise_warden_call(:app, request).resolve
    end

    def promise_warden_call(connection_name, request)
      Promise.new do |p|
        logger.info(request.inspect)
        connection = promise_warden_connection(connection_name).resolve
        connection.call(request) do |result|
          logger.info(result.inspect)
          error = nil
          begin
            response = result.get
          rescue => error
            logger.warn "warden call error: #{error}"
            p.fail(error)
          else
            p.deliver(response)
          end
        end
      end
    end

   def promise_warden_connection(name)
      Promise.new do |p|
        connection = find_warden_connection(name)
        # Deliver cached connection if possible
        if connection && connection.connected?
          p.deliver(connection)
        else
          socket = bootstrap.config["warden_socket"]
          klass  = ::EM::Warden::Client::Connection

          begin
            connection = ::EM.connect_unix_domain(socket, klass)
          rescue => error
            p.fail(WardenError.new("Cannot connect to warden on #{socket}: #{error.message}"))
          end

          if connection
            connection.on(:connected) do
              cache_warden_connection(name, connection)

              p.deliver(connection)
            end

            connection.on(:disconnected) do
              p.fail(WardenError.new("Cannot connect to warden on #{socket}"))
            end
          end
        end
      end
    end
    def find_warden_connection(name)
      @warden_connections[name]
    end
    def cache_warden_connection(name, connection)
      @warden_connections[name] = connection
    end

    end
end
