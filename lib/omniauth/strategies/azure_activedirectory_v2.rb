# frozen_string_literal: true

require 'omniauth-oauth2'

module OmniAuth
  module Strategies
    class AzureActivedirectoryV2 < OmniAuth::Strategies::OAuth2
      BASE_AZURE_URL = 'https://login.microsoftonline.com'

      option :name, 'azure_activedirectory_v2'
      option :tenant_provider, nil
      option :authorized_emails, []  # Add option for authorized external emails

      DEFAULT_SCOPE = 'openid profile email'

      # tenant_provider must return client_id, client_secret and optionally tenant_id and base_azure_url
      args [:tenant_provider]

      def client
        provider = if options.tenant_provider
          options.tenant_provider.new(self)
        else
          options
        end

        options.client_id = provider.client_id
        options.client_secret = provider.client_secret
        options.tenant_id =
          provider.respond_to?(:tenant_id) ? provider.tenant_id : 'common'
        options.base_azure_url =
          provider.respond_to?(:base_azure_url) ? provider.base_azure_url : BASE_AZURE_URL

        if provider.respond_to?(:authorize_params)
          options.authorize_params = provider.authorize_params
        end

        if provider.respond_to?(:domain_hint) && provider.domain_hint
          options.authorize_params.domain_hint = provider.domain_hint
        end

        if defined?(request) && request.params['prompt']
          options.authorize_params.prompt = request.params['prompt']
        end

        options.authorize_params.scope = if defined?(request) && request.params['scope']
          request.params['scope']
        elsif provider.respond_to?(:scope) && provider.scope
          provider.scope
        else
          DEFAULT_SCOPE
        end

        options.custom_policy =
          provider.respond_to?(:custom_policy) ? provider.custom_policy : nil

        oauth2 = provider.respond_to?(:adfs?) && provider.adfs? ? 'oauth2' : 'oauth2/v2.0'
        options.client_options.authorize_url = "#{options.base_azure_url}/#{options.tenant_id}/#{oauth2}/authorize"
        options.client_options.token_url =
          if options.custom_policy
            "#{options.base_azure_url}/#{options.tenant_id}/#{options.custom_policy}/#{oauth2}/token"
          else
            "#{options.base_azure_url}/#{options.tenant_id}/#{oauth2}/token"
          end

        super
      end

      uid { raw_info['oid'] }

      info do
        {
          name: raw_info['name'],
          email: raw_info['email'] || raw_info['upn'],
          nickname: raw_info['unique_name'],
          first_name: raw_info['given_name'],
          last_name: raw_info['family_name']
        }
      end

      extra do
        { raw_info: raw_info }
      end

      def callback_url
        full_host + callback_path
      end

      # https://docs.microsoft.com/en-us/azure/active-directory/develop/id-tokens
      #
      # Some account types from Microsoft seem to only have a decodable ID token,
      # with JWT unable to decode the access token. Information is limited in those
      # cases. Other account types provide an expanded set of data inside the auth
      # token, which does decode as a JWT.
      #
      # Merge the two, allowing the expanded auth token data to overwrite the ID
      # token data if keys collide, and use this as raw info.
      #

      def raw_info
        if @raw_info.nil?
          id_token_data = begin
            ::JWT.decode(access_token.params['id_token'], nil, false).first
          rescue StandardError
            {}
          end
          auth_token_data = begin
            ::JWT.decode(access_token.token, nil, false).first
          rescue StandardError
            {}
          end

          id_token_data.merge!(auth_token_data)
          @raw_info = id_token_data
        end

        @raw_info
      end

      # Custom method to verify authorized domains or emails
      def verify_user
        email = raw_info['email'] || raw_info['upn']
        domain = email.split('@').last

        if options.authorized_emails.include?(email)
          true
        else
          raise CallbackError.new(:invalid_email, 'Invalid Email Domain or Email Not Authorized')
        end
      end

      # Overriding callback phase to include custom verification
      def callback_phase
        super
        verify_user
      rescue CallbackError => e
        fail!(e.message, e)
      end
    end
  end
end
