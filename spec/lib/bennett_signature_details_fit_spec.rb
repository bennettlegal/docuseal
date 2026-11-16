# frozen_string_literal: true

require 'hexapdf'
require_relative '../../lib/bennett_signature_details_fit'

RSpec.describe BennettSignatureDetailsFit do
  let(:document) { HexaPDF::Document.new }
  let(:font) { document.fonts.add('Helvetica') }
  let(:identifier) { '2F563FF3-FF4B-4139-8576-1234567890AB' }
  let(:details) do
    "ID: #{identifier}\nDigitally signed by María García & Juan Pérez\n" \
      "<synthetic-long-signing-address@example.invalid>\nNovember 16, 2026 at 1:18 PM CST"
  end

  [78, 148].each do |width|
    it "retains every character within a #{width}-point annotation column" do
      result = described_class.fit(details, font:, font_size: 6, width:, height: 28)
      expect(result.status).to eq(:success)
      expect(result.lines.sum(&:height)).to be <= 28
      expect(result.lines.map(&:width).max).to be <= width

      page = document.pages.add
      result.draw(page.canvas, 100, 600)
      bytes = StringIO.new
      document.write(bytes)
      serialized = HexaPDF::Document.new(io: StringIO.new(bytes.string))
      reader = Class.new(HexaPDF::Content::Processor) do
        attr_reader :text

        def initialize
          super
          @text = +''
        end

        def show_text(data)
          @text << decode_text_with_positioning(data).string
        end
        alias_method :show_text_with_positioning, :show_text
      end.new
      serialized.pages.first.process_contents(reader)
      expect(reader.text.gsub(/\s+/, '')).to eq(details.gsub(/\s+/, ''))
    end
  end

  it 'fits bounded long client names and email addresses without omitting their ends' do
    value = "ID: #{identifier}\nDigitally signed by #{'W' * 200}\n<#{'x' * 242}@example.co>\n" \
            'November 16, 2026 at 1:18 PM CST'
    result = described_class.fit(value, font:, font_size: 6, width: 148, height: 28)
    expect(result.status).to eq(:success)
    expect(result.lines.sum(&:height)).to be <= 28
  end

  it 'refuses an impossible rectangle instead of returning a partial annotation' do
    expect { described_class.fit(details, font:, font_size: 6, width: 1, height: 1) }
      .to raise_error(ArgumentError, 'Signature details do not fit their field')
  end
end
