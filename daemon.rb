#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("lib", __dir__)
require "bambu_companion/application"

begin
  application = BambuCompanion::Application.new
  Signal.trap("TERM") { Thread.main.raise(Interrupt) }
  Signal.trap("INT") { Thread.main.raise(Interrupt) }
  application.run
rescue Interrupt
  exit 0
rescue StandardError
  begin
    $stderr.write("bambu-companion: fatal error\n")
    $stderr.flush
  rescue StandardError
    nil
  end
  exit 1
end
