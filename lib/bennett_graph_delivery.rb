# frozen_string_literal: true

require 'base64'
require 'json'
require 'net/http'

# A dedicated Exchange application must be scoped to this mailbox only.
# Keep the complete MIME message: signatures, inline images and PDFs are unchanged.
class BennettGraphDelivery
  MAILBOX = 'solar@bennettlegal.com'
  UUID = /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i
  MAX_MIME_BYTES = 3_000_000

  class AuthenticationError < StandardError; end
  class UncertainDelivery < StandardError; end

  attr_reader :settings, :accepted

  def self.enabled?
    ENV['BENNETT_GRAPH_MAIL_ENABLED'] == 'true'
  end

  def self.validate_configuration!
    valid = %w[TENANT_ID CLIENT_ID].all? { |key| UUID.match?(ENV.fetch("BENNETT_GRAPH_#{key}", '')) }
    valid &&= ENV.fetch('BENNETT_GRAPH_CLIENT_SECRET', '').present?
    raise AuthenticationError, 'Dedicated Solar mail application is not configured' unless valid
  end

  def self.protect_accepted_delivery(mail)
    yield
  rescue StandardError
    delivery = mail.message.delivery_method
    if delivery.is_a?(self) && delivery.accepted
      raise UncertainDelivery, 'Solar mail accepted; follow-up record requires review', cause: nil
    end

    raise
  end

  def initialize(settings = {})
    @settings = settings
    @accepted = false
  end

  def deliver!(mail)
    self.class.validate_configuration!
    raise AuthenticationError, 'Solar is the only permitted Graph sender' unless mail.from == [MAILBOX]

    # Graph obtains MIME recipients from the headers, including Bcc. Exchange
    # removes Bcc from the delivered copy; Mail normally omits it at encoding.
    mail[:bcc].include_in_headers = true if mail[:bcc]
    mime = mail.encoded
    raise AuthenticationError, 'Solar message exceeds the Graph MIME bound' if mime.bytesize > MAX_MIME_BYTES

    token = access_token
    uri = URI("https://graph.microsoft.com/v1.0/users/#{MAILBOX}/sendMail")
    begin
      code, = post(uri, { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'text/plain' },
                   Base64.strict_encode64(mime))
      raise UncertainDelivery, "Solar mail requires review (HTTP #{code})" unless code == '202'

      @accepted = true
    rescue UncertainDelivery
      raise
    rescue StandardError
      raise UncertainDelivery, 'Solar mail acceptance is unknown; inspect Sent Items before retrying', cause: nil
    end
  end

  private

  def access_token
    body = URI.encode_www_form(client_id: ENV.fetch('BENNETT_GRAPH_CLIENT_ID'),
                               client_secret: ENV.fetch('BENNETT_GRAPH_CLIENT_SECRET'),
                               scope: 'https://graph.microsoft.com/.default', grant_type: 'client_credentials')
    uri = URI("https://login.microsoftonline.com/#{ENV.fetch('BENNETT_GRAPH_TENANT_ID')}/oauth2/v2.0/token")
    code, response = post(uri, { 'Content-Type' => 'application/x-www-form-urlencoded' }, body)
    token = JSON.parse(response)['access_token'] if code == '200'
    unless token.is_a?(String) && token.present?
      raise AuthenticationError, 'Solar mail authentication failed before sending'
    end

    token
  rescue StandardError
    raise AuthenticationError, 'Solar mail authentication failed before sending', cause: nil
  end

  def post(uri, headers, body)
    http = Net::HTTP.new(uri.host, uri.port, nil)
    http.use_ssl = true
    http.open_timeout = 15
    http.read_timeout = 25
    http.write_timeout = 25
    http.max_retries = 0
    response_body = +''
    code = nil
    http.start do
      http.request(Net::HTTP::Post.new(uri, headers).tap { |request| request.body = body }) do |response|
        code = response.code
        response.read_body do |part|
          response_body << part
          raise IOError, 'Solar mail response exceeded its bound' if response_body.bytesize > 65_536
        end
      end
    end
    [code, response_body]
  end
end
