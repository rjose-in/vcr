HTTP_LIBRARY_ADAPTERS = {}

HTTP_LIBRARY_ADAPTERS['net/http'] = Module.new do
  def self.http_library_name; 'Net::HTTP'; end

  def get_body_string(response); response.body; end

  def get_header(header_key, response)
    response.get_fields(header_key)
  end

  def make_http_request(method, url, body = nil, headers = {})
    uri = URI.parse(url)
    Net::HTTP.new(uri.host, uri.port).send_request(method.to_s.upcase, url, body, headers)
  end
end

HTTP_LIBRARY_ADAPTERS['patron'] = Module.new do
  def self.http_library_name; 'Patron'; end

  def get_body_string(response); response.body; end

  def get_header(header_key, response)
    response.headers[header_key]
  end

  def make_http_request(method, url, body = nil, headers = {})
    Patron::Session.new.request(method, url, headers, :data => body || '')
  end
end

HTTP_LIBRARY_ADAPTERS['httpclient'] = Module.new do
  def self.http_library_name; 'HTTP Client'; end

  def get_body_string(response)
    string = response.body.content
    string.respond_to?(:read) ? string.read : string
  end

  def get_header(header_key, response)
    response.header[header_key]
  end

  def make_http_request(method, url, body = nil, headers = {})
    HTTPClient.new.request(method, url, nil, body, headers)
  end
end

HTTP_LIBRARY_ADAPTERS['em-http-request'] = Module.new do
  def self.http_library_name; 'EM HTTP Request'; end

  def get_body_string(response)
    response.response
  end

  def get_header(header_key, response)
    response.response_header[header_key.upcase.gsub('-', '_')].split(', ')
  end

  def make_http_request(method, url, body = nil, headers = {})
    http = nil
    EventMachine.run do
      http = EventMachine::HttpRequest.new(url).send(method, :body => body, :head => headers)
      http.callback { EventMachine.stop }
    end
    http
  end
end

HTTP_LIBRARY_ADAPTERS['curb'] = Module.new do
  def self.http_library_name; "Curb"; end

  def get_body_string(response)
    response.body_str
  end

  def get_header(header_key, response)
    headers = response.header_str.split("\r\n")[1..-1]
    headers.each do |h|
      if h =~ /^#{Regexp.escape(header_key)}: (.*)$/
        return $1.split(', ')
      end
    end
  end

  def make_http_request(method, url, body = nil, headers = {})
    Curl::Easy.new(url) do |c|
      c.headers = headers

      if [:post, :put].include?(method)
        c.send("http_#{method}", body)
      else
        c.send("http_#{method}")
      end
    end
  end
end

HTTP_LIBRARY_ADAPTERS['typhoeus'] = Module.new do
  def self.http_library_name; "Typhoeus"; end

  def get_body_string(response)
    response.body
  end

  def get_header(header_key, response)
    response.headers_hash[header_key]
  end

  def make_http_request(method, url, body = nil, headers = {})
    Typhoeus::Request.send(method, url, :body => body, :headers => headers)
  end
end

%w[ net_http typhoeus patron ].each do |_faraday_adapter|
  HTTP_LIBRARY_ADAPTERS["faraday-#{_faraday_adapter}"] = Module.new do
    class << self; self; end.class_eval do
      define_method(:http_library_name) do
        "Faraday (#{_faraday_adapter})"
      end
    end

    define_method(:faraday_adapter) { _faraday_adapter.to_sym }

    def get_body_string(response)
      response.body
    end

    def get_header(header_key, response)
      response.headers[header_key]
    end

    def make_http_request(method, url, body = nil, headers = {})
      url_root, url_rest = split_url(url)

      faraday_connection(url_root).send(method) do |req|
        req.url url_rest
        headers.each { |k, v| req[k] = v }
        req.body = body if body
      end
    end

    def split_url(url)
      uri = URI.parse(url)
      url_root = "#{uri.scheme}://#{uri.host}:#{uri.port}"
      rest = url.sub(url_root, '')

      [url_root, rest]
    end

    def faraday_connection(url_root)
      Faraday::Connection.new(:url => url_root) do |builder|
        builder.use VCR::Middleware::Faraday do |cassette|
          cassette.name    'faraday_example'

          if respond_to?(:match_requests_on)
            cassette.options :match_requests_on => match_requests_on
          end

          if respond_to?(:record_mode)
            cassette.options :record => record_mode
          end
        end

        builder.adapter faraday_adapter
      end
    end
  end
end

NET_CONNECT_NOT_ALLOWED_ERROR = /You can use VCR to automatically record this request and replay it later/

module HttpLibrarySpecs
  def test_http_library(library, supported_request_match_attributes, *other)
    # skip libs that only work on MRI
    return if RUBY_INTERPRETER != :mri && library =~ /(typhoeus|curb|patron|em-http)/

    unless adapter_module = HTTP_LIBRARY_ADAPTERS[library]
      raise ArgumentError.new("No http library adapter module could be found for #{library}")
    end

    describe "using #{adapter_module.http_library_name}" do
      include adapter_module

      # Necessary for ruby 1.9.2.  On 1.9.2 we get an error when we use super,
      # so this gives us another alias we can use for the original method.
      alias make_request make_http_request

      describe '#stub_requests using specific match_attributes' do
        before(:each) { subject.http_connections_allowed = false }
        let(:interactions) { YAML.load(File.read(File.join(File.dirname(__FILE__), '..', 'fixtures', YAML_SERIALIZATION_VERSION, 'match_requests_on.yml'))) }

        @supported_request_match_attributes = supported_request_match_attributes
        def self.matching_on(attribute, valid, invalid, &block)
          supported_request_match_attributes = @supported_request_match_attributes

          describe ":#{attribute}" do
            let(:perform_stubbing) { subject.stub_requests(interactions, match_requests_on) }
            let(:match_requests_on) { [attribute] }
            let(:record_mode) { :none }

            if supported_request_match_attributes.include?(attribute)
              before(:each) { perform_stubbing }
              module_eval(&block)

              valid.each do |val, response|
                it "returns the expected response for a #{val.inspect} request" do
                  get_body_string(make_http_request(val)).should == response
                end
              end

              it "raises an error for a request with a different #{attribute}" do
                expect { make_http_request(invalid) }.to raise_error(NET_CONNECT_NOT_ALLOWED_ERROR)
              end
            else
              it 'raises an error indicating matching requests on this attribute is not supported' do
                expect { perform_stubbing }.to raise_error(/does not support matching requests on #{attribute}/)
              end
            end
          end
        end

        matching_on :method, { :get => "get method response", :post => "post method response" }, :put do
          def make_http_request(http_method)
            make_request(http_method, 'http://some-wrong-domain.com/', nil, {})
          end
        end

        matching_on :host, { 'example1.com' => 'example1.com host response', 'example2.com' => 'example2.com host response' }, 'example3.com' do
          def make_http_request(host)
            make_request(:get, "http://#{host}/some/wrong/path", nil, {})
          end
        end

        matching_on :path, { '/path1' => 'path1 response', '/path2' => 'path2 response' }, '/path3' do
          def make_http_request(path)
            make_request(:get, "http://some.wrong.domain.com#{path}?p=q", nil, {})
          end
        end

        matching_on :uri, { 'http://example.com/uri1' => 'uri1 response', 'http://example.com/uri2' => 'uri2 response' }, 'http://example.com/uri3' do
          def make_http_request(uri)
            make_request(:get, uri, nil, {})
          end
        end

        matching_on :body, { 'param=val1' => 'val1 body response', 'param=val2' => 'val2 body response' }, 'param=val3' do
          def make_http_request(body)
            make_request(:put, "http://wrong-domain.com/wrong/path", body, {})
          end
        end

        matching_on :headers, {{ 'X-HTTP-HEADER1' => 'val1' } => 'val1 header response', { 'X-HTTP-HEADER1' => 'val2' } => 'val2 header response' }, { 'X-HTTP-HEADER1' => 'val3' } do
          def make_http_request(headers)
            make_request(:get, "http://wrong-domain.com/wrong/path", nil, headers)
          end
        end
      end

      def self.test_real_http_request(http_allowed, *other)
        let(:url) { "http://localhost:#{VCR::SinatraApp.port}/foo" }

        if http_allowed

          it 'allows real http requests' do
            get_body_string(make_http_request(:get, url)).should == 'FOO!'
          end

          describe 'recording new http requests' do
            let(:recorded_interaction) do
              interaction = nil
              VCR.should_receive(:record_http_interaction) { |i| interaction = i }
              make_http_request(:get, url)
              interaction
            end

            it 'does not record the request if the adapter is disabled' do
              subject.stub(:enabled?).and_return(false)
              VCR.should_not_receive(:record_http_interaction)
              make_http_request(:get, url)
            end

            it 'records the request uri' do
              recorded_interaction.request.uri.should == url
            end

            it 'records the request method' do
              recorded_interaction.request.method.should == :get
            end

            it 'records the request body' do
              recorded_interaction.request.body.should be_nil
            end

            it 'records the request headers' do
              recorded_interaction.request.headers.should be_nil
            end

            it 'records the response status code' do
              recorded_interaction.response.status.code.should == 200
            end

            it 'records the response status message' do
              recorded_interaction.response.status.message.should == 'OK'
            end unless other.include?(:status_message_not_exposed)

            it 'records the response body' do
              recorded_interaction.response.body.should == 'FOO!'
            end

            it 'records the response headers' do
              recorded_interaction.response.headers['content-type'].should == ["text/html;charset=utf-8"]
            end
          end
        else
          let(:record_mode) { :none }

          it 'does not allow real HTTP requests or record them' do
            VCR.should_receive(:record_http_interaction).never
            expect { make_http_request(:get, url) }.to raise_error(NET_CONNECT_NOT_ALLOWED_ERROR)
          end
        end
      end

      def test_request_stubbed(method, url, expected)
        subject.request_stubbed?(VCR::Request.new(method, url), [:method, :uri]).should == expected
      end

      it "returns false from #http_connections_allowed? when http_connections_allowed is set to nil" do
        subject.http_connections_allowed = nil
        subject.http_connections_allowed?.should == false
      end

      [true, false].each do |http_allowed|
        context "when #http_connections_allowed is set to #{http_allowed}" do
          before(:each) { subject.http_connections_allowed = http_allowed }

          it "returns #{http_allowed} for #http_connections_allowed?" do
            subject.http_connections_allowed?.should == http_allowed
          end

          test_real_http_request(http_allowed, *other)

          unless http_allowed
            describe '.ignore_localhost =' do
              localhost_response = "Localhost response"
              let(:record_mode) { :none }

              VCR::LOCALHOST_ALIASES.each do |localhost_alias|
                describe 'when set to true' do
                  before(:each) { subject.ignore_localhost = true }

                  it "allows requests to #{localhost_alias}" do
                    get_body_string(make_http_request(:get, "http://#{localhost_alias}:#{VCR::SinatraApp.port}/localhost_test")).should == localhost_response
                  end
                end

                describe 'when set to false' do
                  before(:each) { subject.ignore_localhost = false }

                  it "does not allow requests to #{localhost_alias}" do
                    expect { make_http_request(:get, "http://#{localhost_alias}:#{VCR::SinatraApp.port}/localhost_test") }.to raise_error(NET_CONNECT_NOT_ALLOWED_ERROR)
                  end
                end
              end
            end
          end

          context 'when some requests are stubbed, after setting a checkpoint' do
            before(:each) do
              subject.create_stubs_checkpoint(:my_checkpoint)
              @recorded_interactions = YAML.load(File.read(File.join(File.dirname(__FILE__), '..', 'fixtures', YAML_SERIALIZATION_VERSION, 'fake_example.com_responses.yml')))
              subject.stub_requests(@recorded_interactions, VCR::RequestMatcher::DEFAULT_MATCH_ATTRIBUTES)
            end

            if other.include?(:needs_net_http_extension)
              it 'returns true from #request_stubbed? for the requests that are stubbed' do
                test_request_stubbed(:post, 'http://example.com', true)
                test_request_stubbed(:get, 'http://example.com/foo', true)
              end

              it 'returns false from #request_stubbed? for requests that are not stubbed' do
                test_request_stubbed(:post, 'http://example.com/foo', false)
                test_request_stubbed(:get, 'http://google.com', false)
              end
            end

            it 'gets the stubbed responses when requests are made to http://example.com/foo, and does not record them' do
              VCR.should_receive(:record_http_interaction).never
              get_body_string(make_http_request(:get, 'http://example.com/foo')).should =~ /example\.com get response \d with path=foo/
            end

            it 'rotates through multiple responses for the same request' do
              get_body_string(make_http_request(:get, 'http://example.com/foo')).should == 'example.com get response 1 with path=foo'
              get_body_string(make_http_request(:get, 'http://example.com/foo')).should == 'example.com get response 2 with path=foo'

              # subsequent requests keep getting the last one
              get_body_string(make_http_request(:get, 'http://example.com/foo')).should == 'example.com get response 2 with path=foo'
              get_body_string(make_http_request(:get, 'http://example.com/foo')).should == 'example.com get response 2 with path=foo'
            end unless other.include?(:does_not_support_rotating_responses)

            it "correctly handles stubbing multiple values for the same header" do
              get_header('Set-Cookie', make_http_request(:get, 'http://example.com/two_set_cookie_headers')).should =~ ['bar=bazz', 'foo=bar']
            end

            context 'when we restore our previous check point' do
              before(:each) { subject.restore_stubs_checkpoint(:my_checkpoint) }

              test_real_http_request(http_allowed, *other)

              if other.include?(:needs_net_http_extension)
                it 'returns false from #request_stubbed?' do
                  test_request_stubbed(:get, 'http://example.com/foo', false)
                  test_request_stubbed(:post, 'http://example.com', false)
                  test_request_stubbed(:get, 'http://google.com', false)
                end
              end
            end
          end
        end
      end
    end
  end
end
