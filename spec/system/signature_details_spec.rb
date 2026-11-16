# frozen_string_literal: true

require 'base64'

RSpec.describe 'Signature detail fitting' do
  let(:identifier) { '2F563FF3-FF4B-4139-8576-1234567890AB' }
  let(:signature_url) do
    svg = '<svg xmlns="http://www.w3.org/2000/svg" width="160" height="30">' \
          '<path d="M4 22 Q40 2 75 20 T154 12" fill="none" stroke="black" stroke-width="2"/></svg>'
    "data:image/svg+xml;base64,#{Base64.strict_encode64(svg)}"
  end

  before do
    sign_in(create(:user))
    visit root_path
  end

  def fixture_html(field_width)
    attachment = Data.define(:uuid, :created_at, :image_url) do
      def url(**) = image_url
    end.new(identifier, Time.utc(2026, 11, 16, 19, 18), signature_url)
    field = { 'name' => 'Signature', 'type' => 'signature',
              'preferences' => { 'font_size' => 11, 'with_signature_id' => true } }
    area = { 'x' => 232.0 / 612, 'y' => 374.0 / 792, 'w' => field_width / 612.0, 'h' => 30.0 / 792 }
    submitter = Data.define(:name, :email, :values).new('María García & Juan Pérez', 'client@example.invalid', {})
    locals = { field:, area:, value: 'signature', attachments_index: { 'signature' => attachment }, submitter:,
               page_width: 612, page_height: 792, font_scale: 1000.0 / 612,
               with_signature_id: false, locale: :en, timezone: 'UTC' }
    value = ApplicationController.render(partial: 'submissions/value', locals:)
    "<main style='position:relative;width:min(100vw,1000px);aspect-ratio:612/792;container-type:inline-size'>" \
      "#{value}</main>"
  end

  def annotation_metrics
    page.evaluate_async_script <<~JS
      const done = arguments[arguments.length - 1];
      customElements.whenDefined('signature-details').then(() => document.fonts.ready).then(() => {
        requestAnimationFrame(() => requestAnimationFrame(() => requestAnimationFrame(() => {
          const details = document.querySelector('signature-details');
          const bounds = details.getBoundingClientRect();
          const walker = document.createTreeWalker(details, NodeFilter.SHOW_TEXT);
          const rectangles = [];
          while (walker.nextNode()) {
            if (!walker.currentNode.textContent.trim()) continue;
            const range = document.createRange();
            range.selectNodeContents(walker.currentNode);
            rectangles.push(...range.getClientRects());
          }
          done({text: details.textContent, inside: rectangles.length > 0 && rectangles.every(rect =>
            rect.left >= bounds.left - 0.5 && rect.right <= bounds.right + 0.5 &&
            rect.top >= bounds.top - 0.5 && rect.bottom <= bounds.bottom + 0.5)});
        })));
      });
    JS
  end

  [375, 1200].product([160, 300]).each do |viewport, field_width|
    it "shows all signature metadata in a #{field_width}-point field at #{viewport}px" do
      page.current_window.resize_to(viewport, 900)
      page.execute_script('document.body.innerHTML = arguments[0]', fixture_html(field_width))
      metrics = annotation_metrics
      expect(metrics).to include('inside' => true)
      expect(metrics.fetch('text')).to include(identifier, 'María García & Juan Pérez', 'client@example.invalid',
                                               '2026')

      page.current_window.resize_to(viewport == 375 ? 1200 : 375, 900)
      expect(annotation_metrics).to include('inside' => true)

      email = "#{'x' * 64}@#{'a' * 63}.#{'b' * 63}.#{'c' * 53}.invalid"
      name = "#{'W' * 95} & #{'Z' * 102}"
      rows = ["ID: #{identifier}", "Digitally signed by #{name}", "<#{email}>", 'November 16, 2026 at 1:18 PM CST']
      page.execute_script(<<~JS, rows)
        const content = document.querySelector('signature-details').firstElementChild;
        content.replaceChildren(...arguments[0].map(text => {
          const row = document.createElement('div'); row.textContent = text; return row;
        }));
      JS
      metrics = annotation_metrics
      expect(metrics).to include('inside' => true)
      expect(metrics.fetch('text')).to include(identifier, name, email, 'November 16, 2026 at 1:18 PM CST')

      font = Base64.strict_encode64(Rails.public_path.join('fonts/bennett-noto-serif-latin.woff2').binread)
      page.evaluate_async_script(<<~JS, font)
        const done = arguments[arguments.length - 1];
        const face = new FontFace('LateSignatureFont', `url(data:font/woff2;base64,${arguments[0]})`);
        document.fonts.add(face);
        document.querySelector('signature-details').firstElementChild.style.fontFamily = 'LateSignatureFont, Arial';
        face.load().then(() => done(true));
      JS
      expect(annotation_metrics).to include('inside' => true)

      page.execute_script(<<~JS)
        const details = document.querySelector('signature-details');
        details.style.lineHeight = '0.7';
        details.firstElementChild.append(document.createTextNode(' Font metric regression'));
      JS
      expect(annotation_metrics).to include('inside' => true)
    end
  end
end
