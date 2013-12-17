# coding: UTF-8
require 'socket'
require 'yaml'
BOX_INFO = "/tmp/.box_info.yml"
module Dea
    class BoxIp
           attr_accessor :host_ip
           attr_accessor :ip_list
           attr_accessor :box_ip
           def self.get_box_ip
           #todo
             @host_ip = IPSocket.getaddress(Socket.gethostname) 
             @ip_list = Socket.ip_address_list.map {|o| o.ip_address}
             if File.exist?("#{BOX_INFO}")
               config = File.open("#{BOX_INFO}") { |f| YAML.load(f) }
               @box_ip = config["box_ip"]
             else
               raise "Setup box ip fisrt!"
             end
             @box_ip if @ip_list.include?@box_ip and @box_ip != @host_ip 
           end
    end
end
#Dea::BoxIp.get_box_ip
