require 'set'

module VCR
  class RequestMatcher
    VALID_MATCH_ATTRIBUTES = [:method, :uri, :uri_minus_oauth, :host, :path, :headers, :body]
    DEFAULT_MATCH_ATTRIBUTES = [:method, :uri]

    attr_reader :request, :match_attributes

    def initialize(request = nil, match_attributes = [])
      if (match_attributes - VALID_MATCH_ATTRIBUTES).size > 0
        raise ArgumentError.new("The only valid match_attributes options are: #{VALID_MATCH_ATTRIBUTES.inspect}.  You passed: #{match_attributes.inspect}.")
      end

      @request, self.match_attributes = request, match_attributes
    end

    def match_attributes=(attributes)
      # Unfortunately, 1.9.2 doesn't give the same hash code
      # for two sets of the same elements unless they are ordered
      # the same, so we sort the attributes here.
      attributes = attributes.sort { |a, b| a.to_s <=> b.to_s }
      @match_attributes = Set.new(attributes)
    end

    def uri
      return request.uri unless request.uri.is_a?(String)
      uri_matchers = match_attributes.to_a & [:uri, :uri_minus_oauth, :host, :path]

      uri = URI(request.uri)
      uri_minus_oauth_pattern =  %r{(\Ahttps?://[^/]+#{Regexp.escape(uri.path)}/?.*?)(oauth.+=[^&]+)*\z}
      request.uri =~ uri_minus_oauth_pattern
      uri_without_oauth = $1
      uri_minus_oauth_pattern = %r{\A#{Regexp.escape(uri_without_oauth)}.*\z}i
      
      case Set.new(uri_matchers)
        when Set.new then /.*/
        when Set.new([:uri]) then request.uri
        when Set.new([:uri_minus_oauth]) then uri_minus_oauth_pattern
        when Set.new([:host]) then %r{\Ahttps?://((\w+:)?\w+@)?#{Regexp.escape(uri.host)}(:\d+)?/}i
        when Set.new([:path]) then %r{\Ahttps?://[^/]+#{Regexp.escape(uri.path)}/?(\?.*)?\z}i
        when Set.new([:host, :path])
          %r{\Ahttps?://((\w+:)?\w+@)?#{Regexp.escape(uri.host)}(:\d+)?#{Regexp.escape(uri.path)}/?(\?.*)?\z}i
        else raise ArgumentError.new("match_attributes cannot include #{uri_matchers.join(' and ')}")
      end
    end

    def method
      request.method if match_requests_on?(:method)
    end

    def headers
      request.headers if match_requests_on?(:headers)
    end

    def body
      request.body if match_requests_on?(:body)
    end

    def match_requests_on?(attribute)
      match_attributes.include?(attribute)
    end

    def eql?(other)
      self == other
    end

    def ==(other)
      %w( class match_attributes method uri headers body ).all? do |attr|
        send(attr) == other.send(attr)
      end
    end

    def hash
      # on Ruby 1.8.6, identical sets have different hash values,
      # but identical arrays have the same hash values,
      # so we convert match_attributes to an array here.
      [match_attributes.to_a, method, uri, sorted_header_array, body].hash
    end

    private

      def sorted_header_array
        header_hash = headers
        return header_hash unless header_hash.is_a?(Hash)

        array = []
        header_hash.each do |k, v|
          v = v.sort if v.respond_to?(:sort)
          array << [k, v]
        end

        array.sort! { |a1, a2| a1.first <=> a2.first }
      end
  end
end
