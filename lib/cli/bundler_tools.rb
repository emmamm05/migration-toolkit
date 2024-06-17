# frozen_string_literal: true

require 'thor'
require_relative '../bundler_compare'

module BundlerTools
  class Diff < Thor
    desc 'diff [SOURCE] [TARGET]', 'prints diff between source and target git refs'
    def diff(source = 'master', target = 'HEAD')
      LockfileDiffer.new(source, target).run.each { |line| puts line }
    end
  end

  class Bundler < Thor
    desc 'bundler SUBCOMMAND ...ARGS', 'manage bundler related commands'
    subcommand 'bundler', Diff
  end
end
