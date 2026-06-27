# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'autochef/safety'

RSpec.describe Autochef::Safety do
  let(:safety_cfg) do
    double('SafetyConfig',
           spending_cap_usd:         150,
           cart_deviation_alert_pct: 20,
           kill_switch_file:         kill_switch_path,
           dry_run:                  true)
  end
  let(:cfg) { double('Config', safety: safety_cfg) }

  # Use a temp dir so tests never create real files in the project.
  let(:tmpdir)          { Dir.mktmpdir }
  let(:kill_switch_path) { File.join(tmpdir, 'PAUSE') }

  after(:each) { FileUtils.rm_rf(tmpdir) }

  # Safety uses Autochef::REPO_ROOT to expand the kill switch path.
  # Stub it to point at our temp dir so we can create/remove the file freely.
  before(:each) do
    stub_const('Autochef::REPO_ROOT', tmpdir)
    # kill_switch_file in config is a relative path from REPO_ROOT.
    allow(safety_cfg).to receive(:kill_switch_file).and_return('PAUSE')
  end

  subject(:safety) { described_class.new(cfg) }

  # ── kill switch ───────────────────────────────────────────────────────────

  describe '#check_kill_switch!' do
    it 'does not raise when the kill-switch file is absent' do
      expect { safety.check_kill_switch! }.not_to raise_error
    end

    it 'raises KillSwitchError when the kill-switch file exists' do
      FileUtils.touch(kill_switch_path)
      expect { safety.check_kill_switch! }
        .to raise_error(Autochef::Safety::KillSwitchError, /Kill switch active/)
    end
  end

  # ── spending cap ─────────────────────────────────────────────────────────

  describe '#check_spending_cap!' do
    it 'does not raise when total is under the cap' do
      expect { safety.check_spending_cap!(100.0) }.not_to raise_error
    end

    it 'does not raise when total exactly equals the cap' do
      expect { safety.check_spending_cap!(150.0) }.not_to raise_error
    end

    it 'raises SpendingCapError when total exceeds the cap' do
      expect { safety.check_spending_cap!(200.0) }
        .to raise_error(Autochef::Safety::SpendingCapError, /200/)
    end

    it 'does not raise when total is nil (unknown)' do
      expect { safety.check_spending_cap!(nil) }.not_to raise_error
    end
  end

  # ── idempotency ───────────────────────────────────────────────────────────

  describe '#check_idempotency!' do
    let(:run_key) { 'autochef-2026-06-28' }

    it 'does not raise when no order exists for the run_key' do
      expect { safety.check_idempotency!(run_key) }.not_to raise_error
    end

    it 'raises IdempotencyError when a cart_built row exists for the run_key' do
      Autochef::Models::OrderHistory.create!(
        run_key: run_key, status: 'cart_built', week_start: Date.today
      )
      expect { safety.check_idempotency!(run_key) }
        .to raise_error(Autochef::Safety::IdempotencyError, /already built/)
    end

    it 'does not raise when a non-cart_built row exists (e.g. aborted)' do
      Autochef::Models::OrderHistory.create!(
        run_key: run_key, status: 'aborted', week_start: Date.today
      )
      expect { safety.check_idempotency!(run_key) }.not_to raise_error
    end
  end

  # ── deviation warning ─────────────────────────────────────────────────────

  describe '#deviation_warning' do
    it 'returns nil when either value is nil' do
      expect(safety.deviation_warning(nil, 120.0)).to be_nil
      expect(safety.deviation_warning(100.0, nil)).to be_nil
    end

    it 'returns nil when deviation is within threshold' do
      expect(safety.deviation_warning(100.0, 115.0)).to be_nil  # 15% < 20%
    end

    it 'returns a warning string when deviation exceeds threshold' do
      result = safety.deviation_warning(100.0, 130.0)  # 30% > 20%
      expect(result).to be_a(String)
      expect(result).to match(/deviates/)
    end
  end

  # ── idempotency_key ────────────────────────────────────────────────────────

  describe '#idempotency_key' do
    it 'returns autochef-YYYY-MM-DD for a Date' do
      expect(safety.idempotency_key(Date.new(2026, 6, 28))).to eq('autochef-2026-06-28')
    end

    it 'returns autochef-YYYY-MM-DD for a String' do
      expect(safety.idempotency_key('2026-06-28')).to eq('autochef-2026-06-28')
    end
  end
end
