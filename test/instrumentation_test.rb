require "test_helper"

class Pricing
  include NewFenic::MethodTracer
  def quote(n, discount: 0) = n * 2 - discount
  trace_method :quote
  def self.region = "eu"
  trace_class_method :region
end

class InstrumentationTest < NewFenicTest
  def test_web_request_records_ar_db_and_custom_segments
    Widget.delete_all
    3.times { |i| Widget.create!(name: "w#{i}", price: i) }
    setup # discard writes above (they were outside a request anyway)

    app = lambda do |_env|
      NewFenic.set_transaction_name("WidgetsController#index")
      Widget.where("price >= ?", 0).to_a
      Widget.find(Widget.first.id)
      assert_equal 9, Pricing.new.quote(5, discount: 1)
      assert_equal "eu", Pricing.region
      [200, {}, ["ok"]]
    end
    status, = run_request(app)
    assert_equal 200, status

    bucket, = drained
    stat = bucket.transactions[[:web, "WidgetsController#index"]]
    assert_equal 1, stat.count
    names = stat.segments.keys
    assert_includes names, "ActiveRecord/Widget/load"
    assert_includes names, "ActiveRecord/Widget/find"
    assert_includes names, "Database/widgets/select"
    assert_includes names, "Custom/Pricing#quote"
    assert_includes names, "Custom/Pricing.region"
    assert_operator stat.breakdown[:database], :>, 0
    assert_operator stat.breakdown[:activerecord], :>, 0
    refute bucket.sql.empty?
    sql = bucket.sql.values.map { |a| a.statement.sql }
    assert(sql.any? { |s| s.include?(%(WHERE (price >= ?))) }, sql.inspect)
  end

  def test_n_plus_one_counts_per_transaction
    Widget.create!(name: "n1", price: 1) if Widget.count.zero?
    setup
    app = lambda do |_env|
      NewFenic.set_transaction_name("WidgetsController#n1")
      12.times { |i| Widget.where(id: i).first }
      [200, {}, []]
    end
    run_request(app)
    bucket, = drained
    agg = bucket.sql.values.max_by(&:count)
    assert_equal 12, agg.max_per_tx
    assert_equal 1, agg.tx_count
  end

  def test_errors_and_traces
    NewFenic.config.trace_threshold = 0
    app = ->(_env) { NewFenic.set_transaction_name("BoomController#show"); raise ArgumentError, "bad id 42" }
    assert_raises(ArgumentError) { run_request(app) }
    bucket, traces = drained
    stat = bucket.transactions[[:web, "BoomController#show"]]
    assert_equal 1, stat.errors
    err = bucket.errors.values.first
    assert_equal "ArgumentError", err["class"]
    assert_equal 1, traces.size
    assert_equal "ArgumentError", traces.first["error"]
  ensure
    NewFenic.config.trace_threshold = 300.0
  end

  def test_ignored_paths_and_unnamed_requests
    run_request(->(_) { [200, {}, []] }, "/assets/app.css")
    run_request(->(_) { [404, {}, []] }, "/nope")
    bucket, = drained
    assert_equal [[:web, "Rack/404"]], bucket.transactions.keys
  end

  def test_in_transaction_for_background_work
    NewFenic.in_transaction("Rake/import") { Widget.count }
    bucket, = drained
    stat = bucket.transactions[[:job, "Rake/import"]]
    assert_equal 1, stat.count
    assert stat.segments.key?("ActiveRecord/Widget/count")
  end

  def test_reporter_payload_roundtrip
    run_request(->(_) { NewFenic.set_transaction_name("X#y"); Widget.count; [200, {}, []] })
    reporter = NewFenic.reporter
    sent = nil
    reporter.define_singleton_method(:post) { |body| sent = body; true }
    assert reporter.flush
    doc = MessagePack.unpack(Zlib::GzipReader.new(StringIO.new(sent)).read)
    assert_equal 1, doc["v"]
    tx = doc["buckets"].first["transactions"].find { |t| t["name"] == "X#y" }
    assert_equal 1, tx["count"]
    assert tx["segments"].any? { |s| s["name"] == "ActiveRecord/Widget/count" }
  ensure
    reporter.singleton_class.send(:remove_method, :post)
  end

  def test_failed_flush_is_retried
    run_request(->(_) { NewFenic.set_transaction_name("Retry#me"); [200, {}, []] })
    reporter = NewFenic.reporter
    calls = []
    reporter.define_singleton_method(:post) { |body| calls << body; calls.size > 1 }
    refute reporter.flush
    assert reporter.flush
    doc = MessagePack.unpack(Zlib::GzipReader.new(StringIO.new(calls.last)).read)
    assert(doc["buckets"].flat_map { |b| b["transactions"] }.any? { |t| t["name"] == "Retry#me" })
  ensure
    reporter.singleton_class.send(:remove_method, :post)
  end
end
