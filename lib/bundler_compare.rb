#!/usr/bin/env ruby
# frozen_string_literal: true

# Compares to Bundler lock files and prints a report
# of which gems have changed version
require 'bundler'
require 'pry'
require 'active_support'
require 'active_support/core_ext/string'
require 'rubytoolbox/api'

class LockfileDiffer
  attr_reader :output, :source, :target, :source_lockfile, :target_lockfile

  def initialize(source, target)
    @output = []
    @source = source
    @target = target
  end

  def run
    prepare
    diff
  end

  def prepare
    csource = source.parameterize
    ctarget = target.parameterize

    tmpdir = ".gemfile-comparisons/#{csource}/#{ctarget}/#{DateTime.now.iso8601(3)}"
    @source_lockfile = "#{tmpdir}/Gemfile.#{csource}.lock"
    @target_lockfile = "#{tmpdir}/Gemfile.#{ctarget}.lock"

    FileUtils.mkdir_p(tmpdir)
    `git show #{source}:Gemfile.lock > #{source_lockfile}`
    `git show #{target}:Gemfile.lock > #{target_lockfile}`
  end

  def diff
    # a => b
    parser_a = read(source_lockfile)
    parser_b = read(target_lockfile)
    specs_a = parser_a.specs.to_h { [_1.name, _1] }
    specs_b = parser_b.specs.to_h { [_1.name, _1] }
    keys = (specs_a.keys | specs_b.keys).sort
    
    ruby_toolbox = {}
    health_status_names = Set[]
    fetch_ruby_toolbox(keys) do |gem|
        ruby_toolbox[gem.name] = gem
        hs = gem&.health&.statuses&.map{ |status| status.key}
        health_status_names |= hs if hs
    end
    Gem.ruby_toolbox_health_status_names = health_status_names.to_a.sort

    lines = []
    keys.each do |key|
      gem = Gem.new(
        key,
        parser_a,
        parser_b,
        specs_a,
        specs_b,
        ruby_toolbox[key],
      )
      lines << [
        key,
        gem.state_a.spec&.version,
        gem.state_b.spec&.version,
        gem.change_type,
        gem.semantic_type_of_update,
        gem.last_state.in_gemfile,
        gem.last_state.gemfile_source_type,
        gem.last_state.url,
        gem.ruby_toolbox&.score,
        gem.ruby_toolbox&.health&.overall_level,
      ] + gem.ruby_toolbox_health_status_values + [
        gem.ruby_toolbox&.rubygem&.latest_release_on,
        gem.ruby_toolbox&.rubygem&.stats&.downloads,
        gem.ruby_toolbox&.rubygem&.stats&.reverse_dependencies_count,
        gem.ruby_toolbox&.github_repo&.average_recent_committed_at,
        gem.ruby_toolbox&.github_repo&.repo_pushed_at,
        gem.ruby_toolbox&.github_repo&.is_archived,
        gem.ruby_toolbox&.github_repo&.is_fork,
        gem.ruby_toolbox&.github_repo&.stats&.forks_count,
        gem.ruby_toolbox&.github_repo&.stats&.stargazers_count,
        gem.ruby_toolbox&.github_repo&.stats&.watchers_count,
        gem.ruby_toolbox&.github_repo&.issues&.total_count,
        gem.ruby_toolbox&.github_repo&.issues&.closed_count,
        gem.ruby_toolbox&.github_repo&.issues&.open_count,
        gem.ruby_toolbox&.github_repo&.pull_requests&.total_count,
        gem.ruby_toolbox&.github_repo&.pull_requests&.closed_count,
        gem.ruby_toolbox&.github_repo&.pull_requests&.open_count,
      ]
    end

    output << "Files: #{source_lockfile} -> #{target_lockfile}" 
    lines.prepend %w[
      Name
      SourceVersion
      TargetVersion
      ChangeType
      UpdateSemanticType
      InGemfile
      GemfileSource
      GithubUrl
      RubyToolboxScore
      HealthOverallLevel
    ] + Gem.ruby_toolbox_health_status_names + %w[
      RubygemLatestRelease
      RubygemDownloads
      RubygemReverseDependenciesCount
      GithubAverageRecentCommittedAt,
      GithubLatestRepoPush
      GithubArchived?
      GithubIsFork?
      GithubForksCount
      GithubStars
      GithubWatchers
      GithubIssuesTotal
      GithubIssuesClosed
      GithubIssuesOpen
      GithubPullRequestsTotal
      GithubPullRequestsClosed
      GithubPullRequestsOpen
    ]

    lines.sort!
    lines.each do |cols|
      output << cols.join("\t")
    end
    output
  end

  private

  class Gem
    attr_reader :key, :state_a, :state_b, :spec_a, :spec_b, :ruby_toolbox

    class << self
      attr_reader :ruby_toolbox_health_status_names

      def ruby_toolbox_health_status_names=(value)
        @ruby_toolbox_health_status_names = value
      end
    end

    class GemState
      attr_reader :key, :parser, :spec, :dependency, :ruby_toolbox

      def initialize(key, parser, specs, ruby_toolbox)
        @key = key
        @parser = parser
        @spec = specs[key]
        @dependency = parser.dependencies[key]
        @ruby_toolbox = ruby_toolbox
      end

      def in_gemfile
        !dependency.nil?
      end

      def gemfile_source
        spec.source
      end

      def url
        if gemfile_source_type == :github
          spec.source
        else
          ruby_toolbox&.github_repo&.url
        end
      end

      def gemfile_source_type 
        {
          gem: /locally installed gems/,
          github: /github\.com/,
          subfolder: /source at/
        }.each_pair do |key, rx|
            return key if spec.source.to_s.match rx
          end
        ""
      end
    end

    def initialize(key, parser_a, parser_b, specs_a, specs_b, ruby_toolbox)
      @key = key
      @state_a = GemState.new(key, parser_a, specs_a, ruby_toolbox)
      @state_b = GemState.new(key, parser_b, specs_b, ruby_toolbox)
      @ruby_toolbox = ruby_toolbox
    end

    def added?
      !state_a.spec && state_b.spec
    end

    def removed?
      state_a.spec && !state_b.spec
    end

    def updated?
      state_a.spec && state_b.spec && state_a.spec.version.to_s != state_b.spec.version.to_s
    end

    def same?
      state_a.spec && state_b.spec && state_a.spec.version.to_s == state_b.spec.version.to_s
    end

    def change_type
      if added?
        'added'
      elsif removed?
        'removed'
      else
        updated? ? 'updated' : 'unchanged'
      end
    end
    
    def semantic_type_of_update
      return unless updated?

      a_major, a_minor, a_patch = state_a.spec.version.to_s.split('.').map(&:to_i)
      b_major, b_minor, b_patch = state_b.spec.version.to_s.split('.').map(&:to_i)

      return 'major+' if b_major && a_major && b_major > a_major
      return 'major-' if b_major && a_major && b_major < a_major

      return 'minor+' if b_minor && a_minor && b_minor > a_minor
      return 'minor-' if b_minor && a_minor && b_minor < a_minor

      return 'patch+' if b_patch && a_patch && b_patch > a_patch
      return 'patch-' if b_patch && a_patch && b_patch < a_patch

      'rest'
    end

    def last_state
      removed? ? state_a : state_b
    end

    def ruby_toolbox_health_status_values
      Gem.ruby_toolbox_health_status_names
        .map{ |status_name| ruby_toolbox&.health&.statuses&.any?{ |st| st.key == status_name } }
    end
  end

  def read(file)
    Bundler::LockfileParser.new(Bundler.read_file(file))
  end

  def fetch_ruby_toolbox(keys)
    keys.each_slice(100) do |slice|
      payload = Rubytoolbox::Api.new.compare(slice)
      payload.each do |gem|
        yield gem
      end
    end
  end
end
