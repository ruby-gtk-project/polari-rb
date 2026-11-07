# frozen_string_literal: true

# Config for development dependencies of this library
# i.e., not configured by this library
#
# SimpleCov & related config (must run BEFORE any other requires)
# NOTE: Gemfiles for non-coverage appraisals may not have kettle-soup-cover.
#       The rescue LoadError handles that scenario.
begin
  require "kettle-soup-cover"
  if Kettle::Soup::Cover::DO_COV
    # Requiring simplecov loads the project-local `.simplecov`.
    require "simplecov"
    require "kettle/soup/cover/config"
    SimpleCov.start
  end
rescue LoadError => error
  # check the error message and re-raise when unexpected
  raise error unless error.message.include?("kettle")
end

# External RSpec & related config
begin
  require "kettle/test/rspec"
  # `kettle/test/rspec` installs harness helpers documented in spec/README.md.
rescue LoadError => error
  # The kettle-test bundle is a development dependency and is not always
  # installed — `nix develop` carries the app's runtime gems plus rspec, and
  # the full kettle-test harness is not always on PATH there. Fall back to
  # plain RSpec rather than failing every spec run.
  raise error unless error.message.include?("kettle")

  warn "NOTE: kettle-test isn't installed; running with plain RSpec."
end

# This library
require "polari/rb"

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
