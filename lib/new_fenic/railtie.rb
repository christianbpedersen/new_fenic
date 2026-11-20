module NewFenic
  class Railtie < ::Rails::Railtie
    config.new_fenic = ActiveSupport::OrderedOptions.new

    initializer "new_fenic.middleware" do |app|
      app.middleware.insert(0, NewFenic::Middleware)
    end

    initializer "new_fenic.configure", after: :load_config_initializers do |app|
      c = NewFenic.config
      c.app_name ||= app.class.module_parent_name
      c.logger ||= Rails.logger
      app.config.new_fenic.each { |k, v| c.public_send("#{k}=", v) if c.respond_to?("#{k}=") }
    end

    config.after_initialize do |app|
      if NewFenic.start!
        unless NewFenic.config.auto_instrument_paths.empty?
          # Classes must be loaded before their methods can be wrapped.
          Rails.application.eager_load! unless app.config.eager_load
          n = MethodTracer.auto_instrument(NewFenic.config.auto_instrument_paths, Rails.root)
          NewFenic.config.logger&.info("[NewFenic] auto-instrumented #{n} methods")
        end
        NewFenic.config.logger&.info("[NewFenic] reporting #{NewFenic.config.app_name} to #{NewFenic.config.endpoint}")
      end
    end
  end
end
