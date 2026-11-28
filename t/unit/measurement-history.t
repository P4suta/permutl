use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use lib 't/lib';
use Capability;
use lib 't/contract/lib';
use Samples;
use Test::Mutation::Settings;
use Test::Mutation::Source;
use Test::Mutation::Store::History;
use Test::Mutation::Store::Key;

my $root   = File::Temp::tempdir( CLEANUP => 1 );
my $config = Test::Mutation::Settings::of_call( { root => $root, cache => 1 } );
my $whole  = Samples::result( statuses => [qw(Survived NoCoverage Killed)] );
is Test::Mutation::Store::History::undetected($config),        undef, 'a project has no completed measurement yet';
is Test::Mutation::Store::History::entries( $config, {}, [] ), undef, 'a new checkout has no indexed observations';
isa_ok dies { Test::Mutation::Store::History::entries( $config, {}, ['unresolved'] ) }, ['Error::TypeTiny'],
  'an indexed lookup accepts resolved mutants';
isa_ok dies { Test::Mutation::Store::History::undetected_scope( $config, [ { 'lib/A.pm' => [17] } ] ) },
  ['Error::TypeTiny'], 'a history filter requires pairs of line numbers';
Test::Mutation::Store::History::record( $config, $whole, 1 );
my $recorded = Test::Mutation::Store::read_database( Test::Mutation::Store::path( $config, 0 ) );
is [ map { $recorded->selectrow_array("SELECT count(*) FROM $_") } qw(measurement observation) ],
  [ 1, 3 ], 'one ordinary run records one measurement and one observation per mutant';
my $gap = sub ($entry) {
    my $mutant = $entry->{mutant};
    return {
        id     => $mutant->id,
        path   => $mutant->path,
        source => Test::Mutation::Store::Key::digest( $whole->sources->{ $mutant->path } )
    };
};
is Test::Mutation::Store::History::undetected($config), [ map { $gap->($_) } $whole->entries->@[ 0, 1 ] ],
  'the latest completed scope yields only its undetected mutants in inventory order';
subtest 'range filters keep the identifiers of gaps outside the recheck' => sub {
    my ( $surviving, $uncovered ) = $whole->entries->@[ 0, 1 ];
    my $path = $surviving->{mutant}->path;
    my $file = { $path => [] };
    my $line = { $path => [ [ 2, 2 ] ] };
    is Test::Mutation::Store::History::undetected( $config, [$file] ), [ $gap->($surviving), $gap->($uncovered) ],
      'a file without a line range includes both recorded changes';
    is Test::Mutation::Store::History::undetected_scope( $config, [ $file, $line ] ),
      { identifiers => [ $surviving->{mutant}->id, $uncovered->{mutant}->id ], selected => [ $gap->($uncovered) ] },
      'a line filter skips the first gap and keeps the second in the recheck';
    is Test::Mutation::Store::History::undetected( $config, [ $line, { 'lib/Other.pm' => [] } ] ), [],
      'line and file filters must both include the change';
};
my $uncertain = Samples::result( statuses => [qw(NoVerdict Timeout NoVerdict)], finished => 104 );
Test::Mutation::Store::History::record( $config, $uncertain, 0 );
is Test::Mutation::Store::History::undetected($config), [ map { $gap->($_) } $whole->entries->@[ 0, 1 ] ],
  'inconclusive rechecks preserve known gaps and leave a confirmed detection closed';
my $first   = $whole->entries->[0]{mutant};
my $file    = $first->path;
my $source  = Test::Mutation::Source->from_bytes( path => $file, bytes => $whole->sources->{$file} );
my $history = Test::Mutation::Store::History::entries( $config, { $file => $source }, [$first] );
is $history->{ $first->id }{status}, 'NoVerdict', 'the latest inconclusive observation is available for inspection';
my $narrow  = Test::Mutation::Result->new( $whole->%*, entries => [ $whole->entries->[0] ], finished => 105 );
my $changed = { $narrow->entries->[0]->%*, status => 'Killed', by => 't/verify.t' };
$narrow = Test::Mutation::Result->new( $narrow->%*, entries => [ $changed, $whole->entries->[1] ] );
Test::Mutation::Store::History::record( $config, $narrow, 0 );
is Test::Mutation::Store::History::undetected($config), [ $gap->( $whole->entries->[1] ) ],
  'a verified kill clears that gap while leaving the other gap in the preceding scope';
my $delayed = Test::Mutation::Result->new( $whole->%*, entries => [ $whole->entries->[0] ], finished => 103 );
Test::Mutation::Store::History::record( $config, $delayed, 0 );
is Test::Mutation::Store::History::undetected($config), [ $gap->( $whole->entries->[1] ) ],
  'an earlier verification published late cannot reopen a more recently detected gap';
my $empty = Test::Mutation::Result->new( $whole->%*, entries => [], finished => 106 );
Test::Mutation::Store::History::record( $config, $empty, 1 );
is Test::Mutation::Store::History::undetected($config), [], 'a completed empty scope is distinct from missing history';
my $uncovered = $whole->entries->[1]{mutant};
my $old_kill  = { $changed->%*, mutant => $uncovered };
my $merged    = Test::Mutation::Result->new(
    $whole->%*,
    entries  => [ $whole->entries->[0], $old_kill ],
    started  => 80,
    finished => 90
);
my $merged_at = { completed => 107, measured => { $first->id => 89, $uncovered->id => 90 } };
Test::Mutation::Store::History::record( $config, $merged, 1, $merged_at );
my $remaining = [ $gap->( $whole->entries->[1] ) ];
is Test::Mutation::Store::History::undetected_scope( $config, [] ),
  { selected => $remaining, identifiers => [ $uncovered->id ] },
  'merging older shards selects their members and uses the later kill and uncovered verdict';
my $inspected = Test::Mutation::Store::History::entries( $config, { $file => $source }, [ $first, $uncovered ] );
is [ map { [ $inspected->{ $_->id }->@{qw(status finished)} ] } $first, $uncovered ],
  [ [ 'Killed', 105 ], [ 'NoCoverage', 105 ] ], 'both inspected verdicts and timestamps come from the later recheck';

subtest 'a merge keeps the finish time of each part for inspection' => sub {
    my $other   = Test::Mutation::Settings::of_call( { root => File::Temp::tempdir( CLEANUP => 1 ) } );
    my $result  = Test::Mutation::Result->new( $whole->%*, started => 0, finished => 1 );
    my @mutants = map { $_->{mutant} } $result->entries->@*;
    my %dates   = ( $mutants[0]->id => 0, $mutants[1]->id => 0.5 );
    Test::Mutation::Store::History::record( $other, $result, 1, { completed => 2, measured => \%dates } );
    my $saved = Test::Mutation::Store::History::entries( $other, { $file => $source }, \@mutants );
    is [ map { $saved->{ $_->id }{finished} } @mutants ], [ 0, 0.5, 1 ],
      'the result finish fills a missing timestamp and preserves an observation at the epoch';
};

subtest 'each merged mutant uses the latest eligible observation of its own source' => sub {
    my $other   = Test::Mutation::Settings::of_call( { root => File::Temp::tempdir( CLEANUP => 1 ) } );
    my $checked = Samples::result( statuses => [qw(Killed Survived Killed)], finished => 120 );
    Test::Mutation::Store::History::record( $other, $checked, 0 );
    my $joined  = Samples::result( statuses => [qw(Survived Killed NoCoverage)], finished => 121 );
    my @mutants = map { $_->{mutant} } $joined->entries->@*;
    my %measured;
    @measured{ map { $_->id } @mutants } = ( 119, 121, 120 );
    Test::Mutation::Store::History::record( $other, $joined, 1, { completed => 200, measured => \%measured } );
    my $expected = [ $gap->( $joined->entries->[2] ) ];
    is Test::Mutation::Store::History::undetected($other), $expected,
      'the recheck at 120 beats the first shard, predates the next and loses the tie with the last';
    my $inspect = Test::Mutation::Store::History::entries( $other, { $file => $source }, \@mutants );
    is [ map { [ $inspect->{ $_->id }->@{qw(status finished)} ] } @mutants ],
      [ [ 'Killed', 120 ], [ 'Killed', 121 ], [ 'NoCoverage', 120 ] ],
      'inspection orders each verdict by the same measurement time and insertion order';
    my $candidate = Samples::result( statuses => [qw(Survived Survived Killed)], finished => 210 );

    for my $case (
        [ 'another source revision', { sources     => { $file => $whole->sources->{$file} . "\n" } }, 0 ],
        [ 'an interrupted run',      { interrupted => 'TERM' },                                       1 ],
        [ 'an unmerged shard',       { shard       => '1/2' },                                        1 ],
      )
    {
        my ( $label, $overrides, $anchor ) = @$case;
        Test::Mutation::Store::History::record( $other, Test::Mutation::Result->new( $candidate->%*, %$overrides ),
            $anchor );
        is Test::Mutation::Store::History::undetected($other), $expected, "$label leaves the gaps in place";
    }
    my $unknown = Samples::result( statuses => [qw(Timeout NoVerdict Pending)], finished => 220 );
    Test::Mutation::Store::History::record( $other, $unknown, 0 );
    is Test::Mutation::Store::History::undetected($other), $expected,
      'a recheck without a verdict leaves the gaps in place';
};

my $off = Test::Mutation::Settings::of_call( { root => $root, cache => 0 } );
is Test::Mutation::Store::History::undetected($off), undef, 'disabling the cache bypasses saved history';
subtest 'history follows finish times when concurrent writers commit out of order' => sub {
    my $other  = Test::Mutation::Settings::of_call( { root => File::Temp::tempdir( CLEANUP => 1 ) } );
    my $record = sub ( $finished, $entries, $anchor ) {
        my $result = Test::Mutation::Result->new( $whole->%*, entries => $entries, finished => $finished );
        Test::Mutation::Store::History::record( $other, $result, $anchor );
    };
    my $gaps = sub { Test::Mutation::Store::History::undetected($other) };
    $record->( 120, [$changed],      0 );
    $record->( 110, $whole->entries, 1 );
    is $gaps->(), [ $gap->( $whole->entries->[1] ) ], 'a later detection can commit before its scope';
    $record->( 108, [], 1 );
    is $gaps->(), [ $gap->( $whole->entries->[1] ) ], 'a late write with an older finish cannot replace the scope';
    $record->( 130, [ $whole->entries->[0] ],     0 );
    $record->( 130, [ $uncertain->entries->[0] ], 1 );
    is $gaps->(), [], 'an inconclusive scope excludes the earlier write with the same finish';
    $record->( 129.5, [ $whole->entries->[0] ], 0 );
    is $gaps->(), [], 'a late observation from before the scope cannot open a gap';
    $record->( 130, [ $whole->entries->[0] ], 0 );
    is $gaps->(), [ $gap->( $whole->entries->[0] ) ], 'the next write with the same finish can open a gap';
    $record->( 130, [], 1 );
    is $gaps->(), [], 'recording another scope with the same finish breaks the tie';
};

sub history_read_cost ( $lookup, $expected, $label ) {
    my $hundreds = 0;
    my $read     = \&Test::Mutation::Store::read_database;
    no warnings 'redefine';
    local *Test::Mutation::Store::read_database = sub ($path) {
        my $connection = $read->($path);
        $connection->sqlite_progress_handler( 100, sub { ++$hundreds; return 0 } );
        return $connection;
    };
    is $lookup->(), $expected, $label;
    return $hundreds;
}

subtest 'reading a scope and its evidence takes bounded work as unrelated history grows' => sub {
    my $directory = File::Temp::tempdir( CLEANUP => 1 );
    my $other     = Test::Mutation::Settings::of_call( { root => $directory } );
    Test::Mutation::Store::History::record( $other, $empty, 1 );
    my $db    = Test::Mutation::Store::database( Test::Mutation::Store::path($other) );
    my $steps = sub ($expected) {
        return history_read_cost( sub { Test::Mutation::Store::History::undetected($other) },
            $expected, 'the selected scope keeps its own verdicts' );
    };
    my $empty_cost = $steps->( [] );
    my $one        = Test::Mutation::Result->new( $whole->%*, entries => [ $whole->entries->[0] ], finished => 130 );
    Test::Mutation::Store::History::record( $other, $one, 1 );
    my $one_gap = [ $gap->( $whole->entries->[0] ) ];
    my $initial = $steps->($one_gap);
    $db->do( <<'SQL', undef, Cwd::abs_path($directory) );
WITH RECURSIVE older(finished) AS (SELECT 1 UNION ALL SELECT finished + 1 FROM older WHERE finished < 1000)
INSERT INTO measurement(project,finished,anchor,complete) SELECT ?, -finished, 1, 1 FROM older
SQL
    $db->do( <<'SQL', undef, $first->id, $one_gap->[0]{source} );
INSERT INTO observation(run,ordinal,id,source,status,data)
SELECT run, 0, ?, 'other source', 'Killed', '{}' FROM measurement WHERE finished < 0
UNION ALL SELECT run, 1, 'other mutant', ?, 'Killed', '{}' FROM measurement WHERE finished < 0
SQL
    cmp_ok $steps->($one_gap), '<=', $initial + 1,
      'one thousand observations for each unrelated mutant or source cost at most one extra block of 100 SQLite operations';
    Test::Mutation::Store::History::record( $other, Test::Mutation::Result->new( $empty->%*, finished => 131 ), 1 );
    cmp_ok $steps->( [] ), '<=', $empty_cost + 1,
      'one thousand older scopes cost at most one extra block of 100 SQLite operations';
};

subtest 'looking for an unmeasured project skips unrelated history in a shared cache' => sub {
    my $directory = File::Temp::tempdir( CLEANUP => 1 );
    my $shared    = "$directory/cache";
    my $absent    = Test::Mutation::Settings::of_call( { root => $directory, cache_dir => $shared } );
    my $neighbor  = Test::Mutation::Settings::of_call( { root => $root,      cache_dir => $shared } );
    Test::Mutation::Store::History::record( $neighbor, $empty, 1 );
    my $db   = Test::Mutation::Store::database( Test::Mutation::Store::path($absent) );
    my $cost = sub {
        return history_read_cost(
            sub { Test::Mutation::Store::History::entries( $absent, { $file => $source }, [$first] ) },
            undef, 'the other projects supply no result for this checkout' );
    };
    my $small = $cost->();
    $db->do(<<'SQL');
WITH RECURSIVE numbers(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM numbers WHERE n < 1000)
INSERT INTO measurement(project,finished,anchor,complete) SELECT 'other-' || n, n, 1, 1 FROM numbers
SQL
    cmp_ok $cost->(), '<=', $small + 1,
      'one thousand unrelated projects cost at most one extra block of one hundred SQLite operations';
};

subtest 'read-only history stays available and fresh observations are private' => sub {
    Capability::need( 'unprivileged', $> != 0, 'the superuser can write to read-only directories' );
    chmod oct('555'), $root or die "chmod: $!";
    my $reader = Test::Mutation::Settings::of_call( { root => $root } );
    is Test::Mutation::Store::History::undetected($reader), $remaining,
      'a query reads the existing history in the checkout';
    my $private = Test::Mutation::Store::path($reader);
    ok -f $private, 'the private writer starts from a snapshot of the indexed checkout';
    is Test::Mutation::Store::History::undetected($reader), $remaining,
      'the private snapshot includes the completed scope';
    Test::Mutation::Store::History::record( $reader, Test::Mutation::Result->new( $empty->%*, finished => 108 ), 1 );
    is Test::Mutation::Store::History::undetected($reader), [], 'a private measurement supersedes the imported scope';
    chmod oct('755'), $root or die "chmod: $!";
    is Test::Mutation::Store::History::undetected($config), $remaining, 'the checkout still holds the earlier scope';
};
done_testing;
