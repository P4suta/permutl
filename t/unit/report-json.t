use v5.36;
use Test2::V0;
use JSON::PP ();
use Test::Mutation::Mutant;
use Test::Mutation::Report::Json;
use Test::Mutation::Result;
use Test::Mutation::Status;

my $source = "sub is_positive {\n    my (\$n) = \@_;\n    return \$n > 0 ? 1 : 0;\n}\n";

sub entry ( $status, %fields ) {
    my $id     = delete $fields{id};
    my $mutant = Test::Mutation::Mutant->new(
        id          => defined $id ? $id : 'abcdefabcdef',
        path        => 'lib/Calc.pm',
        mutator     => 'comparison',
        start       => 50,
        end         => 51,
        original    => q{>},
        replacement => q{>=},
        description => 'replaced > with >=',
        from        => [ 3, 15 ],
        to          => [ 3, 16 ],
        scope       => [ 3, 3 ],
    );
    return {
        mutant     => $mutant,
        status     => $status,
        reason     => Test::Mutation::Status::of($status)->reasons->[0],
        detail     => undef,
        by         => undef,
        covered_by => [],
        tests_run  => 0,
        duration   => 0,
        %fields
    };
}

my $result = Test::Mutation::Result->new(
    root    => '/project',
    sources => { 'lib/Calc.pm' => $source, 'lib/Unmutated.pm' => "1;\n" },
    tests   => [ { name => 't/sign.t', duration => 0.5 }, { name => 't/add.t', duration => 0.25 } ],
    entries => [
        entry(
            'Killed',
            id         => '000000000001',
            by         => 't/sign.t',
            detail     => 't/sign.t failed',
            covered_by => [ 't/add.t', 't/sign.t' ],
            tests_run  => 2,
            duration   => 0.75
        ),
        entry( 'Survived',   id => '000000000002', covered_by => ['t/sign.t'], tests_run => 1, duration => 0.5 ),
        entry( 'NoCoverage', id => '000000000003' ),
        entry(
            'Timeout',
            id         => '000000000004',
            by         => 't/sign.t',
            detail     => 't/sign.t exceeded its time limit',
            covered_by => ['t/sign.t'],
            tests_run  => 1,
            duration   => 2
        ),
    ],
    problems          => [],
    warnings          => [],
    baseline_failures => [],
    jobs              => 2,
    parallel_safe     => 1,
    started           => 100,
    finished          => 103.5,
    stats             =>
      { copies => 2, walks => 8, compiles => 3, spawns => 9, listings => 1, baseline_tests => 2, verifications => 0 },
);

my $document = Test::Mutation::Report::Json::document( $result, high => 80, low => 60 );

subtest 'the report retains the assessment and its threshold' => sub {
    my $gated      = Test::Mutation::Result->new( $result->%*, min_score => 80 );
    my $text       = Test::Mutation::Report::Json::render( $gated, high => 90, low => 50 );
    my $assessment = JSON::PP->new->decode($text)->{testMutation}{assessment};
    is $assessment,         $gated->assessment, 'the JSON decision and counts are the values returned by the API';
    is $assessment->{gate}, 'failed',           'the requested minimum decides the gate';
    is Test::Mutation::Report::Json::parse($text)->assessment, $assessment, 'reading a report restores its threshold';
};

subtest 'a report written before assessments keeps its verdicts and has no score gate' => sub {
    my $saved = Test::Mutation::Report::Json::document( $result, high => 80, low => 60 );
    delete $saved->{testMutation}{assessment};
    my $read = Test::Mutation::Report::Json::parse( JSON::PP->new->encode($saved) );
    is [ map { $_->{status} } $read->entries->@* ], [qw(Killed Survived NoCoverage Timeout)],
      'every saved verdict can still be read';
    is $read->tally, $result->tally, 'the score is computed from the saved verdicts';
    is [ $read->assessment->@{qw(minimum gate exitCode)} ], [ undef, undef, 0 ],
      'the display thresholds set no minimum score';
};

subtest 'a writer receives each source file before the next file' => sub {
    my @chunks;
    Test::Mutation::Report::Json::stream(
        $result,
        high  => 80,
        low   => 60,
        write => sub ($chunk) { push @chunks, $chunk }
    );
    is JSON::PP->new->decode( join q{}, @chunks ), $document, 'streamed JSON carries every result field';
    my @files = grep { /"language"\s*:\s*"perl"/ } @chunks;
    is scalar @files, 2, 'each source is written separately';
    like $files[0], qr{lib/Calc[.]pm},      'the populated source comes first';
    like $files[1], qr{lib/Unmutated[.]pm}, 'the unmutated source comes second';
};

subtest 'the writer can consume the first mutant before the rest of a large file is built' => sub {
    my @entries        = map { entry( 'Survived', id => sprintf( '%012x', $_ ) ) } 1 .. 256;
    my $large          = Test::Mutation::Result->new( $result->%*, entries => \@entries );
    my $description    = Test::Mutation::Mutant->can('description');
    my $encode         = JSON::PP->can('encode');
    my $perl_encodings = 0;
    my ( $built, $first ) = ( 0, undef );
    no warnings 'redefine';
    local *JSON::PP::encode                    = sub (@args) { $perl_encodings++; return $encode->(@args) };
    local *Test::Mutation::Mutant::description = sub ($self) { $built++;          return $description->($self) };
    Test::Mutation::Report::Json::stream(
        $large,
        high  => 80,
        low   => 60,
        write => sub ($chunk) { $first = $built if !defined $first && $chunk =~ /"id":"000000000001"/ }
    );
    is $built, scalar @entries, 'each mutant was described once';
    ok $perl_encodings < @entries,        'the stream avoids a pure Perl JSON encoding for every mutant';
    ok defined $first && $first < $built, 'the first mutant reached the writer before the last was described';
};

subtest 'the document has the required top-level fields' => sub {
    is $document->{schemaVersion}, '2', 'schema version';
    is $document->{thresholds}, { high => 80, low => 60 }, 'thresholds';
    is Test::Mutation::Report::Json::document( $result, high => 79.5, low => 60.25 )->{thresholds},
      { high => 80, low => 60 },
      'the schema takes whole thresholds, so the report rounds them';
    is $document->{projectRoot}, '/project', 'project root';
    is $document->{framework}, { name => 'Test::Mutation', version => Test::Mutation::Report::Json->VERSION },
      'framework';
    is [ sort keys $document->{files}->%* ], [qw(lib/Calc.pm lib/Unmutated.pm)], 'every analyzed source';
    is $document->{files}{'lib/Unmutated.pm'}, { language => 'perl', source => "1;\n", mutants => [] },
      'an analyzed file can contain no mutations';
};

subtest 'a file carries its language, source, and mutants' => sub {
    my $file = $document->{files}{'lib/Calc.pm'};
    is $file->{language},                         'perl',                             'language';
    is $file->{source},                           $source,                            'source';
    is [ map { $_->{id} } $file->{mutants}->@* ], [ map { "00000000000$_" } 1 .. 4 ], 'mutants in order';
};

subtest 'a mutant maps to the schema' => sub {
    my ( $killed, $survived, $uncovered, $timeout ) = $document->{files}{'lib/Calc.pm'}{mutants}->@*;
    is $killed,
      {
        id             => '000000000001',
        mutatorName    => 'comparison',
        replacement    => '>=',
        description    => 'replaced > with >=',
        location       => { start => { line => 3, column => 15 }, end => { line => 3, column => 16 } },
        status         => 'Killed',
        statusReason   => 't/sign.t failed',
        coveredBy      => [ 't/add.t', 't/sign.t' ],
        killedBy       => ['t/sign.t'],
        testsCompleted => 2,
        duration       => 750,
        static         => JSON::PP::false,
        testMutation   => {
            status     => 'Killed',
            reason     => undef,
            scope      => [ 3, 3 ],
            suppressed => JSON::PP::false,
            comparable => JSON::PP::true
        },
      },
      'a killed mutant';
    ok !exists $survived->{killedBy},     'a survived mutant has no killing test';
    ok !exists $timeout->{killedBy},      'the test that ran into the time limit killed nothing';
    ok !exists $survived->{statusReason}, 'an absent detail is left out';
    is $uncovered->{coveredBy}, [], 'an uncovered mutant has no tests';
    is [ $timeout->@{qw(status statusReason)}, $timeout->{testMutation}->@{qw(status reason)} ],
      [ 'Ignored', 't/sign.t exceeded its time limit', 'Timeout', 'time-limit' ],
      'a timeout is ignored in the schema, and the facts keep its status and its reason';
    is [ $uncovered->{testMutation}->@{qw(status reason)} ], [ 'NoCoverage', 'unreached' ],
      'a mutant without coverage keeps its reason';
};

subtest 'every status writes the name of the schema and keeps its own name and reason' => sub {
    my @rows    = Test::Mutation::Status::rows()->@*;
    my $several = Test::Mutation::Result->new(
        (
            map { $_ => $result->$_ }
              qw(root sources tests problems warnings baseline_failures jobs parallel_safe started finished)
        ),
        entries => [ map { entry( $rows[$_]->name, id => sprintf '%012d', $_ ) } 0 .. $#rows ],
    );
    my @mutants =
      Test::Mutation::Report::Json::document( $several, high => 80, low => 60 )->{files}{'lib/Calc.pm'}{mutants}->@*;
    is [ map { [ $_->{status}, $_->{testMutation}->@{qw(status reason)} ] } @mutants ],
      [
        [ 'Killed',       'Killed',       undef ],
        [ 'Survived',     'Survived',     undef ],
        [ 'NoCoverage',   'NoCoverage',   'unreached' ],
        [ 'Ignored',      'Timeout',      'time-limit' ],
        [ 'CompileError', 'CompileError', 'parse' ],
        [ 'RuntimeError', 'NoVerdict',    'loaded-around-hook' ],
        [ 'Ignored',      'Ignored',      'suppressed' ],
        [ 'Pending',      'Pending',      'interrupted' ],
      ],
      'the schema name, the status of the run, and the reason of each status';
};

subtest 'tests are listed as test files' => sub {
    is $document->{testFiles},
      {
        't/add.t'  => { tests => [ { id => 't/add.t',  name => 't/add.t' } ] },
        't/sign.t' => { tests => [ { id => 't/sign.t', name => 't/sign.t' } ] },
      },
      'one test per file';
};

subtest 'the document carries the facts of the run that the schema has no place for' => sub {
    is $document->{testMutation}, {
        shard            => undef,
        inventory        => undef,
        selection        => {},
        assessment       => $result->assessment,
        jobs             => 2,
        parallelSafe     => JSON::PP::true,
        interrupted      => undef,
        reused           => 0,
        started          => 100,
        finished         => 103.5,
        warnings         => [],
        problems         => [],
        baselineFailures => [],
        tests            => [ { name => 't/sign.t', duration => 0.5 }, { name => 't/add.t', duration => 0.25 } ],
        stats            => {
            copies        => 2,
            walks         => 8,
            compiles      => 3,
            spawns        => 9,
            listings      => 1,
            baselineTests => 2,
            verifications => 0
        },

        compilerInputProtocol => 3,
      },
      'the run facts';
};

subtest 'render writes canonical JSON with numbers as numbers' => sub {
    my $text = Test::Mutation::Report::Json::render( $result, high => 80, low => 60 );
    is JSON::PP->new->decode($text), JSON::PP->new->decode( JSON::PP->new->canonical->encode($document) ),
      'the text decodes to the document';
    like $text, qr/"line"\s*:\s*3\b/,       'a line is a JSON number';
    like $text, qr/"duration"\s*:\s*750\b/, 'a duration is a JSON number';
    like $text, qr/"static"\s*:\s*false\b/, 'static is a JSON boolean';
    is $text, Test::Mutation::Report::Json::render( $result, high => 80, low => 60 ), 'the output is stable';
};

done_testing;
