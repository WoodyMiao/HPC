#!/usr/bin/perl
use strict;
use warnings;


# set OOM killer and NMI watchdog threshold
system "echo 0 >/proc/sys/vm/panic_on_oom";
system "echo 0 >/proc/sys/vm/oom_dump_tasks";
system "echo 0 >/proc/sys/vm/oom_kill_allocating_task";
system "echo 0 >/proc/sys/kernel/sched_autogroup_enabled";
system "echo 1 >/proc/sys/kernel/nmi_watchdog";
system "echo 20 >/proc/sys/kernel/watchdog_thresh";
system "echo 60 >/proc/sys/kernel/panic";


my %threshold = ( # the threshold of available RAM (GB) to trigger the killer
    "master" => 10,
    "gpu01"  => 25,
    "node02" => 50,
    "pan02"  => 100,
    "pan01"  => 100,
);


my %suffix = (
    "t" => 1024,
    "g" => 1,
    "m" => 1 / 1024,
    "k" => 1 / 2 ** 20,
    "b" => 1 / 2 ** 30,
);


# Get the user list.
my %exempted_users = qw/ pcga_api 1 nfsnobody 1 /;
my %users;
open I, "<", "/etc/passwd";
while (<I>) {
    my @a = split /:/;
    $users{$a[0]} = 1 if $a[2] > 1000 and !$exempted_users{$a[0]};
}
close I;


# Get local time and host name.
my ($sec,$min,$hour_now,$mday,$mon,$year,$wday,$yday,$isdst) = localtime;
$mon += 1;
$year += 1900;
my $host = `hostname`;
chomp $host;


# Open file handels.
my $nice_filename = sprintf "/home/ml/work/renice_and_kill/${host}_%04s%02s%02s.nice.log", $year, $mon, $mday;
my $kill_filename = sprintf "/home/ml/work/renice_and_kill/${host}_%04s%02s%02s.kill.log", $year, $mon, $mday;
open NICE, ">", $nice_filename;
open KILL, ">", $kill_filename;
NICE -> autoflush;
KILL -> autoflush;
print NICE "Date\tTime\tPGID\tUser\tCPUhour\tNice\tRenice\tCMD\n";
print KILL "Date\tTime\tNodeRAM\tNodeUseRAM\tAvailRAM\tPGID\tUser\tJobID\tJobReqRAM\tJobUseRAM\tKill\tCMD\n";


# Do it;
while (1) {
    &renice_and_kill();
    sleep 10;
}


my %job_pgid; # hash of PBS job ID => PGID;
my %job_req_ram; # hash of PBS job ID => reqested RAM;
sub renice_and_kill {
    # Get local time.
    my ($sec,$min,$hour_now,$mday,$mon,$year,$wday,$yday,$isdst) = localtime;
    $mon += 1;
    $year += 1900;
    my $today = sprintf "%04s-%02s-%02s", $year, $mon, $mday;
    my $time_now = sprintf "%02s:%02s:%02s", $hour_now, $min, $sec;
    system "touch $nice_filename $kill_filename";

    # Get info of PGIDs.
    my %pgid_user; # hash of PGID => user
    my %pgid_ram; # hash of PGID => RAM(GB)
    my %pgid_hour; # hash of PID => CPU hours
    my %pgid_nice; # hash of PGID => nice
    my %pgid_pid; # hash of PGID => array of PID
    my %pgid_cmd; # hash of PGID => CMD
                          # [0]  [1]  [2] [3]     [4]  [5] [6]
    open I, "-|", "ps -e -o user,pgid,pid,cputime,nice,rss,cmd";
    while (<I>) {
        chomp;
        my @a = split /\s+/;
        next if !$users{$a[0]};
        next if $a[6] =~ /lib64\/R\/bin\/Rserve$/;
        if ($a[1] == $a[2]) {
            $pgid_user{$a[1]} = $a[0];
            $pgid_nice{$a[1]} = $a[4];
            $pgid_cmd{$a[1]} = join " ", splice(@a, 6);
        }
        $pgid_ram{$a[1]} += $a[5] / 2 ** 20;
        $a[3] =~ /(?:(\d\d?)-)?(\d\d):(\d\d):(\d\d)/;
        my $cpu_hour = 0;
        $cpu_hour = $1 if $1;
        $pgid_hour{$a[1]} += $cpu_hour * 24 + $2 + $3 / 60 + $4 / 3600;
        push @{$pgid_pid{$a[1]}}, $a[2];
    }
    close I;
    
    
    # Get info of PBS jobs
    my @jobs;
    open I, "-|", "/usr/local/torque/bin/qstat -n";
    while (<I>) {
        if (/^(\d+)\.master/) {
            my $job = $1;
            my @a = split /\s+/;
            $_ = <I>;
            /(gpu01|node02|pan01|pan02)/;
            next if $1 ne $host;
            push @jobs, $job;
            next if $job_pgid{$job};

            if ($a[4] =~ /(\d+)/) {
                $job_pgid{$job} = $1;
                open I1, "-|", "/usr/local/torque/bin/qstat -f $job";
                while (<I1>) {
                    if (/Resource_List.mem = (\d+)(t|g|m|k|b)/) {
                        $job_req_ram{$job} = $1 * $suffix{$2};
                        last;
                    }
                }
                close I1;
                $job_req_ram{$job} = 0 if !$job_req_ram{$job};
            }
        }
    }
    close I;


    my %pgid_job; # hash of PGID => job ID of PBS
    my %pgid_req_ram; # hash of PGID => requested RAM
    for (@jobs) {
        $pgid_job{$job_pgid{$_}} = $_;
        $pgid_req_ram{$job_pgid{$_}} = $job_req_ram{$_};
    }

 
    # renice and decide which one to kill.
    my $kill_pgid; # PGID of the group that is the most likely to be killed
    my $kill_pgid_pbs; # PGID of the PBS job that is the most likely to be killed
    my $max_ram_ratio = 1; # store the current max of UseRAM:ReqRAM

    for (sort { $pgid_ram{$b} <=> $pgid_ram{$a} } keys %pgid_ram) {
        next if !$pgid_user{$_};
        next if $pgid_ram{$_} < 10 and $pgid_hour{$_} < 1;
        if ($pgid_job{$_}) {
            my $ram_ratio;
            if ($pgid_req_ram{$_}) {
                $ram_ratio = $pgid_ram{$_} / $pgid_req_ram{$_};
            } else {
                $ram_ratio = 9999.99;
            }
            if ($ram_ratio > $max_ram_ratio) {
                $kill_pgid_pbs = $_;
                $max_ram_ratio = $ram_ratio;
            }
        } else {
            $kill_pgid = $_ if !$kill_pgid and $pgid_ram{$_} > 10;
            my $new_nice = int($pgid_hour{$_});
            $new_nice = 19 if $new_nice > 19;
            if ($new_nice > $pgid_nice{$_}) {
                my $renice_out = `renice -n $new_nice -g $_`;
                chomp $renice_out;
                if ($new_nice == 19) {
                    my @a = ($today, $time_now, $_, $pgid_user{$_}, sprintf("%.2f", $pgid_hour{$_}), $pgid_nice{$_}, $renice_out, $pgid_cmd{$_});
                    print NICE join("\t",  @a), "\n";
                }
            }
        }
    }


    # Get GB of avail RAM
    my @a = split /\s+/, `free -g`;
    my $total = $a[8];
    my $used = $a[9];
    my $avail = $a[13];

    # kill process groups
    if ($avail < $threshold{$host}) {
        print KILL "$today\t$time_now\t$total\t$used\t$avail\t";
        $kill_pgid = $kill_pgid_pbs if !$kill_pgid and $kill_pgid_pbs;
        if ($kill_pgid) {
            my $kill_cmd = "kill -9 " . join(" ", @{$pgid_pid{$kill_pgid}});
            system $kill_cmd;
            my $job_id;
            my $job_req;
            if ($pgid_job{$kill_pgid}) {
                $job_id = $pgid_job{$kill_pgid};
                $job_req = sprintf "%.2f", $pgid_req_ram{$kill_pgid};
            } else {
                $job_id = "N/A";
                $job_req = "N/A";
            }
            my $job_use = sprintf "%.2f", $pgid_ram{$kill_pgid};
            my @a = ($kill_pgid, $pgid_user{$kill_pgid}, $job_id, $job_req, $job_use, $kill_cmd, $pgid_cmd{$kill_pgid});
            print KILL join("\t",  @a), "\n";
        } else {
            print KILL "\t" x 5, "Nothing to kill, waiting to die ...\n";
        }
    }
}
