module NewFenic
  # One unit of work: a web request or a background job. Lives in a
  # fiber-local slot while it runs and is handed to the aggregator when it
  # finishes. Metrics are accumulated as segments close, so the trace tree is
  # only an optional side product and can be truncated without losing totals.
  class Transaction
    CATEGORIES = %i[middleware controller view activerecord database external cache custom job].freeze
    KEY = :__new_fenic_transaction

    # name, category, start offset (ms), duration (ms), children, extra attrs
    class Segment
      attr_accessor :name, :category, :start, :duration, :children, :child_time, :token, :attrs, :parent, :in_tree

      def initialize(name, category, start, token, parent)
        @name = name
        @category = category
        @start = start
        @token = token
        @parent = parent
        @child_time = 0.0
        @duration = 0.0
      end

      def to_wire(base_start)
        node = [name, category.to_s, (start - base_start).round(3), duration.round(3)]
        node << (children ? children.map { |c| c.to_wire(base_start) } : [])
        node << attrs if attrs
        node
      end
    end

    # Per-transaction rollup of one segment name.
    class SegmentStat
      attr_accessor :category, :count, :total, :exclusive, :min, :max

      def initialize(category)
        @category = category
        @count = 0
        @total = 0.0
        @exclusive = 0.0
        @min = Float::INFINITY
        @max = 0.0
      end

      def add(duration, exclusive)
        @count += 1
        @total += duration
        @exclusive += exclusive
        @min = duration if duration < @min
        @max = duration if duration > @max
      end
    end

    SqlStat = Struct.new(:statement, :count, :total, :max, :location)

    attr_reader :type, :started_at, :segments, :sql, :breakdown, :root, :attributes
    attr_accessor :name, :status, :error, :uri, :queue_time, :duration, :ignored

    def self.current
      Thread.current[KEY]
    end

    def self.current=(txn)
      Thread.current[KEY] = txn
    end

    def initialize(type:, name: nil, uri: nil, config: NewFenic.config)
      @type = type
      @name = name
      @uri = uri
      @config = config
      @started_at = Time.now.to_f
      @start = NewFenic.clock
      @segments = {}
      @sql = {}
      @breakdown = Hash.new(0.0)
      @attributes = {}
      @segment_count = 0
      @max_segments = config.max_segments_per_trace
      @root = Segment.new(type == :job ? "Job" : "Middleware/Rack", type == :job ? :job : :middleware, @start, nil, nil)
      @root.children = []
      @root.in_tree = true
      @stack = [@root]
    end

    def start_segment(name, category, token = nil)
      parent = @stack.last
      segment = Segment.new(name, category, NewFenic.clock, token, parent)
      if parent.in_tree && @segment_count < @max_segments
        @segment_count += 1
        segment.in_tree = true
        (parent.children ||= []) << segment
      end
      @stack << segment
      segment
    end

    # Closes the segment matching +token+ (or the innermost one). Segments
    # opened above it but never closed (exception paths) are closed too.
    def finish_segment(token = nil, attrs = nil)
      return if @stack.size <= 1

      index = token ? @stack.rindex { |s| s.token.equal?(token) } : @stack.size - 1
      return unless index && index.positive?

      now = NewFenic.clock
      segment = nil
      while @stack.size > index
        segment = @stack.pop
        close(segment, now)
      end
      segment.attrs = attrs if attrs
      segment
    end

    def current_segment
      @stack.last
    end

    def in_segment_category?(category)
      @stack.any? { |s| s.category == category }
    end

    def record_sql(statement, duration, location)
      stat = @sql[statement.key]
      unless stat
        return if @sql.size >= @config.max_sql_statements
        stat = @sql[statement.key] = SqlStat.new(statement, 0, 0.0, 0.0, nil)
      end
      stat.count += 1
      stat.total += duration
      stat.max = duration if duration > stat.max
      stat.location ||= location
    end

    def finish
      now = NewFenic.clock
      close(@stack.pop, now) while @stack.size > 1
      close(@root, now)
      @stack.clear
      @duration = @root.duration
    end

    def error?
      !error.nil? || (status && status >= 500)
    end

    def segment_count
      @segment_count
    end

    def trace_wire
      @root.to_wire(@start)
    end

    private

    def close(segment, now)
      duration = now - segment.start
      duration = 0.0 if duration.negative?
      segment.duration = duration
      exclusive = duration - segment.child_time
      exclusive = 0.0 if exclusive.negative?

      segment.parent.child_time += duration if segment.parent
      @breakdown[segment.category] += exclusive

      stat = (@segments[segment.name] ||= SegmentStat.new(segment.category))
      stat.add(duration, exclusive)
    end
  end
end
