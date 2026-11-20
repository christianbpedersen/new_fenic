module NewFenic
  # Times individual methods as "Custom/<Class>#<method>" segments.
  #
  #   class PricingService
  #     include NewFenic::MethodTracer
  #     trace_method :quote
  #     trace_class_method :for_region, name: "Custom/Pricing/region lookup"
  #   end
  module MethodTracer
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      def trace_method(*method_names, name: nil, category: :custom)
        method_names.each do |m|
          MethodTracer.wrap(self, m, name || "Custom/#{self.name}##{m}", category)
        end
      end

      def trace_class_method(*method_names, name: nil, category: :custom)
        method_names.each do |m|
          MethodTracer.wrap(singleton_class, m, name || "Custom/#{self.name}.#{m}", category)
        end
      end
    end

    module_function

    # Prepends a module defining a same-named method that opens a segment and
    # calls super. Idempotent per (class, method).
    def wrap(klass, method_name, segment_name, category)
      tracer = (klass.instance_variable_get(:@__new_fenic_tracer) ||
                klass.instance_variable_set(:@__new_fenic_tracer, Module.new.tap { |m| klass.prepend(m) }))
      return if tracer.method_defined?(method_name) || tracer.private_method_defined?(method_name)

      visibility = if klass.private_method_defined?(method_name) then :private
                   elsif klass.protected_method_defined?(method_name) then :protected
                   else :public
                   end
      tracer.define_method(method_name) do |*args, **kwargs, &block|
        txn = Transaction.current
        return super(*args, **kwargs, &block) unless txn

        token = Object.new
        txn.start_segment(segment_name, category, token)
        begin
          super(*args, **kwargs, &block)
        ensure
          txn.finish_segment(token)
        end
      end
      tracer.send(visibility, method_name)
    end

    # Traces every public method defined directly on the classes loaded from
    # +dirs+ (e.g. app/services). Methods inherited from Rails are left alone.
    def auto_instrument(dirs, root)
      dirs = Array(dirs).map { |d| File.expand_path(d, root.to_s) + "/" }
      return 0 if dirs.empty?

      count = 0
      ObjectSpace.each_object(Module) do |mod|
        next if mod.singleton_class? || mod.name.nil?
        next if defined?(::ActiveRecord::Base) && mod.is_a?(Class) && mod < ::ActiveRecord::Base

        mod.public_instance_methods(false).each do |m|
          next unless defined_in?(mod.instance_method(m), dirs)
          wrap(mod, m, "Custom/#{mod.name}##{m}", :custom)
          count += 1
        end
        mod.singleton_class.public_instance_methods(false).each do |m|
          next unless defined_in?(mod.method(m), dirs)
          wrap(mod.singleton_class, m, "Custom/#{mod.name}.#{m}", :custom)
          count += 1
        end
      rescue StandardError, NameError
        next
      end
      count
    end

    def defined_in?(method, dirs)
      file = method.source_location&.first
      file && dirs.any? { |d| file.start_with?(d) }
    end
  end
end
