# frozen_string_literal: true

# Preserve uncertain requests in Sidekiq's Dead set for manual reconciliation.
# Do not turn a lost Microsoft response into a second client email.
class BennettMailDeliveryJob < ActionMailer::MailDeliveryJob
  include Sidekiq::Job::Options

  sidekiq_retry_in do |_count, error|
    :kill if error.is_a?(BennettGraphDelivery::UncertainDelivery)
  end
end
