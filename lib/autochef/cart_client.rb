# frozen_string_literal: true

require "open3"
require "json"

module Autochef
  # Ruby-side half of the contract documented in cart_builder/cart.py's
  # module docstring. Shells out to the Python script, feeds it JSON on
  # stdin, and parses JSON from stdout. stderr is forwarded to our own
  # logger/stderr for visibility but never parsed.
  #
  # This is the ONLY place in the Ruby codebase that talks to Python —
  # everything past this class is a plain Ruby Hash, by design, so the
  # rest of the app (notify.rb, safety.rb, etc.) never needs to know a
  # subprocess was involved.
  class CartClient
    class CartBuilderError < StandardError; end

    PYTHON_SCRIPT = File.expand_path("../../cart_builder/cart.py", __dir__)
    # Assumes a venv with cart_builder/requirements.txt installed is on
    # PATH as `python3` inside the container — see docker/Dockerfile.
    PYTHON_BIN = ENV.fetch("CART_BUILDER_PYTHON", "python3")

    # input: a Hash matching cart.py's INPUT_SCHEMA (run_key, store_name,
    #   pickup_window_pref, spending_cap_usd, cart_deviation_alert_pct,
    #   dry_run, items: [...]).
    # Returns a Hash matching OUTPUT_SCHEMA (string keys, as parsed from JSON).
    # Raises CartBuilderError on a nonzero exit code or unparseable stdout —
    # per the contract, those are real crashes, distinct from a clean
    # {"status": "aborted", ...} response.
    def self.build_cart(input)
      stdout_str, stderr_str, status = Open3.capture3(
        PYTHON_BIN, PYTHON_SCRIPT,
        stdin_data: input.to_json
      )

      stderr_str.each_line { |line| warn "[cart_builder] #{line.chomp}" }

      unless status.success?
        raise CartBuilderError, "cart.py exited #{status.exitstatus}: #{stderr_str}"
      end

      begin
        JSON.parse(stdout_str)
      rescue JSON::ParserError => e
        raise CartBuilderError, "cart.py produced unparseable stdout: #{e.message}\nstdout was: #{stdout_str.inspect}"
      end
    end
  end
end
