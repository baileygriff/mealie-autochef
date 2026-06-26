# frozen_string_literal: true

module Autochef
  module Models
    # Per-tag preference weight (e.g. "cuisine:thai", "protein:chicken").
    # Nudged up/down by the feedback loop (Phase 6) based on kept/swapped/
    # rated recipes carrying that tag.
    class TagWeight < ActiveRecord::Base
      self.table_name = "tag_weights"
      self.primary_key = "tag"
    end
  end
end
