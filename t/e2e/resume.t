use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use POSIX      ();
use lib 't/e2e/lib';
use Fixture qw(copy_of with_driver_shims write_file);
use Test::Mutation;
use Test::Mutation::Outcome;
use Test::Mutation::Merge;

sub measure (%options) {
    return with_driver_shims( sub { Test::Mutation::run(%options) } );
}

sub verdicts ($result) {
    return [ map { [ $_->{mutant}->id, $_->@{qw(status reason detail by covered_by)} ] } $result->entries->@* ];
}

for my $change ( 0, 1 ) {
    my $root = copy_of('equivalent');
    local $ENV{TMPDIR} = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my %options = ( root => $root, jobs => 1 );
    my $driver  = fork;
    die "fork: $!" unless defined $driver;
    if ( !$driver ) {
        measure(
            %options,
            on_event => sub ( $event, $data ) {
                POSIX::_exit(77) if $event eq 'mutant' && $data->{status} eq 'Killed';
            },
        );
        POSIX::_exit(78);
    }
    waitpid $driver, 0;
    is $? >> 8, 77, 'the driver exited at its first detected change without running cleanup';
    write_file( "$root/t/fold.t", "use Test::More tests => 1;\nuse Fold;\npass 'loaded';\n" ) if $change;
    my $resumed   = measure(%options);
    my $reference = measure( %options, jobs => 2, cache => 0 );
    is $resumed->reused,   $change ? 0 : 1,      'resume uses the completed observation only while its inputs match';
    is verdicts($resumed), verdicts($reference), 'the returned verdicts agree with a fresh parallel measurement';
    is $resumed->tally,    $reference->tally,    'the resumed measurement has the full score';
    is Test::Mutation::Outcome::of( $resumed, 70 )->{exit}->code,
      Test::Mutation::Outcome::of( $reference, 70 )->{exit}->code, 'the resumed threshold decision matches';
    is [ glob "$ENV{TMPDIR}/mutation-*" ], [], 'the next run reclaimed the abandoned workspace';
}

subtest 'interrupted and cached shards agree with a fresh whole measurement' => sub {
    my $root = copy_of('equivalent');
    local $ENV{TMPDIR} = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my %options   = ( root => $root, min_score => 70 );
    my $reference = measure( %options, jobs => 1, cache => 0 );
    my $child     = fork;
    die "fork: $!" unless defined $child;
    if ( !$child ) {
        measure(
            %options,
            jobs     => 2,
            shard    => '1/2',
            on_event => sub ( $event, $data ) {
                POSIX::_exit(77) if $event eq 'mutant' && $data->{status} eq 'Killed';
            }
        );
        POSIX::_exit(78);
    }
    waitpid $child, 0;
    is $? >> 8, 77, 'one shard stops after checkpointing a detection';
    my @parts = map { { name => "part$_", result => measure( %options, shard => "$_/2", jobs => 2 ) } } 1, 2;
    ok $parts[0]{result}->reused, 'the first shard resumes from its checkpoint';
    my $merged = Test::Mutation::Merge::merge( \@parts );
    my $warm   = measure( %options, jobs => 2 );
    ok $warm->reused, 'the whole measurement uses saved observations from both shards';

    for my $measured ( $merged, $warm ) {
        is verdicts($measured), verdicts($reference), 'each mutant has the reference verdict, reason and deciding test';
        is $measured->assessment, $reference->assessment, 'the counts, score and threshold exit code agree';
    }
};

done_testing;
