use v5.36;
use Test2::V0;
use Digest::SHA  ();
use JSON::PP     ();
use Scalar::Util qw(refaddr);
use lib 't/lib';
use Raised;
use Test::Mutation::Merge;
use Test::Mutation::Mutant;
use Test::Mutation::Report::Json;
use Test::Mutation::Report::Results;
use Test::Mutation::Result;
use Test::Mutation::Status;

sub inventory ($count) {
    my @ids = map { sprintf '%012d', $_ } 1 .. $count;
    return { mutants => $count, digest => Digest::SHA::sha256_hex( join "\n", @ids ) };
}

my $digest = inventory(6)->{digest};

sub entry ( $number, $status ) {
    my $mutant = Test::Mutation::Mutant->new(
        id          => sprintf( '%012d', $number ),
        path        => $number > 4 ? 'lib/B.pm' : 'lib/A.pm',
        mutator     => 'arithmetic',
        start       => $number,
        end         => $number + 1,
        original    => q{+},
        replacement => q{-},
        description => 'replaced + with -',
        from        => [ 1, $number + 1 ],
        to          => [ 1, $number + 2 ],
        scope       => [ 1, 1 ],
    );
    return {
        mutant     => $mutant,
        status     => $status,
        reason     => Test::Mutation::Status::of($status)->reasons->[0],
        detail     => undef,
        by         => undef,
        covered_by => [],
        tests_run  => 0,
        duration   => 0
    };
}

sub part ( $shard, $entries, %fields ) {
    return Test::Mutation::Result->new(
        root               => '/project',
        sources            => { map { $_->{mutant}->path => "1 + 2 + 3 + 4 + 5;\n" } $entries->@* },
        tests              => [ { name => 't/a.t', duration => 0.5 } ],
        entries            => $entries,
        problems           => [],
        warnings           => [],
        baseline_failures  => [],
        jobs               => 2,
        parallel_safe      => 1,
        shard              => $shard,
        measurement_digest => 'cd' x 32,
        dependency_digest  => 'ef' x 32,
        inventory          => { mutants => 6, digest => $digest },
        started            => 100,
        finished           => 110,
        %fields,
    );
}

sub work (@counts) {
    my @names = qw(copies walks compiles spawns listings baseline_tests verifications);
    return { map { $names[$_] => $counts[$_] } 0 .. $#names };
}

sub merged (@parts) {
    my $number = 0;
    return Test::Mutation::Merge::merge( [ map { { name => 'report ' . ++$number, result => $_ } } @parts ] );
}

my @first = ( entry( 1, 'Killed' ),  entry( 3, 'Survived' ), entry( 5, 'Killed' ) );
my @rest  = ( entry( 2, 'Timeout' ), entry( 4, 'Killed' ),   entry( 6, 'NoCoverage' ) );

subtest 'reports from before embedded compiler phases can still show their measured verdicts' => sub {
    my $early = part( '1/2', \@first, compiler_input_protocol => 1 );
    my $old =
      Test::Mutation::Report::Json::parse( Test::Mutation::Report::Json::render( $early, high => 80, low => 60 ) );
    is [ $old->compiler_input_protocol, $old->measurement_digest, $old->entries->[0]{status} ],
      [ 1, 'cd' x 32, 'Killed' ], 'the historical report preserves the protocol, original digest, and verdict';
    is $old->verified_measurement_digest, undef,
      'the earlier digest cannot identify inputs read inside a Perl expression';
    like dies { merged( $old, part( '2/2', \@rest, compiler_input_protocol => 1 ) ) },
      qr/measurement inputs are missing/, 'even matching first-generation shards must be measured again';
    like dies { merged( part( '1/2', \@first ), part( '2/2', \@rest, compiler_input_protocol => 1 ) ) },
      qr/measurement inputs are missing/, 'a current shard cannot certify the earlier measurement';
};

subtest 'reports written without the driver quote parser identity remain readable' => sub {
    my @saved =
      map { Test::Mutation::Report::Json::parse( Test::Mutation::Report::Json::render( $_, high => 80, low => 60 ) ) }
      part( '1/2', \@first, compiler_input_protocol => 2 ), part( '2/2', \@rest, compiler_input_protocol => 2 );
    is [ $saved[0]->compiler_input_protocol, $saved[0]->measurement_digest, $saved[0]->entries->[0]{status} ],
      [ 2, 'cd' x 32, 'Killed' ], 'the earlier JSON preserves its recorded measurement';
    like dies { merged(@saved) }, qr/measurement inputs are missing/,
      'two matching earlier digests cannot verify the driver quote parsers';
};

subtest 'merging applies a common deferred threshold' => sub {
    my $result = merged( part( '1/2', \@first, min_score => 90 ), part( '2/2', \@rest, min_score => 90 ) );
    is [ $result->assessment->@{qw(minimum gate exitCode)} ], [ 90, 'failed', 1 ],
      'the combined score decides the threshold shared by the shard reports';
    my $first = part( '1/2', \@first, min_score => 90 );
    for my $other_floor ( undef, 50 ) {
        my $other_part = part( '2/2', \@rest, min_score => $other_floor );
        is [ merged( $first, $other_part )->assessment->@{qw(score minimum gate exitCode)} ],
          [ 60, undef, undef, 0 ], 'shards without a common threshold still yield their combined score';
    }
    my $reports =
      [ { name => 'first', result => $first }, { name => 'second', result => part( '2/2', \@rest, min_score => 90 ) } ];
    my $override = Test::Mutation::Merge::merge( $reports, 60 );
    is [ $override->assessment->@{qw(minimum gate exitCode)} ], [ 60, 'passed', 0 ],
      'a threshold requested for the whole run takes precedence at the exact combined score';
    my $zero = Test::Mutation::Merge::merge( $reports, 0 );
    is [ $zero->assessment->@{qw(minimum gate exitCode)} ], [ 0, 'passed', 0 ],
      'a zero threshold overrides the higher threshold shared by both shards';
    isa_ok dies { Test::Mutation::Merge::merge( $reports, 'unknown' ) }, ['Error::TypeTiny'],
      'a merge rejects a nonnumeric threshold';
};

subtest 'the parts of one run merge into the result of the whole run' => sub {
    my $whole = merged(
        part(
            '2/2',
            \@rest,
            tests => [
                { name => 't/b.t', duration => 2 },
                { name => 't/a.t', duration => 0.75 },
                { name => 't/c.t', duration => 1 }
            ],
            warnings => [ 'shared warning', 'second warning' ],
            problems => [ { path => 'lib/Odd.pm', problem => 'the file has carriage returns' } ],
            jobs     => 4,
            reused   => 2,
            started  => 90,
            finished => 105,
            stats    => work( 1 .. 7 ),
        ),
        part(
            '1/2', \@first,
            tests    => [ { name => 't/a.t', duration => 0.5 }, { name => 't/c.t', duration => 3 } ],
            warnings => ['shared warning'],
            problems => [ { path => 'lib/Odd.pm', problem => 'the file has carriage returns' } ],
            reused   => 1,
            stats    => work( 10, 20, 30, 40, 50, 60, 70 ),
        ),
    );
    is $whole->stats, work( 11, 22, 33, 44, 55, 66, 77 ), 'the work of every part adds up';
    is [ map { $_->{mutant}->id + 0 } $whole->entries->@* ], [ 1 .. 6 ],
      'the mutants return to the order of the whole run';
    is [ map { $_->{status} } $whole->entries->@* ], [qw(Killed Timeout Survived Killed Killed NoCoverage)],
      'each mutant keeps its status';
    is $whole->tally->{score},                                 60,    'the score covers every part';
    is $whole->shard,                                          undef, 'the result is a whole run';
    is $whole->inventory, { mutants => 6, digest => $digest }, 'the inventory stays';
    is [ sort keys $whole->sources->%* ],                      [ 'lib/A.pm', 'lib/B.pm' ], 'the sources of every part';
    is $whole->tests,
      [ { name => 't/a.t', duration => 0.75 }, { name => 't/b.t', duration => 2 }, { name => 't/c.t', duration => 3 } ],
      'each test appears once with its longest duration';
    is $whole->warnings, [ 'shared warning', 'second warning' ], 'each warning appears once';
    is $whole->problems, [ { path => 'lib/Odd.pm', problem => 'the file has carriage returns' } ],
      'each problem appears once';
    is [ $whole->jobs, $whole->reused, $whole->started, $whole->finished, $whole->parallel_safe ], [ 4, 3, 90, 110, 1 ],
      'the largest job count, the sum of the reused results, and the whole time span';
};

subtest 'parallel safety carries over and every shard must finish' => sub {
    my $one = part( '1/2', \@first, parallel_safe => 0 );
    ok !merged( $one, part( '2/2', \@rest ) )->parallel_safe, 'unsafe parallel tests remain unsafe after merging';
    like Raised::message( sub { merged( $one, part( '2/2', \@rest, interrupted => 'TERM' ) ) } ),
      qr/report 2.*SIGTERM.*rerun/i, 'an interrupted shard must finish even when every identifier is present';
};

subtest 'the ordered test observations decide the final verdicts' => sub {
    my $pass   = { test => 't/a.t', result => 'pass', served => 1, load_failed => 0, bypassed => 0, syntax => undef };
    my $fail   = { $pass->%*, result => 'fail' };
    my $loaded = { $first[0]->%*, observations => [ [$pass] ] };
    my $repeat = { $rest[0]->%*,  observations => [ [$pass], [$fail] ] };
    my $whole  = merged( part( '1/2', [ $loaded, @first[ 1, 2 ] ] ), part( '2/2', [ $repeat, @rest[ 1, 2 ] ] ) );
    is [ $whole->entries->[0]->@{qw(status reason tests_run)} ], [ 'Survived', undef, 1 ],
      'the loaded target and the passing test determine survival';
    is [ $whole->entries->[1]->@{qw(status reason tests_run)} ], [ 'NoVerdict', 'unstable-test', 2 ],
      'a contradictory repeat keeps its own reason';
};

subtest 'a compiled duplicate names the first undetected mutant in its own file' => sub {
    my @candidates = map { entry( $_ + 1, (qw(Killed Survived NoCoverage Survived NoCoverage Survived))[$_] ) } 0 .. 5;
    $_->{compiled_digest} = '31' x 32 for @candidates[ 0, 1, 2, 4, 5 ];
    my $whole = merged( part( '1/2', [ @candidates[ 0, 2, 4 ] ] ), part( '2/2', [ @candidates[ 1, 3, 5 ] ] ) );
    is [ map { $_->{status} } $whole->entries->@* ], [qw(Killed Survived Ignored Survived NoCoverage Ignored)],
      'detected mutants, missing digests, and other files are independent';
    for my $pair ( [ 2, 1 ], [ 5, 4 ] ) {
        my ( $duplicate, $first ) = $whole->entries->@[@$pair];
        my $identifier = $first->{mutant}->id;
        is $duplicate->{reason}, 'same-code-as-mutant', 'a duplicate does not count as a missed change';
        like $duplicate->{detail}, qr/\Q$identifier\E/, 'the report identifies the earlier change';
    }
    is $whole->tally->{score}, 25, 'one detection among four distinct valid mutants';
};

subtest 'an empty shard cannot hide conflicting inputs from two measured siblings' => sub {
    my $inventory = inventory(2);
    my $one       = part( '1/3', [ entry( 1, 'Killed' ) ], inventory => $inventory );
    my $two   = sub (%inputs) { return part( '2/3', [ entry( 2, 'Survived' ) ], inventory => $inventory, %inputs ) };
    my $empty = part( '3/3', [], tests => [], inventory => $inventory, dependency_digest => undef );
    for my $order ( [ 2, 0, 1 ], [ 0, 2, 1 ], [ 0, 1, 2 ] ) {
        my $merge = sub (%inputs) { return merged( ( $one, $two->(%inputs), $empty )[@$order] ) };
        is $merge->()->tally->{score}, 50, 'an empty part contributes its inventory position';
        like dies { $merge->( dependency_digest => '03' x 32 ) }, qr/measurement inputs differ/,
          'different dependencies invalidate the combined score';
        like dies { $merge->( measurement_digest => '04' x 32 ) }, qr/measurement inputs differ/,
          'different tests or execution settings invalidate the combined score';
        like dies { $merge->( dependency_digest => undef ) }, qr/inputs are missing.*rerun every shard/,
          'a measured part needs dependency evidence';
    }
};

subtest 'shards agree on the contents of each shared compiler input' => sub {
    my ( $shared, $extra, $seven, $five ) = map { Digest::SHA::sha256_hex($_) } qw(shared.cfg extra.cfg seven five);
    my $first = part( '1/2', \@first, compiler_inputs => { $shared => $seven } );
    my $both  = { $extra => $five, $shared => $seven };
    my $rest  = part( '2/2', \@rest, compiler_inputs => $both );
    for my $parts ( [ $first, $rest ], [ $rest, $first ] ) {
        is merged(@$parts)->compiler_inputs, $both, 'a file used by one shard joins the matching shared input';
    }
    my $changed = part( '2/2', \@rest, compiler_inputs => { $extra => $five, $shared => $five } );
    for my $parts ( [ $first, $changed ], [ $changed, $first ] ) {
        like dies { merged(@$parts) }, qr/measurement inputs differ.*rerun every shard/,
          'a changed shared file requires a new measurement in either report order';
    }
};

subtest 'merging interleaves uneven shards and omits empty positions' => sub {
    for my $case ( [ 0, [ [], [], [], [] ] ], [ 2, [ [1], [2], [], [] ] ], [ 5, [ [ 1, 5 ], [2], [3], [4] ] ] ) {
        my ( $count, $groups ) = @$case;
        my @reports;
        for my $number ( 1 .. 4 ) {
            my @entries = map { entry( $_, 'Killed' ) } $groups->[ $number - 1 ]->@*;
            push @reports, part( "$number/4", \@entries, inventory => inventory($count) );
        }
        my $result = merged( reverse @reports );
        is [ map { 0 + $_->{mutant}->id } $result->entries->@* ], [ 1 .. $count ],
          "four shards reconstruct all $count mutants in measurement order";
    }
};

subtest 'a cache disagreement in either shard propagates to the whole run' => sub {
    for my $case ( [ 0, 0, 0 ], [ 1, 0, 1 ], [ 0, 1, 1 ], [ 1, 1, 1 ] ) {
        my ( $first_shard, $second_shard, $mismatch ) = @$case;
        my $whole = merged(
            part( '1/2', \@first, cache_mismatch => $first_shard ),
            part( '2/2', \@rest,  cache_mismatch => $second_shard )
        );
        is $whole->cache_mismatch, $mismatch,
          "cache disagreement travels from either shard ($first_shard, $second_shard)";
    }
};

subtest 'a set that is not one complete run is refused' => sub {
    my $one = part( '1/2', \@first );
    my $two = part( '2/2', \@rest );
    isa_ok dies { Test::Mutation::Merge::merge( [ { name => 'report', result => undef } ] ) }, ['Error::TypeTiny'],
      'each named input requires a measured result';
    like Raised::message( sub { merged() } ),     qr/\Amerge needs at least one report/, 'no report';
    like Raised::message( sub { merged($one) } ), qr/\Apart 2 of 2 is missing/,          'a missing part';
    like Raised::message( sub { merged( $one, $one ) } ), qr/\Areport 1 and report 2 both hold part 1 of 2/,
      'a repeated part';
    like Raised::message( sub { merged( $one, part( '2/3', \@rest ) ) } ),
      qr/\Areport 1 holds part 1 of 2, and report 2 holds part 2 of 3/,
      'parts of different splits';
    like Raised::message( sub { merged( part( '1/3', \@first ), part( '3/3', \@rest ) ) } ),
      qr/\Apart 2 of 3 is missing/,
      'a missing middle part';
    like Raised::message( sub { merged( part( '1/4', \@first ), part( '2/4', \@rest ) ) } ),
      qr/\Aparts 3 and 4 of 4 are missing/,
      'two missing parts';
    like Raised::message(
        sub { merged( $one, part( '2/2', \@rest, inventory => { mutants => 6, digest => 'cd' x 32 } ) ) } ),
      qr/\Areport 2 covers other mutants than report 1/, 'a part of another source state';
    like Raised::message( sub { merged( $one, part( '2/2', \@rest, shard => undef ) ) } ),
      qr/\Areport 2 is the report of a whole run, not of a part/, 'a whole run';
    like Raised::message( sub { merged( $one, part( '2/2', \@rest, inventory => undef ) ) } ),
      qr/\Areport 2 names no inventory/,
      'a report without an inventory';
    is Raised::error(
        sub {
            merged( $one,
                part( '2/2', [], baseline_failures => [ { test => 't/a.t', output => q{}, errors => q{} } ] ) );
        }
      ),
      [
        'usage',
        'merge-failed-baseline',
        'report 2 has failing tests in its unmodified run, so its part measured nothing'
      ],
      'a part that never ran';
    like Raised::message( sub { merged( $one, part( '2/2', [ @rest[ 0, 1 ] ] ) ) } ),
      qr/\Areport 2 holds 2 mutants, and part 2 of 2 has 3/, 'a part that lost a mutant';
    like Raised::message( sub { merged( $one, part( '2/2', [ @rest[ 0, 1 ], $first[0] ] ) ) } ),
      qr/\Amutant 000000000001 appears in more than one part/, 'a mutant in two parts';
    for my $changed ( [ @rest[ 1, 0, 2 ] ], [ @rest[ 0, 1 ], entry( 7, 'NoCoverage' ) ], ) {
        like Raised::message( sub { merged( $one, part( '2/2', $changed ) ) } ),
          qr/inventory order/, 'the actual sequence must match the advertised digest';
    }
    like Raised::message(
        sub { merged( $one, part( '2/2', \@rest, inventory => { mutants => 5, digest => $digest } ) ) } ),
      qr/covers other mutants/, 'each advertised size must agree';
    like Raised::message( sub { merged( $one, $two, part( '3/2', [] ) ) } ),
      qr/invalid shard 3\/2/, 'an empty shard outside the declared split is refused';
};

subtest 'an interrupted collection can recover every missing shard' => sub {
    my @reports = map { part( "$_/8", $_ <= 6 ? [ entry( $_, 'Killed' ) ] : [] ) } 1 .. 8;
    my @held    = @reports[ 6, 0, 3 ];
    like Raised::message( sub { merged(@held) } ), qr/\Aparts 2, 3, 5, 6, and 8 of 8 are missing/,
      'the diagnostic identifies all missing parts including the empty eighth shard';
    my $complete = merged( @held, @reports[ 1, 2, 4, 5, 7 ] );
    is [ map { $_->{mutant}->id + 0 } $complete->entries->@* ], [ 1 .. 6 ],
      'supplying exactly the listed parts recovers the measured inventory in order';
};

subtest 'refresh counts distinct compiled changes across both measurements' => sub {
    my $pass = { test => 't/a.t', result => 'pass', served => 1, load_failed => 0, bypassed => 0, syntax => undef };
    my $fail = { $pass->%*, result => 'fail' };
    my @rows = ( entry( 1, 'Killed' ), entry( 2, 'Survived' ), entry( 3, 'Survived' ) );
    for my $row (@rows) {
        $row->{compiled_digest} = '31' x 32;
        $row->{observations}    = [ [ $row->{status} eq 'Killed' ? $fail : $pass ] ];
    }
    my %inputs = ( catalog_digest => inventory(3)->{digest}, inventory => inventory(3), min_score => 45 );
    my $first  = part( undef, [ @rows[ 0, 1 ] ], %inputs, selection => { mutants => [qw(000000000001 000000000002)] } );
    my $last   = part( undef, [ $rows[2] ],      %inputs, selection => { mutants => ['000000000003'] } );
    my $saved  = Test::Mutation::Merge::refresh( $first, $last );
    is [ map { $_->{status} } $saved->entries->@* ], [qw(Killed Survived Ignored)],
      'only the first undetected mutant with the same code counts';
    is [ $saved->assessment->@{qw(score gate exitCode)} ], [ 50, 'passed', 0 ],
      'one kill and one distinct survivor meet the threshold';
    like $saved->entries->[2]{detail}, qr/000000000002/, 'the duplicate identifies the survivor in the earlier report';

    my $whole = merged( part( '1/1', \@rows, %inputs ) );
    is $saved->assessment, $whole->assessment, 'refresh and a whole inventory give the same score and counts';
    my $reopened =
      Test::Mutation::Report::Json::parse( Test::Mutation::Report::Json::render( $whole, high => 80, low => 60 ) );
    my $killed  = { %{ $rows[1] }, status => 'Killed', observations => [ [$fail] ] };
    my $updated = part( undef, [$killed], %inputs, selection => { mutants => ['000000000002'] } );
    my $again   = Test::Mutation::Merge::refresh( $reopened, $updated );
    is [ map { $_->{status} } $again->entries->@* ], [qw(Killed Killed Survived)],
      'a saved duplicate counts its passing test when its former representative is killed';
    is $again->entries->[2]{observations}, [ [$pass] ], 'the promoted survivor keeps the observation that supports it';

    my %old_duplicate = $reopened->entries->[2]->%*;
    delete $old_duplicate{observations};
    for my $record ( { tests_run => 0 }, { observations => [] } ) {
        my $legacy =
          Test::Mutation::Result->new( $reopened->%*, entries => [ @rows[ 0, 1 ], { %old_duplicate, $record->%* } ] );
        is Test::Mutation::Merge::refresh( $legacy, $updated )->entries->[2]{status}, 'Ignored',
          'an incomplete record cannot establish the outcome of an earlier duplicate';
    }
};

subtest 'a refreshed threshold uses every row in the measured scope' => sub {
    my $whole  = part( undef, [ map { entry( $_, 'Ignored' ) } 1 .. 6 ], catalog_digest => $digest, min_score => 80 );
    my $single = part(
        undef, [ entry( 1, 'Ignored' ) ],
        catalog_digest => $digest,
        min_score      => 80,
        selection      => { mutants => ['000000000001'] }
    );
    is $whole->assessment->{gate},  'unavailable',         'the whole project has no score to compare to the threshold';
    is $single->assessment->{gate}, 'no mutants selected', 'the narrowed measurement accepts an empty score';
    is $single->score_scope,        $single->selection,    'a fresh score describes the requested selection';
    my $saved = Test::Mutation::Merge::refresh( $whole, $single );
    is $saved->assessment, $whole->assessment, 'refreshing one ignored mutant preserves the whole-project gate';
    is $saved->score_scope, {}, 'the refreshed score includes the whole project after a single-mutant request';
};

subtest 'refresh replaces the selected verdicts and keeps independently measured changes' => sub {
    my $prior = part(
        undef, [ entry( 3, 'Survived' ), entry( 1, 'Killed' ) ],
        selection      => { mutants => [qw(000000000003 000000000001)] },
        catalog_digest => $digest,
        sources        => { 'lib/A.pm' => 'source A', 'lib/Empty.pm' => 'empty source' },
        tests          => [ { name => 't/a.t', duration => 3 }, { name => 't/z.t', duration => 4 } ],
    );
    my $current = part(
        undef, [ entry( 5, 'Killed' ), entry( 3, 'Killed' ), entry( 6, 'NoCoverage' ) ],
        catalog_digest => $digest,
        selection      => { mutants    => [qw(000000000005 000000000003 000000000006)] },
        sources        => { 'lib/A.pm' => 'source A', 'lib/B.pm' => 'source B' },
        tests          => [ { name => 't/c.t', duration => 2 }, { name => 't/a.t', duration => 1 } ],
    );
    my $saved = Test::Mutation::Merge::refresh( $prior, $current );
    my @ids   = map { sprintf '%012d', $_ } ( 3, 1, 5, 6 );
    is [ map { $_->{mutant}->id } $saved->entries->@* ], \@ids,
      'prior entries keep their positions and new entries follow';
    is [ map { $_->{status} } $saved->entries->@* ], [qw(Killed Killed Killed NoCoverage)],
      'the repeated change takes its new verdict';
    is $saved->tests,
      [ { name => 't/a.t', duration => 1 }, { name => 't/c.t', duration => 2 }, { name => 't/z.t', duration => 4 } ],
      'the saved test list includes both measurements and uses the latest duration';
    is $saved->sources, { 'lib/A.pm' => 'source A', 'lib/B.pm' => 'source B', 'lib/Empty.pm' => 'empty source' },
      'sources without a mutant remain in the report';
    is $saved->inventory, { mutants => 4, digest => Digest::SHA::sha256_hex( join "\n", @ids ) },
      'the inventory describes the resulting order';
    is $saved->selection, $current->selection, 'the report records the latest selection';
    is Test::Mutation::Report::Json::document( $saved, high => 80, low => 60 )->{testMutation}{measuredScope},
      { mutants => \@ids }, 'two overlapping partial measurements name the identifiers in the scored inventory';
    is Test::Mutation::Report::Results::overview($saved)->[0], 'Scope: 4 selected mutants',
      'the terminal scope counts every mutant in the refreshed score';

    my $whole          = part( undef, [ map { entry( $_, 'Survived' ) } 1 .. 6 ], catalog_digest => $digest );
    my $file_selection = part(
        undef, [ entry( 5, 'Killed' ), entry( 6, 'NoCoverage' ) ],
        catalog_digest => $digest,
        selection      => { paths => { 'lib/B.pm' => [] } }
    );
    my $single = part(
        undef, [ entry( 5, 'Killed' ) ],
        catalog_digest => $digest,
        selection      => { mutants => ['000000000005'] }
    );

    for my $case (
        [ $whole,          $file_selection, 'configured sources', 6 ],
        [ $file_selection, $single,         'lib/B.pm',           2 ],
        [ $single,         $file_selection, 'lib/B.pm',           2 ],
      )
    {
        my ( $before, $after, $scope, $count ) = @$case;
        my $result = Test::Mutation::Merge::refresh( $before, $after );
        is [ Test::Mutation::Report::Results::overview($result)->[0], $result->tally->{total} ],
          [ "Scope: $scope", $count ], 'the terminal scope describes every row counted in the refreshed report';
        my $parsed =
          Test::Mutation::Report::Json::parse( Test::Mutation::Report::Json::render( $result, high => 80, low => 60 ) );
        is [ $parsed->selection, Test::Mutation::Report::Results::overview($parsed)->[0] ],
          [ $after->selection, "Scope: $scope" ], 'JSON keeps the requested selection and the scope of the score';
        is $parsed->score_scope, $result->score_scope, 'reopening a report retains the scope of its score';
    }
    my $from_whole = Test::Mutation::Merge::refresh( $whole, $file_selection );
    my $reopened =
      Test::Mutation::Report::Json::parse( Test::Mutation::Report::Json::render( $from_whole, high => 80, low => 60 ) );
    is Test::Mutation::Report::Results::overview( Test::Mutation::Merge::refresh( $reopened, $single ) )->[0],
      'Scope: configured sources', 'a second update keeps the measured scope of the earlier report';

    my $file     = '98' x 32;
    my $data     = '54' x 32;
    my $compiled = Test::Mutation::Result->new( $prior->%*, compiler_inputs => { $file => $data } );
    my $superset =
      Test::Mutation::Result->new( $current->%*, compiler_inputs => { $file => $data, '32' x 32 => $data } );
    my $verified = Test::Mutation::Merge::refresh( $compiled, $superset );
    is [ map { $_->{mutant}->id } $verified->entries->@* ], \@ids,
      'current compiler observations can verify every earlier input and add a new one';
    is $verified->compiler_inputs, $superset->compiler_inputs,
      'the refreshed result carries the evidence for every input';
    my $old_document = Test::Mutation::Report::Json::document( $compiled, high => 80, low => 60 );
    delete $old_document->{testMutation}{compilerInputProtocol};
    my $old_measurement = Test::Mutation::Report::Json::parse( JSON::PP->new->encode($old_document) );
    is Test::Mutation::Merge::refresh( $old_measurement, $superset ), $superset,
      'a partial update cannot vouch for rows from before compiler input verification';

    my $early_protocol = { compiler_input_protocol => 1 };
    for my $case (
        [ 'a prior shard',                      { shard => '1/2' },              {} ],
        [ 'a current shard',                    {},                              { shard => '2/2' } ],
        [ 'another project',                    { root => '/other' },            {} ],
        [ 'a legacy prior report',              { catalog_digest => undef },     {} ],
        [ 'a legacy current report',            {},                              { catalog_digest => undef } ],
        [ 'an earlier compiler input protocol', $early_protocol,                 {} ],
        [ 'another catalog',                    { catalog_digest => 'cd' x 32 }, {} ],
        [ 'a whole run',                        {},                              { selection          => {} } ],
        [ 'changed measurement inputs',         {},                              { measurement_digest => 'ab' x 32 } ],
        [ 'missing earlier measurement inputs', { measurement_digest => undef }, {} ],
        [ 'missing current measurement inputs', {},                              { measurement_digest => undef } ],
        [ 'changed test libraries',             {},                              { dependency_digest  => 'ab' x 32 } ],
        [ 'missing earlier test libraries',     { dependency_digest => undef },  {} ],
        [ 'missing current test libraries',     {},                              { dependency_digest => undef } ],
        [
            'a different compiler input',
            { compiler_inputs => { $file => $data } },
            { compiler_inputs => { $file => 'ab' x 32 } }
        ],
        [
            'an earlier compiler input absent from the current measurement',
            { compiler_inputs => { $file => $data } }, {}
        ],
        [ 'an interrupted earlier measurement', { interrupted => 'TERM' }, {} ],
        [ 'an interrupted current measurement', {}, { interrupted => 'INT' } ],
        [
            'an earlier baseline failure',
            { baseline_failures => [ { test => 't/a.t', output => 'not ok', errors => q{} } ] }, {}
        ],
        [ 'an earlier cache verification failure', { cache_mismatch => 1 }, {} ],
        [ 'a current cache verification failure',  {}, { cache_mismatch => 1 } ],
        [
            'a failed original test',
            {}, { baseline_failures => [ { test => 't/a.t', output => 'not ok', errors => q{} } ] }
        ],
      )
    {
        my ( $label, $older, $newer ) = @$case;
        my $before = Test::Mutation::Result->new( $prior->%*,   %$older );
        my $after  = Test::Mutation::Result->new( $current->%*, %$newer );
        is refaddr( Test::Mutation::Merge::refresh( $before, $after ) ), refaddr($after),
          "returns the current scope and evidence for $label";
    }
    isa_ok dies { Test::Mutation::Merge::refresh( $prior, {} ) }, ['Error::TypeTiny'],
      'the refresh boundary requires two measured results';
};

done_testing;
