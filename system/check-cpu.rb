#!/usr/bin/env ruby
# frozen_string_literal: true

#
#   check-cpu
#
# DESCRIPTION:
#   Check CPU usage, and include the busiest processes over the same sample
#   window. Based on sensu-plugins-cpu-checks check-cpu.rb.
#
# OUTPUT:
#   plain text
#
# PLATFORMS:
#   Linux
#
# USAGE:
#   check-cpu.rb -w 80 -c 95
#   check-cpu.rb -w 80 -c 95 --top 15
#   check-cpu.rb --no-top
#
# LICENSE:
#   Copyright 2014 Sonian, Inc. and contributors. <support@sensuapp.org>
#   Released under the same terms as Sensu (the MIT license); see LICENSE
#   for details.
#

require 'optparse'
require 'json'
require 'etc'

CPU_METRICS = %i[user nice system idle iowait irq softirq steal guest guest_nice].freeze
DEFAULT_IDLE_METRICS = %i[idle iowait steal guest guest_nice].freeze
STATUS_LABELS = %w[OK WARNING CRITICAL UNKNOWN].freeze
MAX_COMMAND_LENGTH = 200

options = {
  less_than: false,
  warn: 80.0,
  crit: 100.0,
  sleep: 5.0,
  cache_file: nil,
  proc_path: '/proc',
  idle_metrics: DEFAULT_IDLE_METRICS.dup,
  top: 10,
  no_top: false
}
CPU_METRICS.each { |metric| options[metric] = false }

banner = <<BANNER
Usage: #{File.basename($PROGRAM_NAME)} [options]

Check CPU usage from #{options[:proc_path]}/stat and list the top processes
over the same sample window (PID, user, CPU%, MEM%, RSS, command).
BANNER

begin
  OptionParser.new do |opts|
    opts.banner = banner
    opts.separator ''
    opts.separator 'Options:'
    opts.on('-l', '--less_than', 'Alert when usage is below the threshold') do
      options[:less_than] = true
    end
    opts.on('-w WARN', Float, 'Warning threshold (default: 80)') do |value|
      options[:warn] = value
    end
    opts.on('-c CRIT', Float, 'Critical threshold (default: 100)') do |value|
      options[:crit] = value
    end
    opts.on('--sleep SLEEP', Float, 'Seconds between /proc/stat samples (default: 5)') do |value|
      options[:sleep] = value
    end
    opts.on('--cache-file CACHEFILE', 'Compare against a previous sample instead of sleeping') do |value|
      options[:cache_file] = value
    end
    opts.on('--proc-path PATH', 'Path to procfs (default: /proc)') do |value|
      options[:proc_path] = value
    end
    opts.on('--idle-metrics METRICS', 'Comma-separated metrics treated as idle') do |value|
      options[:idle_metrics] = value.split(',').map { |metric| metric.strip.to_sym }
    end
    opts.on('--top COUNT', Integer, 'How many processes to list (default: 10)') do |value|
      options[:top] = value
    end
    opts.on('--no-top', 'Do not list processes') do
      options[:no_top] = true
    end
    CPU_METRICS.each do |metric|
      opts.on("--#{metric}", "Check cpu #{metric} instead of total cpu usage") do
        options[metric] = true
      end
    end
    opts.on('-h', '--help', 'Show this help message') do
      puts opts
      exit 0
    end
  end.parse!
rescue OptionParser::ParseError => e
  warn "CheckCPU UNKNOWN: #{e.message}"
  exit 3
end

class CheckCPU
  def initialize(options)
    @options = options
    @check_name = 'CheckCPU TOTAL'
  end

  def run
    sample = acquire_stats(@options[:sleep])
    cpu_stats_before = sample[:cpu_before]
    cpu_stats_now = sample[:cpu_now]

    unknown('Could not read cpu stats from procfs') if cpu_stats_before.nil? || cpu_stats_now.nil?
    unknown('CPU sample is missing values') if cpu_stats_now.length.zero? || cpu_stats_before.length.zero?

    metrics = CPU_METRICS.slice(0, cpu_stats_now.length)

    cpu_total_diff = 0.to_f
    cpu_stats_diff = []
    metrics.each_index do |i|
      before = cpu_stats_before[i] || 0.0
      cpu_stats_diff[i] = cpu_stats_now[i] - before
      cpu_total_diff += cpu_stats_diff[i]
    end

    unknown('CPU total delta is zero; cannot calculate usage') if cpu_total_diff.zero?

    cpu_stats = []
    metrics.each_index do |i|
      cpu_stats[i] = 100 * (cpu_stats_diff[i] / cpu_total_diff)
    end

    idle_diff = metrics.each_with_index.map do |metric, i|
      @options[:idle_metrics].include?(metric) ? cpu_stats_diff[i] : 0.0
    end.reduce(0.0, :+)

    cpu_usage = 100 * (cpu_total_diff - idle_diff) / cpu_total_diff
    checked_usage = cpu_usage

    metrics.each do |metric|
      next unless @options[metric]
      @check_name = "CheckCPU #{metric.to_s.upcase}"
      checked_usage = cpu_stats[metrics.find_index(metric)]
    end

    msg = "total=#{round_pct(cpu_usage)}"
    cpu_stats.each_index { |i| msg += " #{metrics[i]}=#{round_pct(cpu_stats[i])}" }
    msg += format_top_processes(sample[:procs_before], sample[:procs_now], sample[:elapsed])

    if @options[:less_than]
      critical(msg) if checked_usage <= @options[:crit]
      warning(msg) if checked_usage <= @options[:warn]
    else
      critical(msg) if checked_usage >= @options[:crit]
      warning(msg) if checked_usage >= @options[:warn]
    end
    ok(msg)
  rescue StandardError => e
    unknown(e.message)
  end

  private

  def acquire_cpu_stats
    File.open("#{@options[:proc_path]}/stat", 'r').each_line do |line|
      info = line.split(/\s+/)
      name = info.shift
      return info.map(&:to_f) if name =~ /^cpu$/
    end
    nil
  end

  def acquire_process_stats
    stats = {}
    Dir.foreach(@options[:proc_path]) do |entry|
      next unless entry =~ /\A\d+\z/
      pid = entry.to_i
      next if pid == Process.pid
      parsed = read_process(pid)
      stats[pid] = parsed if parsed
    end
    stats
  rescue Errno::ENOENT, Errno::EACCES
    {}
  end

  def read_process(pid)
    proc_dir = "#{@options[:proc_path]}/#{pid}"
    line = File.read("#{proc_dir}/stat").chomp
    match = line.match(/\A(\d+)\s+\((.*)\)\s+(.*)\z/)
    return nil unless match

    rest = match[3].split
    return nil if rest.length < 22

    cmd = read_command(proc_dir, match[2])
    {
      utime: rest[11].to_f,
      stime: rest[12].to_f,
      rss_pages: rest[21].to_i,
      uid: File.stat(proc_dir).uid,
      cmd: cmd
    }
  rescue Errno::ENOENT, Errno::EACCES, Errno::ESRCH
    nil
  end

  def read_command(proc_dir, comm)
    cmdline = File.read("#{proc_dir}/cmdline")
    cmdline = cmdline.tr("\0", ' ').strip
    return "[#{comm}]" if cmdline.empty?
    cmdline
  rescue Errno::ENOENT, Errno::EACCES, Errno::ESRCH
    "[#{comm}]"
  end

  def acquire_stats(sec)
    if @options[:cache_file] && File.exist?(@options[:cache_file])
      acquire_stats_with_cache_file
    else
      acquire_stats_with_sleeping(sec)
    end
  end

  def acquire_stats_with_sleeping(sec)
    before_cpu = acquire_cpu_stats
    before_procs = acquire_process_stats
    sleep sec
    now_cpu = acquire_cpu_stats
    now_procs = acquire_process_stats
    write_cache(now_cpu, now_procs) if @options[:cache_file]
    {
      cpu_before: before_cpu,
      cpu_now: now_cpu,
      procs_before: before_procs,
      procs_now: now_procs,
      elapsed: sec.to_f
    }
  end

  def acquire_stats_with_cache_file
    cache = read_cache
    now_cpu = acquire_cpu_stats
    now_procs = acquire_process_stats
    now_ts = Time.now.to_f
    write_cache(now_cpu, now_procs, now_ts)
    elapsed = cache[:ts] ? now_ts - cache[:ts] : 0.0
    {
      cpu_before: cache[:cpu],
      cpu_now: now_cpu,
      procs_before: cache[:processes],
      procs_now: now_procs,
      elapsed: elapsed
    }
  end

  def read_cache
    parsed = JSON.parse(File.read(@options[:cache_file]))
    if parsed.is_a?(Array)
      { cpu: parsed.map(&:to_f), processes: {}, ts: nil }
    else
      {
        cpu: Array(parsed['cpu']).map(&:to_f),
        processes: normalize_proc_cache(parsed['processes']),
        ts: parsed['ts'] && parsed['ts'].to_f
      }
    end
  end

  def normalize_proc_cache(procs)
    return {} unless procs.is_a?(Hash)
    out = {}
    procs.each do |pid, data|
      next unless data.is_a?(Hash)
      utime = data['utime'] || data[:utime]
      stime = data['stime'] || data[:stime]
      next if utime.nil? || stime.nil?
      out[pid.to_i] = { utime: utime.to_f, stime: stime.to_f }
    end
    out
  end

  def write_cache(cpu, procs, timestamp = Time.now.to_f)
    payload = {
      'cpu' => cpu,
      'ts' => timestamp,
      'processes' => procs.each_with_object({}) do |(pid, data), hash|
        hash[pid.to_s] = { 'utime' => data[:utime], 'stime' => data[:stime] }
      end
    }
    File.write(@options[:cache_file], JSON.generate(payload))
  end

  def format_top_processes(before, after, elapsed)
    return '' if @options[:no_top] || @options[:top].to_i <= 0
    return '' if before.nil? || after.nil? || before.empty? || after.empty?
    return '' if elapsed.nil? || elapsed <= 0

    ticks = clk_tck
    pagesz = page_size
    mem_total = mem_total_kb
    rows = []

    after.each do |pid, now|
      prev = before[pid]
      next unless prev
      delta = (now[:utime] + now[:stime]) - (prev[:utime] + prev[:stime])
      cpu = 100.0 * delta / (ticks * elapsed)
      rss_kb = now[:rss_pages].to_f * pagesz / 1024.0
      mem = mem_total > 0 ? 100.0 * rss_kb / mem_total : 0.0
      rows << {
        pid: pid,
        user: user_name(now[:uid]),
        cpu: cpu,
        mem: mem,
        rss: format_rss(rss_kb),
        cmd: truncate_command(now[:cmd])
      }
    end

    return '' if rows.empty?

    lines = ['', 'Top processes:']
    lines << format('%-7s %-12s %6s %6s %8s %s', 'PID', 'USER', 'CPU%', 'MEM%', 'RSS', 'COMMAND')
    rows.sort_by { |row| -row[:cpu] }.first(@options[:top]).each do |row|
      lines << format(
        '%-7d %-12s %6.1f %6.1f %8s %s',
        row[:pid],
        row[:user],
        row[:cpu],
        row[:mem],
        row[:rss],
        row[:cmd]
      )
    end
    lines.join("\n")
  end

  def clk_tck
    return @clk_tck if defined?(@clk_tck)
    tck = `getconf CLK_TCK 2>/dev/null`.to_i
    @clk_tck = tck > 0 ? tck : 100
  end

  def page_size
    return @page_size if defined?(@page_size)
    size = `getconf PAGE_SIZE 2>/dev/null`.to_i
    @page_size = size > 0 ? size : 4096
  end

  def mem_total_kb
    return @mem_total_kb if defined?(@mem_total_kb)
    total = 0.0
    File.foreach("#{@options[:proc_path]}/meminfo") do |line|
      if line.start_with?('MemTotal:')
        total = line.split[1].to_f
        break
      end
    end
    @mem_total_kb = total
  rescue Errno::ENOENT, Errno::EACCES
    @mem_total_kb = 0.0
  end

  def user_name(uid)
    return '?' if uid.nil?
    Etc.getpwuid(uid).name
  rescue ArgumentError
    uid.to_s
  end

  def format_rss(kb)
    if kb >= 1_048_576
      format('%.1fG', kb / 1_048_576.0)
    elsif kb >= 1024
      format('%.1fM', kb / 1024.0)
    else
      format('%dK', kb.round)
    end
  end

  def truncate_command(cmd)
    text = cmd.to_s.gsub(/\s+/, ' ')
    return text if text.length <= MAX_COMMAND_LENGTH
    "#{text[0, MAX_COMMAND_LENGTH - 3]}..."
  end

  def round_pct(value)
    (value * 100).round / 100.0
  end

  def ok(message)
    finish(0, message)
  end

  def warning(message)
    finish(1, message)
  end

  def critical(message)
    finish(2, message)
  end

  def unknown(message)
    finish(3, message)
  end

  def finish(status, message)
    puts "#{@check_name} #{STATUS_LABELS[status]}: #{message}"
    exit status
  end
end

CheckCPU.new(options).run
