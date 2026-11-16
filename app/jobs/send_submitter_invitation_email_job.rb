# frozen_string_literal: true

class SendSubmitterInvitationEmailJob
  include Sidekiq::Job

  sidekiq_retry_in do |_count, error|
    :kill if error.is_a?(BennettGraphDelivery::UncertainDelivery)
  end

  def perform(params = {})
    submitter = Submitter.find(params['submitter_id'])

    return if submitter.completed_at?
    return if submitter.declined_at?
    return if submitter.submission.archived_at?
    return if submitter.submission.expired?
    return if submitter.template&.archived_at?
    return if submitter.submission.source == 'invite' && !Accounts.can_send_emails?(submitter.account, on_events: true)

    unless Accounts.can_send_invitation_emails?(submitter.account)
      Rollbar.warning("Skip email: #{submitter.account.id}") if defined?(Rollbar)

      return
    end

    mail =
      if submitter.viewer?
        SubmitterMailer.invitation_view_email(submitter)
      else
        SubmitterMailer.invitation_email(submitter)
      end

    Submitters::ValidateSending.call(submitter, mail)

    BennettGraphDelivery.protect_accepted_delivery(mail) do
      mail.deliver_now!

      SubmissionEvent.create!(submitter:, event_type: 'send_email')

      submitter.sent_at ||= Time.current
      submitter.save!
    end
  end
end
