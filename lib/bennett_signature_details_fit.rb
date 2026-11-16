# frozen_string_literal: true

# Keep the complete signature reference and signer details inside a wide field.
module BennettSignatureDetailsFit
  module_function

  def fit(value, font:, font_size:, width:, height:)
    raise ArgumentError, 'Signature details need a positive field size' unless width.positive? && height.positive?

    size = font_size.to_f
    loop do
      text = HexaPDF::Layout::TextFragment.create(value, font:, font_size: size, line_height: size * 1.1)
      layouter = HexaPDF::Layout::TextLayouter.new(font:, font_size: size, text_valign: :top, text_align: :left)
      result = layouter.fit([text], width, height)
      return result if result.status == :success && result.lines.sum(&:height) <= height &&
                       result.lines.all? { |line| line.width <= width + 0.01 }

      raise ArgumentError, 'Signature details do not fit their field' if size <= 1.5

      size = [size - 0.25, 1.5].max
    end
  end
end
