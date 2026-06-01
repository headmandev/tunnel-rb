#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("lib", __dir__)

require "tunnel_rb/server"

if ["1", "true", "yes"].include?(ENV["RELAY_SYNC_OUTPUT"]&.downcase)
  $stdout.sync = true
  $stderr.sync = true
end

public_port = Integer(ENV.fetch("RELAY_PUBLIC_PORT", "8080"))

url_port_env = ENV.fetch("RELAY_URL_PORT", public_port.to_s)
url_port = url_port_env.empty? ? nil : Integer(url_port_env)

TunnelRb::Server.new(
  control_port: Integer(ENV.fetch("RELAY_CONTROL_PORT", "7777")),
  public_port: public_port,
  domain: ENV.fetch("RELAY_DOMAIN", "localhost"),
  url_port: url_port,
  tls_cert: ENV["RELAY_TLS_CERT"],
  tls_key: ENV["RELAY_TLS_KEY"]
).start
