use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use TOML::Tiny ();
use lib 't/lib', 't/e2e/lib';
use Fixture qw(write_file);
use Gate;
use Test::Mutation::Source ();

my $scratch = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
my $project = "$scratch/project";
my $log     = "$scratch/events";
my $runner  = Cwd::abs_path('xt/bin') . '/record-release-check';

sub tool ( $name, $source ) {
    my $path = write_file( "$scratch/bin/$name", "#!/bin/sh\nset -eu\n$source" );
    chmod oct '755', $path or die "make $path executable: $!";
    return;
}

tool( 'gh', <<'SH' );
case "$1" in
    repo) printf '%s\n' 'fixture/distribution' ;;
    api) printf 'github %s\n' "$*" >> "$CHECK_LOG" ;;
    *) exit 2 ;;
esac
SH
tool( 'mise', <<'SH' );
case "$*" in
    'run check'|'run check-ci-interpreters')
        printf '%s\n' "$*" >> "$CHECK_LOG"
        if [ "${EDIT_AFTER:-}" = "$*" ]; then printf 'changed\n' >> source; fi
        if [ "${COMMIT_AFTER:-}" = "$*" ]; then
            git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name=Fixture \
                -c user.email=check@example.invalid commit --quiet --allow-empty -m 'Another commit'
        fi
        exit "${GATE_EXIT:-0}" ;;
    'run release-gate')
        printf 'run %s\n' "$(git rev-parse HEAD)" >> "$CHECK_LOG"
        if [ -n "${CHANGE_FILE:-}" ]; then printf 'changed\n' >> source; fi
        exit "${GATE_EXIT:-0}" ;;
    *) exit 2 ;;
esac
SH

write_file( "$project/source", "tracked\n" );
my @git = (
    'git',                      '-C', $project,               '-c',
    'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false', '-c',
    'user.name=Release check',  '-c', 'user.email=check@example.invalid'
);
system( @git, 'init', '-q' ) == 0     or die 'initialize the fixture';
system( @git, 'add',  'source' ) == 0 or die 'stage the source';
system( @git, 'commit', '-qm', 'source' ) == 0 or die 'commit the source';
open my $head, q{-|}, @git, 'rev-parse', 'HEAD' or die 'read the fixture commit';
chomp( my $commit = readline $head );
close $head or die 'resolve the fixture commit';

sub run_in_project (@command) {
    write_file( $log, q{} );
    my $previous = Cwd::getcwd();
    chdir $project or die "enter $project: $!";
    local $ENV{PATH}      = "$scratch/bin:$ENV{PATH}";
    local $ENV{CHECK_LOG} = $log;
    my $status = system(@command);
    chdir $previous or die "return to $previous: $!";
    return [ $status >> 8, Test::Mutation::Source::read_bytes($log) ];
}

sub record () { return run_in_project( 'sh', $runner ) }

my ( $status, $events ) = record()->@*;
is $status, 0, 'the checked release can record success';
my @events = split /\n/, $events;
is scalar @events, 3, 'one gate runs between two status updates';
Gate::checked( 'commit status updates', scalar( grep { /\Agithub / } @events ), at_least => 2 );
like $events[0], qr{repos/fixture/distribution/statuses/$commit\b.*state=pending\b.*context=release/local\b},
  'the pending status identifies the checked commit';
is $events[1], "run $commit", 'the full local release gate checks that commit';
like $events[2], qr{repos/fixture/distribution/statuses/$commit\b.*state=success\b.*context=release/local\b},
  'success follows the completed gate';

subtest 'the recording command rejects a failed release gate' => sub {
    local $ENV{GATE_EXIT} = 19;
    my $failed = record();
    isnt $failed->[0], 0, 'a failed gate fails the command';
    like $failed->[1],   qr/state=failure\b/, 'a failure supersedes any earlier success';
    unlike $failed->[1], qr/state=success\b/, 'a failed gate cannot record success';
};
subtest 'the pre-push gate checks the same clean commit on every interpreter' => sub {
    my $task    = TOML::Tiny::from_toml( Test::Mutation::Source::read_bytes('mise.toml') )->{tasks}{'check-ci'}{run};
    my $program = ref $task eq 'ARRAY' ? join( "\n", @$task ) : $task;
    my $check   = sub { return run_in_project( 'sh', '-ec', $program ) };
    is $check->(), [ 0, "run check\nrun check-ci-interpreters\n" ], 'the clean commit receives both checks';
    my $untracked = write_file( "$project/local-only.t", "uncommitted test\n" );
    my $dirty     = $check->();
    isnt $dirty->[0], 0,   'an uncommitted test fails the pre-push check';
    is $dirty->[1],   q{}, 'the mismatched checkout starts no expensive checks';
    unlink $untracked or die "remove the temporary test: $!";

    for my $stage ( 'run check', 'run check-ci-interpreters' ) {
        local $ENV{EDIT_AFTER} = $stage;
        my $changed = $check->();
        isnt $changed->[0], 0, "an edit during $stage invalidates the result";
        is $changed->[1], "run check\n", 'a change during fast checks stops the remaining work'
          if $stage eq 'run check';
        write_file( "$project/source", "tracked\n" );
    }
    local $ENV{COMMIT_AFTER} = 'run check-ci-interpreters';
    isnt $check->()->[0], 0, 'a different clean commit cannot inherit the local result';
};
{
    local $ENV{CHANGE_FILE} = 1;
    my $changed = record();
    isnt $changed->[0], 0, 'a source edit during measurement fails the command';
    like $changed->[1], qr/state=failure\b/, 'changed sources invalidate the measurement';
}
my $dirty = record();
isnt $dirty->[0], 0,   'a dirty checkout is refused before testing';
is $dirty->[1],   q{}, 'a dirty checkout starts no gate and changes no status';
subtest 'the local release tasks run a cold measurement with optional reports' => sub {
    my $config = TOML::Tiny::from_toml( Test::Mutation::Source::read_bytes('mise.toml') );
    my $tasks  = $config->{tasks};
    is $tasks->{'record-release-check'}{run}, 'sh xt/bin/record-release-check',
      'the recording task executes the checked release script';
    my @steps = $tasks->{'mutation-gate'}{run}->@*;
    is [ @steps[ 1, 2 ] ], [ 'prove -l xt/release', 'mise run discover-mutants' ],
      'the local gate verifies the completed inventory and the installed corpus';
    tool( 'perl', <<'SH' );
test -z "${TEST_MUTATION_DETECTOR_DIR+x}"
printf '%s\n' "$@" > "$CHECK_LOG"
SH
    my $directory = "$scratch/prior reports";
    write_file( "$directory/one.json",      q{} );
    write_file( "$directory/two days.json", q{} );
    local $ENV{PATH}                       = "$scratch/bin:$ENV{PATH}";
    local $ENV{CHECK_LOG}                  = $log;
    local $ENV{TEST_MUTATION_DETECTOR_DIR} = $directory;
    is system( 'sh', '-ec', $steps[0] ), 0, 'the scheduling input stays outside the measured environment';
    is Test::Mutation::Source::read_bytes($log),
      "xt/bin/confirm-self-measurement\n$directory/one.json\n$directory/two days.json\n",
      'the measurement receives both filenames as separate arguments';
    delete $ENV{TEST_MUTATION_DETECTOR_DIR};
    is system( 'sh', '-ec', $steps[0] ), 0, 'the full measurement can run on a fresh machine';
    is Test::Mutation::Source::read_bytes($log), "xt/bin/confirm-self-measurement\n",
      'a fresh machine supplies no reports';
};
done_testing;
