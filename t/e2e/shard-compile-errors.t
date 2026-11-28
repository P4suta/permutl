use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use lib 't/e2e/lib';
use Fixture qw(run_fixture write_file);
use Test::Mutation::Merge;

my $area = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
my $root = "$area/project";
local $ENV{TEST_PROJECT_TABLE} = "$area/limit";
write_file( "$root/lib/Bound.pm", <<'MODULE' );
package Bound;
BEGIN {
    open my $input, '<', $ENV{TEST_PROJECT_TABLE} or die $!;
    close $input;
}
BEGIN { die "changed guard\n" if 3 - 1 != 2 }
sub value { return $_[0] + 1 }
1;
MODULE
write_file( "$root/t/value.t", "use Test::More tests => 1; use Bound; is Bound::value(6), 7;\n" );

sub measure ($shard) {
    my ($result) = run_fixture(
        $root,
        jobs    => 1,
        cache   => 0,
        disable => [qw(@removal condition-negation comparison-negation logical)],
        defined $shard ? ( shard => "$shard/2" ) : (),
    );
    return $result;
}

write_file( $ENV{TEST_PROJECT_TABLE}, "2\n" );
my $first = { name => 'first', result => measure(1) };
my $other = { name => 'other', result => measure(2) };
my $whole = measure(undef);
is [ map { $_->{status} } $whole->entries->@* ], [qw(CompileError Killed)],
  'the reference contains a rejected compilation and a detected change';
my $merged;
ok lives { $merged = Test::Mutation::Merge::merge( [ $other, $first ] ) },
  'a rejected mutant with known compiler inputs can merge';
is [ map { [ $_->{mutant}->id, $_->{status}, $_->{reason} ] } $merged->entries->@* ],
  [ map { [ $_->{mutant}->id, $_->{status}, $_->{reason} ] } $whole->entries->@* ],
  'both measurements attribute the same outcomes'
  if $merged;
write_file( $ENV{TEST_PROJECT_TABLE}, "02\n" );
$other->{result} = measure(2);
like dies { Test::Mutation::Merge::merge( [ $first, $other ] ) }, qr/measurement inputs differ/,
  'even equivalent file contents must match the measured compiler inputs';

done_testing;
