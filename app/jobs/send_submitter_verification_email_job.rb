# frozen_string_literal: true

class SendSubmitterVerificationEmailJob
  include Sidekiq::Job

  sidekiq_retry_in do |_count, error|
    :kill if error.is_a?(BennettGraphDelivery::UncertainDelivery)
  end

  def perform(params = {})
    submitter = Submitter.find(params['submitter_id'])

    locale = params['locale'].presence || submitter.account.locale

    mail = SubmitterMailer.otp_verification_email(submitter, locale:)
    BennettGraphDelivery.protect_accepted_delivery(mail) do
      mail.deliver_now!

      SubmissionEvent.create!(submitter_id: params['submitter_id'],
                              event_type: 'send_2fa_email',
                              data: { email: submitter.email })
    end
  end
end
