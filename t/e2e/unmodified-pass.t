use v5.36;
use Test2::V0;
use lib 't/e2e/lib';
use Config;
use Cwd        ();
use File::Temp ();
use Fixture    qw(ran_from write_file run_fixture);
use Test::Mutation;
use Test::Mutation::Launch;
use Test::Mutation::Runner;

my $root  = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
my %files = (
    'lib/Calc.pm' => "package Calc;\nsub add { return \$_[0] + \$_[1] }\nsub scale { return \$_[0] * \$_[1] }\n1;\n",
    't/calc.t'    => <<'TEST',
use Test::More tests => 2;
use Calc;
mkdir 'once' or die "setup has already run\n";
is Calc::add(5, 0), 5, 'adding zero';
is Calc::scale(5, 2), 10, 'multiplication';
TEST
);
write_file( "$root/$_", $files{$_} ) for keys %files;
my $list       = Test::Mutation::mutants( root => $root );
my ($add)      = grep { $_->description eq 'replaced + with -' } $list->@*;
my ($multiply) = grep { $_->description eq 'replaced * with /' } $list->@*;
ok $add && $multiply, 'both behavioral changes occur in the example';
my ($result) = run_fixture( $root, jobs => 1, equivalence => 0, mutant => [ $add->id, $multiply->id ] );
my %status = map { $_->{mutant}->id => $_->{status} } $result->entries->@*;
is $status{ $add->id },      'Survived', 'a second setup failure cannot turn adding zero into a detection';
is $status{ $multiply->id }, 'Killed',   'the same test can still detect an observable arithmetic change';
ok !-e "$root/once", 'test setup stays in the job workspace';
my ($all) = run_fixture( $root, jobs => 1, equivalence => 0 );
cmp_ok $all->stats->{copies}, '<=', 1 + scalar $all->entries->@*,
  'mutants of a test with one-time setup share the verified starting tree';

my ($in_place) = run_fixture( $root, jobs => 1, equivalence => 0, in_place => 1 );
ok grep( { /in-place.*hook/ } $in_place->warnings->@* ), 'the in-place run names its observation limit';
ok !-e "$root/once",                                     'the in-place run restores the test setup before returning';
my %inside = map { $_->{mutant}->id => $_->{status} } $in_place->entries->@*;
is $inside{ $add->id },      'Survived', 'repeating setup in the project does not detect an equivalent result';
is $inside{ $multiply->id }, 'Killed',   'a test with one-time setup can detect multiplication in the project';
subtest 'an in-place test has the state that earlier original tests prepared' => sub {
    my $ordered = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    write_file( "$ordered/lib/Calc.pm", $files{'lib/Calc.pm'} );
    write_file( "$ordered/t/a.t",       "use Test::More tests => 1;\nok mkdir('prepared'), 'prepare once';\n" );
    write_file( "$ordered/t/b.t",       <<'TEST' );
use Test::More tests => 2;
use Calc;
ok -d 'prepared', 'the earlier test ran';
is Calc::add(5, 0), 5, 'adding zero';
TEST
    my ($report) = run_fixture( $ordered, jobs => 1, in_place => 1, equivalence => 0, mutant => [ $add->id ] );
    is $report->entries->[0]{status}, 'Survived', 'replaying prerequisites preserves the actual change in behavior';
    ok !-e "$ordered/prepared", 'the original project returns to its state before the baseline';
};

subtest 'a test can detect the bytes of a target before it loads the module' => sub {
    my $reader  = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my $outside = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    write_file( "$reader/lib/Calc.pm", $files{'lib/Calc.pm'} );
    write_file( "$reader/t/read.t",    <<'TEST' );
use Test::More tests => 1;
open my $file, '<', 'lib/Calc.pm' or die $!;
my $bytes = do { local $/; <$file> };
close $file or die $!;
if ( index($bytes, ' + ') < 0 ) {
    ok $ENV{REPEAT_MARK} && !mkdir($ENV{REPEAT_MARK}), 'the changed source';
    exit;
}
require Calc;
is Calc::add(5, 0), 5, 'the original source';
TEST
    my $measure = sub {
        my ($report) = run_fixture( $reader, jobs => 1, equivalence => 0, mutant => [ $add->id ] );
        return $report->entries->[0];
    };
    local $ENV{REPEAT_MARK} = undef;
    is $measure->()->{status}, 'Killed', 'the source read detects the same change twice';
    local $ENV{REPEAT_MARK} = "$outside/first-reading";
    my $unstable = $measure->();
    is [ $unstable->@{qw(status reason)} ], [ 'NoVerdict', 'unstable-test' ],
      'one failing read followed by a passing read leaves the test inconclusive';
};

subtest 'the test can require a plain Perl library search path' => sub {
    my $plain = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    delete local $ENV{PERL5OPT};
    write_file( "$plain/lib/Calc.pm", $files{'lib/Calc.pm'} );
    write_file( "$plain/t/search.t",  <<'TEST' );
use Test::More tests => 2;
use Calc;
ok !grep( { ref } @INC ), 'a plain search path';
is Calc::scale(3, 2), 6, 'multiplication';
TEST
    my ($report) = run_fixture( $plain, jobs => 1, mutant => [ $multiply->id ], equivalence => 0 );
    is $report->baseline_failures,    [],       'the original test works with the normal Perl search path';
    is $report->entries->[0]{status}, 'Killed', 'the disk copy changes the result of multiplication';
};

subtest 'disk fallback preserves a lookup hook installed by the caller' => sub {
    my $project = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    write_file( "$project/lib/Calc.pm",            $files{'lib/Calc.pm'} );
    write_file( "$project/caller/CallerLoader.pm", <<'MODULE' );
package CallerLoader;
our $saw_calc;
sub observe { $saw_calc = 1 if $_[1] eq 'Calc.pm'; return }
sub import { unshift @INC, \&observe }
1;
MODULE
    write_file( "$project/t/search.t", <<'TEST' );
use Test::More tests => 3;
use Calc;
is_deeply [grep { ref } @INC], [\&CallerLoader::observe], 'the caller supplies the only hook';
ok $CallerLoader::saw_calc, 'the caller observed the module lookup';
is Calc::scale(3, 2), 6, 'multiplication';
TEST
    local $ENV{PERL5LIB} = join $Config{path_sep}, "$project/caller", grep { defined && length } $ENV{PERL5LIB};
    local $ENV{PERL5OPT} = '-MCallerLoader';
    my ($report) = run_fixture( $project, jobs => 1, mutant => [ $multiply->id ], equivalence => 0 );
    is $report->baseline_failures,    [],       'the original test uses the caller hook on disk';
    is $report->entries->[0]{status}, 'Killed', 'the disk mutation remains detectable with the caller hook';
};

subtest 'a directory round trip cannot give coverage to an unused source' => sub {
    my $project = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    write_file( "$project/lib/Resident.pm",       "package Resident;\nsub value { return \$_[0] + 17 }\n1;\n" );
    write_file( "$project/other/lib/Resident.pm", "package Resident;\nsub value { return \$_[0] + 29 }\n1;\n" );
    write_file( "$project/t/resident.t",          <<'TEST' );
use Test::More tests => 2;
BEGIN { @INC = grep { !ref } @INC }
unshift @INC, 'lib';
my $other = $ENV{LOAD_OTHER_RESIDENT};
chdir 'other' or die "enter other directory: $!" if $other;
require Resident;
is Resident::value(1), $other ? 30 : 18, 'the selected implementation ran';
is $INC{'Resident.pm'}, 'lib/Resident.pm', 'Perl registered a relative file';
chdir '..' or die "return to the starting directory: $!" if $other;
TEST
    my @selection = ( root => $project, source => ['lib/Resident.pm'] );
    my ($mutant) = grep { $_->description eq 'replaced + with -' } Test::Mutation::mutants(@selection)->@*;
    ok $mutant, 'the tracked implementation has an arithmetic mutant';
    for my $other ( 0, 1 ) {
        local $ENV{LOAD_OTHER_RESIDENT} = $other;
        my ($report) = run_fixture(
            $project,
            jobs        => 1,
            cache       => 0,
            equivalence => 0,
            source      => ['lib/Resident.pm'],
            mutant      => [ $mutant->id ]
        );
        is $report->baseline_failures, [], 'the ordinary run loads the selected module successfully';
        is $report->entries->[0]{status}, $other ? 'NoCoverage' : 'Killed',
          'only the test that loaded the tracked arithmetic can detect its mutant';
    }
};

subtest 'a fixture CLI receives the outer mutation and its child keeps the caller preload' => sub {
    my $area       = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my $generation = 1 + ( $ENV{TEST_MUTATION_GENERATION} || 0 );
    my $module     = "Test/Mutation/Shim/G$generation.pm";
    my $shim       = "$area/outer shim";
    write_file( "$shim/$module", Test::Mutation::Runner::shim_text($generation) );
    my $driver = <<'PERL';
package Test::Mutation::CLI;
sub main {
    print "original driver\n";
    my $child = 'print $CallerPreload::loaded ? "caller " : "missing "; print exists $INC{$ARGV[0]} ? "shim\n" : "plain\n"';
    system {$^X} $^X, '-e', $child, @_ and die 'child failed';
    return 0;
}
1;
PERL
    my $original = write_file( "$area/driver/Test/Mutation/CLI.pm", $driver );
    my $changed  = write_file( "$area/changed",                     $driver =~ s/original driver/changed driver/r );
    my $spec     = write_file( "$area/spec",                        "target\t$original\t$changed\n" );
    write_file( "$area/caller/CallerPreload.pm", "package CallerPreload; our \$loaded = 1; 1;\n" );
    mkdir "$area/records" or die $!;
    my $launch = Test::Mutation::Launch::test_command(
        perl    => $^X,
        root    => $area,
        program => 'driver',
        tmp     => $area,
        lib     => [],
        switch  => [],
        env     => {
            PERL5LIB => join( $Config{path_sep}, "$area/caller",                     grep { defined } $ENV{PERL5LIB} ),
            PERL5OPT => join( q{ },              grep( { defined } $ENV{PERL5OPT} ), '-MCallerPreload' )
        },
        shim => { generation => $generation, directory => $shim, spec => $spec, record => "$area/records" },
    );
    local @INC = ( $shim, @INC );
    require $module;
    local %ENV = ( %ENV, $launch->{env}->%* );
    my $run = ran_from( "$area/driver", 0, $area, $module );
    is $run->{stdout}, "changed driver\ncaller plain\n", 'the application inherits only its caller preload';
};
done_testing;
