require File::expand_path('../../spec_helper', __FILE__)
require 'opbeat'
require 'faraday'

http = Faraday.new do |builder|
  builder.adapter :test do |stub|
    stub.get('/') { |env| [ 200, {}, 'foo' ]}
  end
end

describe Opbeat::Client do
  before do
    @configuration = Opbeat::Configuration.new
    @configuration.environments = ["test"]
    @configuration.current_environment = :test
    @configuration.secret_token = 'test'
    @configuration.organization_id = 'test'
    @configuration.app_id = 'test'
    @client = Opbeat::Client.new(@configuration)
    allow(@client).to receive(:send)
  end

  it 'send_release should send' do
    message = "Test message"
    expect(@client).to receive(:send).with("/releases/", message)
    @client.send_release(message)
  end

  it 'send_message should send' do
    event = Opbeat::Event.new :message => "my message"
    req = http.get '/'
    expect(@client).to receive(:send).with("/errors/", event).and_return(req)
    @client.send_event(event)
  end
end
