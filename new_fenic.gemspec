require_relative "lib/new_fenic/version"

Gem::Specification.new do |spec|
  spec.name = "new_fenic"
  spec.version = NewFenic::VERSION
  spec.authors = ["NewFenic"]
  spec.summary = "Rails-specific application performance monitoring agent"
  spec.description = "Instruments controllers, views, ActiveRecord, SQL, jobs, external HTTP and custom code, " \
                     "aggregates in-process and ships compact batches to a NewFenic server."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"
  spec.files = Dir["lib/**/*.rb", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activesupport", ">= 7.0"
  spec.add_dependency "msgpack", ">= 1.4"
  spec.add_development_dependency "minitest", ">= 5.0"
  spec.add_development_dependency "rake"
end
