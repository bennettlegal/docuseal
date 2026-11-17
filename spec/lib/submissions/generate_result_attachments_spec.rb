# frozen_string_literal: true

RSpec.describe Submissions::GenerateResultAttachments do
  [[160, 60], [300, 30]].each do |width, height|
    it "generates a completed signature and its details in a #{width} by #{height}-point field" do
      author = create(:user)
      template = create(:template, author:, account: author.account, only_field_types: ['signature'])
      field = template.fields.sole
      field['preferences'] = { 'with_signature_id' => true, 'font_size' => 11 }
      field['areas'].sole.merge!('w' => width / 612.0, 'h' => height / 792.0)
      template.save!
      submission = create(:submission, :with_submitters, template:, created_by_user: template.author)
      signer = submission.submitters.sole
      Rails.root.join('spec/fixtures/sample-image.png').open do |io|
        signer.attachments.attach(io:, filename: 'signature.png', content_type: 'image/png')
      end
      signature = signer.attachments.last
      signer.update!(name: 'Synthetic Client', email: 'client@example.invalid', completed_at: Time.current,
                     values: { field.fetch('uuid') => signature.uuid })

      pdf = described_class.generate_pdfs(signer).values.sole
      bytes = StringIO.new
      pdf.write(bytes)
      result = HexaPDF::Document.new(io: StringIO.new(bytes.string))
      expect(result.pages.count).to eq(1)
      expect(result.pages.first[:Resources][:XObject]).to be_present
      text = Pdfium::Document.open_bytes(bytes.string) { |doc| doc.get_page(0).text }.gsub(/\s+/, '')
      expect(text).to include("ID:#{signature.uuid.upcase}", 'DigitallysignedbySyntheticClient',
                              '<client@example.invalid>')
    end
  end
end
