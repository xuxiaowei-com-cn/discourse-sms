# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseSms::PhoneNumber do
  describe ".normalize" do
    it "keeps an E.164 number as is" do
      expect(described_class.normalize("+8613800138000")).to eq("+8613800138000")
    end

    it "strips formatting characters" do
      expect(described_class.normalize("+86 138-0013-8000")).to eq("+8613800138000")
      expect(described_class.normalize("+1 (415) 555-2671")).to eq("+14155552671")
    end

    it "adds the default country code to a local number" do
      expect(described_class.normalize("13800138000")).to eq("+8613800138000")
    end

    it "does not duplicate an already present country code" do
      expect(described_class.normalize("8613800138000")).to eq("+8613800138000")
    end

    it "accepts the international 00 prefix" do
      expect(described_class.normalize("008613800138000")).to eq("+8613800138000")
    end

    it "uses the configured default country code" do
      expect(described_class.normalize("4155552671", default_country_code: "1")).to eq(
        "+14155552671",
      )
    end

    it "ignores leading zeros in the configured country code" do
      expect(described_class.normalize("4155552671", default_country_code: "001")).to eq(
        "+14155552671",
      )
    end

    it "rejects blank values" do
      expect(described_class.normalize(" ")).to be_nil
    end

    it "rejects values containing letters" do
      expect(described_class.normalize("+861380013800O")).to be_nil
    end

    it "rejects numbers that are too short or too long" do
      expect(described_class.normalize("+1234567")).to be_nil
      expect(described_class.normalize("+1234567890123456")).to be_nil
    end
  end

  describe ".valid?" do
    it "accepts E.164 numbers" do
      expect(described_class.valid?("+8613800138000")).to eq(true)
    end

    it "rejects numbers without a plus prefix" do
      expect(described_class.valid?("8613800138000")).to eq(false)
    end
  end

  describe ".mask" do
    it "hides the middle of the number" do
      expect(described_class.mask("+8613800138000")).to eq("+8613****8000")
    end

    it "keeps short values unchanged" do
      expect(described_class.mask("+1234567")).to eq("+1234567")
    end

    it "returns nil for a blank value" do
      expect(described_class.mask(nil)).to be_nil
    end
  end
end
