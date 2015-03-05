require 'openssl'
require 'uri'
require 'multi_json'
require 'faraday'

require 'opbeat/version'
require 'opbeat/error'
require 'opbeat/filter'

module Opbeat

  class ClientState
    def initialize(configuration)
      @configuration = configuration
      @retry_number = 0
      @last_check = Time.now
    end

    def should_try?
      return true if @status == :online

      interval = ([@retry_number, 6].min() ** 2) * @configuration[:backoff_multiplier]
      return true if Time.now - @last_check > interval

      false
    end

    def set_fail
      @status = :error
      @retry_number += 1
      @last_check = Time.now
    end

    def set_success
      @status = :online
      @retry_number = 0
      @last_check = nil
    end
  end

  class Client

    USER_AGENT = "opbeat-ruby/#{Opbeat::VERSION}"

    attr_accessor :configuration
    attr_accessor :state

    def initialize(conf)
      raise Error.new('No server specified') unless conf.server
      raise Error.new('No secret token specified') unless conf.secret_token
      raise Error.new('No organization ID specified') unless conf.organization_id
      raise Error.new('No app ID specified') unless conf.app_id

      @configuration = conf
      @state = ClientState.new conf
      @filter = Filter.new conf.filter_parameters
      @base_url = "#{conf.server}/api/v1/organizations/#{conf.organization_id}/apps/#{conf.app_id}"
      @auth_header = 'Bearer ' + conf.secret_token
    end

    def conn
      @conn ||= Faraday.new(@base_url) do |faraday|
        Opbeat.logger.debug "Initializing connection to #{self.configuration.server}"
        faraday.adapter Faraday.default_adapter
        faraday.ssl[:verify] = self.configuration.ssl_verification
        faraday.options[:timeout] = self.configuration.timeout if self.configuration.timeout
        faraday.options[:open_timeout] = self.configuration.open_timeout if self.configuration.open_timeout
      end
    end

    def encode(event)
      event_hash = event.to_hash
      event_hash = @filter.process_event_hash(event_hash)
      return MultiJson.encode(event_hash)
    end

    def send(url_postfix, message)
      begin
        response = self.conn.post @base_url + url_postfix do |req|
          req.body = self.encode(message)
          req.headers['Authorization'] = @auth_header
          req.headers['Content-Type'] = 'application/json'
          req.headers['Content-Length'] = req.body.bytesize.to_s
          req.headers['User-Agent'] = USER_AGENT
        end
        unless response.status.between?(200, 299)
          raise Error.new("Error from Opbeat server (#{response.status}): #{response.body}")
        end
      rescue
        @state.set_fail
        raise
      end

      @state.set_success
      response
    end

    def send_event(event)
      return unless configuration.send_in_current_environment?
      unless state.should_try?
        Opbeat.logger.info "Temporarily skipping sending to Opbeat due to previous failure."
        return
      end

      # Set the organization ID correctly
      event.organization = self.configuration.organization_id
      event.app = self.configuration.app_id
      Opbeat.logger.debug "Sending event to Opbeat"
      response = send("/errors/", event)
      if response.status.between?(200, 299)
        Opbeat.logger.info "Event logged successfully at " + response.headers["location"].to_s
      end
      response
    end

    def send_release(release)
      Opbeat.logger.debug "Sending release to Opbeat"
      send("/releases/", release)
    end
  end

end
