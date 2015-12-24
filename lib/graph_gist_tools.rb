require 'json'
require 'open-uri'
require 'faraday'

require 'action_controller'

module GraphGistTools
  class InvalidGraphGistIDError < StandardError; end

  ASCIIDOC_ATTRIBUTES = ['env-graphgist']

  # ActionController::Base.helpers.image_url('loading.gif')

  loading_image_tag = '<img src="' + ActionController::Base.asset_host.to_s + '/images/loading.gif" style="width: 30px">'

  COMMENT_REPLACEMENTS = {
    console: '<p class="console"><span class="loading">' + loading_image_tag + ' Running queries, preparing the console!</span></p>',

    graph_result: '<h5 class="graph-visualization" data-style="{style}" graph-mode="result">' + loading_image_tag + '</h5>',
    graph: '<h5 class="graph-visualization" data-style="{style}">Loading graph...' + loading_image_tag + '</h5>',
    table: '<h5 class="result-table">Loading table...' + loading_image_tag + '</h5>',

    hide: '<span class="hide-query"></span>',
    setup: '<span class="setup"></span>',
    output: '<span class="query-output"></span>'
  }

  def self.asciidoc_document(asciidoc_text)
    text = asciidoc_text.dup
    COMMENT_REPLACEMENTS.each do |tag, replacement|
      prefix = nil
      prefix = "\n\n[subs=\"attributes\"]\n" if [:graph_result, :graph].include?(tag)
      text.gsub!(Regexp.new(%r{^//\s*#{tag}}, 'gm'), "#{prefix}++++\n#{replacement}\n++++\n")
    end

    Asciidoctor.load(text, attributes: ASCIIDOC_ATTRIBUTES)
  end

  def self.metadata_html(asciidoc_doc)
    attrs = asciidoc_doc.attributes

    %(<span id="metadata" author="#{attrs['author']}" version="#{attrs['neo4j-version']}" twitter="#{attrs['twitter']}" tags="#{attrs['tags']}" />)
  end

  #   let_context url: 'http://github.com/neo4j-examples/graphgists/blob/master/fraud/bank-fraud-detection.adoc' do
  #     it { should eq 'https://raw.githubusercontent.com/neo4j-examples/graphgists/master/fraud/bank-fraud-detection.adoc' }

  def self.raw_url_for(url) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength
    case url.strip
    when %r{^https?://gist\.github\.com/([^/]+/)?([^/]+)/?(edit|[0-9a-f]{40})?/?$}
      url_from_github_graphgist_api($2, ($3.to_s.size == 40) ? $3 : nil)

    when %r{^https?://gist\.neo4j\.org/\?(.+)$}
      raw_url_for_graphgist_id($1)

    when %r{^https?://graphgist.neo4j.com/#!/gists/([^/]+)/?$}
      id = $1
      raw_url_for_graphgist_id(id) if id && !id.match(/[0-9a-f]{32}/)

    when %r{^https?://(www\.)?github\.com/([^/]+)/([^/]+)/blob/([^/]+)/(.+)/?$}
      raw_url_from_github_api($2, $3, $5, $4)

    when %r{^https?://(www\.)?dropbox\.com/s/([^/]+)/([^\?]+)(\?dl=(0|1))?$}
      "https://www.dropbox.com/s/#{$2}/#{$3}?dl=1"

    when %r{^https?://docs.google.com/document/d/([^\/]+)(/edit)?$}
      "https://docs.google.com/document/u/0/export?format=txt&id=#{$1}"

    when %r{^(https?://[^/]*etherpad[^/]*/([^/]+/)*)p/([^/]+)/?$}
      "#{$1}p/#{$3}/export/txt"

    when %r{^https?://(www.)?pastebin.com/([^/]+)/?$}
      "http://pastebin.com/raw.php?i=#{$2}"

    else
      url if url_returns_text_content_type?(url)
    end
  end

  class BasicAuthRequiredError < StandardError; end

  def self.url_returns_text_content_type?(url)
    http_connection = Faraday.new url: url
    result = http_connection.head url

    raise BasicAuthRequiredError if result.status == 401 && result['www-authenticate']

    [200, 302].include?(result.status) && result.headers['content-type'].match(%r{^text/})
  rescue URI::InvalidURIError, Faraday::ConnectionFailed
    nil
  end


  def self.raw_url_for_graphgist_id(graphgist_id)
    id = graphgist_id.nil? ? nil : URI.decode(graphgist_id) if graphgist_id

    raw_url = raw_url_for_provider(id)
    return raw_url if raw_url

    if id.match(%r{^(https?://[^/]+)/(.+)$})
      _, host, path = id.match(%r{^(https?://[^/]+)/(.+)$}).to_a
      host + '/' + URI.encode(URI.decode(path))
    else
      url_from_github_graphgist_api(id)
    end
  end

  def self.raw_url_for_provider(id)
    case id
    when %r{^github-([^/]*)/([^/]*)/(.*)$}
      raw_url_from_github_api($1, $2, $3)
    when /^dropbox(s?)-(.*)$/
      "https://dl.dropboxusercontent.com/#{$1.empty? ? 'u' : 's'}/#{$2}"
    when /^copy-(.*)$/
      "https://copy.com/#{$1}?download=1"
    end
  end



  def self.github_api_headers
    ENV['GITHUB_TOKEN'] ? {'Authorization' => "token #{ENV['GITHUB_TOKEN']}"} : {}
  end

  def self.raw_url_from_github_api(owner, repo, path, branch = 'master')
    begin
      url = "https://api.github.com/repos/#{owner}/#{repo}/contents/#{path}?ref=#{branch}"
      data = JSON.load(open(url, github_api_headers).read)
    rescue OpenURI::HTTPError
      puts "WARNING: Error trying to fetch: #{url}"
      return nil
    end

    data['download_url']
  end

  def self.url_from_github_graphgist_api(id, revision = nil)
    begin
      url = "https://api.github.com/gists/#{id}#{'/' + revision if revision}"
      data = JSON.load(open(url, github_api_headers).read)
    rescue OpenURI::HTTPError
      puts "WARNING: Error trying to fetch: #{url}"
      return nil
    end

    fail InvalidGraphGistIDError, 'Gist has more than one file!' if data['files'].size > 1

    data['files'].to_a[0][1]['raw_url']
  end
end
