# frozen_string_literal: true

RSpec.describe ProcessSubmitterCompletionJob do
  include ActiveJob::TestHelper

  let(:user) { create(:user, email: 'attorney@example.invalid') }
  let(:account) { user.account }
  let(:template) { create(:template, account:, author: user, submitter_count: 2) }
  let(:issuance) { SecureRandom.uuid }
  let(:reference) { 'LEAD-2099-02739' }
  let(:language) { 'en' }
  let(:submission) do
    create(:submission, template:, created_by_user: user, source: 'api', submitters_order: 'preserved',
                        preferences: { 'send_email' => false }, completed_at: Time.current,
                        variables: { 'bennett_issuance_id' => issuance })
  end
  let(:client) do
    create(:submitter, submission:, uuid: submission.template_submitters.first['uuid'],
                       name: 'Synthetic Client', email: 'client@example.invalid', external_id: "#{issuance}:0",
                       preferences: { 'send_email' => false }, metadata: { 'lang' => language },
                       completed_at: 1.minute.ago)
  end
  let(:firm) do
    create(:submitter, submission:, uuid: submission.template_submitters.last['uuid'],
                       name: 'Synthetic Attorney', email: user.email, external_id: "#{issuance}:1",
                       preferences: { 'send_email' => true }, completed_at: Time.current,
                       metadata: { 'lang' => language, 'bennett_jud_context' => context })
  end
  let(:context) do
    { 'version' => 'jud-retainer-email/1', 'issuance_id' => issuance, 'record_type' => 'lead',
      'reference' => reference, 'url' => "https://jud.bennettlegal.com/intake/leads##{reference}",
      'client_name' => 'Synthetic Client' }
  end
  let(:pdf) { Rails.root.join('spec/fixtures/sample-document.pdf').binread }
  let(:audit) { "#{pdf}\n% synthetic audit" }

  around do |example|
    adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
  ensure
    ActiveJob::Base.queue_adapter = adapter
  end

  before do
    clear_enqueued_jobs
    clear_performed_jobs
    ActionMailer::Base.deliveries.clear
    client
    firm.documents.attach(io: StringIO.new(pdf), filename: 'signed.pdf', content_type: 'application/pdf')
    submission.audit_trail.attach(io: StringIO.new(audit), filename: 'audit.pdf', content_type: 'application/pdf')
    LockEvent.create!(key: "result_attachments:#{firm.id}", event_name: :complete)
    submission.submitters.reload
  end

  def deliver_completed_copies
    perform_enqueued_jobs { described_class.new.enqueue_completed_emails(firm) }
    ActionMailer::Base.deliveries
  end

  %w[en es].each do |locale|
    context "with a #{locale} JUD first-email signing request" do
      let(:language) { locale }

      it 'delivers the final PDF and audit separately to the client and attorney without another invitation' do
        messages = deliver_completed_copies
        expect(messages.map(&:to)).to contain_exactly([client.email], [firm.email])
        client_message = messages.find { |mail| mail.to == [client.email] }
        firm_message = messages.find { |mail| mail.to == [firm.email] }
        expect(client_message.subject).not_to include(reference)
        expect(client_message.html_part.decoded).not_to include('jud.bennettlegal.com', reference)
        expect(firm_message.html_part.decoded).to include(reference)
        expected = locale == 'es' ? 'Gracias por firmar.' : 'Thank you for signing.'
        expect(client_message.html_part.decoded).to include(expected)
        messages.each do |mail|
          expect(mail.attachments.map(&:decoded)).to include(pdf, audit)
        end
        expect(client.reload.preferences['send_email']).to be(false)
        expect(SendSubmitterInvitationEmailJob.jobs).to be_empty
        expect(EmailEvent.where(tag: 'submitter_documents_copy').pluck(:email))
          .to contain_exactly(client.email, firm.email)
      end
    end
  end

  it 'keeps ordinary native recipient email opt-outs unchanged' do
    submission.update!(variables: {})
    expect(deliver_completed_copies.map(&:to)).to eq([[firm.email]])
  end

  it 'does not treat invalid JUD context as permission to mail an opted-out recipient' do
    firm.update!(metadata: { 'bennett_jud_context' => context.merge('url' => 'https://example.invalid/') })
    submission.submitters.reload
    expect(deliver_completed_copies.map(&:to)).to eq([[firm.email]])
  end

  it 'requires the completed client identity bound to this exact JUD issuance' do
    client.update!(external_id: 'foreign-client')
    submission.submitters.reload
    expect(deliver_completed_copies.map(&:to)).to eq([[firm.email]])
  end

  it 'does not send the completion copy to a client who has not completed signing' do
    client.update!(completed_at: nil)
    submission.submitters.reload
    expect(deliver_completed_copies.map(&:to)).to eq([[firm.email]])
  end

  it 'retains an explicit template-level completed-copy disablement' do
    template.update!(preferences: { 'documents_copy_email_enabled' => false })
    expect(deliver_completed_copies).to be_empty
  end

  it 'retains an explicit account-level completed-copy disablement' do
    create(:account_config, account:, key: AccountConfig::SUBMITTER_DOCUMENTS_COPY_EMAIL_KEY,
                            value: { 'enabled' => false })
    expect(deliver_completed_copies).to be_empty
  end
end
