use v5.36;
use Test2::V0;
use File::Temp ();
use lib 't/e2e/lib';
use Fixture qw(ran write_file);
use Test::Mutation::Report::Json;
use Test::Mutation::Source;
use Test::Mutation ();

my $project = File::Temp::tempdir( CLEANUP => 1 );
write_file( "$project/lib/Totals.pm", "package Totals;\nsub sum { return \$_[0] + \$_[1] }\n1;\n" );
write_file( "$project/t/sum.t",       "use Test::More tests => 1;\nuse Totals;\nis Totals::sum(4, 0), 4;\n" );
my @options = ( '--format', 'terminal', '--jobs', 1 );

my $initial = ran( 2, $project, 'run', '--undetected', @options );
like $initial->{stderr}, qr/no completed measurement.*mutation run/,
  'the first use explains how to collect a measurement';
unlike $initial->{stderr},                           qr/Baseline \(/,  'requesting missing history launches no tests';
like ran( 0, $project, 'help', 'run' )->{stdout},    qr/--undetected/, 'run help describes the selection';
unlike ran( 0, $project, 'help', 'list' )->{stdout}, qr/--undetected/, 'the recheck belongs to run';

my $ordinary = ran( 0, $project, 'run', @options );
my ($id) = $ordinary->{stdout} =~ /^  ([a-f0-9]+)  .*?\[Survived\]/m;
ok defined $id, 'the original test misses the arithmetic change';
my $api = Test::Mutation::run( root => $project, jobs => 1, undetected => 1, min_score => 100 );
is $api->assessment->{exitCode}, 1, 'the missed change fails the requested threshold in the API';
is [ map { [ $_->{mutant}->id, $_->{status} ] } $api->entries->@* ], [ [ $id, 'Survived' ] ],
  'the Perl API measures the same remaining gap';
write_file( "$project/t/positive.t", "use Test::More tests => 1;\nuse Totals;\nis Totals::sum(4, 1), 5;\n" );
my $recheck = ran( 0, $project, 'run', '--undetected', @options, '--format', 'json', '--min-score', 100 );
like $recheck->{stdout}, qr/^Scope: previously undetected mutants\nUndetected: 0$/m,
  'the terminal report identifies the rechecked mutants and shows that the gap closed';
my $result =
  Test::Mutation::Report::Json::parse( Test::Mutation::Source::read_bytes("$project/mutation-report/mutation.json") );
is [ map { [ $_->{mutant}->id, $_->{status}, $_->{by}, $_->{tests_run} ] } $result->entries->@* ],
  [ [ $id, 'Killed', 't/positive.t', 2 ] ], 'only the saved gap runs and the new test confirms it twice';
is $result->assessment->{gate}, 'passed', 'the CLI stores the same gate that accepted the repaired test';
ok $result->selection->{undetected}, 'the report identifies a recheck of undetected mutants';
my $empty = ran( 0, $project, 'run', '--undetected', @options, '--min-score', 100 );
like $empty->{stdout},   qr/^0 mutants$/m, 'a repaired scope has zero mutants';
unlike $empty->{stderr}, qr/Baseline \(/,  'an empty recheck skips the test processes';

unlink "$project/t/positive.t" or die $!;
ran( 0, $project, 'run', @options );
write_file( "$project/lib/Totals.pm", "package Totals;\nsub sum { return 4 }\n1;\n" );
my $stale = ran( 2, $project, 'run', '--undetected', @options );
like $stale->{stderr}, qr/\Q$id\E.*mutation run lib\/Totals\.pm/,
  'a missing historical mutant names the file to measure';
unlike $stale->{stderr}, qr/Baseline \(/, 'a stale identifier is diagnosed before testing';

subtest 'the latest merged scope supplies uncovered changes to the recheck' => sub {
    my $root = File::Temp::tempdir( CLEANUP => 1 );
    for my $name (qw(Sum Unused)) {
        write_file( "$root/lib/$name.pm", "package $name;\nsub add { return \$_[0] + \$_[1] }\n1;\n" );
    }
    write_file( "$root/t/original.t", "use Test::More tests => 1;\npass 'original test';\n" );
    my $archive = File::Temp::tempdir( CLEANUP => 1 );
    my ( @reports, %when );
    for my $part ( 1, 2 ) {
        my $directory = "$archive/part$part";
        ran(
            0,            $root,          'run',      'lib/Sum.pm', '--shard', "$part/2",
            '--no-cache', '--report-dir', $directory, '--format',   'json'
        );
        my $path        = "$directory/mutation.json";
        my $part_result = Test::Mutation::Report::Json::parse( Test::Mutation::Source::read_bytes($path) );
        my $dated       = Test::Mutation::Result->new( $part_result->%*, started => 0, finished => 10 * $part );
        write_file( $path, Test::Mutation::Report::Json::render( $dated, high => 80, low => 60 ) );
        push @reports, $path;
        $when{ $dated->entries->[0]{mutant}->id } = sprintf '1970-01-01T00:00:%02dZ', 10 * $part;
    }
    ran( 0, $root, 'run', 'lib/Unused.pm', @options );
    ran( 0, $root, 'merge', reverse(@reports), '--format', 'json' );
    for my $id ( sort keys %when ) {
        like ran( 0, $root, 'show', $id )->{stdout}, qr/^Measured at: \Q$when{$id}\E$/m,
          'the merged history shows the original measurement date for each shard';
    }
    my $file      = "$root/mutation-report/mutation.json";
    my $read      = sub { Test::Mutation::Report::Json::parse( Test::Mutation::Source::read_bytes($file) ) };
    my @uncovered = map { $_->{mutant}->id } grep { $_->{status} eq 'NoCoverage' } $read->()->entries->@*;
    ok @uncovered, 'the merged scope has uncovered changes';
    write_file( "$root/t/new.t", "use Test::More tests => 1;\nuse Sum;\nis Sum::add(4, 1), 5;\n" );
    ran( 0, $root, 'run', '--undetected', '--min-score', 100, '--format', 'json' );
    my $checked = $read->();
    is [ map { $_->{mutant}->id } $checked->entries->@* ], \@uncovered, 'the merge replaces the preceding file scope';

    for my $entry ( $checked->entries->@* ) {
        is [ $entry->{mutant}->path, $entry->@{qw(status by tests_run)} ],
          [ 'lib/Sum.pm', 'Killed', 't/new.t', 2 ], 'the new covering test detects the change twice';
    }

    ran( 0, $root, 'merge', @reports, '--format', 'json' );
    like ran( 0, $root, 'show', $uncovered[0] )->{stdout}, qr/^Last result: Killed$/m,
      'inspection keeps the newer detection after the same shards are merged again';
    my $remaining = ran( 0, $root, 'run', '--undetected', @options );
    like $remaining->{stdout},   qr/^0 mutants$/m, 'merging older observations leaves the repaired gaps closed';
    unlike $remaining->{stderr}, qr/Baseline \(/,  'closed gaps start no tests after a repeated merge';
};

done_testing;
