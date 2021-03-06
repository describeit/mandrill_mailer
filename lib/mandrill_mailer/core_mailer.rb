# MandrilMailer class for sending transactional emails through mandril.
# Only template based emails are supported at this time.

# Example usage:

# class InvitationMailer < MandrillMailer::TemplateMailer
#   default from: 'support@codeschool.com',
#           from_name: 'Code School',
#           merge_vars: { 'FOO' => 'Bar' }
#           view_content_link: false

#   def invite(invitation)
#     invitees = invitation.invitees.map { |invitee| { email: invitee.email, name: invitee.name } }
#
#     mandrill_mail template: 'Group Invite',
#                   subject: I18n.t('invitation_mailer.invite.subject'),
#                   to: invitees,
#                   # to: invitation.email
#                   # to: { email: invitation.email, name: invitation.recipient_name }
#                   vars: {
#                     'OWNER_NAME' => invitation.owner_name,
#                     'PROJECT_NAME' => invitation.project_name
#                   },
#                   recipient_vars: invitation.invitees.map do |invitee| # invitation.invitees is an Array
#                                     { invitee.email =>
#                                       {
#                                         'INVITEE_NAME' => invitee.name,
#                                         'INVITATION_URL' => new_invitation_url(invitee.email, secret: invitee.secret_code)
#                                       }
#                                     }
#                                   end,
#                   template_content: {},
#                   attachments: [{file: File.read(File.expand_path('assets/some_image.png')), filename: 'My Image.png', mimetype: 'image/png'}],
#                   important: true,
#                   inline_css: true
#   end
# end

# #default:
#   :from               - set the default from email address for the mailer
#   :from_name          - set the default from name for the mailer
#   :merge_vars         - set the default merge vars for the mailer
#   :view_content_link  - set a default view_content_link option for the mailer

# .mandrill_mail
#   :template(required) - Template name from within Mandrill

#   :subject(required) - Subject of the email

#   :to(required) - Accepts an email String, a Hash with :name and :email keys
#                   or an Array of Hashes with :name and :email keys
#     examples:
#       1)
#         'example@domain.com`
#       2)
#         { email: 'someone@email.com', name: 'Bob Bertly' }
#       3)
#         [{ email: 'someone@email.com', name: 'Bob Bertly' },
#          { email: 'other@email.com', name: 'Claire Nayo' }]
#

#   :vars - A Hash of merge tags made available to the email. Use them in the
#     email by wrapping them in '*||*' vars: {'OWNER_NAME' => 'Suzy'} is used
#     by doing: *|OWNER_NAME|* in the email template within Mandrill
#
#   :recipient_vars - Similar to :vars, this is a Hash of merge tags specific to a particular recipient.
#     Use this if you are sending batch transactions and hence need to send multiple emails at one go.
#     ex. [{'someone@email.com' => {'INVITEE_NAME' => 'Roger'}}, {'another@email.com' => {'INVITEE_NAME' => 'Tommy'}}]

#   :template_content - A Hash of values and content for Mandrill editable content blocks.
#     In MailChimp templates there are editable regions with 'mc:edit' attributes that look
#     a little like: '<div mc:edit="header">My email content</div>' You can insert content directly into
#     these fields by passing a Hash {'header' => 'my email content'}

#   :attachments - An array of file objects with the following keys:
#       file: This is the actual file, it will be converted to byte data in the mailer
#       filename: The name of the file
#       mimetype: This is the mimetype of the file. Ex. png = image/png, pdf = application/pdf, txt = text/plain etc

#   :images - An array of embedded images to add to the message:
#       file: This is the actual file, it will be converted to byte data in the mailer
#       filename: The Content ID of the image - use <img src="cid:THIS_VALUE"> to reference the image in your HTML content
#       mimetype: The MIME type of the image - must start with "image/"

# :headers - Extra headers to add to the message (currently only Reply-To and X-* headers are allowed) {"...": "..."}

# :bcc - Add an email to bcc to

# :tags - Array of Strings to tag the message with. Stats are
#   accumulated using tags, though we only store the first 100 we see,
#   so this should not be unique or change frequently. Tags should be
#   50 characters or less. Any tags starting with an underscore are
#   reserved for internal use and will cause errors.

# :google_analytics_domains - Array of Strings indicating for which any
#   matching URLs will automatically have Google Analytics parameters appended
#   to their query string automatically.

# :google_analytics_campaign - String indicating the value to set for
#   the utm_campaign tracking parameter. If this isn't provided the email's
#   from address will be used instead.

# :inline_css - whether or not to automatically inline all CSS styles provided in the
#   message HTML - only for HTML documents less than 256KB in size

# :important - whether or not this message is important, and should be delivered ahead of non-important messages

# Required for hash.stringify_keys!
require 'active_support/all'
require 'mandrill_mailer/arg_formatter'

module MandrillMailer
  class CoreMailer < ActionMailer::Base
    include ActionView::Helpers::NumberHelper
    include Devise::Controllers::UrlHelpers
    include Devise::Mailers::Helpers
    include ActionDispatch::Routing::PolymorphicRoutes

    class InvalidEmail < StandardError; end
    class InvalidMailerMethod < StandardError; end
    class InvalidInterceptorParams < StandardError; end
    class InvalidMergeLanguageError < StandardError; end

    # Public: Other information on the message to send
    attr_accessor :message

    # Public: Enable background sending mode
    attr_accessor :async

    # Public:  Name of the dedicated IP pool that should be used to send the message
    attr_accessor :ip_pool

    # Public: When message should be sent
    attr_accessor :send_at

    # Public: Defaults for the mailer. Currently the only option is from:
    #
    # options       - The Hash options used to refine the selection (default: {}):
    #   :from       - Default from email address
    #   :from_name  - Default from name
    #   :merge_vars - Default merge vars
    #
    # Examples
    #
    #   default from: 'foo@bar.com',
    #           from_name: 'Foo Bar',
    #           merge_vars: {'FOO' => 'Bar'}
    #
    #
    # Returns options
    def self.defaults
      @defaults || super_defaults || {}
    end

    def self.super_defaults
      superclass.defaults if superclass.respond_to?(:defaults)
    end

    def self.default(args)
      @defaults ||= {}
      @defaults[:from] ||= 'example@email.com'
      @defaults[:merge_vars] ||= {}
      @defaults.merge!(args)
    end

    class << self
      attr_writer :defaults
    end

    # Public: setup a way to test mailer methods
    #
    # mailer_method - Name of the mailer method the test setup is for
    #
    # block - Block of code to execute to perform the test. The mailer
    # and options are passed to the block. The options have to
    # contain at least the :email to send the test to.
    #
    # Examples
    #
    #   test_setup_for :invite do |mailer, options|
    #     invitation = OpenStruct.new({
    #       email: options[:email],
    #       owner_name: 'foobar',
    #       secret: rand(9000000..1000000).to_s
    #     })
    #     mailer.invite(invitation).deliver
    #   end
    #
    # Returns the duplicated String.
    def self.test_setup_for(mailer_method, &block)
      @mailer_methods ||= {}
      @mailer_methods[mailer_method] = block
    end

    # Public: Executes a test email
    #
    # mailer_method - Method to execute
    #
    # options - The Hash options used to refine the selection (default: {}):
    #   :email - The email to send the test to.
    #
    # Examples
    #
    #   InvitationMailer.test(:invite, email: 'benny@envylabs.com')
    #
    # Returns the duplicated String.
    def self.test(mailer_method, options={})
      unless options[:email]
        raise InvalidEmail.new 'Please specify a :email option(email to send the test to)'
      end

      if @mailer_methods[mailer_method]
        @mailer_methods[mailer_method].call(self.new, options)
      else
        raise InvalidMailerMethod.new "The mailer method: #{mailer_method} does not have test setup"
      end

    end

    # Public: Triggers the stored Mandrill params to be sent to the Mandrill api
    def deliver_now
      raise NotImplementedError.new("#{self.class.name}#deliver_now is not implemented.")
    end

    def deliver_later
      raise NotImplementedError.new("#{self.class.name}#deliver_later is not implemented.")
    end

    def mandrill_mail_handler(args)
      args
    end

    # Public: Build the hash needed to send to the mandrill api
    #
    # args - The Hash options used to refine the selection:
    #
    # Examples
    #
    #   mandrill_mail template: 'Group Invite',
    #               subject: I18n.t('invitation_mailer.invite.subject'),
    #               to: invitation.email,
    #               vars: {
    #                 'OWNER_NAME' => invitation.owner_name,
    #                 'INVITATION_URL' => new_invitation_url(email: invitation.email, secret: invitation.secret)
    #               }
    #
    # Returns the the mandrill mailer class (this is so you can chain #deliver like a normal mailer)
    def mandrill_mail(args)
      extract_api_options!(args)

      # Call the mandrill_mail_handler so mailers can handle the args in custom ways
      mandrill_mail_handler(args)

      # Construct message hash
      self.message = MandrillMailer::ArgFormatter.format_messages_api_message_data(args, self.class.defaults)

      # Apply any interceptors that may be present
      apply_interceptors!(self.message)

      # return self so we can chain deliver after the method call, like a normal mailer.
      self
    end

    def from
      self.message && self.message['from_email']
    end

    def to
      self.message && self.message['to']
    end

    def to=(values)
      self.message && self.message['to'] = MandrillMailer::ArgFormatter.params(values)
    end

    def bcc
      self.message && self.message['bcc_address']
    end

    protected

    def apply_interceptors!(obj)
      unless MandrillMailer.config.interceptor.nil?
        unless MandrillMailer.config.interceptor.is_a?(Proc)
          raise InvalidInterceptorParams.new "The interceptor_params config must be a proc"
        end
        MandrillMailer.config.interceptor.call(obj)
      end

      obj
    end

    # Makes this class act as a singleton without it actually being a singleton
    # This keeps the syntax the same as the orginal mailers so we can swap quickly if something
    # goes wrong.
    def self.method_missing(method, *args)
      return super unless respond_to?(method)
      new.method(method).call(*args)
    end

    def self.respond_to?(method, include_private = false)
      super || instance_methods.include?(method.to_sym)
    end

    # Proxy route helpers to rails if Rails exists. Doing routes this way
    # makes it so this gem doesn't need to be a rails engine
    def method_missing(method, *args)
      return super unless defined?(Rails) && Rails.application.routes.url_helpers.respond_to?(method)
      # Check to see if one of the args is an open struct. If it is, we'll assume it's the
      # test stub and try to call a path or url attribute.
      if args.any? {|arg| arg.kind_of?(MandrillMailer::Mock)}
        # take the first OpenStruct found in args and look for .url or.path
        args.each do |arg|
          if arg.kind_of?(MandrillMailer::Mock)
            break arg.url || arg.path
          end
        end
      else
        options = args.extract_options!.merge({host: MandrillMailer.config.default_url_options[:host], protocol: MandrillMailer.config.default_url_options[:protocol]})
        args << options
        Rails.application.routes.url_helpers.method(method).call(*args)
      end
    end

    def image_path(image)
      if defined? Rails
        ActionController::Base.helpers.asset_path(image)
      else
        method_missing(:image_path, image)
      end
    end

    def image_url(image)
      "#{root_url}#{image_path(image).split('/').reject!(&:empty?).join('/')}"
    end

    def api_key
      MandrillMailer.config.api_key
    end

    def mandrill_api
      @mandrill_api ||= Mandrill::API.new(api_key)
    end

    def extract_api_options!(args)
      self.async = args.delete(:async)
      self.ip_pool = args.delete(:ip_pool)

      if args.has_key?(:send_at)
        self.send_at = args.delete(:send_at).getutc.strftime('%Y-%m-%d %H:%M:%S')
      end
    end
  end
end
