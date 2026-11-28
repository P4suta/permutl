use v5.36;
use Test2::V0;
use File::Temp ();
use lib 't/e2e/lib';
use Fixture qw(write_file run_fixture);
use Test::Mutation::Source;

subtest 'a child with a relative include path reports only the statements it executes' => sub {
    my $root = File::Temp::tempdir( CLEANUP => 1 );
    write_file( "$root/lib/Loaded.pm", <<'MODULE' );
package Loaded;
use strict;
use warnings;
sub reached { my ($x, $y) = @_; return $x + $y }
sub unused { my ($x, $y) = @_; return $x * $y }
1;
MODULE
    write_file( "$root/t/child.t", <<'TEST' );
use Test::More tests => 1;
delete $ENV{PERL5LIB};
my $status = system $^X, '-Ilib', '-MLoaded', '-e', 'exit(Loaded::reached(2, 3) == 5 ? 0 : 1)';
is $status, 0, 'the child calls the addition in the project module';
TEST
    my ($report) = run_fixture( $root, cache => 0, jobs => 2, equivalence => 0 );
    is $report->baseline_failures, [], 'the unmodified child exits successfully';
    my %arithmetic = map { $_->{mutant}->original => [ $_->@{qw(status covered_by)} ] }
      grep { $_->{mutant}->mutator eq 'arithmetic' } $report->entries->@*;
    is \%arithmetic, { '+' => [ 'Killed', ['t/child.t'] ], '*' => [ 'NoCoverage', [] ] },
      'loading the module on the command line observes the addition and leaves the multiplication uncovered';
};

subtest 'children with an empty environment still identify the test that loaded the file' => sub {
    my $root = File::Temp::tempdir( CLEANUP => 1 );
    write_file( "$root/lib/Loaded.pm",
        "package Loaded;\nsub value { return \$_[0] + 1 }\nsub unused { return \$_[0] * 2 }\n1;\n" );
    write_file( "$root/t/a.t", <<'PERL' );
use Test::More tests => 1;
%ENV = ();
my $status = system $^X, '-T', '-Ilib', '-e', 'require Loaded; exit(Loaded::value(3) == 4 ? 0 : 1)';
is $status, 0, 'the child computes four';
PERL
    write_file( "$root/t/b.t", "use Test::More tests => 1;\n%ENV = ();\nok 1, 'another test';\n" );
    my ($report) = run_fixture( $root, jobs => 2, equivalence => 0 );
    is $report->baseline_failures, [], 'the unmodified children pass';
    my ($entry) = grep { $_->{mutant}->description eq 'replaced + with -' } $report->entries->@*;
    is $entry->{status},     'Killed',  'the tainted child receives the code change';
    is $entry->{by},         't/a.t',   'only the test that launched the child detects the change';
    is $entry->{covered_by}, ['t/a.t'], 'the other process owns a separate observation';
    my ($inside) = run_fixture( $root, jobs => 2, equivalence => 0, in_place => 1 );
    my ($blind)  = grep { $_->{mutant}->id eq $entry->{mutant}->id } $inside->entries->@*;
    is [ $blind->@{qw(status reason covered_by)} ], [ 'NoVerdict', 'loaded-around-hook', ['t/a.t'] ],
      'a child that compiled the target without the project hook has an attributed observation limit';
    my ($idle) = grep { $_->{mutant}->description eq 'replaced * with /' } $report->entries->@*;
    is [ $idle->@{qw(status covered_by)} ], [ 'NoCoverage', [] ], 'the child never reaches the multiplication';
};
subtest 'the load path and string evaluation retain statement coverage' => sub {
    my $root = File::Temp::tempdir( CLEANUP => 1 );
    write_file( "$root/lib/Loaded.pm",
        "package Loaded;\nsub value { return \$_[0] + 1 }\nsub unused { return \$_[0] * 2 }\n1;\n" );
    my %load = (
        absolute => q{use Cwd (); require( Cwd::getcwd() . '/lib/Loaded.pm' );},
        do_file  => q{do './lib/Loaded.pm' or die $@;},
        evaluate =>
          q{open my $in, '<', 'lib/Loaded.pm' or die $!; my $bytes = do { local $/; <$in> }; close $in; eval $bytes or die $@;},
    );
    write_file( "$root/t/$_.t", "use Test::More tests => 1;\n$load{$_}\nis Loaded::value(2), 3;\n" ) for keys %load;
    my ($report) = run_fixture( $root, jobs => 2, equivalence => 0 );
    is $report->baseline_failures, [], 'all three ways to load the original work';
    my ($addition) = grep { $_->{mutant}->description eq 'replaced + with -' } $report->entries->@*;
    my ($unused)   = grep { $_->{mutant}->description eq 'replaced * with /' } $report->entries->@*;
    is $addition->{covered_by}, [ map { "t/$_.t" } sort keys %load ], 'each style executes the addition';
    is [ $unused->@{qw(status covered_by)} ], [ 'NoCoverage', [] ],
      'loading the module does not execute the unused multiplication';
};
subtest 'a byte-for-byte source check can detect a mutant on an unexecuted line' => sub {
    my $root   = File::Temp::tempdir( CLEANUP => 1 );
    my $module = "package Loaded;\nsub unused { return \$_[0] + 1 }\n1;\n";
    write_file( "$root/lib/Loaded.pm", $module );
    write_file( "$root/reference",     $module );
    write_file( "$root/t/check.t",     <<'TEST' );
use Test::More tests => 1;
sub bytes {
    open my $input, '<:raw', shift or die $!;
    local $/;
    return scalar <$input>;
}
is bytes('lib/Loaded.pm'), bytes('reference'), 'the published source bytes';
TEST
    my ($report) = run_fixture( $root, jobs => 1, equivalence => 0 );
    is $report->baseline_failures, [], 'the original bytes pass the check';
    my ($entry) = grep { $_->{mutant}->description eq 'replaced + with -' } $report->entries->@*;
    is [ $entry->@{qw(status by)} ], [ 'Killed', 't/check.t' ],
      'the source comparison detects a change that never executes';
    is Test::Mutation::Source::read_bytes("$root/lib/Loaded.pm"), $module,
      'the source in the working directory still matches';
};
subtest 'a quoted project path preserves the source filename and line coverage' => sub {
    my $root = File::Temp::tempdir( CLEANUP => 1 ) . q{/build'path"};
    write_file( "$root/lib/Loaded.pm",
        "package Loaded;\nsub value { return \$_[0] + 1 }\nsub unused { return \$_[0] * 2 }\nsub location { return (__FILE__, __LINE__) }\n1;\n"
    );
    write_file( "$root/t/path.t", <<'TEST' );
use Cwd ();
use Test::More tests => 2;
use lib Cwd::abs_path('lib');
use Loaded;
is_deeply [Loaded::location()], [Cwd::abs_path('lib/Loaded.pm'), 4], 'the compiler preserves the quoted filename and line number';
is Loaded::value(2), 3, 'the calculation runs';
TEST
    my ($report) = run_fixture( $root, jobs => 1, equivalence => 0 );
    is $report->baseline_failures, [], 'the quoted unmodified project passes';
    my ($unused) = grep { $_->{mutant}->description eq 'replaced * with /' } $report->entries->@*;
    is [ $unused->@{qw(status covered_by)} ], [ 'NoCoverage', [] ],
      'a file with quotes in its path keeps line coverage';
};
done_testing;
