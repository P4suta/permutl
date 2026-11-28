use v5.36;
use Test2::V0;
use lib 't/lib';
use Raised;
use lib 't/e2e/lib';
use Cwd        ();
use File::Temp ();
use Fixture    qw(copy_of ran_from with_driver_shims write_file);
use Test::Mutation;
use Test::Mutation::Report::Json;
use Test::Mutation::Runner;

my $root = copy_of('calc');

# The listing comes first: a call that takes another project than the named one fails here within a moment.
subtest 'mutants lists the mutants without running a test' => sub {
    my $mutants = Test::Mutation::mutants( root => $root, disable => ['sub-body'] );
    is scalar( $mutants->@* ), 17, 'the mutants of the enabled mutators';
    isa_ok $mutants->[0], ['Test::Mutation::Mutant'], 'each element';
};

subtest 'run measures a project and returns the result' => sub {
    my ( @events, @phases );
    my $result = Test::Mutation::run(
        root     => $root,
        jobs     => 2,
        on_event => sub ( $event, $data ) {
            push @events, $event;
            push @phases, $data->{name} if $event eq 'phase';
        }
    );
    isa_ok $result, ['Test::Mutation::Result'], 'the result';
    is $result->tally->{counts}{Killed}, 15, 'the killed mutants';
    is \@phases, [qw(resolve analyze plan acquire build baseline mutants conclude release)],
      'each run phase arrives in order';
    is Test::Mutation::Runner::phases(), \@phases, 'the phase inventory matches the observed run';
    ok scalar grep( { $_ eq 'analyzed' } @events ), 'the listener receives the inventory as well';
};

subtest 'settings are checked' => sub {
    like dies { Test::Mutation::run( root => $root, jobs => 0 ) }, qr/jobs/, 'a value outside its type is refused';
    like Raised::error( sub { Test::Mutation::run( root => $root, speed => 'fast', hurry => 1 ) } ),
      [ 'usage', 'setting-unknown', qr/\Ahurry names no setting; the nearest is [a-z_]+\z/ ],
      'the first unknown setting in the order of the names is refused';
    is Raised::message( sub { Test::Mutation::run( root => $root, min_scor => 1 ) } ),
      'min_scor names no setting; the nearest is min_score', 'with the nearest name';
    like Raised::message( sub { Test::Mutation::run( root => $root, resolve => 1 ) } ),
      qr/\Aresolve names no setting/, 'a function of the settings is no setting';
};

subtest 'tests load a project module named Test::Mutation::CompilerInputs' => sub {
    my $project = File::Temp::tempdir( CLEANUP => 1 );
    write_file( "$project/lib/Test/Mutation/CompilerInputs.pm", <<'MODULE' );
package Test::Mutation::CompilerInputs;
sub positive { return $_[0] > 0 }
1;
MODULE
    write_file( "$project/t/positive.t", <<'TEST' );
use Test::More tests => 2;
use Test::Mutation::CompilerInputs ();
ok Test::Mutation::CompilerInputs::positive(1);
ok !Test::Mutation::CompilerInputs::positive(0);
TEST
    my $result = Test::Mutation::run( root => $project, jobs => 1, cache => 0 );
    is $result->baseline_failures, [], 'the unmodified test calls the project function';
    my @reversed = grep { $_->{mutant}->original eq '>' && $_->{mutant}->replacement eq '<=' } $result->entries->@*;
    is [ map { [ $_->{status}, $_->{by} ] } @reversed ], [ [ 'Killed', 't/positive.t' ] ],
      'the same test detects the reversed comparison';
};

subtest 'standalone compilation imports the project compiler inputs package' => sub {
    my $project = File::Temp::tempdir( CLEANUP => 1 );
    write_file( "$project/lib/Test/Mutation/CompilerInputs.pm", <<'MODULE' );
package Test::Mutation::CompilerInputs 0.100;
sub _record { 7 }
sub limit () { _record() }
1;
MODULE
    write_file( "$project/lib/Boundary.pm", <<'MODULE' );
package Boundary;
use Test::Mutation::CompilerInputs 0.100 ();
sub above { return $_[0] > Test::Mutation::CompilerInputs::limit() }
1;
MODULE
    write_file( "$project/t/pass.t", <<'TEST' );
use Test::More tests => 1;
use Test::Mutation::CompilerInputs 0.100 ();
is Test::Mutation::CompilerInputs::limit(), 7;
TEST
    my $result = with_driver_shims(
        sub { Test::Mutation::run( root => $project, source => ['lib/Boundary.pm'], jobs => 1, cache => 0 ) } );
    is $result->baseline_failures, [], 'the independent test calls the project function';
    is $result->warnings,          [], 'the original compiles with the required project module version';
    ok scalar( grep { defined $_->{compiled_digest} } $result->entries->@* ),
      'the compiler compares changes to the uncovered boundary';

    my $reports = File::Temp::tempdir( CLEANUP => 1 );
    local $ENV{PERL5LIB} = join q{:}, Cwd::abs_path('lib'), grep { defined } $ENV{PERL5LIB};
    my $run = ran_from(
        "$project/lib", 0,          $project, 'run',          '--no-cache', '--jobs',
        1,              '--format', 'json',   '--report-dir', $reports,     'lib/Boundary.pm'
    );
    if ( !$run->{exit} ) {
        my $saved = Test::Mutation::Report::Json::parse( Test::Mutation::Source::read_bytes("$reports/mutation.json") );
        ok scalar( grep { defined $_->{compiled_digest} } $saved->entries->@* ),
          'a project library ahead of the installed driver leaves its compiler observations available';
    }
};

subtest 'the working directory is the project when the call names no root' => sub {
    my $here = Cwd::getcwd();
    chdir $root or die "chdir: $!";
    my $mutants = eval { Test::Mutation::mutants( disable => ['sub-body'] ) };
    my $error   = $@;
    chdir $here or die "chdir: $!";
    is scalar( @{ $mutants || [] } ), 17, 'the mutants of the project in the working directory' or diag $error;
};

ok Test::Mutation->VERSION, 'the distribution has a version';

done_testing;
