# frozen_string_literal: true

module ::DiscourseSms
  class Engine < ::Rails::Engine
    engine_name PLUGIN_NAME
    isolate_namespace DiscourseSms
    config.autoload_paths << File.join(config.root, "lib")
  end
end
