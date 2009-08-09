module Babushka
  module DepHelpers
    def self.included base # :nodoc:
      base.send :include, HelperMethods
    end

    module HelperMethods
      def Dep name;                    Dep.for name.to_s                                        end
      def dep name, opts = {}, &block; Dep.new name, opts, block, BaseDepDefiner, BaseDepRunner end
      def pkg name, opts = {}, &block; Dep.new name, opts, block, PkgDepDefiner , PkgDepRunner  end
      def gem name, opts = {}, &block; Dep.new name, opts, block, GemDepDefiner , GemDepRunner  end
      def ext name, opts = {}, &block; Dep.new name, opts, block, ExtDepDefiner , ExtDepRunner  end
    end
  end

  class Dep
    attr_reader :name, :opts, :vars, :definer, :runner, :local_runner
    attr_accessor :unmet_message

    delegate :set, :merge, :define_var, :to => :local_runner

    def initialize name, in_opts, block, definer_class = DepDefiner, runner_class = DepRunner
      @name = name
      @opts = {
        :for => :all
      }.merge in_opts
      @vars = {}
      @local_runner = runner_class.new self
      @definer = definer_class.new self, &block
      @definer.process
      debug "\"#{name}\" depends on #{payload[:requires].inspect}"
      Dep.register self
    end

    def self.deps
      @@deps ||= {}
    end
    def self.count
      deps.length
    end
    def self.names
      @@deps.keys
    end
    def self.all
      @@deps.values
    end
    def self.clear!
      @@deps = {}
    end

    def self.register dep
      raise "There is already a registered dep called '#{dep.name}'." unless deps[dep.name].nil?
      deps[dep.name] = dep
    end
    def self.for name
      returning dep = deps[name] do |result|
        log"#{name.colorize 'grey'} #{"<- this dep isn't defined!".colorize('red')}" unless result
      end
    end

    def met? run_opts = {}
      process_with_opts run_opts.merge :attempt_to_meet => false
    end
    def meet run_opts = {}
      process_with_opts run_opts.merge :attempt_to_meet => !Base.opts[:dry_run]
    end

    def process with_runner
      @runner = with_runner
      cached? ? cached_result : process_and_cache
    end

    private

    def process_with_opts run_opts
      @local_runner.opts.update run_opts
      process @local_runner
    end

    def process_and_cache
      log name, :closing_status => (runner.attempt_to_meet ? true : :dry_run) do
        if runner.callstack.include? self
          log_error "Oh crap, endless loop! (#{runner.callstack.push(self).drop_while {|dep| dep != self }.map(&:name).join(' -> ')})"
        elsif ![:all, uname].include?(opts[:for])
          log_extra "not required on #{uname_str}."
          true
        else
          runner.callstack.push self
          returning process_in_dir do
            runner.callstack.pop
          end
        end
      end
    end

    def process_in_dir
      path = payload[:run_in].is_a?(Symbol) ? vars[payload[:run_in]] : payload[:run_in]
      in_dir path do
        call_task(:setup) and process_deps and process_self
      end
    end

    def process_deps
      @definer.requires.send(runner.attempt_to_meet ? :all? : :each, &L{|dep_name|
        unless (dep = Dep(dep_name)).nil?
          dep.send :process, runner
        end
      })
    end

    def process_self
      if !(met_result = run_met_task(:initial => true))
        if !runner.attempt_to_meet
          met_result
        else
          call_task :before and
          returning call_task :meet do call_task :after end
          run_met_task
        end
      elsif :fail == met_result
        log "fail lulz"
      else
        true
      end
    end

    def run_met_task task_opts = {}
      returning cache_process(call_task(:met?)) do |result|
        if :fail == result
          log_extra "You'll have to fix '#{name}' manually."
        elsif !result && task_opts[:initial]
          log_extra "#{name} not already met#{unmet_message_for(result)}."
        elsif result && !task_opts[:initial]
          log "#{name} met.".colorize('green')
        end
      end
    end

    def call_task task_name
      # log "calling #{name} / #{task_name}"
      local_runner.instance_exec &(@definer.send(task_name) || @definer.default_task(task_name))
    end

    def unmet_message_for result
      unmet_message.nil? || result ? '' : " - #{unmet_message}"
    end

    def cached_result
      returning cached_process do |result|
        log_result "#{name} (cached)", :result => result
      end
    end
    def cached?
      instance_variable_defined? :@_cached_process
    end
    def cached_process
      @_cached_process
    end
    def cache_process value
      @_cached_process = value
    end

    def payload
      @definer.payload
    end

    def require_counts
      (payload[:requires] || {}).map {|k,v| "#{k.inspect} => #{v.length}" }.join(', ')
    end


    public

    def inspect
      "#<Dep:#{object_id} '#{name}'#{" #{'un' if cached_process}met" if cached?}, deps = { #{require_counts} }>"
    end
  end
end
