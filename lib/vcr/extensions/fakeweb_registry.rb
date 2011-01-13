require 'fake_web/registry'

module FakeWeb
  class Registry    

    def normalize_uri_without_param_sorting(uri)
      return uri if uri.is_a?(Regexp)
      normalized_uri =
        case uri
        when URI then uri
        when String
          uri = 'http://' + uri unless uri.match('^https?://')
          URI.parse(uri)
        end
      # NOTE: This is what we're changing from Fakeweb
      # normalized_uri.query = sort_query_params(normalized_uri.query)
      normalized_uri.normalize
    end    
    
    alias original_normalize_uri normalize_uri
    alias normalize_uri normalize_uri_without_param_sorting
    
  end
end