# frozen_string_literal: true

require 'sinatra/base'
require 'date'
require_relative '../sinatra_prefs_source'

module Autochef
  module Web
    class App < Sinatra::Base
      set :views, File.expand_path('views', __dir__)

      def self.configure_autochef(cfg:, prefs_source:)
        set :autochef_cfg, cfg
        set :prefs_source, prefs_source
      end

      get '/week' do
        @cfg        = settings.autochef_cfg
        @source     = settings.prefs_source
        @week_start = next_week_start(@cfg)
        @existing   = @source.fetch(@week_start)
        erb :week_config
      end

      post '/week' do
        @cfg        = settings.autochef_cfg
        @source     = settings.prefs_source
        @week_start = next_week_start(@cfg)
        @source.save(@week_start, params)
        erb :submitted
      end

      private

      def next_week_start(cfg)
        order    = %w[Sun Mon Tue Wed Thu Fri Sat]
        wday_idx = order.index(cfg.schedule.pickup_day) || 0
        today    = Date.today
        offset   = (wday_idx - today.wday) % 7
        offset   = 7 if offset.zero?
        today + offset
      end
    end
  end
end
