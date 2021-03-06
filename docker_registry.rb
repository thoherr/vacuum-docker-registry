#!/usr/bin/env ruby

require "json"
require "logger"
require "net/http"
require "optparse"
require "pp"
require "openssl"
require "uri"
require "set"
require "yaml"

DEFAULT_LOGGER = Logger.new(STDERR)
DEFAULT_LOGGER.level = Logger::WARN

def q(s)
    URI.escape(s)
end
class Layer
    attr_reader :digest, :size

    def initialize(dict)
        @dict = dict
        @size = dict["size"]
        @digest = dict["digest"]
    end

    def to_s
        "Digest=#{@digest}, Size: #{@size}"
    end
end


class Manifest
    attr_reader :dict, :version, :digest, :layers
    def initialize(digest, dict)
        @digest = digest
        @dict = dict
        @version = dict["schemaVersion"]
        raise "unknown manifest version: #{@version}" unless @version == 2
        @layers = dict["layers"].map { |d| Layer.new(d) }
    end

    def to_s
        "Digest=#{@digest}, Layers: #{@layers}"
    end
end

class HttpError < Exception
    attr_reader :code, :code_message, :body
    def initialize(url, code, code_message, body)
        super("HTTP Error #{code} on #{url}: #{code_message}")
        @body = body
        @code_message = code_message
        @code = code.to_i
    end
end

class DockerRegistry
    def initialize(base_url, ca_file=nil, insecure=false, logger=DEFAULT_LOGGER)
        @base_url = base_url + "/v2/"
        @ca_file = ca_file
        @insecure = insecure
        @logger = logger
    end

    def request(url, clazz=Net::HTTP::Get)
        uri = URI(@base_url + url)

        res = Net::HTTP.start(uri.host, uri.port,
                              :use_ssl => uri.scheme == 'https',
                              :ca_file => @ca_file,
                              :verify_mode => @insecure ? OpenSSL::SSL::VERIFY_NONE : OpenSSL::SSL::VERIFY_PEER) do |http|
            request_uri_param = if uri.respond_to? :request_uri then uri.request_uri else uri end
            request = clazz.new request_uri_param
            request["Accept"] = "application/vnd.docker.distribution.manifest.v2+json"
            @logger.debug("Request #{clazz} #{uri}")
            http.request request
        end
        @logger.debug("Reponse #{clazz} #{uri} returned #{res.code} (#{res.body})")
        res
    end

    def json_request(url, clazz=Net::HTTP::Get)
        res = request(url, clazz)
        if res.is_a? Net::HTTPSuccess
            body = if res.body.empty? then nil else JSON.parse(res.body) end
            [body, res.to_hash]
        elsif res.is_a? Net::HTTPClientError
            raise HttpError.new(url, res.code, res.message, res.body)
        else
            raise "Unknown response: #{res}"
        end
    end

    def validate()
        begin
            res, _ = json_request("")
            if res != {}
                raise "Error expected empty object as V2 validation result; got #{res}"
            end
        rescue Net::HTTPServerError => e
            raise "Error validing Registry Server API v2 - got #{e}"
        end
    end

    def list_repositories(count=250)
        res, _ = json_request("_catalog?n=#{count}")
        res["repositories"]
    end

    def list_tags(repo)
        res, _ = json_request("#{repo}/tags/list")
        res["tags"] or []
    end

    def get_manifest(repo, reference)
        begin
            manifest, headers = json_request("#{q(repo)}/manifests/#{q(reference)}")
        rescue HttpError => e
            if e.code == 404
                return nil
            else
                raise e
            end
        end
        Manifest.new(headers["docker-content-digest"].first, manifest)
    end

    def delete_manifest(repo, digest)
        res = json_request("#{q(repo)}/manifests/#{q(digest)}", clazz=Net::HTTP::Delete)
    end

    def delete_blob(repo, digest)
        res = request("#{q(repo)}/blobs/#{q(digest)}", clazz=Net::HTTP::Delete)
    end

    def human_size(i)
        sizes = [ "B", "KB", "MB", "GB", "TB" ]
        index = 0
        while i > 1000.0 && index < sizes.length
            i /= 1000.0
            index += 1
        end
        return sprintf("%.1f %s", i, sizes[index])
    end

    def list_size(repo)
	puts " - #{repo}"
	repo_sizes = {}
	for tag in self.list_tags(repo)
	    begin
		mani = get_manifest(repo, tag)
		if mani.nil?
		    raise "No manifest found"
		end
	    rescue RuntimeError => e
		puts "  - #{tag} (error: #{e})"
		next
	    end
	    digest = mani.digest
	    size = mani.layers.inject(0) { |sum, l| sum + l.size.to_i }
	    puts "  - #{tag} (#{digest}) #{human_size(size)}"
	    for l in mani.layers
		repo_sizes[l.digest] = l.size
	    end
	end
	puts " - overall: #{human_size(repo_sizes.values.inject(0) { |sum, x| sum + x }) } "
    end

    def list_all
        for repo in self.list_repositories
            list_size(repo)
        end
    end
end


if __FILE__ == $PROGRAM_NAME
    options = {
        :insecure => false
    }

    OptionParser.new do |opts|
        opts.banner = "Usage: docker_registry.rb [options] <command>"

        opts.on("-cFILE", "--ca-file", "Trust CA certificate from file") do |c|
            options[:ca_file] = c
        end
        opts.on("-k", "--insecure", "Do not verify peer SSL certificate") do |c|
            options[:insecure] = true
        end
        opts.on("-v", "--verbose", "Verbose output") do |c|
            DEFAULT_LOGGER.level = Logger::DEBUG
        end
    end.parse!

    if ARGV.size < 2
        puts "Syntax: #{$0} <registry> command"
        exit 1
    end

    r = DockerRegistry.new(ARGV[0], options[:ca_file], options[:insecure])
    r.validate
    result = r.send(ARGV[1], *ARGV[2..-1])
    if result.is_a? Enumerable
        for r in result
            puts "- #{r}"
        end
    else
        puts result
    end
end
