use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use lib 't/e2e/lib';
use Fixture qw(run_fixture write_file);
use Test::Mutation::Report::Json;
use Test::Mutation::Runner;
use Test::Mutation::Settings;
use Test::Mutation::Store;

my $parent = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
my $root   = "$parent/project";
local $ENV{CHECK_CHANGED_VALUE} = "$parent/check";
write_file( "$root/lib/Value.pm", "package Value;\nsub plus { return \$_[0] + 1 }\n1;\n" );
write_file( "$root/t/value.t",    <<'PERL' );
use strict;
use warnings;
use Value;
use Test::More tests => 1;
my $value = Value::plus(2);
if (-e $ENV{CHECK_CHANGED_VALUE}) { is $value, 3, 'the sum' }
else { pass 'the sum is observed' }
PERL
write_file( "$root/t/conditional.t", <<'PERL' );
use Test::More tests => 1;
if (-e $ENV{CHECK_CHANGED_VALUE}) {
    require Value;
    is Value::plus(2), 3, 'the new branch uses the sum';
} else {
    pass 'the sum is unused';
}
PERL

my ($first) = run_fixture( $root, equivalence => 0 );
my ($warm)  = run_fixture( $root, equivalence => 0 );
my $count   = scalar $first->entries->@*;
is [ map { $_->{status} } $first->entries->@* ], [ ('Survived') x $count ], 'the original tests miss every change';
is $warm->reused,                                $count, 'the unchanged evaluation uses the stored verdicts';
is $warm->stats->{verifications},                3,      'three reusable verdicts were measured again';
write_file( $ENV{CHECK_CHANGED_VALUE}, "test the changed result\n" );
my ($changed) = run_fixture( $root, equivalence => 0 );
is $changed->reused, 0, 'an inconsistent sample discards all cached verdicts';
is [ map { $_->{status} } $changed->entries->@* ], [ ('Killed') x $count ],
  'every returned verdict comes from a fresh measurement';
is [ map { [ sort $_->{covered_by}->@* ] } $changed->entries->@* ],
  [ ( [qw(t/conditional.t t/value.t)] ) x $count ], 'every new job uses the coverage of the repeated baseline';
ok !$changed->conclusive, 'the mismatch prevents the run from passing its gate';
like $changed->warnings, bag { item match qr/cached verdict.*fresh measurement/; etc },
  'the report names the discrepancy';
my $restored =
  Test::Mutation::Report::Json::parse( Test::Mutation::Report::Json::render( $changed, high => 80, low => 60 ) );
ok !$restored->conclusive, 'the report preserves the failed cache check';

run_fixture( $root, equivalence => 0 );
my $cache_file = "$root/.mutation/measurement.sqlite";
my $saved      = Test::Mutation::Store::load($cache_file);
ok keys %$saved, 'the project holds measured verdicts before its source changes';
write_file( "$root/lib/Value.pm", "package Value;\n1;\n" );
unlink "$root/t/value.t"       or die "remove the test: $!";
unlink "$root/t/conditional.t" or die "remove the conditional test: $!";
for my $case (
    [ 'disabled caching',    0, {} ],
    [ 'a partial selection', 1, { paths         => { 'lib/Value.pm' => [] } } ],
    [ 'a baseline command',  1, { baseline_only => 1 } ]
  )
{
    my ( $label, $cache, $options ) = @$case;
    my $settings = Test::Mutation::Settings::of_call( { root => $root, cache => $cache } );
    my $run      = Test::Mutation::Runner::run( $settings, sub { return }, $options );
    is $run->entries,                            [],     "$label has no mutant to measure";
    is Test::Mutation::Store::load($cache_file), $saved, "$label preserves the preceding verdict inventory";
}
my ($empty) = run_fixture( $root, equivalence => 0 );
is $empty->entries, [], 'removing the last mutation produces an empty inventory';
is Test::Mutation::Store::load("$root/.mutation/measurement.sqlite"), {},
  'records of the last removed source are pruned';

subtest 'a warm copy checks the configuration bytes that the tests will read' => sub {
    my $project  = "$parent/config-input";
    my $settings = write_file( "$project/settings.toml", "# original\n" );
    write_file( "$project/lib/Value.pm", "package Value; sub plus { \$_[0] + 1 } 1;\n" );
    write_file( "$project/t/value.t",    <<'PERL' );
use Test::More tests => 2;
use Value;
open my $file, '<', 'settings.toml' or die $!;
is scalar readline $file, "# original\n", 'the expected input was copied';
close $file or die $!;
is Value::plus(2), 3, 'the sum';
PERL
    my %options  = ( root => $project, config => 'settings.toml', jobs => 1, equivalence => 0 );
    my $recorded = Test::Mutation::run(%options);
    is $recorded->baseline_failures, [], 'the original test passes with the recorded configuration bytes';
    my $error = dies {
        Test::Mutation::run(
            %options,
            on_event => sub ( $event, $data ) {
                write_file( $settings, "# changed\n" ) if $event eq 'phase' && $data->{name} eq 'acquire';
                return;
            }
        );
    };
    like $error, qr/measurement inputs changed/, 'a copy that no longer matches the saved original is rejected';
};

subtest 'an interrupted cache sample keeps only the verdicts it measured' => sub {
    my $project = "$parent/interrupted";
    write_file( "$project/lib/Totals.pm", <<'PERL' );
package Totals;
sub sum        { return $_[0] + $_[1] }
sub difference { return $_[0] - $_[1] }
1;
PERL
    local $ENV{SAMPLE_PROGRESS} = "$parent/observations";
    local $ENV{SAMPLE_DRIVER}   = $$;
    write_file( "$project/t/totals.t", <<'PERL' );
use strict;
use warnings;
use Test::More tests => 1;
use Totals;
my @values = ( Totals::sum(5, 2), Totals::difference(5, 2) );
my $record = $ENV{SAMPLE_PROGRESS};
if (-d $record && join(',', map { defined $_ ? $_ : 'undef' } @values) ne '7,3') {
    if (-e "$record/first") {
        die "unexpected parent\n" unless getppid == $ENV{SAMPLE_DRIVER};
        kill 'TERM', getppid or die "signal the measurement: $!";
    } else {
        open my $first, '>', "$record/first" or die "record the first observation: $!";
        close $first or die "close the observation: $!";
    }
}
is_deeply \@values, [7, 3], 'both arithmetic results';
PERL
    my %options = ( jobs => 1, equivalence => 0 );
    my ($cold)  = run_fixture( $project, %options );
    my @ids     = map { $_->{mutant}->id } $cold->entries->@*;
    cmp_ok scalar @ids, '>', 3, 'the inventory includes unsampled verdicts';
    is [ map { $_->{status} } $cold->entries->@* ], [ ('Killed') x @ids ], 'the cold run detected every change';
    mkdir $ENV{SAMPLE_PROGRESS} or die "enable the interrupt: $!";
    my ($partial) = run_fixture( $project, %options );
    is $partial->interrupted, 'TERM', 'the interrupt during the second sample reaches the result';
    is $partial->reused,      0,      'previous verdicts do not count as measured after an interrupt';
    is [ map { $_->{mutant}->id } $partial->entries->@* ], \@ids, 'the result keeps the complete ordered inventory';
    is [ sort map { $_->{status} } $partial->entries->@* ], [ 'Killed', ('Pending') x ( @ids - 1 ) ],
      'only the completed sample keeps its verdict';
    unlink "$ENV{SAMPLE_PROGRESS}/first" or die "remove the observation: $!";
    rmdir $ENV{SAMPLE_PROGRESS}          or die "disable the interrupt: $!";
    my ($resumed) = run_fixture( $project, %options );
    is $resumed->reused, scalar @ids, 'the interrupt preserves the previously completed cache';
    is [ map { $_->{status} } $resumed->entries->@* ], [ ('Killed') x @ids ], 'a new run verifies the cached results';
};

done_testing;
