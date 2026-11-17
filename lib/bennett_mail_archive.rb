# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'securerandom'
require 'time'

# Keep the submitted MIME under the private, backed-up WORKDIR volume. This is
# an outgoing-message record, not evidence that a recipient received or read it.
module BennettMailArchive
  module_function

  def delivering_email(mail)
    mail.remove_instance_variable(:@bennett_mail_archive_directory) if
      mail.instance_variable_defined?(:@bennett_mail_archive_directory)
    return unless ENV['BENNETT_MAIL_ARCHIVE_ENABLED'] == 'true'
    return unless mail.delivery_method.is_a?(Mail::SMTP) && mail.perform_deliveries

    context = mail.instance_variable_get(:@message_metadata) || {}
    return unless %w[Submitter Submission].include?(context['record_type'])

    mime = mail.encoded
    directory = File.join(ENV.fetch('WORKDIR'), 'bennett-mail-archive', Time.now.utc.strftime('%Y/%m/%d'),
                          SecureRandom.uuid)
    FileUtils.mkdir_p(directory, mode: 0o700)
    write(File.join(directory, 'message.eml'), mime)
    receipt = {
      schema: 1, state: 'prepared', recorded_at: Time.now.utc.iso8601,
      mime_sha256: Digest::SHA256.hexdigest(mime), mime_bytes: mime.bytesize,
      message_id: mail.message_id, envelope_from: mail.smtp_envelope_from, envelope_to: mail.smtp_envelope_to,
      context: context.slice('tag', 'record_id', 'record_type')
    }
    write(File.join(directory, 'prepared.json'), JSON.generate(receipt))
    sync_directory(directory)
    mail.instance_variable_set(:@bennett_mail_archive_directory, directory)
  end

  def delivered_email(mail)
    directory = mail.instance_variable_get(:@bennett_mail_archive_directory)
    return unless directory

    receipt = { schema: 1, state: 'delivery_callback_completed', recorded_at: Time.now.utc.iso8601,
                message_id: mail.message_id }
    write(File.join(directory, 'delivery-callback.json'), JSON.generate(receipt))
    sync_directory(directory)
  rescue StandardError
    # SMTP may already have accepted this message. Never trigger another send
    # because its secondary receipt failed; the prepared MIME remains available.
    Rails.logger.error('Bennett mail archive delivery receipt requires review')
  end

  def write(path, bytes)
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(bytes)
      file.flush
      file.fsync
    end
  end

  def sync_directory(directory)
    File.open(directory, File::RDONLY, &:fsync)
  end
end
