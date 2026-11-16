# frozen_string_literal: true

require_relative '../../lib/bennett_graph_delivery'

ActionMailer::Base.add_delivery_method(:bennett_graph, BennettGraphDelivery)

# Cover existing serialized mail jobs as well as newly queued mail.
ActionMailer::MailDeliveryJob.include(Sidekiq::Job::Options)
ActionMailer::MailDeliveryJob.sidekiq_retry_in do |_count, error|
  :kill if error.is_a?(BennettGraphDelivery::UncertainDelivery)
end

BennettGraphDelivery.validate_configuration! if Rails.env.production? && BennettGraphDelivery.enabled?
