# frozen_string_literal: true

require 'action_view'
require 'active_support/all'

RSpec.describe 'submissions/_value' do
  let(:view) { ActionView::Base.with_empty_template_cache.new(ActionView::LookupContext.new('app/views'), {}, nil) }
  let(:attachment) do
    Class.new do
      def uuid = 'signature-reference'
      def created_at = Time.utc(2026, 11, 14)
      def url(**) = '/signature.png'
    end.new
  end
  let(:submitter) { Data.define(:name, :email, :values).new('Synthetic Client', 'synthetic@example.invalid', {}) }
  let(:field) { { 'name' => 'Signature', 'type' => 'signature', 'preferences' => { 'font_size' => 9 } } }
  let(:area) { { 'x' => 0.2, 'y' => 0.5, 'w' => 160.0 / 612, 'h' => 30.0 / 792 } }

  before do
    stub_const('ActiveStorage::Attachment', Class.new { def self.service_url_time = 300 })
    stub_const('TimeUtils', Class.new { def self.timezone_abbr(*) = 'UTC' })
  end

  def render_signature(account_preference)
    view.render(partial: 'submissions/value', locals: {
                  field:, area:, value: 'signature', attachments_index: { 'signature' => attachment },
                  submitter:, page_width: 612, page_height: 792, font_scale: 1.0,
                  with_signature_id: account_preference, locale: :en, timezone: 'UTC'
                })
  end

  it 'uses the whole field for a clean signature even when account annotations are enabled' do
    field['preferences']['with_signature_id'] = false
    html = render_signature(true)
    expect(html).to include('/signature.png', 'flex-grow')
    expect(html).not_to include('ID:', 'Synthetic Client', 'synthetic@example.invalid', 'w-1/2')
  end

  it 'retains an explicit field opt-in even when account annotations are disabled' do
    field['preferences']['with_signature_id'] = true
    html = render_signature(false)
    expect(html).to include('ID: signature-reference', 'Synthetic Client', 'synthetic@example.invalid')
  end

  it 'inherits the account setting when the field has no preference' do
    expect(render_signature(true)).to include('ID: signature-reference')
    expect(render_signature(false)).not_to include('ID:', 'Synthetic Client')
  end

  it 'preserves required signing reasons when the signature ID preference is off' do
    field['preferences'].merge!('with_signature_id' => false, 'reason_field_uuid' => 'reason')
    submitter.values['reason'] = 'Authorized representative'
    expect(render_signature(true)).to include('Authorized representative')
  end

  it 'bounds legacy annotation and signature containers inside their field' do
    html = Nokogiri::HTML.fragment(render_signature(true))
    signature = html.at_css('field-value > div')
    expect(signature['class']).to include('overflow-hidden')
    expect(signature.css('> div').pluck('class')).to all(include('min-w-0', 'overflow-hidden'))
    details = signature.at_css('signature-details')
    expect(details['class']).to include('min-w-0', 'min-h-0', 'h-full', 'overflow-hidden')
    expect(details.at_css('.uppercase')['class']).not_to include('truncate')
  end
end
