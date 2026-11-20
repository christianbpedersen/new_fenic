$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "minitest/autorun"
require "active_record"
require "rack"
require "new_fenic"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :widgets do |t|
    t.string :name
    t.integer :price
  end
end

class Widget < ActiveRecord::Base; end

NewFenic.config.enabled = true
NewFenic.config.api_key = "test"
NewFenic.config.app_name = "Test"
NewFenic.start!

class NewFenicTest < Minitest::Test
  def setup
    NewFenic.aggregator.drain
    NewFenic.aggregator.take_pending
  end

  def run_request(app, path = "/widgets")
    NewFenic::Middleware.new(app).call(Rack::MockRequest.env_for(path))
  end

  def drained
    buckets, traces = NewFenic.aggregator.drain
    [buckets.values.first, traces]
  end
end
