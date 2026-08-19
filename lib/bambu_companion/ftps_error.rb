# frozen_string_literal: true

module BambuCompanion
  class FtpsError < StandardError
    attr_reader :code

    def initialize(code, message)
      @code = String(code)
      super(message)
    end
  end
end
