#!/usr/bin/env ruby

# -------------------------------------------------------------------------- #
# Copyright 2002-2019, OpenNebula Project, OpenNebula Systems                #
#                                                                            #
# Licensed under the Apache License, Version 2.0 (the "License"); you may    #
# not use this file except in compliance with the License. You may obtain    #
# a copy of the License at                                                   #
#                                                                            #
# http://www.apache.org/licenses/LICENSE-2.0                                 #
#                                                                            #
# Unless required by applicable law or agreed to in writing, software        #
# distributed under the License is distributed on an "AS IS" BASIS,          #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.   #
# See the License for the specific language governing permissions and        #
# limitations under the License.                                             #
#--------------------------------------------------------------------------- #

require 'rubygems'
require 'ffi-rzmq'
require 'nokogiri'
require 'yaml'
require 'logger'
require 'base64'

ONE_LOCATION = ENV['ONE_LOCATION']

if !ONE_LOCATION
    LOG_LOCATION  = '/var/log/one'
    VAR_LOCATION  = '/var/lib/one'
    ETC_LOCATION  = '/etc/one'
    LIB_LOCATION  = '/usr/lib/one'
    HOOK_LOCATION = '/var/lib/one/remotes/hooks'
    RUBY_LIB_LOCATION = '/usr/lib/one/ruby'
else
    VAR_LOCATION  = ONE_LOCATION + '/var'
    LOG_LOCATION  = ONE_LOCATION + '/var'
    ETC_LOCATION  = ONE_LOCATION + '/etc'
    LIB_LOCATION  = ONE_LOCATION + '/lib'
    HOOK_LOCATION = ONE_LOCATION + '/var/remotest/hooks'
    RUBY_LIB_LOCATION = ONE_LOCATION + '/lib/ruby'
end

$LOAD_PATH << RUBY_LIB_LOCATION

require 'opennebula'
require 'CommandManager'
require 'ActionManager'

#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
# This module includes basic functions to deal with Hooks
#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
module HEMHook
    # --------------------------------------------------------------------------
    # Hook types
    # --------------------------------------------------------------------------
    HOOK_TYPES  = [:api, :state]

    # --------------------------------------------------------------------------
    # Hook Execution
    # --------------------------------------------------------------------------
    # Parse hook arguments
    def arguments(event_str)
        hook_args = self['TEMPLATE/ARGUMENTS']

        return "" unless hook_args

        begin
            event = Nokogiri::XML(event_str)

            event_type = event.xpath('//HOOK_TYPE')[0].upcase

            api = ""
            template = ""

            case event_type
            when 'API'
                api = event.xpath('//PARAMETERS')[0].to_s
                api = Base64.strict_encode64(api)
            when 'STATE'
                object   = event.xpath('//HOOK_OBJECT')[0].upcase
                template = event.xpath("//#{object}")[0].to_s
                template = Base64.strict_encode64(template)
            end
        rescue StandardError => se
            return ""
        end

        parguments = ""
        hook_args  = hook_args.split ' '

        hook_args.each do |arg|
            case arg
            when '$API'
                parguments << api << ' '
            when '$TEMPLATE'
                parguments << template << ' '
            else
                parguments << arg << ' '
            end
        end

        parguments
    end

    # Execute the hook command
    def execute(path, params)
        #TODO send arguments via stdin if configured
        remote  = self['TEMPLATE/REMOTE'].casecmp('YES').zero?
        command = self['TEMPLATE/COMMAND']

        command.prepend(path) if command[0] != '/'

        command.concat(" #{params}") unless params.empty?

        if !remote
            LocalCommand.run(command)
        else
            #TODO REMOTE_HOST from event_str
            SSHCommand.run(command, self['TEMPLATE/REMOTE_HOST'])
        end
    end

    #---------------------------------------------------------------------------
    # Hook attributes
    #---------------------------------------------------------------------------
    def type
        self['TYPE'].to_sym
    end

    def valid?
        HOOK_TYPES.include? type
    end

    def id
        self['ID'].to_i
    end

    # Generates a key for a given hook
    def key
        begin
            case type
            when :api
                self['TEMPLATE/CALL']
            when :state
                "#{self['//RESOURCE']}/#{self['//STATE']}/#{self['//LCM_STATE']}"
            else
                ""
            end
        rescue
            return ""
        end
    end

    # Generate a sbuscriber filter for a Hook given the type and the key
    def filter(key)
        case type
        when :api
            "API #{key} 1"
        when :state
            "STATE #{key}"
        else
            ""
        end
    end
end

#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
# This class represents the hook pool synced from oned
#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
class HookMap

    def initialize(logger)
        @hooks   = {}
        @filters = {}

        @logger  = logger
        @client  = OpenNebula::Client.new
    end

    # Load Hooks from oned (one.hookpool.info) into a dictionary with the
    # following format:
    #
    # hooks[hook_type][hook_key] = Hook object
    #
    # Also generates and store the corresponding filters
    #
    # @return dicctionary containing hooks dictionary and filters
    def load
        @logger.info('Loading Hooks...')

        hook_pool = OpenNebula::HookPool.new(@client)

        rc = hook_pool.info

        if OpenNebula.is_error?(rc)
            @logger.error("Cannot get hook information: #{rc.message}")
            return
        end

        @hooks   = {}
        @filters = {}

        HEMHook::HOOK_TYPES.each do |type|
            @hooks[type] = {}
        end

        hook_pool.each do |hook|
            hook.extend(HEMHook)

            if !hook.valid?
                @logger.error("Error loading hooks. Invalid type: #{hook.type}")
                next
            end

            key = hook.key

            @hooks[hook.type][key] = hook

            @filters[hook['ID'].to_i] = hook.filter(key)
        end

        @logger.info('Hooks successfully loaded')
    end

    # Execute the given lambda on each event filter in the map
    def each_filter(&block)
        @filters.each_value { |f| block.call(f) }
    end

    # Returns a hook by key
    def get_hook(type, key)
        @hooks[type.downcase.to_sym][key]
    end
end

# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
# Hook Execution Manager class
# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
class HookExecutionManager
    attr_reader :am

    # --------------------------------------------------------------------------
    # Default configuration options, overwritten in hem.conf
    # --------------------------------------------------------------------------
    DEFAULT_CONF = {
        :hook_base_path      => HOOK_LOCATION,
        :subscriber_endpoint => 'tcp://localhost:5556',
        :replier_endpoint    => 'tcp://localhost:5557',
        :debug_level         => 2,
        :concurrency         => 10
    }

    # --------------------------------------------------------------------------
    # File paths
    # --------------------------------------------------------------------------
    CONFIGURATION_FILE = ETC_LOCATION + '/hem.conf'
    HEM_LOG            = LOG_LOCATION + '/hem.log'

    # --------------------------------------------------------------------------
    # API calls which trigger hook info reloading and filters to suscribe to
    # --------------------------------------------------------------------------
    UPDATE_CALLS = [
        'one.hook.update',
        'one.hook.allocate',
        'one.hook.delete'
    ]

    const_set('STATIC_FILTERS', UPDATE_CALLS.map {|e| "API #{e} 1" })

    # --------------------------------------------------------------------------
    # Logger configuration
    # --------------------------------------------------------------------------
    DEBUG_LEVEL = [
        Logger::ERROR, # 0
        Logger::WARN,  # 1
        Logger::INFO,  # 2
        Logger::DEBUG  # 3
    ]

    # Mon Feb 27 06:02:30 2012 [Clo] [E]: Error message example
    MSG_FORMAT  = %(%s [%s]: %s\n)
    # Mon Feb 27 06:02:30 2012
    DATE_FORMAT = '%a %b %d %H:%M:%S %Y'

    # --------------------------------------------------------------------------
    # --------------------------------------------------------------------------
    def initialize
        # ----------------------------------------------------------------------
        # Load config from configuration file
        # ----------------------------------------------------------------------
        begin
            conf = YAML.load_file(CONFIGURATION_FILE)
        rescue Exception => e
            STDERR.puts "Error loading config #{CONFIGURATION_FILE}: #{e.message}"
            exit 1
        end

        @conf = DEFAULT_CONF.merge(conf)

        # ----------------------------------------------------------------------
        # Init log system
        # ----------------------------------------------------------------------
        @logger       = Logger.new(HEM_LOG)
        @logger.level = DEBUG_LEVEL[@conf[:debug_level].to_i]

        @logger.formatter = proc do |severity, datetime, _progname, msg|
            format(MSG_FORMAT, datetime.strftime(DATE_FORMAT),
                severity[0..0], msg)
        end

        #-----------------------------------------------------------------------
        # 0mq related variables
        #   - context (shared between all the sockets)
        #   - suscriber and requester sockets (exclusive access)
        #-----------------------------------------------------------------------
        @context    = ZMQ::Context.new(1)
        @subscriber = @context.socket(ZMQ::SUB)
        @requester  = @context.socket(ZMQ::REQ)

        @requester_lock = Mutex.new

        # Maps for existing hooks and filters and oned client
        @hooks = HookMap.new(@logger)

        #Internal event manager
        @am = ActionManager.new(@conf[:concurrency], true)
        @am.register_action(:EXECUTE, method('execute_action'))
    end

    ##############################################################################
    # Helpers
    ##############################################################################
    # Subscribe the subscriber socket to the given filter
    def subscribe(filter)
        # TODO, check params
        @subscriber.setsockopt(ZMQ::SUBSCRIBE, filter)
    end

    # Unsubscribe the subscriber socket from the given filter
    def unsubscribe(filter)
        # TODO, check params
        @subscriber.setsockopt(ZMQ::UNSUBSCRIBE, filter)
    end

    ############################################################################
    # Hook manager methods
    ############################################################################
    # Subscribe to the socket filters and STATIC_FILTERS
    def load_hooks
        @hooks.load

        # Subscribe to hooks modifier calls
        STATIC_FILTERS.each { |filter| subscribe(filter) }

        # Subscribe to each existing hook
        @hooks.each_filter { |filter| subscribe(filter) }
    end

    def reload_hooks
        #TODO recover the reload_hooks
        @hooks.each_filter { |filter| unsubscribe(filter) }

        @hooks.load

        @hooks.each_filter { |filter| subscribe(filter) }
    end

    ############################################################################
    # Hook Execution Manager main loop
    ############################################################################

    def hem_loop
        # Connect subscriber/requester sockets
        @subscriber.connect(@conf[:subscriber_endpoint])

        @requester.connect(@conf[:replier_endpoint])

        # Initialize @hooks and filters
        load_hooks

        loop do
            key     = ''
            content = ''

            @subscriber.recv_string(key)
            @subscriber.recv_string(content)

            type, key = key.split(' ')
            content   = Base64.decode64(content)
            hook      = @hooks.get_hook(type, key)

            @am.trigger_action(:EXECUTE, 0, hook, content) unless hook.nil?

            reload_hooks if UPDATE_CALLS.include? key
        end
    end

    def execute_action(hook, content)
        ack = ''
        params = hook.arguments(content)
        rc     = hook.execute(@conf[:hook_base_path], params)

        if rc.code.zero?
            @logger.info("Hook successfully executed for #{hook.key}")
        else
            @logger.error("Failure executing hook for #{hook.key}")
        end

        xml_response =<<-EOF
            <ARGUMENTS>#{params}</ARGUMENTS>
            #{rc.to_xml}
        EOF

        xml_response = Base64.strict_encode64(xml_response)

        @requester_lock.synchronize {
            @requester.send_string("#{rc.code} #{hook.id} #{xml_response}")
            @requester.recv_string(ack)
        }

        @logger.error('Wrong ACK message: #{ack}.') if ack != 'ACK'
    end

    def start
        hem_thread = Thread.new { hem_loop }
        @am.start_listener
        hem_thread.kill
    end

end

################################################################################
################################################################################
#
#
################################################################################
################################################################################

hem = HookExecutionManager.new
hem.start