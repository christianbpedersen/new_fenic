require "time"
require "active_support/notifications"

module NewFenic
  # Turns Rails' own ActiveSupport::Notifications events into segments. Evented
  # listeners (start/finish) give us proper nesting without monkey patching.
  module Subscribers
    # Base listener: opens a segment on start, closes it on finish. The payload
    # hash is the same object in both callbacks, so it is the matching token.
    class Segment
      def initialize(category, &namer)
        @category = category
        @namer = namer
      end

      def start(_event, _id, payload)
        txn = Transaction.current
        return unless txn

        name = @namer.call(payload)
        txn.start_segment(name, @category, payload) if name
      rescue StandardError => e
        Subscribers.warn(e)
      end

      def finish(_event, _id, payload)
        txn = Transaction.current
        txn&.finish_segment(payload)
      rescue StandardError => e
        Subscribers.warn(e)
      end

      def publish_event(*); end
    end

    class ProcessAction < Segment
      def initialize
        super(:controller) { |p| "Controller/#{p[:controller]}##{p[:action]}" }
      end

      def start(event, id, payload)
        txn = Transaction.current
        return unless txn

        # The first controller to run names the request; forwarded or nested
        # dispatches are just segments.
        txn.name ||= "#{payload[:controller]}##{payload[:action]}"
        txn.attributes["format"] ||= payload[:format].to_s if payload[:format]
        txn.attributes["method"] ||= payload[:method] if payload[:method]
        super
      end

      def finish(event, id, payload)
        txn = Transaction.current
        return unless txn

        super
        txn.status ||= payload[:status].to_i if payload[:status]
        if (error = payload[:exception_object])
          txn.error ||= error
          txn.status ||= 500
        end
      end
    end

    class Sql < Segment
      SKIP = %w[SCHEMA EXPLAIN].freeze

      def initialize
        super(:database) { nil }
      end

      def start(_event, _id, payload)
        txn = Transaction.current
        return unless txn
        return if SKIP.include?(payload[:name])

        if payload[:cached]
          txn.start_segment("Database/query cache", :cache, payload)
          return
        end

        statement = SqlObfuscator.call(payload[:sql])
        name = statement.table ? "Database/#{statement.table}/#{statement.operation.downcase}" : "Database/#{statement.operation.downcase}"
        segment = txn.start_segment(name, :database, payload)
        segment.attrs = { "sql" => statement.sql, "key" => statement.key }
        payload[:__new_fenic_statement] = statement
      rescue StandardError => e
        Subscribers.warn(e)
      end

      def finish(_event, _id, payload)
        txn = Transaction.current
        return unless txn
        return if SKIP.include?(payload[:name])

        segment = txn.finish_segment(payload)
        statement = payload.delete(:__new_fenic_statement)
        return unless segment && statement

        location = nil
        if segment.duration >= NewFenic.config.sql_backtrace_threshold
          location = Subscribers.app_location
          segment.attrs["loc"] = location if location && segment.attrs
        end
        txn.record_sql(statement, segment.duration, location)
      rescue StandardError => e
        Subscribers.warn(e)
      end
    end

    class PerformJob < Segment
      def initialize
        super(:job) { |p| "Job/#{Subscribers.job_name(p)}/perform" }
      end

      def start(event, id, payload)
        if Transaction.current
          super
        else
          txn = Transaction.new(type: :job, name: Subscribers.job_name(payload))
          job = payload[:job]
          txn.attributes["queue"] = job.queue_name if job.respond_to?(:queue_name)
          txn.attributes["adapter"] = payload[:adapter].class.name.split("::").last if payload[:adapter]
          txn.attributes["executions"] = job.executions if job.respond_to?(:executions)
          if job.respond_to?(:enqueued_at) && job.enqueued_at
            enqueued = job.enqueued_at.is_a?(String) ? Time.parse(job.enqueued_at).to_f : job.enqueued_at.to_f
            txn.queue_time = ((txn.started_at - enqueued) * 1000.0).clamp(0.0, 86_400_000.0)
          end
          txn.attributes[:__owner] = payload
          Transaction.current = txn
          txn.start_segment("Job/#{txn.name}/perform", :job, payload)
        end
      rescue StandardError => e
        Subscribers.warn(e)
      end

      def finish(event, id, payload)
        txn = Transaction.current
        return unless txn

        if txn.attributes[:__owner].equal?(payload)
          txn.attributes.delete(:__owner)
          txn.error ||= payload[:exception_object] if payload[:exception_object]
          Transaction.current = nil
          txn.finish
          NewFenic.record(txn)
        else
          super
        end
      rescue StandardError => e
        Subscribers.warn(e)
      end
    end

    VIEW_PREFIX = %r{\A.*?/app/views/}

    module_function

    def subscribe!
      return if @subscribed

      n = ActiveSupport::Notifications
      n.subscribe("process_action.action_controller", ProcessAction.new)
      n.subscribe("sql.active_record", Sql.new)
      n.subscribe("instantiation.active_record", Segment.new(:activerecord) { |p| "ActiveRecord/#{p[:class_name]}/instantiate" })
      n.subscribe("render_template.action_view", Segment.new(:view) { |p| "View/#{view_name(p[:identifier])}/template" })
      n.subscribe("render_partial.action_view", Segment.new(:view) { |p| "View/#{view_name(p[:identifier])}/partial" })
      n.subscribe("render_collection.action_view", Segment.new(:view) { |p| "View/#{view_name(p[:identifier])}/collection" })
      n.subscribe("render_layout.action_view", Segment.new(:view) { |p| "View/#{view_name(p[:identifier])}/layout" })
      n.subscribe("perform.active_job", PerformJob.new)
      n.subscribe("enqueue.active_job", Segment.new(:job) { |p| "Job/#{job_name(p)}/enqueue" })
      %w[read write delete exist? fetch_hit generate read_multi write_multi increment decrement].each do |op|
        n.subscribe("cache_#{op}.active_support", Segment.new(:cache) { |_| "Cache/#{op.delete('?')}" })
      end
      n.subscribe("deliver.action_mailer", Segment.new(:external) { |p| "External/mail/#{p[:mailer]}" })
      @subscribed = true
    end

    def view_name(identifier)
      return "unknown" unless identifier
      identifier.to_s.sub(VIEW_PREFIX, "")
    end

    def job_name(payload)
      job = payload[:job]
      return "UnknownJob" unless job
      job.class.name
    end

    # First stack frame inside the application (not gems, not Ruby itself).
    def app_location
      root = defined?(Rails.root) && Rails.root ? "#{Rails.root}/" : nil
      return nil unless root

      caller_locations(3, 80)&.each do |loc|
        path = loc.absolute_path || loc.path
        next unless path&.start_with?(root)
        next if path.include?("/vendor/") || path.include?("/gems/")
        return "#{path.delete_prefix(root)}:#{loc.lineno}:in `#{loc.label}'"
      end
      nil
    end

    def warn(error)
      NewFenic.config.logger&.warn("[NewFenic] instrumentation error: #{error.class}: #{error.message}")
    end
  end
end
