# frozen_string_literal: true

require 'mail'
require 'logger'
require 'tmpdir'
require_relative '../../lib/bennett_mail_archive'

RSpec.describe BennettMailArchive do
  let(:mail) do
    message = Mail.new do
      from 'Bennett Legal <solar@notify.example.invalid>'
      to 'client@example.invalid'
      bcc 'staff@example.invalid'
      self.subject = 'Su contrato de Bennett Legal'
      html_part { body '<a href="https://sign.example.invalid/s/private">Revisar y firmar</a>' }
      text_part { body 'Revisar y firmar: https://sign.example.invalid/s/private' }
      attachments['retainer.pdf'] = { mime_type: 'application/pdf', content: '%PDF-synthetic' }
    end
    message.delivery_method(:smtp)
    message.instance_variable_set(:@message_metadata,
                                  { 'tag' => 'submitter_invitation', 'record_type' => 'Submitter', 'record_id' => 123 })
    message
  end

  around do |example|
    environment = ENV.to_h.slice('WORKDIR', 'BENNETT_MAIL_ARCHIVE_ENABLED')
    Dir.mktmpdir('bennett-mail-archive-') do |directory|
      ENV.update('WORKDIR' => directory, 'BENNETT_MAIL_ARCHIVE_ENABLED' => 'true')
      example.run
    end
  ensure
    %w[WORKDIR BENNETT_MAIL_ARCHIVE_ENABLED].each do |key|
      environment.key?(key) ? ENV[key] = environment[key] : ENV.delete(key)
    end
  end

  def files(pattern) = Dir[File.join(ENV.fetch('WORKDIR'), '**', pattern)]

  it 'preserves complete MIME, attachments, private envelope recipients and native context' do
    described_class.delivering_email(mail)
    archived = Mail.read(files('message.eml').fetch(0))
    expect(File.binread(files('message.eml').fetch(0))).to eq(mail.encoded)
    expect(archived.attachments['retainer.pdf'].decoded).to eq('%PDF-synthetic')
    expect(archived.html_part.decoded).to include('https://sign.example.invalid/s/private')
    expect(archived.text_part.decoded).to include('Revisar y firmar')
    receipt = JSON.parse(File.read(files('prepared.json').fetch(0)))
    expect(receipt).to include('state' => 'prepared', 'envelope_to' => mail.smtp_envelope_to)
    expect(receipt.fetch('envelope_to')).to include('staff@example.invalid')
    expect(receipt.fetch('context')).to include('record_id' => 123)
    expect(receipt.fetch('mime_sha256')).to eq(Digest::SHA256.file(files('message.eml').fetch(0)).hexdigest)
    expect(files('delivery-callback.json')).to be_empty
    files('*').each do |path|
      expect(File.stat(path).mode & 0o777).to eq(File.directory?(path) ? 0o700 : 0o600)
    end
  end

  it 'keeps separate attempts and callbacks without replacing prepared evidence' do
    described_class.delivering_email(mail)
    original = File.binread(files('prepared.json').fetch(0))
    described_class.delivered_email(mail)
    expect(File.binread(files('prepared.json').fetch(0))).to eq(original)
    expect(JSON.parse(File.read(files('delivery-callback.json').fetch(0))))
      .to include('state' => 'delivery_callback_completed')
    described_class.delivering_email(mail)
    expect(files('message.eml').length).to eq(2)
    expect(files('delivery-callback.json').length).to eq(1)
  end

  it 'skips disabled, non-SMTP, suppressed and unrelated messages' do
    ENV['BENNETT_MAIL_ARCHIVE_ENABLED'] = 'false'
    described_class.delivering_email(mail)
    ENV['BENNETT_MAIL_ARCHIVE_ENABLED'] = 'true'
    mail.delivery_method(:test)
    described_class.delivering_email(mail)
    mail.delivery_method(:smtp)
    mail.perform_deliveries = false
    described_class.delivering_email(mail)
    mail.perform_deliveries = true
    mail.instance_variable_set(:@message_metadata, { 'record_type' => 'User' })
    described_class.delivering_email(mail)
    expect(files('message.eml')).to be_empty
  end

  it 'does not retry mail when a receipt fails after transport' do
    described_class.delivering_email(mail)
    Dir.mkdir(File.join(File.dirname(files('message.eml').fetch(0)), 'delivery-callback.json'))
    stub_const('Rails', Class.new { def self.logger; end }) unless defined?(Rails)
    logger = instance_spy(Logger)
    allow(Rails).to receive(:logger).and_return(logger)
    expect { described_class.delivered_email(mail) }.not_to raise_error
    expect(logger).to have_received(:error).with('Bennett mail archive delivery receipt requires review')
    expect(files('message.eml').length).to eq(1)
  end

  it 'archives before the real Mail delivery hooks and prevents submission when preparation fails' do
    interceptor_present = Mail.delivery_interceptors.include?(described_class)
    Mail.register_interceptor(described_class)
    allow(ActionMailerEventsObserver).to receive(:delivered_email) if defined?(ActionMailerEventsObserver)
    # Call the observer explicitly after transport; do not alter the app's
    # global observer registry when Rails has already registered it.
    observations = []
    allow(mail.delivery_method).to receive(:deliver!) { observations << files('prepared.json').length }
    mail.deliver!
    expect(observations).to eq([1])
    described_class.delivered_email(mail) if files('delivery-callback.json').empty?
    expect(files('delivery-callback.json').length).to eq(1)
    blocked = File.join(ENV.fetch('WORKDIR'), 'blocked')
    File.write(blocked, 'synthetic')
    ENV['WORKDIR'] = blocked
    expect { mail.deliver! }.to raise_error(SystemCallError)
    expect(observations).to eq([1])
  ensure
    Mail.unregister_interceptor(described_class) unless interceptor_present
  end
end
