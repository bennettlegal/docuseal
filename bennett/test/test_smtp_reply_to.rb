# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../lib/action_mailer_configs_interceptor'

# Exercise the interceptor without Rails, a database, dependencies or delivery.
module Rails
  def self.env = Struct.new(:production?).new(true)

  def self.application
    Struct.new(:config).new(Struct.new(:action_mailer).new(Struct.new(:delivery_method).new(:smtp)))
  end
end

module Docuseal
  def self.demo? = false
end

module BennettGraphDelivery
  MAILBOX = 'solar@bennettlegal.com'
  class << self
    attr_accessor :enabled

    def enabled? = enabled
  end
end

module User
  EMAIL_REGEXP = /[^@;,<>\s]+@[^@;,<>\s]+/
  FULL_EMAIL_REGEXP = /\A#{EMAIL_REGEXP}\z/
end

class SmtpReplyToTest < Minitest::Test
  Message = Struct.new(:from, :reply_to, :delivery_transport) do
    def delivery_method(value) = self.delivery_transport = value
  end

  def setup
    @previous = ENV.to_h.slice('SMTP_FROM', 'SMTP_REPLY_TO')
    ENV['SMTP_FROM'] = 'Bennett Legal <solar@notify.bennettlegal.com>'
    ENV.delete('SMTP_REPLY_TO')
    BennettGraphDelivery.enabled = false
    @message = Message.new('original@example.test', ['lawyer@example.test'])
  end

  def teardown
    %w[SMTP_FROM SMTP_REPLY_TO].each { |key| @previous.key?(key) ? ENV[key] = @previous[key] : ENV.delete(key) }
    BennettGraphDelivery.enabled = false
  end

  def test_configured_reply_to_replaces_existing_header
    ENV['SMTP_REPLY_TO'] = 'solar@bennettlegal.com'
    assert_same @message, ActionMailerConfigsInterceptor.delivering_email(@message)
    assert_equal 'solar@bennettlegal.com', @message.reply_to
    assert_equal 'Bennett Legal <solar@notify.bennettlegal.com>', @message.from
  end

  def test_unset_and_blank_reply_to_preserve_existing_header
    [nil, '', '  '].each do |value|
      value ? ENV['SMTP_REPLY_TO'] = value : ENV.delete('SMTP_REPLY_TO')
      message = Message.new('original@example.test', ['lawyer@example.test'])
      ActionMailerConfigsInterceptor.delivering_email(message)
      assert_equal ['lawyer@example.test'], message.reply_to
    end
  end

  def test_graph_path_keeps_its_own_reply_to_behavior
    ENV['SMTP_REPLY_TO'] = 'other@example.test'
    BennettGraphDelivery.enabled = true
    ActionMailerConfigsInterceptor.delivering_email(@message)
    assert_equal BennettGraphDelivery, @message.delivery_transport
    assert_equal ['solar@bennettlegal.com', 'lawyer@example.test'], @message.reply_to
  end
end
