# frozen_string_literal: true

require_relative '../../lib/bennett_graph_delivery'

ActionMailer::Base.add_delivery_method(:bennett_graph, BennettGraphDelivery)

if Rails.env.production? && BennettGraphDelivery.enabled?
  BennettGraphDelivery.validate_configuration!
  ActionMailer::Base.delivery_job = 'BennettMailDeliveryJob'
end
