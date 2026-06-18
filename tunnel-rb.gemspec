# frozen_string_literal: true

require_relative "lib/tunnel_rb/version"

Gem::Specification.new do |spec|
  spec.name = "tunnel-rb"
  spec.version = TunnelRb::VERSION
  spec.authors = ["headmandev"]
  spec.email = ["headman.dev@gmail.com"]

  spec.summary = "Expose a local HTTP server to the internet through a tunnel server"
  spec.description = <<~DESC
    tunnel-rb exposes a local HTTP server (e.g. a Rails app) to the internet through a tunnel server.
    Includes the tunnel client CLI and tunnel server library — plain Ruby stdlib only, no runtime dependencies.
  DESC
  spec.homepage = "https://github.com/headmandev/tunnel-rb"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 2.7"

  spec.metadata = {
    "source_code_uri" => spec.homepage
  }

  spec.files = Dir.chdir(__dir__) do
    Dir.glob("{exe,lib}/**/*").select { |path| File.file?(path) } +
      %w[tunnel-rb.gemspec README.md LICENSE]
  end

  spec.bindir = "exe"
  spec.executables = %w[tunnel]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
