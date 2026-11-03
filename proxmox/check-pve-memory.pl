#!/usr/bin/perl
#
#   check-pve-memory
#
# DESCRIPTION:
#   Check memory on a Proxmox VE host, and look for memory that keeps
#   growing, such as a leak, in:
#     - host processes (PVE daemons, agents, anything else)
#     - LXC containers, as a whole
#     - QEMU processes, counting only memory above the VM's configured RAM,
#       so a VM using the RAM it was given is not treated as a leak
#     - kernel unreclaimable slab and shared memory (tmpfs, /dev/shm)
#   and project when the host will run out at the current rate of growth.
#
#   ZFS ARC above its minimum size is counted as available, because the
#   kernel can reclaim it.
#
#   Trends need history, so the check keeps samples in a state file and must
#   run on a schedule. It reports trends once it has --min-history hours of
#   samples, and history resets when the host reboots.
#
#   Runs as an unprivileged user; it only reads /proc and /sys.
#
# OUTPUT:
#   plain text
#
# PLATFORMS:
#   Linux (Proxmox VE, cgroup v1 or v2)
#
# USAGE:
#   check-pve-memory.pl
#   check-pve-memory.pl -w 90 -c 95 --creep-warn 256 --creep-crit 2048
#   check-pve-memory.pl --exclude '^java '
#

use strict;
use warnings;
use Getopt::Long qw(:config no_ignore_case bundling);

# JSON::PP comes with full Perl (the perl package); JSON with libjson-perl
my $JSON_CLASS;
BEGIN {
  for my $class (qw(JSON::PP JSON)) {
    if (eval "require $class; 1") {
      $JSON_CLASS = $class;
      last;
    }
  }
}

my @STATUS_LABELS = qw(OK WARNING CRITICAL UNKNOWN);
my $CHECK_NAME = 'CheckPVEMemory';
my $MIN_POINTS = 6;
my $MAX_LABEL = 80;

my %opt = (
  warn => 90,
  crit => 95,
  window => 24,
  min_history => 6,
  sample_interval => 300,
  min_size => 64,
  creep_warn => 256,
  creep_crit => 2048,
  min_fit => 0.8,
  eta_warn => 168,
  eta_crit => 24,
  top => 5,
  exclude => undef,
  no_arc => 0,
  state_file => undef,
  proc_path => '/proc',
  sys_path => '/sys',
  now => undef,
);

my $usage = <<"USAGE";
Usage: check-pve-memory.pl [options]

Check memory on a Proxmox VE host and alert on memory that keeps growing.

Options:
  -w PCT                 Warn when host memory used is at least PCT (default: $opt{warn})
  -c PCT                 Critical when host memory used is at least PCT (default: $opt{crit})
  --creep-warn MB        Warn when something grows by MB per day or more (default: $opt{creep_warn})
  --creep-crit MB        Critical when something grows by MB per day or more (default: $opt{creep_crit})
  --eta-warn HOURS       Warn when the host will run out within HOURS (default: $opt{eta_warn})
  --eta-crit HOURS       Critical when the host will run out within HOURS (default: $opt{eta_crit})
  --window HOURS         Hours of history to fit trends over (default: $opt{window})
  --min-history HOURS    Hours of history needed before trends are checked (default: $opt{min_history})
  --min-fit R2           How closely growth must follow a straight line, 0-1 (default: $opt{min_fit})
  --sample-interval SEC  Minimum seconds between stored samples (default: $opt{sample_interval})
  --min-size MB          Track processes using at least MB (default: $opt{min_size})
  --top COUNT            How many of the largest users to list, 0 for none (default: $opt{top})
  --exclude REGEX        Ignore growth in anything whose label matches REGEX
  --no-arc               Do not count reclaimable ZFS ARC as available
  --state-file PATH      Where to keep history (default: first writable of
                         /var/cache/sensu/sensu-agent, /var/lib/sensu, /var/tmp, /tmp)
  --proc-path PATH       Path to procfs (default: /proc)
  --sys-path PATH        Path to sysfs (default: /sys)
  --now EPOCH            Use this time instead of the clock (for testing)
  -h, --help             Show this help message
USAGE

GetOptions(
  'w=f' => \$opt{warn},
  'c=f' => \$opt{crit},
  'creep-warn=f' => \$opt{creep_warn},
  'creep-crit=f' => \$opt{creep_crit},
  'eta-warn=f' => \$opt{eta_warn},
  'eta-crit=f' => \$opt{eta_crit},
  'window=f' => \$opt{window},
  'min-history=f' => \$opt{min_history},
  'min-fit=f' => \$opt{min_fit},
  'sample-interval=f' => \$opt{sample_interval},
  'min-size=f' => \$opt{min_size},
  'top=i' => \$opt{top},
  'exclude=s' => \$opt{exclude},
  'no-arc' => \$opt{no_arc},
  'state-file=s' => \$opt{state_file},
  'proc-path=s' => \$opt{proc_path},
  'sys-path=s' => \$opt{sys_path},
  'now=f' => \$opt{now},
  'h|help' => sub { print $usage; exit 0 },
) or finish(3, "invalid arguments\n$usage");

finish(3, 'unexpected argument: ' . join(' ', @ARGV)) if @ARGV;
finish(3, 'needs the JSON::PP Perl module (apt-get install perl)') unless $JSON_CLASS;
finish(3, '--window must be greater than --min-history') if $opt{window} <= $opt{min_history};
finish(3, '--min-history must be greater than 0') if $opt{min_history} <= 0;
finish(3, '--min-fit must be between 0 and 1') if $opt{min_fit} < 0 || $opt{min_fit} > 1;

my $exclude_re;
if (defined $opt{exclude}) {
  $exclude_re = eval { qr/$opt{exclude}/ };
  finish(3, "invalid --exclude regex: $@") unless $exclude_re;
}

my $now = defined $opt{now} ? $opt{now} : time();
my @notes;

my $result = eval { run(); 1 };
finish(3, "check failed: $@") unless $result;

sub run {
  my $mem = read_meminfo() or finish(3, "cannot read $opt{proc_path}/meminfo");
  my $arc = read_arc();
  my $history = load_state();
  my $procs = read_processes($history->{series});
  my $cts = read_containers();

  # Host totals
  my $total = $mem->{MemTotal};
  my $available = $mem->{MemAvailable};
  unless (defined $available) {
    $available = ($mem->{MemFree} || 0) + ($mem->{Buffers} || 0) + ($mem->{Cached} || 0);
  }
  my $arc_reclaimable = 0;
  if ($arc && !$opt{no_arc}) {
    $arc_reclaimable = $arc->{size} - $arc->{c_min};
    $arc_reclaimable = 0 if $arc_reclaimable < 0;
  }
  $available += $arc_reclaimable;
  $available = $total if $available > $total;
  my $used = $total - $available;
  my $used_pct = $total > 0 ? 100 * $used / $total : 0;
  my $swap_used = ($mem->{SwapTotal} || 0) - ($mem->{SwapFree} || 0);

  # Everything that can be trended, as key => { value (kB), label }
  my %current;
  my $vm_ram_in_use = 0;
  for my $vm (@{ $procs->{vms} }) {
    my $in_config = $vm->{footprint} < $vm->{configured} ? $vm->{footprint} : $vm->{configured};
    $vm_ram_in_use += $in_config;
    my $overhead = $vm->{footprint} - $vm->{configured};
    $current{"vm:$vm->{vmid}:$vm->{pid}:$vm->{start}"} = {
      value => $overhead > 0 ? $overhead : 0,
      label => "$vm->{label} QEMU overhead above " . fmt_kb($vm->{configured}) . ' configured',
    };
  }
  for my $proc (@{ $procs->{processes} }) {
    $current{"p:$proc->{pid}:$proc->{start}"} = { value => $proc->{footprint}, label => $proc->{label} };
  }
  for my $ct (@$cts) {
    $current{"ct:$ct->{vmid}"} = { value => $ct->{footprint}, label => "CT $ct->{vmid}" };
  }
  $current{'host:slab'} = { value => $mem->{SUnreclaim} || 0, label => 'kernel slab (SUnreclaim)' }
    if defined $mem->{SUnreclaim};
  $current{'host:shmem'} = { value => $mem->{Shmem} || 0, label => 'shared memory and tmpfs (Shmem)' }
    if defined $mem->{Shmem};

  # Host memory in use other than guest RAM, so VMs filling their own RAM
  # after starting do not look like the host running out.
  my $used_ex_vm = $used - $vm_ram_in_use;
  $used_ex_vm = 0 if $used_ex_vm < 0;
  $current{'host:used_ex_vm'} = { value => $used_ex_vm, label => 'host memory used outside VM RAM' };

  # History
  my $state = update_state($history, \%current);
  my %status = (code => 0);
  my @creeping;
  my $host_trend;

  for my $key (keys %current) {
    my $points = $state->{series}{$key} || [];
    my $growth = assess_growth($points);
    next unless $growth;
    if ($key eq 'host:used_ex_vm') {
      $host_trend = $growth;
      next;
    }
    next unless $growth->{creeping} && $growth->{rate} >= $opt{creep_warn};
    my $label = $current{$key}{label};
    next if $exclude_re && $label =~ $exclude_re;
    my $level = $growth->{rate} >= $opt{creep_crit} ? 2 : 1;
    raise(\%status, $level);
    push @creeping, { %$growth, label => $label, value => $current{$key}{value}, level => $level };
  }

  # Thresholds on memory used now
  if ($used_pct >= $opt{crit}) {
    raise(\%status, 2);
  } elsif ($used_pct >= $opt{warn}) {
    raise(\%status, 1);
  }

  # When the host runs out at the current rate of growth
  my $eta_hours;
  if ($host_trend && $host_trend->{creeping} && $host_trend->{rate} > 0) {
    $eta_hours = $available / ($host_trend->{rate} * 1024 / 24);
    if ($eta_hours <= $opt{eta_crit}) {
      raise(\%status, 2);
    } elsif ($eta_hours <= $opt{eta_warn}) {
      raise(\%status, 1);
    }
  }

  # Build the output
  my $summary = sprintf('used %.1f%% (%s of %s), available %s', $used_pct, fmt_kb($used), fmt_kb($total), fmt_kb($available));
  $summary .= ' incl. ' . fmt_kb($arc_reclaimable) . ' reclaimable ZFS ARC' if $arc_reclaimable > 0;
  $summary .= ', swap used ' . fmt_kb($swap_used) if ($mem->{SwapTotal} || 0) > 0;
  $summary .= ', ' . scalar(@creeping) . ' growing' if @creeping;
  $summary .= sprintf(', runs out in %s', fmt_hours($eta_hours)) if defined $eta_hours;

  my @lines = ($summary);

  if (@creeping) {
    push @lines, '', 'Growing steadily:';
    for my $c (sort { $b->{rate} <=> $a->{rate} } @creeping) {
      push @lines, sprintf(
        '  %-11s %s, now %s, over %s, fit %.2f%s',
        '+' . fmt_kb($c->{rate} * 1024) . '/day',
        $c->{label},
        fmt_kb($c->{value}),
        fmt_hours($c->{span}),
        $c->{fit},
        $c->{level} == 2 ? ' CRITICAL' : ''
      );
    }
  }

  push @lines, '', host_trend_line($host_trend, $eta_hours);

  my @largest = largest($procs, $cts);
  if (@largest) {
    push @lines, '', 'Largest:';
    push @lines, map { sprintf('  %-8s %s', fmt_kb($_->{footprint}), $_->{label}) } @largest;
  }

  push @lines, '', @notes if @notes;

  # History that cannot be saved means trends are never checked, so do not
  # report OK on memory use alone.
  raise(\%status, 3) if $state->{save_failed} && $status{code} == 0;

  finish($status{code}, join("\n", @lines));
}

sub host_trend_line {
  my ($trend, $eta_hours) = @_;
  if (!$trend) {
    return 'Trend: no history yet';
  }
  if ($trend->{short}) {
    return sprintf(
      'Trend: collecting history, %s of %s needed (%d samples)',
      fmt_hours($trend->{span}),
      fmt_hours($opt{min_history}),
      $trend->{count}
    );
  }
  if (defined $eta_hours) {
    return sprintf(
      'Trend: host memory outside VM RAM growing %s/day (fit %.2f over %s), runs out in %s',
      fmt_kb($trend->{rate} * 1024),
      $trend->{fit},
      fmt_hours($trend->{span}),
      fmt_hours($eta_hours)
    );
  }
  return sprintf('Trend: host memory outside VM RAM not growing steadily over %s', fmt_hours($trend->{span}));
}

sub largest {
  my ($procs, $cts) = @_;
  return () if $opt{top} <= 0;
  my @rows;
  for my $vm (@{ $procs->{vms} }) {
    push @rows, { footprint => $vm->{footprint}, label => "$vm->{label}, " . fmt_kb($vm->{configured}) . ' configured' };
  }
  for my $ct (@$cts) {
    my $label = "CT $ct->{vmid}";
    $label .= ', limit ' . fmt_kb($ct->{limit}) if $ct->{limit};
    push @rows, { footprint => $ct->{footprint}, label => $label };
  }
  # Container processes are already counted in their container
  for my $proc (@{ $procs->{processes} }) {
    push @rows, $proc unless defined $proc->{ct};
  }
  @rows = sort { $b->{footprint} <=> $a->{footprint} } @rows;
  splice(@rows, $opt{top}) if @rows > $opt{top};
  return @rows;
}

# --- history ---

sub default_state_file {
  for my $dir ('/var/cache/sensu/sensu-agent', '/var/lib/sensu') {
    return "$dir/check-pve-memory.json" if -d $dir && -w $dir;
  }
  for my $dir ('/var/tmp', '/tmp') {
    return "$dir/check-pve-memory.$<.json" if -d $dir && -w $dir;
  }
  return undef;
}

sub load_state {
  my $path = defined $opt{state_file} ? $opt{state_file} : default_state_file();
  my $boot_id = read_file("$opt{proc_path}/sys/kernel/random/boot_id");
  $boot_id = '' unless defined $boot_id;
  chomp $boot_id;

  my $state;
  if (defined $path && -e $path) {
    my $raw = read_file($path);
    $state = eval { $JSON_CLASS->new->decode($raw) } if defined $raw;
    if (!$state || ref $state ne 'HASH' || ref $state->{series} ne 'HASH') {
      push @notes, "History in $path was unreadable and has been reset.";
      $state = undef;
    }
  }
  if ($state && ($state->{boot_id} || '') ne $boot_id) {
    $state = undef;
  }
  $state ||= { last_sample => undef, series => {} };
  $state->{boot_id} = $boot_id;
  $state->{path} = $path;
  return $state;
}

sub update_state {
  my ($state, $current) = @_;
  my ($path, $boot_id) = ($state->{path}, $state->{boot_id});

  my $cutoff = $now - $opt{window} * 3600;
  my %series;
  for my $key (keys %$current) {
    my $old = $state->{series}{$key};
    my @points = ref $old eq 'ARRAY'
      ? grep { ref $_ eq 'ARRAY' && @$_ == 2 && $_->[0] >= $cutoff && $_->[0] < $now } @$old
      : ();
    $series{$key} = \@points;
  }

  my $last = $state->{last_sample};
  my $record = !defined $last || $last > $now || $now - $last >= $opt{sample_interval} * 0.9;
  for my $key (keys %$current) {
    push @{ $series{$key} }, [int($now), int($current->{$key}{value})];
  }

  my $saved = { boot_id => $boot_id, last_sample => $record ? int($now) : $last, series => {} };
  if ($record) {
    $saved->{series} = \%series;
  } else {
    # Keep stored history unchanged; the current reading is only used for this run.
    for my $key (keys %series) {
      my @stored = @{ $series{$key} };
      pop @stored;
      $saved->{series}{$key} = \@stored;
    }
  }

  my $save_failed = 0;
  if ($record) {
    if (!defined $path) {
      push @notes, 'Cannot save history: no writable state directory; trends are not being checked.';
      $save_failed = 1;
    } elsif (my $error = write_state($path, $saved)) {
      push @notes, "Cannot save history to $path: $error; trends are not being checked.";
      $save_failed = 1;
    }
  }

  return { series => \%series, save_failed => $save_failed };
}

sub write_state {
  my ($path, $state) = @_;
  my $tmp = "$path.tmp.$$";
  my $json = $JSON_CLASS->new->canonical->encode($state);
  open(my $fh, '>', $tmp) or return "$!";
  print {$fh} $json or do { my $e = "$!"; close $fh; unlink $tmp; return $e };
  close $fh or do { my $e = "$!"; unlink $tmp; return $e };
  rename($tmp, $path) or do { my $e = "$!"; unlink $tmp; return $e };
  return undef;
}

# --- trend maths ---

# Least squares fit of value (kB) against time (hours).
sub fit {
  my ($points) = @_;
  my $n = @$points;
  return undef if $n < 3;
  my $t0 = $points->[0][0];
  my ($sx, $sy) = (0, 0);
  for my $p (@$points) {
    $sx += ($p->[0] - $t0) / 3600;
    $sy += $p->[1];
  }
  my ($mean_x, $mean_y) = ($sx / $n, $sy / $n);
  my ($sxx, $sxy, $syy) = (0, 0, 0);
  for my $p (@$points) {
    my $dx = ($p->[0] - $t0) / 3600 - $mean_x;
    my $dy = $p->[1] - $mean_y;
    $sxx += $dx * $dx;
    $sxy += $dx * $dy;
    $syy += $dy * $dy;
  }
  return undef if $sxx == 0;
  return {
    slope => $sxy / $sxx,
    fit => $syy == 0 ? 0 : ($sxy * $sxy) / ($sxx * $syy),
  };
}

# Growth in MB per day, and whether it is steady growth rather than noise,
# a one-off jump, or a warm-up that has levelled off.
sub assess_growth {
  my ($points) = @_;
  return undef unless @$points;
  my $span = ($points->[-1][0] - $points->[0][0]) / 3600;
  my $count = @$points;
  if ($span < $opt{min_history} || $count < $MIN_POINTS) {
    return { short => 1, span => $span, count => $count, creeping => 0, rate => 0 };
  }

  my $all = fit($points);
  return { span => $span, count => $count, creeping => 0, rate => 0, fit => 0 } unless $all && $all->{slope} > 0;

  my $mid = $points->[0][0] + ($points->[-1][0] - $points->[0][0]) / 2;
  my @recent = grep { $_->[0] >= $mid } @$points;
  my $recent = fit(\@recent);

  my $rate = $all->{slope} * 24 / 1024;
  my $creeping = $all->{fit} >= $opt{min_fit}
    && $recent
    && $recent->{slope} >= 0.5 * $all->{slope}
    && $points->[-1][1] > $points->[0][1];

  return { span => $span, count => $count, rate => $rate, fit => $all->{fit}, creeping => $creeping ? 1 : 0 };
}

# --- readers ---

sub read_file {
  my ($path) = @_;
  open(my $fh, '<', $path) or return undef;
  local $/;
  my $content = <$fh>;
  close $fh;
  return $content;
}

sub read_meminfo {
  my $raw = read_file("$opt{proc_path}/meminfo");
  return undef unless defined $raw;
  my %mem;
  for my $line (split /\n/, $raw) {
    $mem{$1} = $2 if $line =~ /^(\w+):\s+(\d+)/;
  }
  return undef unless $mem{MemTotal};
  return \%mem;
}

# ZFS ARC size and minimum, in kB
sub read_arc {
  my $raw = read_file("$opt{proc_path}/spl/kstat/zfs/arcstats");
  return undef unless defined $raw;
  my %arc;
  for my $line (split /\n/, $raw) {
    $arc{$1} = $2 if $line =~ /^(size|c_min)\s+\d+\s+(\d+)/;
  }
  return undef unless defined $arc{size} && defined $arc{c_min};
  return { size => int($arc{size} / 1024), c_min => int($arc{c_min} / 1024) };
}

# Processes using at least --min-size, plus any already being tracked so a
# process that dips below it keeps its history.
sub read_processes {
  my ($series) = @_;
  my (@processes, @vms);
  my $others_visible = 0;
  my $min_size = $opt{min_size} * 1024;

  opendir(my $dh, $opt{proc_path}) or die "cannot read $opt{proc_path}: $!\n";
  my @pids = grep { /^\d+$/ } readdir($dh);
  closedir $dh;

  for my $pid (@pids) {
    next if $pid == $$;
    my $dir = "$opt{proc_path}/$pid";
    my $status = read_file("$dir/status");
    next unless defined $status;
    my %f;
    for my $line (split /\n/, $status) {
      $f{$1} = $2 if $line =~ /^(Name|Uid|VmRSS|RssAnon|RssShmem|VmSwap):\s+(\S+)/;
    }
    $others_visible = 1 if defined $f{Uid} && $f{Uid} != $<;
    next unless defined $f{VmRSS};    # kernel threads

    my $stat = read_file("$dir/stat");
    next unless defined $stat && $stat =~ /\)\s+(.*)$/s;
    my @rest = split /\s+/, $1;
    my $start = $rest[19];
    next unless defined $start;

    my $swap = $f{VmSwap} || 0;
    my $name = defined $f{Name} ? $f{Name} : '?';
    my $proc = { pid => $pid, start => $start, name => $name };

    if ($name eq 'kvm' || $name =~ /^qemu-system/) {
      my $vm = parse_kvm(read_file("$dir/cmdline"));
      if ($vm) {
        my $footprint = defined $f{RssAnon}
          ? $f{RssAnon} + ($f{RssShmem} || 0) + $swap
          : $f{VmRSS} + $swap;
        push @vms, { %$proc, %$vm, footprint => $footprint };
        next;
      }
    }

    # Private memory, including any swapped out. Shared and file-backed pages
    # move with caching and other processes, so they are left out.
    $proc->{footprint} = defined $f{RssAnon} ? $f{RssAnon} + $swap : $f{VmRSS} + $swap;
    next if $proc->{footprint} < $min_size && !$series->{"p:$pid:$start"};

    my $cgroup = read_file("$dir/cgroup");
    $proc->{ct} = $1 if defined $cgroup && $cgroup =~ m{/lxc/(\d+)(?:/|$)}m;
    $proc->{cmdline} = read_file("$dir/cmdline");
    $proc->{label} = process_label($proc);
    push @processes, $proc;
  }

  if (!$others_visible && $< != 0) {
    push @notes, "Only this user's processes are visible (is /proc mounted with hidepid?); process growth is not being checked.";
  }

  return { processes => \@processes, vms => \@vms };
}

sub process_label {
  my ($proc) = @_;
  my $cmd = defined $proc->{cmdline} ? $proc->{cmdline} : '';
  $cmd =~ s/\0+$//;
  $cmd =~ s/\0/ /g;
  $cmd =~ s/\s+/ /g;
  $cmd = "[$proc->{name}]" if $cmd eq '';
  $cmd = substr($cmd, 0, $MAX_LABEL - 3) . '...' if length($cmd) > $MAX_LABEL;
  my $label = "$cmd (pid $proc->{pid})";
  $label .= " in CT $proc->{ct}" if defined $proc->{ct};
  return $label;
}

# Proxmox starts VMs as: kvm -id 101 -name 'web1,debug-threads=on' -m 4096 ...
sub parse_kvm {
  my ($cmdline) = @_;
  return undef unless defined $cmdline;
  my @args = split /\0/, $cmdline;
  my ($vmid, $name, $configured);
  my $dimms = 0;
  for my $i (0 .. $#args - 1) {
    my ($arg, $value) = ($args[$i], $args[$i + 1]);
    if ($arg eq '-id') {
      $vmid = $value;
    } elsif ($arg eq '-name') {
      ($name) = split /,/, $value;
    } elsif ($arg eq '-m') {
      my $size = $value =~ /(?:^|,)size=([^,]+)/ ? $1 : (split /,/, $value)[0];
      $configured = size_kb($size, 'M');
    } elsif ($arg eq '-object' && $value =~ /^memory-backend-\w+,/ && $value =~ /(?:^|,)id=mem-dimm/) {
      # Hotplugged memory
      $dimms += size_kb($1, 'B') || 0 if $value =~ /(?:^|,)size=([^,]+)/;
    }
  }
  return undef unless defined $vmid && $vmid =~ /^\d+$/ && $configured;
  my $label = "VM $vmid";
  $label .= " ($name)" if defined $name && length $name;
  return { vmid => $vmid, label => $label, configured => $configured + $dimms };
}

sub size_kb {
  my ($value, $default_unit) = @_;
  return undef unless defined $value && $value =~ /^(\d+(?:\.\d+)?)([KMGT]?)i?B?$/i;
  my ($number, $unit) = ($1, uc($2 || $default_unit));
  my %factor = (B => 1 / 1024, K => 1, M => 1024, G => 1024**2, T => 1024**3);
  return int($number * $factor{$unit});
}

# LXC containers' own memory: anonymous, tmpfs and swap
sub read_containers {
  my @cts;
  my $v2 = "$opt{sys_path}/fs/cgroup/lxc";
  my $v1 = "$opt{sys_path}/fs/cgroup/memory/lxc";
  my ($base, $version) = -f "$opt{sys_path}/fs/cgroup/cgroup.controllers" ? ($v2, 2) : ($v1, 1);
  opendir(my $dh, $base) or return [];
  my @ids = grep { /^\d+$/ } readdir($dh);
  closedir $dh;

  for my $vmid (@ids) {
    my $dir = "$base/$vmid";
    my $raw = read_file("$dir/memory.stat");
    next unless defined $raw;
    my %stat;
    for my $line (split /\n/, $raw) {
      $stat{$1} = $2 if $line =~ /^(\w+)\s+(\d+)/;
    }
    my ($bytes, $limit);
    if ($version == 2) {
      next unless defined $stat{anon};
      my $swap = read_file("$dir/memory.swap.current");
      $bytes = $stat{anon} + ($stat{shmem} || 0) + (defined $swap && $swap =~ /(\d+)/ ? $1 : 0);
      my $max = read_file("$dir/memory.max");
      $limit = $1 if defined $max && $max =~ /^(\d+)/;
    } else {
      next unless defined $stat{total_rss};
      $bytes = $stat{total_rss} + ($stat{total_shmem} || 0) + ($stat{total_swap} || 0);
      my $max = read_file("$dir/memory.limit_in_bytes");
      $limit = $1 if defined $max && $max =~ /^(\d+)/ && $1 < 2**60;
    }
    push @cts, {
      vmid => $vmid,
      footprint => int($bytes / 1024),
      limit => defined $limit ? int($limit / 1024) : undef,
    };
  }
  return \@cts;
}

# --- output ---

sub fmt_kb {
  my ($kb) = @_;
  my $abs = abs($kb);
  return sprintf('%.1fG', $kb / 1048576) if $abs >= 1048576;
  return sprintf('%.0fM', $kb / 1024) if $abs >= 1024;
  return sprintf('%dK', $kb);
}

sub fmt_hours {
  my ($hours) = @_;
  return sprintf('%.0fd', $hours / 24) if $hours >= 72;
  return sprintf('%.1fh', $hours);
}

sub raise {
  my ($status, $level) = @_;
  # UNKNOWN never hides a WARNING or CRITICAL
  return if $level == 3 && $status->{code} > 0;
  $status->{code} = $level if $level > $status->{code} || $status->{code} == 3;
}

sub finish {
  my ($code, $message) = @_;
  print "$CHECK_NAME $STATUS_LABELS[$code]: $message\n";
  exit $code;
}
