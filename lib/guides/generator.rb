# ---------------------------------------------------------------------------
#
# This script generates the guides. It can be invoked either directly or via the
# generate_guides rake task within the railties directory.
#
# Guides are taken from the source directory, and the resulting HTML goes into the
# output directory. Assets are stored under files, and copied to output/files as
# part of the generation process.
#
# Some arguments may be passed via environment variables:
#
#   WARNINGS
#     If you are writing a guide, please work always with WARNINGS=1. Users can
#     generate the guides, and thus this flag is off by default.
#
#     Internal links (anchors) are checked. If a reference is broken levenshtein
#     distance is used to suggest an existing one. This is useful since IDs are
#     generated by Textile from headers and thus edits alter them.
#
#     Also detects duplicated IDs. They happen if there are headers with the same
#     text. Please do resolve them, if any, so guides are valid XHTML.
#
#   ALL
#    Set to "1" to force the generation of all guides.
#
#   ONLY
#     Use ONLY if you want to generate only one or a set of guides. Prefixes are
#     enough:
#
#       # generates only association_basics.html
#       ONLY=assoc ruby rails_guides.rb
#
#     Separate many using commas:
#
#       # generates only association_basics.html and migrations.html
#       ONLY=assoc,migrations ruby rails_guides.rb
#
#     Note that if you are working on a guide generation will by default process
#     only that one, so ONLY is rarely used nowadays.
#
#   EDGE
#     Set to "1" to indicate generated guides should be marked as edge. This
#     inserts a badge and changes the preamble of the home page.
#
# ---------------------------------------------------------------------------

require 'set'
require 'fileutils'
require 'yaml'

require 'active_support/core_ext/string/output_safety'
require 'active_support/core_ext/object/blank'
require 'action_controller'
require 'action_view'

require 'guides/indexer'
require 'guides/helpers'
require 'guides/levenshtein'

module Guides
  class Generator
    attr_reader :guides_dir, :source_dir, :output_dir, :edge, :warnings, :all

    GUIDES_RE = /\.(?:textile|html\.erb)$/
    LOCAL_ASSETS = File.expand_path("../templates/assets", __FILE__)

    def initialize(options)
      @options = options

      @guides_dir = File.expand_path(Dir.pwd)
      @source_dir = File.join(@guides_dir, "source")
      @output_dir = File.join(@guides_dir, "output")

      FileUtils.mkdir_p(@output_dir)

      @edge     = options[:edge]
      @warnings = options[:warnings]
      @all      = options[:all]

      @meta = Guides.meta
    end

    def generate
      generate_guides
      copy_assets
    end

  private
    def generate_guides
      guides_to_generate.each do |guide|
        next if guide =~ /(_.*|layout)\.html\.erb$/
        output_file = guide.sub(GUIDES_RE, '.html')
        generate_guide(guide, output_file)
      end
    end

    def guides_to_generate
      guides = Dir.entries(source_dir).grep(GUIDES_RE)

      guides.select do |guide|
        if @options[:only].empty?
          true
        else
          @options[:only].any? { |prefix| guide.start_with?(prefix) }
        end
      end
    end

    def copy_assets
      FileUtils.cp_r(Dir["#{LOCAL_ASSETS}/*"], output_dir)
      FileUtils.cp_r(Dir["#{guides_dir}/assets/*"], output_dir)
    end

    def generate?(source_file, output_file)
      fin  = File.join(source_dir, source_file)
      fout = File.join(output_dir, output_file)
      all || !File.exists?(fout) || File.mtime(fout) < File.mtime(fin)
    end

    def generate_guide(guide, output_file)
      return unless generate?(guide, output_file)

      puts "Generating #{output_file}"
      File.open(File.join(output_dir, output_file), 'w') do |f|
        view = ActionView::Base.new(source_dir, :edge => edge)
        view.extend(Helpers)

        if guide =~ /\.html\.erb$/
          # Generate the special pages like the home.
          view.render("sections")
          type = @edge ? "edge" : "normal"
          result = view.render(:layout => 'layout', :file => guide, :locals => {:guide_type => type})
        else
          body = File.read(File.join(source_dir, guide))
          body = set_header_section(body, view)
          body = set_index(body, view)

          result = view.render(:layout => 'layout', :text => textile(body))

          warn_about_broken_links(result) if @warnings
        end

        f.write result
      end
    end

    def set_header_section(body, view)
      new_body = body.gsub(/(.*?)endprologue\./m, '').strip
      header = $1

      header =~ /h2\.(.*)/
      page_title = "#{@meta["title"]}: #{$1.strip}"

      header = textile(header)

      view.content_for(:page_title) { page_title.html_safe }
      view.content_for(:header_section) { header.html_safe }
      new_body
    end

    def set_index(body, view)
      index = <<-INDEX
      <div id="subCol">
        <h3 class="chapter"><img src="images/chapters_icon.gif" alt="" />Chapters</h3>
        <ol class="chapters">
      INDEX

      i = Indexer.new(body, warnings)
      i.index

      # Set index for 2 levels
      i.level_hash.each do |key, value|
        link = view.content_tag(:a, :href => key[:id]) { textile(key[:title], true).html_safe }

        children = value.keys.map do |k|
          view.content_tag(:li,
            view.content_tag(:a, :href => k[:id]) { textile(k[:title], true).html_safe })
        end

        children_ul = children.empty? ? "" : view.content_tag(:ul, children.join(" ").html_safe)

        index << view.content_tag(:li, link.html_safe + children_ul.html_safe)
      end

      index << '</ol>'
      index << '</div>'

      view.content_for(:index_section) { index.html_safe }

      i.result
    end

    def textile(body, lite_mode=false)
      # If the issue with notextile is fixed just remove the wrapper.
      with_workaround_for_notextile(body) do |new_body|
        t = RedCloth.new(new_body)
        t.hard_breaks = false
        t.lite_mode = lite_mode
        t.to_html(:notestuff, :plusplus, :code, :tip)
      end
    end

    # For some reason the notextile tag does not always turn off textile. See
    # LH ticket of the security guide (#7). As a temporary workaround we deal
    # with code blocks by hand.
    def with_workaround_for_notextile(body)
      code_blocks = []

      body.gsub!(%r{<(yaml|shell|ruby|erb|html|sql|plain|javascript)>(.*?)</\1>}m) do |m|
        brush = case $1
          when 'ruby', 'sql', 'javascript', 'plain'
            $1
          when 'erb'
            'ruby; html-script: true'
          when 'html'
            'xml' # html is understood, but there are .xml rules in the CSS
          else
            'plain'
        end

        code_blocks.push(<<HTML)
<notextile>
<div class="code_container">
<pre class="brush: #{brush}; gutter: false; toolbar: false">
#{ERB::Util.h($2).strip}
</pre>
</div>
</notextile>
HTML
        "\ndirty_workaround_for_notextile_#{code_blocks.size - 1}\n"
      end

      body = yield body

      body.gsub(%r{<p>dirty_workaround_for_notextile_(\d+)</p>}) do |_|
        code_blocks[$1.to_i]
      end
    end

    def warn_about_broken_links(html)
      anchors = extract_anchors(html)
      check_fragment_identifiers(html, anchors)
    end

    def extract_anchors(html)
      # Textile generates headers with IDs computed from titles.
      anchors = Set.new
      html.scan(/<h\d\s+id="([^"]+)/).flatten.each do |anchor|
        if anchors.member?(anchor)
          puts "*** DUPLICATE ID: #{anchor}, please put and explicit ID, e.g. h4(#explicit-id), or consider rewording"
        else
          anchors << anchor
        end
      end

      # Footnotes.
      anchors += Set.new(html.scan(/<p\s+class="footnote"\s+id="([^"]+)/).flatten)
      anchors += Set.new(html.scan(/<sup\s+class="footnote"\s+id="([^"]+)/).flatten)
      return anchors
    end

    def check_fragment_identifiers(html, anchors)
      html.scan(/<a\s+href="#([^"]+)/).flatten.each do |fragment_identifier|
        next if fragment_identifier == 'mainCol' # in layout, jumps to some DIV
        unless anchors.member?(fragment_identifier)
          guess = anchors.min { |a, b|
            Levenshtein.distance(fragment_identifier, a) <=> Levenshtein.distance(fragment_identifier, b)
          }
          puts "*** BROKEN LINK: ##{fragment_identifier}, perhaps you meant ##{guess}."
        end
      end
    end
  end
end
