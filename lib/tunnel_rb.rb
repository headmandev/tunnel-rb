# frozen_string_literal: true

require_relative "tunnel_rb/version"
require_relative "tunnel_rb/client"
require_relative "tunnel_rb/server"

# Backward-compatible alias for scripts that reference the top-level Tunnel class.
Tunnel = TunnelRb::Client
