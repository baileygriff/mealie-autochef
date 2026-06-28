# frozen_string_literal: true

require 'telegram/bot'
require 'date'
require_relative 'models/plan_history'
require_relative 'models/recipe_stat'
require_relative 'models/manual_addition'
require_relative 'models/recurring_item'
require_relative 'shopping'
require_relative 'sinatra_prefs_source'

module Autochef
  # Telegram notification + approval bot for Mealie AutoChef.
  #
  # Two entry points:
  #   notifier.send_draft(plan_history_id:)  — one-shot; called from `main.rb plan`
  #   notifier.run_bot                        — blocking polling loop; called from `main.rb serve`
  #
  # Inline keyboard callback data format: "<action>:<plan_id>[:<param>]"
  #   approve:<plan_id>
  #   swap:<plan_id>:<date>        (date = YYYY-MM-DD)
  #   regenerate:<plan_id>
  #   add_note:<plan_id>
  #
  # State machine (for multi-turn flows):
  #   @pending_states[chat_id] = { action: :waiting_note, plan_id: 123, message_id: 456 }
  class Notifier
    MAX_CALLBACK_DATA_BYTES = 64  # Telegram hard limit

    def initialize(cfg, mealie_client:, scorer: nil, llm_planner: nil)
      @cfg         = cfg
      @token       = cfg.notify.telegram_bot_token
      @chat_id     = cfg.notify.telegram_chat_id.to_s
      @mealie      = mealie_client
      @scorer      = scorer
      @llm_planner = llm_planner

      @pending_states = {}  # { chat_id => { action:, plan_id:, message_id: } }
    end

    # Send the plan draft for plan_history_id to Telegram and return.
    # Called from main.rb plan (one-shot, no polling loop needed).
    def send_draft(plan_history_id:, note: nil)
      history = Models::PlanHistory.find(plan_history_id)
      text, keyboard = build_plan_message(history, note: note)
      bot_api.send_message(
        chat_id: @chat_id,
        text: text,
        reply_markup: keyboard,
        parse_mode: 'Markdown'
      )
    end

    # Start the blocking Telegram polling loop. Never returns.
    # Called from main.rb serve.
    def run_bot
      puts "Starting Telegram bot (polling)..."
      Telegram::Bot::Client.run(@token) do |bot|
        bot.listen do |update|
          handle_update(bot, update)
        rescue StandardError => e
          warn "Bot handler error: #{e.class}: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        end
      end
    end

    # -------------------------------------------------------------------------
    # Cart-ready notifications (Phase 5) — called from main.rb build-cart
    # -------------------------------------------------------------------------

    # Send a "cart is ready" Telegram message after a successful cart build.
    # result is the Hash parsed from cart.py's OUTPUT_SCHEMA JSON.
    # deviation_warning is an optional String from Safety#deviation_warning.
    def send_cart_ready(result, dry_run:, deviation_warning: nil, skipped_items: [])
      lines = ["*Cart ready✅*"]
      lines[0] += ' (dry run — cart built, no order placed)' if dry_run
      lines << ''

      if result['cart_total']
        lines << "Total: *$#{'%.2f' % result['cart_total']}*"
      elsif result['est_total']
        lines << "Est. total: *$#{'%.2f' % result['est_total']}* (actual not captured)"
      end

      lines << "Pickup slot: #{result['pickup_slot']}" if result['pickup_slot']

      if result['cart_url']
        lines << ''
        lines << "Cart: #{result['cart_url']}"
      end

      if result['flagged_items']&.any?
        lines << ''
        lines << "*#{result['flagged_items'].size} item(s) could not be added ⚠️*"
        result['flagged_items'].each { |item| lines << "  • #{item}" }
        lines << "These were not substituted. Add them manually in the Food Lion app."
      end

      if skipped_items.any?
        lines << ''
        lines << "*Pantry assumed on hand (#{skipped_items.size}) — verify stock:*"
        skipped_items.each { |n| lines << "  • #{n}" }
        lines << "Use /add if you need to restock any, then re-run: build-cart --force"
      end

      if deviation_warning
        lines << ''
        lines << "⚠️ *#{deviation_warning}*"
      end

      if result['screenshot_path']
        lines << ''
        lines << "Screenshot: `#{result['screenshot_path']}`"
      end

      if dry_run
        lines << ''
        lines << "Review the cart in Food Lion To Go, then place the order manually."
      end

      bot_api.send_message(
        chat_id:    @chat_id,
        text:       lines.join("\n"),
        parse_mode: 'Markdown'
      )
    end

    # Send a Telegram alert when the cart build was aborted (kill switch,
    # spending cap, crash, etc.).
    def send_cart_aborted(reason)
      text = "*Cart build aborted ⛔*\n\n#{reason}"
      bot_api.send_message(chat_id: @chat_id, text: text, parse_mode: 'Markdown')
    end

    # -------------------------------------------------------------------------
    # Reminder notifications (Phase 6) — called by Reminders scheduler jobs
    # -------------------------------------------------------------------------

    # Send the night-before thaw nudge: "take the protein out tonight".
    def send_thaw_reminder(date:, recipe_name:)
      day_name = date.strftime('%A')
      text = "*Thaw reminder* — tomorrow is #{day_name}!\n\n" \
             "Take the protein out tonight for: *#{recipe_name}*"
      bot_api.send_message(chat_id: @chat_id, text: text, parse_mode: 'Markdown')
    rescue StandardError => e
      warn "send_thaw_reminder error: #{e.message}"
    end

    # Send the optional cook-day morning ping: "tonight's dinner is X".
    def send_morning_ping(date:, recipe_name:)
      text = "*Tonight:* #{recipe_name}"
      bot_api.send_message(chat_id: @chat_id, text: text, parse_mode: 'Markdown')
    rescue StandardError => e
      warn "send_morning_ping error: #{e.message}"
    end

    private

    # -------------------------------------------------------------------------
    # Update routing
    # -------------------------------------------------------------------------

    def handle_update(bot, update)
      case update
      when Telegram::Bot::Types::CallbackQuery
        handle_callback(bot, update)
      when Telegram::Bot::Types::Message
        handle_message(bot, update)
      end
    end

    # -------------------------------------------------------------------------
    # Message handler (commands + pending-state text)
    # -------------------------------------------------------------------------

    def handle_message(bot, msg)
      return unless msg.is_a?(Telegram::Bot::Types::Message)
      return unless msg.chat.id.to_s == @chat_id  # ignore messages from other chats

      text = msg.text.to_s.strip
      return if text.empty?

      # If there's a pending state and this isn't a new command, handle as continuation.
      state = @pending_states[msg.chat.id]
      if state && !text.start_with?('/')
        handle_state_input(bot, msg, state)
        return
      end

      # Parse command (strip bot username suffix, e.g. /add@mybot → /add)
      parts   = text.split(' ', -1)
      command = parts[0].downcase.gsub(/@\S+$/, '')
      args    = parts[1..]

      case command
      when '/add'      then cmd_add(bot, msg, args)
      when '/list'     then cmd_list(bot, msg)
      when '/remove'   then cmd_remove(bot, msg, args)
      when '/staples'  then cmd_staples(bot, msg, args)
      when '/servings' then cmd_servings(bot, msg, args)
      when '/help'     then cmd_help(bot, msg)
      end
    end

    # Handles free-text input during a multi-turn flow (e.g. note for regenerate).
    def handle_state_input(bot, msg, state)
      case state[:action]
      when :waiting_note
        note_text = msg.text.to_s.strip
        @pending_states.delete(msg.chat.id)
        reply(bot, msg.chat.id, "_Got it. Regenerating with your note..._", parse_mode: 'Markdown')
        run_regenerate(bot, state[:plan_id], freeform_note: note_text,
                       chat_id: msg.chat.id, message_id: state[:message_id])
      when :waiting_staple_cadence
        cadence_text = msg.text.to_s.strip
        name = state[:staple_name]
        @pending_states.delete(msg.chat.id)
        finish_staple_add(bot, msg, name, cadence_text)
      end
    end

    # -------------------------------------------------------------------------
    # Callback handler
    # -------------------------------------------------------------------------

    def handle_callback(bot, query)
      parts  = query.data.to_s.split(':', 3)
      action = parts[0]
      plan_id = parts[1]&.to_i
      param   = parts[2]

      case action
      when 'approve'    then callback_approve(bot, query, plan_id)
      when 'swap'       then callback_swap(bot, query, plan_id, param)
      when 'regenerate' then callback_regenerate(bot, query, plan_id)
      when 'add_note'   then callback_add_note(bot, query, plan_id)
      end

      bot.api.answer_callback_query(callback_query_id: query.id)
    rescue StandardError => e
      bot.api.answer_callback_query(callback_query_id: query.id,
                                    text: "Error: #{e.message.slice(0, 200)}", show_alert: true)
    end

    # -------------------------------------------------------------------------
    # Callback implementations
    # -------------------------------------------------------------------------

    def callback_approve(bot, query, plan_id)
      history = Models::PlanHistory.find(plan_id)

      if history.approved == 1
        bot.api.answer_callback_query(callback_query_id: query.id,
                                      text: 'Already approved.', show_alert: false)
        return
      end

      history.approved = 1
      history.save!

      # Stamp last_planned now that the plan is committed — not on draft save.
      history.plan.each_value do |entry|
        stat = Models::RecipeStat.find_or_initialize_by(recipe_id: entry['recipe_id'])
        stat.last_planned = history.week_start
        stat.save!
      end

      # Tell Bailey something is happening while we build the list.
      bot.api.edit_message_text(
        chat_id:    query.message.chat.id,
        message_id: query.message.message_id,
        text:       "✓ *Plan approved!*\n\n_Building shopping list..._",
        parse_mode: 'Markdown'
      )

      result_text = build_shopping_list_for(history)

      bot.api.edit_message_text(
        chat_id:    query.message.chat.id,
        message_id: query.message.message_id,
        text:       result_text,
        parse_mode: 'Markdown'
      )
    end

    def callback_swap(bot, query, plan_id, date_str)
      history = Models::PlanHistory.find(plan_id)

      if history.approved == 1
        bot.api.answer_callback_query(callback_query_id: query.id,
                                      text: 'Plan already approved — cannot swap.', show_alert: true)
        return
      end

      pool, scored_ids = fetch_pool_and_scores
      if pool.nil? || pool.empty?
        bot.api.answer_callback_query(callback_query_id: query.id,
                                      text: 'Could not reach Mealie to fetch pool.', show_alert: true)
        return
      end

      current_plan  = history.plan
      current_entry = current_plan[date_str]

      unless current_entry
        bot.api.answer_callback_query(callback_query_id: query.id,
                                      text: "No assignment found for #{date_str}.", show_alert: true)
        return
      end

      swapped_id = current_entry['recipe_id']

      # Log swap — strongest preference signal.
      stat = Models::RecipeStat.find_or_initialize_by(recipe_id: swapped_id)
      stat.times_swapped_out = stat.times_swapped_out.to_i + 1
      stat.save!

      swaps = history.swaps
      swaps[date_str] ||= []
      swaps[date_str] = Array(swaps[date_str]) << swapped_id
      history.swaps = swaps

      # Exclude: already used in other slots + swapped-out recipe + recently planned.
      used_ids      = current_plan.reject { |d, _| d == date_str }.values.map { |e| e['recipe_id'] }.to_set
      avoid_before  = history.week_start.to_date - (@cfg.selection.repeat_avoidance_weeks * 7)

      eligible = pool.reject do |r|
        used_ids.include?(r['id']) ||
          r['id'] == swapped_id ||
          recently_planned?(r['id'], since: avoid_before)
      end
      eligible = eligible.sort_by { |r| -(scored_ids[r['id']] || 0.0) }

      # Prefer a recipe that won't violate perishability for this slot.
      date           = Date.parse(date_str)
      days_until_cook = (date - history.week_start.to_date).to_i
      replacement    = eligible.find { |r| (r['perishability'] || 365) >= days_until_cook }
      replacement  ||= eligible.first

      if replacement.nil?
        bot.api.answer_callback_query(callback_query_id: query.id,
                                      text: 'No eligible replacement found — try Regenerate.', show_alert: true)
        return
      end

      current_plan[date_str] = current_entry.merge(
        'recipe_id'   => replacement['id'],
        'recipe_name' => replacement['name'],
        'rationale'   => ''
      )
      history.plan = current_plan
      history.save!

      swapped_name     = current_entry['recipe_name']
      replacement_name = replacement['name']
      new_text, new_keyboard = build_plan_message(history,
                                                  note: "↔ #{date.strftime('%a')} swapped: #{swapped_name} → #{replacement_name}")
      bot.api.edit_message_text(
        chat_id:    query.message.chat.id,
        message_id: query.message.message_id,
        text:       new_text,
        reply_markup: new_keyboard,
        parse_mode: 'Markdown'
      )
    end

    def callback_regenerate(bot, query, plan_id)
      run_regenerate(bot, plan_id, freeform_note: nil,
                     chat_id: query.message.chat.id,
                     message_id: query.message.message_id)
    end

    def callback_add_note(bot, query, plan_id)
      @pending_states[query.message.chat.id] = {
        action:     :waiting_note,
        plan_id:    plan_id,
        message_id: query.message.message_id
      }
      reply(bot, query.message.chat.id,
            "Send me a note for the regeneration (e.g. \"light week, no fish, want a freezer meal\"):")
    end

    # Shared regeneration logic used by both the button and the note flow.
    def run_regenerate(bot, plan_id, freeform_note:, chat_id:, message_id:)
      history = Models::PlanHistory.find(plan_id)

      if history.approved == 1
        reply(bot, chat_id, 'Plan already approved — cannot regenerate.')
        return
      end

      pool, scored_ids = fetch_pool_and_scores
      if pool.nil? || pool.empty?
        reply(bot, chat_id, 'Could not reach Mealie to regenerate plan.')
        return
      end

      raise 'LlmPlanner not available in this process — start with `serve`.' unless @llm_planner

      recent_plans = Models::PlanHistory
                     .order(created_at: :desc)
                     .limit(4)
                     .map(&:plan)

      # Apply week prefs (same logic as cmd_plan in main.rb).
      prefs_source       = SinatraPrefsSource.new
      week_start_date    = history.week_start.to_date
      week_prefs         = prefs_source.fetch(week_start_date)
      layout_overrides   = {}
      servings_overrides = {}
      combined_note      = freeform_note

      if week_prefs
        week_prefs.protein_excludes.each do |excluded|
          pool.reject! { |r| (r['tags'] || []).any? { |t| t['name'] == "protein:#{excluded}" } }
        end

        week_prefs.days.each do |date_str, dp|
          date = Date.parse(date_str.to_s)
          layout_overrides[date]   = dp if dp.meal_type
          servings_overrides[date] = dp.dinner&.servings if dp.dinner&.servings
        end

        vibe_notes = week_prefs.days.filter_map do |date_str, dp|
          next unless dp.dinner
          label = dp.dinner.vibe == 'treat' ? 'Treat meal' : nil
          note  = dp.dinner.note.to_s.strip
          next unless label || !note.empty?
          "#{Date.parse(date_str.to_s).strftime('%a')} #{[label, note].compact.join(': ')}"
        end
        parts = [week_prefs.freeform_note, *vibe_notes].reject(&:empty?)
        combined_note = parts.any? ? parts.join('. ') : freeform_note
      end

      result  = @llm_planner.plan(
        pool:               pool,
        scored_ids:         scored_ids,
        week_start:         week_start_date,
        freeform_note:      combined_note,
        recent_plans:       recent_plans,
        layout_overrides:   layout_overrides,
        servings_overrides: servings_overrides
      )
      plan = result.week_plan

      assignments_hash = plan.assignments.to_h do |a|
        [a.date.iso8601, {
          'recipe_id'      => a.recipe_id,
          'recipe_name'    => a.recipe_name,
          'servings'       => a.servings,
          'meal_type'      => a.meal_type,
          'makes_leftovers' => a.makes_leftovers,
          'rationale'      => a.rationale
        }]
      end

      history.plan    = assignments_hash
      history.swaps   = {}
      history.approved = 0
      history.save!

      plan.assignments.each do |a|
        stat = Models::RecipeStat.find_or_initialize_by(recipe_id: a.recipe_id)
        stat.times_planned = stat.times_planned.to_i + 1
        stat.save!
      end

      via_label = result.via_llm ? 'Claude ✓' : 'deterministic'
      note = freeform_note.to_s.strip.empty? ? "↺ Regenerated (#{via_label})" : "↺ Regenerated with note (#{via_label})"
      note += " — #{result.llm_error}" if result.llm_error

      new_text, new_keyboard = build_plan_message(history, note: note)
      bot_client = bot.respond_to?(:api) ? bot.api : bot
      bot_client.edit_message_text(
        chat_id:      chat_id,
        message_id:   message_id,
        text:         new_text,
        reply_markup: new_keyboard,
        parse_mode:   'Markdown'
      )
    end

    # -------------------------------------------------------------------------
    # Command implementations
    # -------------------------------------------------------------------------

    def cmd_add(bot, msg, args)
      if args.empty?
        reply(bot, msg.chat.id, "Usage: /add <quantity> <unit> <item>  or  /add <item>\nExample: `/add 2 lbs chicken thighs`", parse_mode: 'Markdown')
        return
      end

      qty, unit, name = parse_add_args(args)

      addition = Models::ManualAddition.new(name: name, quantity: qty, unit: unit)
      unless addition.valid?
        reply(bot, msg.chat.id, "Invalid item: #{addition.errors.full_messages.join(', ')}")
        return
      end
      addition.save!

      # Also push to Mealie "Next Order" list.
      mealie_result = push_to_next_order(name: name, quantity: qty, unit: unit)

      if mealie_result
        reply(bot, msg.chat.id, "Added *#{name}* (#{qty}#{unit ? " #{unit}" : ''}) to local DB and Mealie Next Order (id: #{addition.id}).", parse_mode: 'Markdown')
      else
        reply(bot, msg.chat.id, "Added *#{name}* to local DB (id: #{addition.id}). Mealie push failed — check logs.", parse_mode: 'Markdown')
      end
    end

    def cmd_list(bot, msg)
      pending = Models::ManualAddition.pending.order(added_at: :asc)
      if pending.empty?
        reply(bot, msg.chat.id, 'No pending manual additions.')
        return
      end

      lines = ["*Pending additions:*"]
      pending.each do |a|
        qty_str = "#{a.quantity}#{a.unit ? " #{a.unit}" : ''}"
        lines << "  `#{a.id}` — #{a.name} (#{qty_str})"
      end
      reply(bot, msg.chat.id, lines.join("\n"), parse_mode: 'Markdown')
    end

    def cmd_remove(bot, msg, args)
      id = args.first&.to_i
      if id.nil? || id.zero?
        reply(bot, msg.chat.id, "Usage: /remove <id>  (use /list to see ids)")
        return
      end

      addition = Models::ManualAddition.find_by(id: id)
      if addition.nil?
        reply(bot, msg.chat.id, "No addition found with id #{id}.")
        return
      end

      addition.destroy!
      reply(bot, msg.chat.id, "Removed: #{addition.name}.")
    end

    def cmd_staples(bot, msg, args)
      sub = args.first&.downcase

      case sub
      when nil, 'list'
        staples_list(bot, msg)
      when 'add'
        staples_add(bot, msg, args[1..])
      when 'remove'
        staples_remove(bot, msg, args[1..])
      else
        reply(bot, msg.chat.id,
              "Usage:\n  /staples list\n  /staples add <name> <cadence>\n  /staples remove <id>\n\n" \
              "Cadence examples: `every_order`  `every_2_orders`  `every_14_days`",
              parse_mode: 'Markdown')
      end
    end

    def cmd_servings(bot, msg, args)
      if args.length < 2
        reply(bot, msg.chat.id, "Usage: /servings <day> <n>\nExample: `/servings Mon 4`", parse_mode: 'Markdown')
        return
      end

      day_input = args[0]
      new_servings = args[1].to_i
      if new_servings < 1
        reply(bot, msg.chat.id, 'Servings must be a positive integer.')
        return
      end

      history = pending_plan
      if history.nil?
        reply(bot, msg.chat.id, 'No pending (unapproved) plan found. Run `main.rb plan` first.')
        return
      end

      plan = history.plan
      target_date_str = find_date_for_day(plan, day_input)

      if target_date_str.nil?
        days_in_plan = plan.keys.map { |d| Date.parse(d).strftime('%a') }.join(', ')
        reply(bot, msg.chat.id, "No cook day matching '#{day_input}' in the current plan. Cook days: #{days_in_plan}")
        return
      end

      plan[target_date_str]['servings'] = new_servings
      history.plan = plan
      history.save!

      recipe_name = plan[target_date_str]['recipe_name']
      reply(bot, msg.chat.id, "Updated #{Date.parse(target_date_str).strftime('%A')} (#{recipe_name}) to *#{new_servings} servings*.", parse_mode: 'Markdown')
    end

    def cmd_help(bot, msg)
      text = <<~HELP
        *Mealie AutoChef — Bot Commands*

        */add* <qty> <unit> <item> — add to next order
        */list* — show pending manual additions
        */remove* <id> — remove a manual addition
        */servings* <day> <n> — change servings for a meal (e.g. `/servings Mon 4`)
        */staples list* — show recurring staples
        */staples add* <name> <cadence> — add a staple (cadence: `every_order`, `every_2_orders`, `every_14_days`)
        */staples remove* <id> — deactivate a staple

        _Approval buttons appear when a plan draft is sent._
      HELP
      reply(bot, msg.chat.id, text, parse_mode: 'Markdown')
    end

    # -------------------------------------------------------------------------
    # Staples sub-commands
    # -------------------------------------------------------------------------

    def staples_list(bot, msg)
      items = Models::RecurringItem.active.order(:name)
      if items.empty?
        reply(bot, msg.chat.id, 'No active staples. Add one with `/staples add <name> <cadence>`.', parse_mode: 'Markdown')
        return
      end

      lines = ["*Active staples:*"]
      items.each do |item|
        cadence_label = format_cadence(item)
        last = item.last_added ? " (last: #{item.last_added})" : ''
        lines << "  `#{item.id}` — #{item.name} | #{cadence_label}#{last}"
      end
      reply(bot, msg.chat.id, lines.join("\n"), parse_mode: 'Markdown')
    end

    def staples_add(bot, msg, args)
      if args.empty?
        reply(bot, msg.chat.id,
              "Usage: /staples add <name> <cadence>\nCadence: `every_order`, `every_2_orders`, `every_14_days`",
              parse_mode: 'Markdown')
        return
      end

      # The last "word" is the cadence if it looks like one; otherwise ask.
      last_arg = args.last.to_s.strip
      cadence_type, cadence_value = parse_cadence(last_arg)

      if cadence_type
        name = args[0..-2].join(' ').strip
        if name.empty?
          reply(bot, msg.chat.id, 'Please provide an item name before the cadence.')
          return
        end
        create_staple(bot, msg, name, cadence_type, cadence_value)
      else
        # Treat all args as the name and ask for cadence interactively.
        name = args.join(' ').strip
        @pending_states[msg.chat.id] = { action: :waiting_staple_cadence, staple_name: name }
        reply(bot, msg.chat.id,
              "What cadence for *#{name}*? Reply with one of:\n" \
              "`every_order`, `every_2_orders`, `every_3_orders`, `every_14_days`, `every_30_days`",
              parse_mode: 'Markdown')
      end
    end

    def staples_remove(bot, msg, args)
      id = args.first&.to_i
      if id.nil? || id.zero?
        reply(bot, msg.chat.id, "Usage: /staples remove <id>  (use /staples list to see ids)")
        return
      end

      item = Models::RecurringItem.find_by(id: id)
      if item.nil?
        reply(bot, msg.chat.id, "No staple found with id #{id}.")
        return
      end

      item.update!(active: false)
      reply(bot, msg.chat.id, "Deactivated staple: *#{item.name}*.", parse_mode: 'Markdown')
    end

    def finish_staple_add(bot, msg, name, cadence_text)
      cadence_type, cadence_value = parse_cadence(cadence_text)
      if cadence_type.nil?
        reply(bot, msg.chat.id,
              "Couldn't parse that cadence. Try: `every_order`, `every_2_orders`, or `every_14_days`.",
              parse_mode: 'Markdown')
        return
      end
      create_staple(bot, msg, name, cadence_type, cadence_value)
    end

    def create_staple(bot, msg, name, cadence_type, cadence_value)
      item = Models::RecurringItem.new(
        name: name, cadence_type: cadence_type, cadence_value: cadence_value, active: true
      )
      if item.valid?
        item.save!
        reply(bot, msg.chat.id,
              "Added staple: *#{name}* (#{format_cadence(item)}, id: #{item.id}).",
              parse_mode: 'Markdown')
      else
        reply(bot, msg.chat.id, "Validation error: #{item.errors.full_messages.join(', ')}")
      end
    end

    # -------------------------------------------------------------------------
    # Message building
    # -------------------------------------------------------------------------

    # Returns [text, InlineKeyboardMarkup].
    def build_plan_message(history, note: nil)
      plan       = history.plan
      week_start = history.week_start.to_date

      lines  = ["*Week of #{week_start.strftime('%A, %B %-d')}*", '']
      kb_swap_buttons = []

      plan.sort_by { |date_str, _| date_str }.each do |date_str, entry|
        date        = Date.parse(date_str)
        day_name    = date.strftime('%a')
        name        = entry['recipe_name'].to_s
        servings    = entry['servings'].to_i
        meal_type   = entry['meal_type'].to_s
        leftovers   = entry['makes_leftovers']
        rationale   = entry['rationale'].to_s.strip

        suffix = leftovers ? ' _(makes leftovers)_' : ''
        type_label = meal_type == 'dinner' ? '' : " [#{meal_type}]"
        line = "#{day_name} #{date.strftime('%b %-d')}: *#{name}*#{type_label} — #{servings} srv#{suffix}"
        line += "\n  ↳ _#{rationale}_" unless rationale.empty?
        lines << line

        btn_text = "↔ #{day_name} #{date.strftime('%-d')}"
        callback  = "swap:#{history.id}:#{date_str}"
        kb_swap_buttons << Telegram::Bot::Types::InlineKeyboardButton.new(
          text: btn_text, callback_data: callback
        )
      end

      lines << '' << "_#{note}_" if note

      keyboard_rows = []

      if @cfg.respond_to?(:web) && @cfg.web&.enabled
        web_url = "http://#{@cfg.web.host}:#{@cfg.web.port}/week"
        keyboard_rows << [
          Telegram::Bot::Types::InlineKeyboardButton.new(
            text: '⚙ Configure week', url: web_url
          )
        ]
      end

      keyboard_rows << [
        Telegram::Bot::Types::InlineKeyboardButton.new(
          text: '✓ Approve', callback_data: "approve:#{history.id}"
        )
      ]

      kb_swap_buttons.each_slice(2) { |row| keyboard_rows << row }

      keyboard_rows << [
        Telegram::Bot::Types::InlineKeyboardButton.new(
          text: '↺ Regenerate', callback_data: "regenerate:#{history.id}"
        ),
        Telegram::Bot::Types::InlineKeyboardButton.new(
          text: '✎ Add note', callback_data: "add_note:#{history.id}"
        )
      ]

      keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: keyboard_rows)
      [lines.join("\n"), keyboard]
    end

    # -------------------------------------------------------------------------
    # Helpers
    # -------------------------------------------------------------------------

    def bot_api
      @bot_api ||= Telegram::Bot::Client.new(@token).api
    end

    def reply(bot, chat_id, text, parse_mode: nil)
      api = bot.respond_to?(:api) ? bot.api : bot
      opts = { chat_id: chat_id, text: text }
      opts[:parse_mode] = parse_mode if parse_mode
      api.send_message(**opts)
    rescue StandardError => e
      warn "Telegram send_message error: #{e.message}"
    end

    def fetch_pool_and_scores
      raise 'MealieClient required for swap/regenerate' unless @mealie
      raise 'Scorer required for swap/regenerate' unless @scorer

      pool = @mealie.eligible_pool(@cfg.mealie.eligible_tag)
      pool = pool.map do |recipe|
        full = @mealie.recipe(recipe['id'])
        ingredients = full['recipeIngredient'] || []
        shelf_lives = ingredients.filter_map do |ing|
          food = ing['food']
          next if food.nil? || food['onHand']

          extras = food['extras'] || {}
          days   = extras['shelf_life_days']&.to_i
          days ||= MealieClient.suggest_shelf_life(food['name'].to_s)
          days
        end
        recipe.merge('perishability' => shelf_lives.min || 365)
      rescue StandardError
        recipe.merge('perishability' => 365)
      end

      recipe_map = pool.to_h { |r| [r['id'], r] }
      @scorer.update_scores!(recipe_map)
      scored_ids = Models::RecipeStat.all.to_h { |s| [s.recipe_id, s.score.to_f] }

      [pool, scored_ids]
    rescue StandardError => e
      warn "fetch_pool_and_scores error: #{e.message}"
      [nil, {}]
    end

    def recently_planned?(recipe_id, since:)
      stat = Models::RecipeStat.find_by(recipe_id: recipe_id)
      return false if stat.nil? || stat.last_planned.nil?

      stat.last_planned.to_date >= since
    end

    def pending_plan
      Models::PlanHistory.where(approved: 0).order(created_at: :desc).first
    end

    # Match a day abbreviation/name to a date string in the plan.
    def find_date_for_day(plan, day_input)
      normalized = day_input.downcase.slice(0, 3).capitalize  # "mon" → "Mon"
      plan.keys.find do |date_str|
        Date.parse(date_str).strftime('%a') == normalized
      end
    end

    # Parse "/add" args into [qty, unit, name].
    # "2 lbs chicken thighs" → [2.0, "lbs", "chicken thighs"]
    # "milk" → [1.0, nil, "milk"]
    def parse_add_args(args)
      if args.length >= 3 && args[0].match?(/\A\d+(?:\.\d+)?\z/) && args[1].match?(/\A[a-zA-Z]+\z/)
        qty  = args[0].to_f
        unit = args[1]
        name = args[2..].join(' ')
      elsif args.length >= 2 && args[0].match?(/\A\d+(?:\.\d+)?\z/)
        qty  = args[0].to_f
        unit = nil
        name = args[1..].join(' ')
      else
        qty  = 1.0
        unit = nil
        name = args.join(' ')
      end
      [qty, unit, name]
    end

    # Parse a cadence string → [cadence_type, cadence_value] or nil.
    # Accepts: every_order, every_2_orders, every_n_orders, every_14_days, every_n_days
    # Also natural: "every order", "every 2 orders", "every 14 days"
    def parse_cadence(str)
      s = str.to_s.strip.downcase.gsub(/\s+/, '_')

      case s
      when 'every_order', 'every_1_order', 'every_1_orders'
        ['every_order', 1]
      when /\Aevery_(\d+)_orders?\z/
        n = Regexp.last_match(1).to_i
        n >= 1 ? ['every_n_orders', n] : nil
      when /\Aevery_(\d+)_days?\z/
        n = Regexp.last_match(1).to_i
        n >= 1 ? ['every_n_days', n] : nil
      end
    end

    def format_cadence(item)
      case item.cadence_type
      when 'every_order'   then 'every order'
      when 'every_n_orders' then "every #{item.cadence_value} orders"
      when 'every_n_days'  then "every #{item.cadence_value} days"
      else item.cadence_type
      end
    end

    # Run ShoppingListBuilder for an approved plan and return a formatted
    # Telegram message string. Catches errors so a list-build failure doesn't
    # crash the bot.
    def build_shopping_list_for(history)
      builder = ShoppingListBuilder.new(@cfg, mealie_client: @mealie)
      result  = builder.build_and_push(history)

      lines = ["✓ *Plan approved — shopping list pushed to Mealie!*", '']
      lines << "#{result.recipe_items} recipe ingredient(s)"
      lines << "#{result.recurring_count} recurring staple(s)" if result.recurring_count.positive?
      lines << "#{result.manual_count} manual addition(s) consumed" if result.manual_count.positive?
      lines << "#{result.pushed_count} total item(s) in _Next Order_"

      if result.unmapped_items.any?
        lines << ''
        lines << "⚠️ *#{result.unmapped_items.size} unmapped ingredient(s) — no Food Lion product set:*"
        result.unmapped_items.each { |name| lines << "  • #{name}" }
        lines << "_Run `scripts/seed_product_map.rb` to map them before building the cart._"
      end

      if result.warnings.any?
        lines << ''
        result.warnings.each { |w| lines << "⚠ #{w}" }
      end

      lines.join("\n")
    rescue StandardError => e
      warn "ShoppingListBuilder error: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      "✓ *Plan approved!*\n\n⚠️ Shopping list build failed: #{e.message.slice(0, 300)}\n" \
        "_Plan is saved. Run `main.rb shop` to retry._"
    end

    # Push an item to the Mealie "Next Order" shopping list.
    # Returns true on success, false on failure.
    def push_to_next_order(name:, quantity:, unit:)
      list = @mealie.find_or_create_shopping_list(@cfg.mealie.next_order_list)
      @mealie.add_shopping_list_item(list['id'], name: name, quantity: quantity, unit: unit)
      true
    rescue StandardError => e
      warn "Mealie shopping list push failed: #{e.message}"
      false
    end
  end
end
