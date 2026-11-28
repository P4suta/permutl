use v5.36;
use Test2::V0;
use File::Temp ();
use POSIX      ();
use lib 't/lib';
use ManualClock;
use Test::Mutation::Pool;

# Every way through the loop of the pool ends by itself, and the pool counts the processes that it started and listed.
# The clock moves by hand, so no case waits for a deadline, and the cases together take less than a second.
# A pool that never ends meets the limit of the waits of the clock or the alarm, and either ends this file at once.
# A pool that loops forever therefore fails here long before the time limit of a mutation run would call it a timeout.

my $dir = File::Temp::tempdir( CLEANUP => 1 );

sub script ( $name, $code ) {
    my $path = "$dir/$name";
    open my $handle, '>', $path or die "open $path: $!";
    print {$handle} "alarm 60;\n\$| = 1;\n", $code or die "print $path: $!";
    close $handle or die "close $path: $!";
    return $path;
}

# No case opens the gate: the pool ends each gated test.
my $GATE = qq{select undef, undef, undef, 0.01 until -e "\$0.gate";\n};

sub task ( $path, %fields ) {
    return {
        command         => [ $^X, $path ],
        env             => {},
        cwd             => $dir,
        timeout         => 3,
        output_limit    => 100_000,
        stop_on_failure => 0,
        %fields,
    };
}

# The pool under a clock that moves by hand, with the work that it counted.
# The cleanup of a pool that never ends would wait on a clock that stands still, so the alarm ends the whole file.
sub pooled ( $clock, $jobs, $tasks, $done = sub (@) { return } ) {
    my ( %result, %work );
    my @queue = $tasks->@*;
    local $SIG{ALRM} = sub { POSIX::write( 2, "the pool did not end\n", 21 ); POSIX::_exit(1) };
    alarm 3;
    my $count = eval {
        Test::Mutation::Pool::run(
            jobs  => $jobs,
            clock => $clock,
            work  => \%work,
            next  => sub { shift @queue },
            done  => sub ( $task, $got ) { $result{ $task->{command}[1] } = $got; return $done->($task) },
        );
    };
    my $error = $@;
    alarm 0;
    bail_out("the pool did not end: $error") if $error =~ /waited (?:more than|for no time)/;
    die $error                               if !defined $count;
    return { count => $count, results => \%result, work => \%work };
}

my $QUICK = qq{print "1..1\\nok 1\\n";\n};

subtest 'an idle pool saves ready checkpoints before requesting work' => sub {
    my @calls;
    my $clock = ManualClock->new( limit => 0 );
    my $count = Test::Mutation::Pool::run(
        jobs        => 1,
        clock       => $clock,
        work        => {},
        checkpoints => [ sub ($may_wait) { push @calls, $may_wait ? 'save' : 'try'; return 1 } ],
        next        => sub { push @calls, 'next'; return },
        done        => sub { die 'unexpected test completion' },
    );
    is $count,  0,               'no child process ran';
    is \@calls, [qw(save next)], 'the saved result is available before the next work request';
};

subtest 'tasks, follow-up tasks, and an empty queue end' => sub {
    my @quick = map { script( "quick-$_.t", $QUICK ) } 1 .. 3;
    my $later = script( 'later.t', $QUICK );
    my $given = 0;
    my $run   = pooled( ManualClock->new, 2, [ map { task($_) } @quick ],
        sub ($task) { return $given++ ? undef : task($later) } );
    is $run->{count},                                          4,              'every task and the follow-up task ran';
    is [ map { $run->{results}{$_}{passed} } @quick, $later ], [ 1, 1, 1, 1 ], 'and passed';
    is $run->{work}, { spawns => 4 },                          'the pool counts a process for each task and lists none';

    is pooled( ManualClock->new, 3, [] ), { count => 0, results => {}, work => {} }, 'an empty queue ends at once';
};

subtest 'a follow-up shares the available slots with newly ready work' => sub {
    my $quick = script( 'follow-and-fill.t', $QUICK );
    my @ready = ( task($quick) );
    my ( %work, $follow, $started );
    my $clock =
      ManualClock->new( steps => [ sub (@) { return 0 unless $follow; $started = $work{spawns}; return 1 } ], );
    my $count = Test::Mutation::Pool::run(
        jobs             => 2,
        clock            => $clock,
        work             => \%work,
        retry_after_done => 1,
        next             => sub { shift @ready },
        done             => sub (@) {
            return if $follow;
            $follow = 1;
            push @ready, task($quick);
            return task($quick);
        },
    );
    is $count,   3, 'the original, follow-up, and independent tasks finished';
    is $started, 3, 'both free slots started work before the pool waited';
};

subtest 'each cause ends a test that would not end' => sub {
    my $failing  = script( 'failing.t',  qq{print "1..2\\nnot ok 1\\n";\n$GATE} );
    my $chatty   = script( 'chatty.t',   qq{print "#" x 100_001;\n$GATE} );
    my $sleeping = script( 'sleeping.t', $GATE );
    my $clock =
      ManualClock->new( steps => [ sub ( $clock, $seconds, $select ) { $select->count > 4 ? 0 : $clock->move(3) } ] );
    my $run   = pooled( $clock, 3, [ task( $failing, stop_on_failure => 1 ), task($chatty), task($sleeping) ] );
    my %cause = map { $_ => [ $run->{results}{$_}->@{qw(stopped overflowed timed_out)} ] } $failing, $chatty, $sleeping;
    is \%cause, { $failing => [ 1, 0, 0 ], $chatty => [ 0, 1, 0 ], $sleeping => [ 0, 0, 1 ] },
      'the first failure, the output limit, and the time limit';
    is $run->{work}, { spawns => 3, listings => 3 }, 'and the pool lists the processes once for each';
};

subtest 'a test that ignores the request to end is killed' => sub {
    my $deaf = script( 'deaf.t',
        qq{\$SIG{TERM} = 'IGNORE';\nopen my \$ready, '>', "\$0.ready" or die \$!;\nprint {\$ready} '1';\nclose \$ready or die \$!;\n$GATE}
    );
    my $clock = ManualClock->new(
        steps => [
            ManualClock::after_ready( "$deaf.ready", sub ( $clock, @ ) { $clock->move(3) } ),
            sub ( $clock, @ ) { $clock->move(0.5) }
        ]
    );
    is pooled( $clock, 1, [ task($deaf) ] )->{results}{$deaf}{signal}, 9, 'by force';
};

subtest 'a pipe that a process outside the group holds stops the pool for a second at most' => sub {
    my $held = script( 'held.t', <<'PERL' );
if ( !fork ) { setpgrp 0, 0; open my $out, '>', "$0.child"; print {$out} $$; close $out; sleep 30; exit 0 }
select undef, undef, undef, 0.01 until -s "$0.child";
print "1..1\nok 1\n";
PERL
    my $clock = ManualClock->new( steps => [ sub ( $clock, $seconds, @ ) { $seconds == 1 && $clock->move(1) } ] );
    is pooled( $clock, 1, [ task( $held, timeout => 20 ) ] )->{results}{$held}{passed}, 1, 'the test passes';
    open my $handle, '<', "$held.child" or die "open: $!";
    kill 'KILL', readline $handle;
};

subtest 'a signal ends the pool and the tests that still run' => sub {
    my $sleeping = script( 'interrupted.t', $GATE );
    my $clock    = ManualClock->new( steps => [ sub (@) { kill 'TERM', $$; return 1 } ] );
    my $error    = dies { pooled( $clock, 1, [ task($sleeping) ] ) };
    is $error && $error->can('signal') ? $error->signal : $error, 'TERM', 'under the name of the signal';
};

done_testing;
