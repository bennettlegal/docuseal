# frozen_string_literal: true

RSpec.describe BennettGraphDelivery do
  let(:tenant) { '11111111-1111-4111-8111-111111111111' }
  let(:token_url) { "https://login.microsoftonline.com/#{tenant}/oauth2/v2.0/token" }
  let(:send_url) { 'https://graph.microsoft.com/v1.0/users/solar@bennettlegal.com/sendMail' }
  let(:delivery) { described_class.new }
  let(:mail) do
    Mail.new do
      from 'Bennett Legal <solar@bennettlegal.com>'
      to 'client@example.invalid'
      bcc 'staff@example.invalid'
      self.subject = 'Your Bennett Legal retainer'
      html_part do
        content_type 'text/html'
        body '<a href="https://sign.example.invalid/s/synthetic">Sign</a>'
      end
      attachments['retainer.pdf'] = { mime_type: 'application/pdf', content: '%PDF-synthetic-unchanged' }
      attachments.inline['logo.png'] = { mime_type: 'image/png', content: 'synthetic-logo' }
    end
  end

  around do |example|
    keys = %w[BENNETT_GRAPH_MAIL_ENABLED BENNETT_GRAPH_TENANT_ID BENNETT_GRAPH_CLIENT_ID BENNETT_GRAPH_CLIENT_SECRET]
    before = ENV.to_h.slice(*keys)
    ENV.update('BENNETT_GRAPH_MAIL_ENABLED' => 'true', 'BENNETT_GRAPH_TENANT_ID' => tenant,
               'BENNETT_GRAPH_CLIENT_ID' => tenant, 'BENNETT_GRAPH_CLIENT_SECRET' => 'synthetic-secret')
    example.run
  ensure
    keys.each { |key| before.key?(key) ? ENV[key] = before[key] : ENV.delete(key) }
  end

  before do
    stub_request(:post, token_url).to_return(status: 200, body: '{"access_token":"synthetic-token"}')
  end

  it 'delivers complete MIME through Solar with unchanged signing links and PDF/inline attachments' do
    request = stub_request(:post, send_url).with(headers: { 'Authorization' => 'Bearer synthetic-token',
                                                            'Content-Type' => 'text/plain' }) do |req|
      sent = Mail.read_from_string(Base64.strict_decode64(req.body))
      expect(sent.from).to eq(['solar@bennettlegal.com'])
      expect(sent.to).to eq(['client@example.invalid'])
      expect(sent.bcc).to eq(['staff@example.invalid'])
      expect(sent.html_part.decoded).to include('https://sign.example.invalid/s/synthetic')
      expect(sent.attachments['retainer.pdf'].decoded).to eq('%PDF-synthetic-unchanged')
      expect(sent.attachments['logo.png'].decoded).to eq('synthetic-logo')
      true
    end.to_return(status: 202)
    delivery.deliver!(mail)
    expect(delivery.accepted).to be(true)
    expect(request).to have_been_requested.once
  end

  %w[en es].each do |language|
    it "records an actual #{language} native invitation only after Microsoft accepts its full MIME" do
      allow(Rails.env).to receive(:production?).and_return(true)
      user = create(:user)
      template = create(:template, account: user.account, author: user)
      submission = create(:submission, :with_submitters, template: template, created_by_user: user)
      submitter = submission.submitters.first
      submitter.update!(metadata: { 'lang' => language })
      request = stub_request(:post, send_url).with do |req|
        sent = Mail.read_from_string(Base64.strict_decode64(req.body))
        expect(sent.from).to eq(['solar@bennettlegal.com'])
        expect(sent.to).to eq([submitter.email])
        expect(sent.reply_to).to include('solar@bennettlegal.com')
        expect(sent.html_part.decoded).to include("/s/#{submitter.slug}")
        expect(sent.attachments.filter_map(&:content_id)).not_to be_empty
        true
      end.to_return(status: 202)
      SendSubmitterInvitationEmailJob.new.perform('submitter_id' => submitter.id)
      expect(request).to have_been_requested.once
      expect(submitter.reload.sent_at).to be_present
      event = EmailEvent.find_by!(emailable: submitter, tag: 'submitter_invitation', event_type: 'send')
      expect(event.data).to include('from' => ['solar@bennettlegal.com'], 'method' => 'bennett_graph_delivery')
    end
  end

  it 'records neither a sent invitation nor an email event for a lost Microsoft response' do
    allow(Rails.env).to receive(:production?).and_return(true)
    user = create(:user)
    template = create(:template, account: user.account, author: user)
    submission = create(:submission, :with_submitters, template: template, created_by_user: user)
    submitter = submission.submitters.first
    stub_request(:post, send_url).to_timeout
    expect do
      SendSubmitterInvitationEmailJob.new.perform('submitter_id' => submitter.id)
    end.to raise_error(described_class::UncertainDelivery)
    expect(submitter.reload.sent_at).to be_nil
    expect(EmailEvent.where(emailable: submitter)).to be_empty
    expect(SubmissionEvent.where(submitter: submitter, event_type: 'send_email')).to be_empty
  end

  it 'refuses other senders or missing application configuration before any network call' do
    mail.from = 'other@example.invalid'
    expect { delivery.deliver!(mail) }.to raise_error(described_class::AuthenticationError, /only permitted/)
    mail.from = described_class::MAILBOX
    ENV.delete('BENNETT_GRAPH_CLIENT_SECRET')
    expect { delivery.deliver!(mail) }.to raise_error(described_class::AuthenticationError, /not configured/)
    expect(a_request(:post, token_url)).not_to have_been_made
  end

  it 'rejects oversized MIME before requesting a token or submitting any message' do
    mail.body = 'x' * (described_class::MAX_MIME_BYTES + 1)
    expect { delivery.deliver!(mail) }.to raise_error(described_class::AuthenticationError, /MIME bound/)
    expect(a_request(:post, token_url)).not_to have_been_made
    expect(a_request(:post, send_url)).not_to have_been_made
  end

  it 'retries no mail when authentication fails and exposes no provider response or credential' do
    stub_request(:post, token_url).to_return(status: 403, body: 'synthetic-secret-private-provider-body')
    expect { delivery.deliver!(mail) }.to raise_error(described_class::AuthenticationError) { |error|
      expect(error.message).not_to include('synthetic-secret', 'private-provider-body')
      expect(error.cause).to be_nil
    }
    expect(a_request(:post, send_url)).not_to have_been_made
  end

  it 'holds a lost mail response for review and never automatically retries the HTTP request' do
    request = stub_request(:post, send_url).to_timeout
    expect { delivery.deliver!(mail) }.to raise_error(described_class::UncertainDelivery, /acceptance is unknown/)
    expect(request).to have_been_requested.once
    expect(delivery.accepted).to be(false)
  end

  it 'does not accept a redirect, error or unexpected success response as a confirmed send' do
    [302, 400, 429, 500, 200].each do |code|
      stub_request(:post, send_url).to_return(status: code)
      expect { delivery.deliver!(mail) }.to raise_error(described_class::UncertainDelivery, /HTTP #{code}/)
    end
  end

  it 'holds a confirmed send whose following database update failed without sending it again' do
    request = stub_request(:post, send_url).to_return(status: 202)
    mail.delivery_method(described_class)
    mail.deliver!
    envelope = Data.define(:message).new(mail)
    expect do
      described_class.protect_accepted_delivery(envelope) { raise ActiveRecord::StatementInvalid }
    end.to raise_error(described_class::UncertainDelivery, /follow-up record requires review/)
    expect(request).to have_been_requested.once
  end

  it 'preserves ordinary SMTP failure handling and leaves SMTP as the default when disabled' do
    ENV['BENNETT_GRAPH_MAIL_ENABLED'] = 'false'
    expect(described_class.enabled?).to be(false)
    mail.delivery_method(:test)
    envelope = Data.define(:message).new(mail)
    expect do
      described_class.protect_accepted_delivery(envelope) { raise IOError, 'original-error' }
    end.to raise_error(IOError, 'original-error')
  end

  it 'holds invitation, verification and completion-mail jobs in the Dead set on uncertain sends' do
    [SendSubmitterInvitationEmailJob, SendSubmitterVerificationEmailJob, ActionMailer::MailDeliveryJob].each do |job|
      expect(job.sidekiq_retry_in_block.call(0, described_class::UncertainDelivery.new)).to eq(:kill)
      expect(job.sidekiq_retry_in_block.call(0, described_class::AuthenticationError.new)).to be_nil
    end
  end

  it 'overrides the native From and retains Solar plus staff Reply-To without changing the message' do
    allow(Rails.env).to receive(:production?).and_return(true)
    mail.from = 'stephen@notify.example.invalid'
    mail.reply_to = 'lawyer@example.invalid'
    ActionMailerConfigsInterceptor.delivering_email(mail)
    expect(mail.delivery_method).to be_a(described_class)
    expect(mail.from).to eq(['solar@bennettlegal.com'])
    expect(mail.reply_to).to eq(['solar@bennettlegal.com', 'lawyer@example.invalid'])
    expect(mail.subject).to eq('Your Bennett Legal retainer')
  end
end
