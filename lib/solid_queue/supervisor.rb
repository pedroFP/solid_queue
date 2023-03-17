# frozen_string_literal: true

class SolidQueue::Supervisor
  include SolidQueue::AppExecutor, SolidQueue::Runner

  class << self
    def start(mode: :all, configuration: SolidQueue::Configuration.new)
      runners = case mode
      when :schedule then scheduler(configuration)
      when :work     then dispatchers(configuration)
      when :all      then [ scheduler(configuration) ] + dispatchers(configuration)
      else           raise "Invalid mode #{mode}"
      end

      new(runners).start
    end

    def dispatchers(configuration)
      configuration.queues.values.map { |queue_options| SolidQueue::Dispatcher.new(**queue_options) }
    end

    def scheduler(configuration)
      SolidQueue::Scheduler.new(**configuration.scheduler_options)
    end
  end

  attr_accessor :runners

  def initialize(runners)
    @runners = Array(runners)
  end

  def start
    trap_signals
    start_process_prune

    start_runners

    loop do
      sleep 0.1
      break if stopping?
    end

    stop_runners
    stop_process_prune
  end

  private
    def trap_signals
      %w[ INT TERM ].each do |signal|
        trap(signal) { stop }
      end
    end

    def start_runners
      runners.each do |runner|
        runner.supervisor_pid = pid

        fork do
          Process.setpgrp
          runner.start
        end

        log "Started #{runner}"
      end
    end

    def stop_runners
      runners.each(&:stop)
    end

    def start_process_prune
      @prune_task = Concurrent::TimerTask.new(run_now: true, execution_interval: SolidQueue.process_alive_threshold) { prune_dead_processes }
      @prune_task.execute
    end

    def stop_process_prune
      @prune_task.shutdown
    end

    def prune_dead_processes
      wrap_in_app_executor do
        SolidQueue::Process.prune
      end
    end
end