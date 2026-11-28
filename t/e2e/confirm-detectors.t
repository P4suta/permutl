use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use lib 't/e2e/lib';
use Fixture                      qw(ran with_driver_shims write_file);
use Test::Mutation::Report::Json ();
use Test::Mutation::Source       ();

my $scratch = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
my $project = "$scratch/project";
my $script  = Cwd::abs_path('xt/bin') . '/confirm-self-measurement';
my $report  = "$project/mutation-report/mutation.json";
my $last_log;

sub result () {
    return Test::Mutation::Report::Json::parse( Test::Mutation::Source::read_bytes($report) );
}

sub addition ($measurement) {
    my ($change) = grep { $_->{mutant}->mutator eq 'arithmetic' } $measurement->entries->@*;
    return $change;
}

sub confirm (@hints) {
    my $child = open my $output, q{-|};
    die "start the measurement: $!" unless defined $child;
    if ( !$child ) {
        chdir $project or die "enter $project: $!";
        open STDERR, '>&', \*STDOUT or die "capture the measurement diagnostic: $!";
        with_driver_shims(
            sub (@switches) { exec {$^X} $^X, @switches, $script, @hints or die "run the measurement: $!" } );
    }
    $last_log = do { local $/ = undef; readline $output };
    close $output;
    my $status = $?;
    die "the measurement ended on a signal: $status" if $status & 127;
    return $status >> 8;
}

write_file( "$project/mutation.toml", "jobs = 1\n" );
write_file( "$project/lib/Totals.pm",
    "package Totals;\nsub sum { my (\$left, \$right) = \@_; \$left + \$right }\n1;\n" );
my $miss = "use Test::More tests => 1;\nuse Totals;\nis Totals::sum(4, 0), 4;\n";
my $kill = "use Test::More tests => 1;\nuse Totals;\nis Totals::sum(4, 1), 5;\n";
write_file( "$project/t/a.t", $miss );
write_file( "$project/t/z.t", $kill );
ran( 0, $project, '--no-cache', '--format', 'json' );
my $original = result();
my $prior    = addition($original);
is [ $prior->@{qw(status by tests_run)} ], [ 'Killed', 't/z.t', 2 ], 'the original order tries both tests';
my $id   = $prior->{mutant}->id;
my $hint = write_file( "$scratch/earlier.json", Test::Mutation::Source::read_bytes($report) );
unlink $report or die "remove the previous report: $!";

is confirm($hint), 0, 'a current detection satisfies the release threshold';
ok -f $report, 'the release measurement publishes a fresh report' or bail_out('the measurement produced no report');
my $fresh = result();
is [ map { $_->{mutant}->id } $fresh->entries->@* ], [ map { $_->{mutant}->id } $original->entries->@* ],
  'the new measurement includes every original mutant';
my $observed = addition($fresh);
is [ $observed->{mutant}->id, $observed->@{qw(status by tests_run)} ],
  [ $id, 'Killed', 't/z.t', 1 ], 'only the suggested covering test needs to detect the mutant';
is $fresh->reused, 0,     'a prior report supplies no cached verdict';
is $fresh->shard,  undef, 'the release measurement covers the complete project';

my $path = "$project/lib/Totals.pm";
my $text = Test::Mutation::Source::read_bytes($path);
write_file( $path, "\n\n$text" );
is confirm($hint), 0, 'a source edit before the expression preserves the detection';
my $shifted = result();
my $moved   = addition($shifted);
isnt $moved->{mutant}->id, $id, 'moving the operator gives it another identifier';
is [ $moved->@{qw(status by tests_run)} ], [ 'Killed', 't/z.t', 1 ],
  'the same unique expression still tries its previous detector first';
is $shifted->reused, 0, 'the moved mutant was measured again';
ok !-d "$project/.mutation", 'suggesting a detector leaves the persistent cache absent';
write_file( "$project/t/z.t", $miss );
is confirm($hint),                 1,          'the gate fails when the earlier detector misses the moved expression';
is addition( result() )->{status}, 'Survived', 'only the current tests decide the moved mutant';
write_file( $path, $text );

is confirm($hint),                 1,          'an earlier detection fails the gate once both tests miss the change';
is addition( result() )->{status}, 'Survived', 'the new result records the missed change';

write_file( "$project/t/z.t", $kill );
is confirm(),                         0, 'the command also runs without a prior measurement';
is addition( result() )->{tests_run}, 2, 'without a suggestion the normal order visits both tests';

write_file( "$project/t/a.t", qq{print "1..1\\nnot ok 1 - broken original\\n";\n} );
is confirm($hint), 3, 'an original test failure blocks even a previously detected mutant';
is [ map { $_->{test} } result()->baseline_failures->@* ], ['t/a.t'], 'the failing original test appears in the report';
like $last_log, qr/^\s*t\/a\.t\s*$/m,                 'the terminal report identifies the failing original test';
like $last_log, qr/^\s*not ok 1 - broken original$/m, 'the terminal report retains the failing TAP assertion';
done_testing;
