require "test_helper"
require "graphql"
NewFenic::Instrumentation::GraphQL.install!

class WidgetSource < GraphQL::Dataloader::Source
  def fetch(ids)
    found = Widget.where(id: ids).index_by(&:id)
    ids.map { |id| found[id] }
  end
end

class WidgetType < GraphQL::Schema::Object
  field :id, ID, null: false
  field :name, String
  field :sibling, WidgetType
  def sibling = dataloader.with(WidgetSource).load(object.id)
end

class QueryType < GraphQL::Schema::Object
  field :widgets, [WidgetType], null: false
  def widgets
    sleep 0.005
    Widget.order(:id).to_a
  end
end

class TestSchema < GraphQL::Schema
  query QueryType
  use GraphQL::Dataloader
end

class GraphqlTest < NewFenicTest
  def test_operation_naming_layer_and_fields
    Widget.create!(name: "g", price: 1) if Widget.count.zero?
    setup
    app = lambda do |_env|
      NewFenic.set_transaction_name("GraphqlController#execute")
      result = TestSchema.execute("query WidgetList { widgets { id name sibling { name } } }")
      raise result["errors"].inspect if result["errors"]
      [200, {}, []]
    end
    run_request(app)
    bucket, = drained
    key, stat = bucket.transactions.first
    assert_equal [:web, "GraphQL/query/WidgetList"], key
    assert_includes stat.segments.keys, "GraphQL/field/Query.widgets"
    assert_includes stat.segments.keys, "GraphQL/field/Widget.sibling"
    assert_includes stat.segments.keys, "GraphQL/Source/WidgetSource"
    refute_includes stat.segments.keys, "GraphQL/field/Widget.name" # scalars are not traced
    assert_includes stat.segments.keys, "GraphQL/parse"
    assert_operator stat.breakdown[:graphql], :>=, 4.0
    assert stat.segments.key?("Database/widgets/select")
  end

  def test_anonymous_and_outside_request
    TestSchema.execute("{ widgets { id } }")
    bucket, = drained
    assert_equal [[:job, "GraphQL/query/<anonymous>"]], bucket.transactions.keys
  end
end
