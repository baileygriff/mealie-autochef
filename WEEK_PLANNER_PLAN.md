# Implementation Plan: Week Configurator — Sinatra Form

> For a fresh agent. Read this document in full before writing any code.
> Also read TESTING_HANDOFF.md for project context, stack notes, and gotchas.

---

## What we're building

A per-week configuration form that lets Bailey adjust the meal plan before it's generated,
without touching config.yaml. Served by a lightweight Sinatra app embedded in the existing
Ruby process. The Telegram plan-draft message gets a "Configure week →" link button. Bailey
taps it on mobile (accessible via Tailscale), fills out the form, hits Submit. The next call
to `main.rb plan` (or Regenerate in Telegram) picks up those preferences.

This step is optional — if no preferences are submitted for the current week, everything
falls back to config.yaml defaults exactly as before.

### Per-day controls

For each cook/leftover day in the week layout:

| Control | Options | Default |
|---|---|---|
| Meal type | Cook / Leftover / Skip | from config.yaml week_layout |
| Dinner servings | 1–8 (spinner) | config.yaml default_servings |
| Dinner vibe | Feed Me (quick/easy) / Treat (fancier) | Feed Me |
| Lunch | Enabled checkbox + same servings/vibe if on | off (no lunch by default) |
| Dietary note | Free text | blank |

### Global week controls

- Protein excludes: tap-to-toggle chips — No Seafood, No Beef, No Pork, Vegetarian only
- Week-level freeform note (goes to LLM)

### Dietary preference strategy

| Preference | Mechanism |
|---|---|
| No seafood / No beef / No pork / Vegetarian only | Hard pool filter before scoring (protein tags already exist) |
| Everything else ("gluten free", "nothing spicy") | Appended to `freeform_note` → LLM best effort |

---

## Modular design requirement

The Sinatra form is one *source* of week preferences. Future sources (Telegram Mini App,
REST API, native mobile app) must be drop-in replacements. Achieve this via a simple
`WeekPrefsSource` interface module. The planner only calls `source.fetch(week_start)` —
it never knows it's talking to Sinatra specifically.

---

## Files to create

```
lib/autochef/
  week_prefs_source.rb        # Interface module (3 lines)
  sinatra_prefs_source.rb     # DB-backed implementation
  web/
    app.rb                    # Sinatra::Base subclass
    views/
      week_config.erb         # The form
      submitted.erb           # Confirmation page

db/migrate/
  007_create_week_prefs.rb    # Migration

spec/
  week_prefs_spec.rb          # Unit tests
```

## Files to modify

```
main.rb                       # cmd_plan: load prefs + apply; serve: start Sinatra thread
lib/autochef/notify.rb        # run_regenerate: apply prefs; plan message: add Configure button
config.yaml                   # Add web: section (port, enabled)
Gemfile                       # Add sinatra, sinatra-contrib
```

---

## Implementation steps

Work through these in order. Run `bundle exec rspec` after each step to catch regressions.

### Step 1 — Gemfile

Add to Gemfile:
```ruby
gem 'sinatra', '~> 4.0'
gem 'sinatra-contrib', '~> 4.0'    # for erb helpers, json
gem 'puma', '~> 6.0'               # threaded server for running alongside Telegram bot
```

Run `bundle install`.

### Step 2 — config.yaml

Add a `web:` section at the bottom:

```yaml
web:
  enabled: true
  port: 3456
```

Add the corresponding struct to `lib/autochef/config.rb` so `cfg.web.port` and
`cfg.web.enabled` work. Look at how other sections (e.g. `cfg.safety`, `cfg.llm`) are
defined there — follow the exact same pattern (OpenStruct or Struct, `symbolize_names: true`).

### Step 3 — Migration

Create `db/migrate/007_create_week_prefs.rb`:

```ruby
class CreateWeekPrefs < ActiveRecord::Migration[7.2]
  def change
    create_table :week_prefs do |t|
      t.date   :week_start, null: false
      t.text   :prefs_json, null: false, default: '{}'
      t.timestamps
    end
    add_index :week_prefs, :week_start, unique: true
  end
end
```

### Step 4 — WeekPrefs model + data structs

Create `lib/autochef/models/week_pref.rb`:

```ruby
module Autochef
  module Models
    class WeekPref < ActiveRecord::Base
      self.table_name = 'week_prefs'

      def prefs
        prefs_json.present? ? JSON.parse(prefs_json, symbolize_names: true) : {}
      end

      def prefs=(hash)
        self.prefs_json = hash.to_json
      end
    end
  end
end
```

Define lightweight structs in `lib/autochef/week_prefs_source.rb`:

```ruby
module Autochef
  # Data objects — provider-agnostic
  MealSlotPrefs = Struct.new(:enabled, :servings, :vibe, :note, keyword_init: true)
  DayPrefs      = Struct.new(:meal_type, :dinner, :lunch, keyword_init: true)
  WeekPrefs     = Struct.new(:week_start, :protein_excludes, :freeform_note, :days,
                             keyword_init: true)

  # Interface — implement #fetch(week_start) -> WeekPrefs or nil
  module WeekPrefsSource
    def fetch(week_start)
      raise NotImplementedError, "#{self.class}#fetch not implemented"
    end
  end
end
```

### Step 5 — SinatraPrefsSource

Create `lib/autochef/sinatra_prefs_source.rb`:

```ruby
require_relative 'week_prefs_source'
require_relative 'models/week_pref'

module Autochef
  class SinatraPrefsSource
    include WeekPrefsSource

    def fetch(week_start)
      row = Models::WeekPref.find_by(week_start: week_start)
      return nil unless row

      raw = row.prefs
      days = (raw[:days] || {}).transform_values do |d|
        DayPrefs.new(
          meal_type: d[:meal_type],
          dinner: slot_from(d[:dinner]),
          lunch:  slot_from(d[:lunch])
        )
      end

      WeekPrefs.new(
        week_start:       week_start,
        protein_excludes: raw[:protein_excludes] || [],
        freeform_note:    raw[:freeform_note].to_s,
        days:             days
      )
    end

    def save(week_start, params)
      row = Models::WeekPref.find_or_initialize_by(week_start: week_start)
      row.prefs = build_prefs_hash(params)
      row.save!
    end

    private

    def slot_from(h)
      return MealSlotPrefs.new(enabled: false) unless h
      MealSlotPrefs.new(
        enabled:  h[:enabled] != false,
        servings: h[:servings]&.to_i,
        vibe:     h[:vibe],
        note:     h[:note].to_s
      )
    end

    def build_prefs_hash(params)
      # params comes from the Sinatra form POST — see web/app.rb for field names
      {
        protein_excludes: Array(params[:protein_excludes]),
        freeform_note:    params[:freeform_note].to_s.strip,
        days: build_days_hash(params)
      }
    end

    def build_days_hash(params)
      (params[:days] || {}).each_with_object({}) do |(date_str, day), h|
        h[date_str] = {
          meal_type: day[:meal_type],
          dinner: {
            enabled:  true,
            servings: day.dig(:dinner, :servings)&.to_i,
            vibe:     day.dig(:dinner, :vibe),
            note:     day.dig(:dinner, :note).to_s.strip
          },
          lunch: {
            enabled:  day.dig(:lunch, :enabled) == '1',
            servings: day.dig(:lunch, :servings)&.to_i,
            vibe:     day.dig(:lunch, :vibe),
            note:     day.dig(:lunch, :note).to_s.strip
          }
        }
      end
    end
  end
end
```

### Step 6 — Sinatra web app

Create `lib/autochef/web/app.rb`:

```ruby
require 'sinatra/base'
require_relative '../sinatra_prefs_source'
require_relative '../planner'   # for next_week_start helper if needed

module Autochef
  module Web
    class App < Sinatra::Base
      set :views, File.expand_path('views', __dir__)
      set :public_folder, File.expand_path('public', __dir__)

      # Injected at startup — keeps the web layer decoupled from global state
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
        # Mirror planner.rb logic — next occurrence of pickup_day
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
```

#### Views

Create `lib/autochef/web/views/week_config.erb`.

The form must:
- Show one section per day in the week layout (`@cfg.meals.week_layout`)
- Default each day's meal_type from config, overridden by `@existing` if present
- Default servings from `@cfg.meals.default_servings`
- Default vibe to "feed_me"
- Show protein-exclude toggle chips (No Seafood, No Beef, No Pork, Vegetarian only)
- Show a global freeform note field
- Be mobile-friendly (single-column layout, large tap targets, no JS required beyond basic form)

Use plain HTML + inline CSS. Keep it minimal — this is an internal tool, not a product.
No JavaScript frameworks. Checkboxes for lunch-enabled that show/hide the lunch sub-form
can use CSS `:has()` or just always show the lunch row collapsed behind a checkbox.

Structure each day row as:
```
[Day name + date]  [Cook ● | Leftover ○ | Skip ○]
  Dinner: [2 ▾] people   [Feed Me ● | Treat ○]   Note: [________]
  Lunch:  [☐ Enable]  (expands same fields if enabled)
```

Form field names must match what `SinatraPrefsSource#build_days_hash` expects:
- `days[2026-07-02][meal_type]`
- `days[2026-07-02][dinner][servings]`
- `days[2026-07-02][dinner][vibe]`
- `days[2026-07-02][dinner][note]`
- `days[2026-07-02][lunch][enabled]` (value "1" when checked)
- `days[2026-07-02][lunch][servings]`
- `days[2026-07-02][lunch][vibe]`
- `protein_excludes[]` (multi-value checkboxes)
- `freeform_note`

Create `lib/autochef/web/views/submitted.erb` — a simple confirmation page that says
"Preferences saved for week of [date]. Close this tab and regenerate your plan in Telegram."

### Step 7 — Apply prefs in cmd_plan (main.rb)

In `main.rb`, find the `cmd_plan` method. After the pool is fetched and before it's passed
to `LlmPlanner`, add the prefs application block:

```ruby
prefs_source = Autochef::SinatraPrefsSource.new
week_prefs   = prefs_source.fetch(next_week_start)  # next_week_start comes from planner

if week_prefs
  # 1. Hard-filter pool by protein exclusions
  week_prefs.protein_excludes.each do |excluded|
    pool.reject! { |r| (r['tags'] || []).any? { |t| t['name'] == "protein:#{excluded}" } }
  end

  # 2. Apply day-level overrides to week_layout before passing to planner
  #    (override meal_type, servings per day)
  layout_overrides = week_prefs.days.each_with_object({}) do |(date_str, dp), h|
    h[Date.parse(date_str)] = dp
  end
  
  # 3. Build combined freeform note from global + per-day vibe + notes
  vibe_notes = week_prefs.days.filter_map do |date_str, dp|
    next unless dp.dinner
    label = dp.dinner.vibe == 'treat' ? 'Treat meal' : nil
    note  = dp.dinner.note.to_s.strip
    [Date.parse(date_str).strftime('%a'), [label, note].compact.join(': ')].join(' ')  if label || note.any?
  end
  combined_note = [week_prefs.freeform_note, *vibe_notes].reject(&:empty?).join('. ')
end

result = llm_planner.plan(
  pool:          pool,
  scored_ids:    scored_ids,
  freeform_note: combined_note || cfg.llm.freeform_note_default
)
```

For the day-level meal_type overrides (skip/leftover), the cleanest approach is to pass
`layout_overrides` as a new optional parameter to `Planner#plan` and have it merge them
into the derived `cook_dates`/`leftover_dates` before assigning. Add the parameter to
`Planner#plan(pool:, scored_ids:, week_start:, layout_overrides: {})` and skip or
reclassify dates that appear in `layout_overrides` with `meal_type: 'skip'` or `'leftover'`.

Servings override: pass per-day servings through to `build_assignment` via a hash keyed
by date. Look at how `default_servings` flows through today — follow the same path.

### Step 8 — Apply prefs in regenerate (notify.rb)

In `notify.rb`'s `run_regenerate` method, apply the same prefs block as Step 7 before
calling `llm_planner.plan`. The `SinatraPrefsSource` is stateless so it can be
instantiated inline.

### Step 9 — Add "Configure week" link to Telegram plan message

In `notify.rb`'s `build_plan_message`, add a URL button row above the Approve button:

```ruby
web_url = "http://#{cfg_host}:#{cfg_port}/week"
keyboard_rows.unshift([
  Telegram::Bot::Types::InlineKeyboardButton.new(
    text: '⚙ Configure week', url: web_url
  )
])
```

The host/port come from `@cfg.web`. Use `192.168.1.64` as the host (same as the Unraid
box IP). The Telegram bot already knows `@cfg` — add `@cfg.web.port` and
`@cfg.web.host` to the `web:` config section (add `host: "192.168.1.64"` to config.yaml).

### Step 10 — Wire Sinatra into main.rb serve

In `main.rb`'s `cmd_serve`:

```ruby
if cfg.web.enabled
  prefs_source = Autochef::SinatraPrefsSource.new
  Autochef::Web::App.configure_autochef(cfg: cfg, prefs_source: prefs_source)
  Thread.new do
    Autochef::Web::App.run!(port: cfg.web.port, bind: '0.0.0.0', quiet: true)
  end
  puts "Week configurator running at http://#{cfg.web.host}:#{cfg.web.port}/week"
end
```

`bind: '0.0.0.0'` is needed so Tailscale can route to it. The app only listens on the
local network — no internet exposure.

### Step 11 — Add require statements

In `main.rb`, add near the top with the other requires:
```ruby
require_relative 'lib/autochef/web/app'
require_relative 'lib/autochef/sinatra_prefs_source'
```

In `lib/autochef/models/week_pref.rb`, ensure it's required from `database.rb` alongside
the other models.

### Step 12 — Specs

Create `spec/week_prefs_spec.rb`. Test:
1. `SinatraPrefsSource#save` persists a round-trippable prefs hash
2. `SinatraPrefsSource#fetch` returns nil for unknown week_start
3. `SinatraPrefsSource#fetch` deserializes protein_excludes correctly
4. `SinatraPrefsSource#fetch` returns correct MealSlotPrefs for dinner/lunch
5. A plan with `protein_excludes: ['seafood']` excludes the Greek Salmon and Lemon Pasta
   recipes from the pool (use the same fixture recipes used in planner_spec.rb)

Use in-memory SQLite (same pattern as other specs — look at spec_helper.rb).

---

## Verification steps

After implementation:

1. `bundle exec rspec` — all existing + new specs pass

2. Start the server:
   ```bash
   bundle exec ruby main.rb serve
   ```
   Verify console shows "Week configurator running at http://192.168.1.64:3456/week"

3. Open http://localhost:3456/week in a browser. Verify:
   - Form loads without error
   - All 7 days from week_layout appear with correct defaults
   - Protein exclude chips are present
   - Freeform note field is present

4. Submit a test preference:
   - Skip one day
   - Set one dinner to "Treat" with 4 servings
   - Check "No Seafood"
   - Add a freeform note "Light week"
   - Submit — verify confirmation page loads

5. Run `bundle exec ruby main.rb plan`:
   - Skipped day should not appear in plan output
   - Treat day should have 4 servings and vibe noted in LLM output
   - No seafood recipes (Greek Salmon, Lemon Pasta with Salmon, Fish Tacos) should not appear
   - LLM note should include "Light week"

6. Test mobile via Tailscale: open http://192.168.1.64:3456/week on phone

7. Run `bundle exec rspec` again after full test to confirm no regressions

---

## Commit and push

Once all verification passes:

```bash
bundle exec rspec
git add Gemfile Gemfile.lock config.yaml main.rb \
        lib/autochef/web/ lib/autochef/web/views/ \
        lib/autochef/week_prefs_source.rb lib/autochef/sinatra_prefs_source.rb \
        lib/autochef/models/week_pref.rb lib/autochef/notify.rb \
        db/migrate/007_create_week_prefs.rb spec/week_prefs_spec.rb
git commit -m "Add week configurator: Sinatra form for per-day plan preferences"
git push
```

Update `TESTING_HANDOFF.md` to mark this step complete and update "What's coming next."

---

## Gotchas for this feature

**Sinatra + Telegram bot in the same process**: Sinatra's `run!` is blocking by default.
Use `Thread.new { App.run!(...) }` so it doesn't block the Telegram polling loop. Puma
is thread-safe; WEBrick (Sinatra's default) is not — Gemfile must include `puma`.

**config.yaml week_layout keys are symbols**: `cfg.meals.week_layout` is keyed by
`:Sun`, `:Mon` etc. (not strings). When iterating to build the form, call `.to_s` on keys.

**AR 7.2 migration context**: Follow the exact same migration pattern already in
`database.rb` — do not use the standalone `ActiveRecord::SchemaMigration` constant.
Look at the comment in `database.rb` before writing any migration code.

**`week_start` is pickup-day-anchored (Thursday)**: The form and the planner both anchor
on the next Thursday pickup date, not Sunday. Use the same `next_week_start` logic from
`planner.rb` when computing what week to display.

**Tailscale routing**: The Sinatra app must bind to `0.0.0.0`, not `127.0.0.1`, for
Tailscale to route to it. The `bind: '0.0.0.0'` option in `App.run!` handles this.

**Form params are strings**: Sinatra form POST gives string values. `servings` will be
`"2"` not `2`. Always `.to_i` numeric fields. Boolean checkboxes send `"1"` when checked
and are absent when unchecked — check for `== '1'`, not truthiness.
