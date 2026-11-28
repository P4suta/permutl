use v5.36;
use Test2::V0;
use Encode ();
use Test::Mutation::Mutant;
use Test::Mutation::Report::GitHub;
use Test::Mutation::Result;
use Test::Mutation::Status;

sub entry ( $status, %fields ) {
    my %mutant = (
        id          => 'abcdefabcdef',
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
        ( $fields{mutant} ? ( delete $fields{mutant} )->%* : () ),
    );
    return {
        mutant     => Test::Mutation::Mutant->new(%mutant),
        status     => $status,
        reason     => Test::Mutation::Status::of($status)->reasons->[0],
        detail     => undef,
        by         => undef,
        covered_by => [],
        tests_run  => 0,
        duration   => 0,
        %fields,
    };
}

sub result ($entries) {
    return Test::Mutation::Result->new(
        root              => '/project',
        sources           => {},
        tests             => [ { name => 't/a.t', duration => 1 } ],
        entries           => $entries,
        problems          => [],
        warnings          => [],
        baseline_failures => [],
        jobs              => 1,
        parallel_safe     => 1,
        started           => 1,
        finished          => 2,
    );
}

subtest 'annotations name the place of each undetected mutant' => sub {
    isa_ok dies { Test::Mutation::Report::GitHub::annotations( {} ) }, ['Error::TypeTiny'],
      'annotation input must be a measurement result';
    my $text = Test::Mutation::Report::GitHub::annotations(
        result(
            [
                entry('Killed'),
                entry('Survived'),
                entry( 'NoCoverage', mutant => { id => '000000000002', from => [ 9, 1 ], to => [ 11, 2 ] } ),
                entry( 'Timeout',    mutant => { id => '000000000003' } ),
                ( map { entry($_) } qw(CompileError NoVerdict Ignored Pending) ),
            ]
        )
    );
    is [ split /\n/, $text ],
      [
        '::warning file=lib/Calc.pm,line=3,col=15,endLine=3,endColumn=16,title=Survived::replaced > with >= (abcdefabcdef)',
        '::warning file=lib/Calc.pm,line=9,col=1,endLine=11,endColumn=2,title=No coverage::replaced > with >= (000000000002)',
        '::notice file=lib/Calc.pm,line=3,col=15,endLine=3,endColumn=16,title=Timeout::replaced > with >= (000000000003)',
      ],
      'one command for each survived, uncovered, and timed-out mutant, titled with the heading of its status';
    is [ grep { defined $_->annotation && !defined $_->heading } Test::Mutation::Status::rows()->@* ], [],
      'every status with an annotation has a heading for its title';
};

subtest 'annotation text is escaped' => sub {
    my $text = Test::Mutation::Report::GitHub::annotations(
        result( [ entry( 'Survived', mutant => { path => 'lib/A,B:C.pm', description => "100% of\nit" } ) ] ) );
    is $text,
      "::warning file=lib/A%2CB%3AC.pm,line=3,col=15,endLine=3,endColumn=16,title=Survived::100%25 of%0Ait (abcdefabcdef)\n",
      'commas and colons in a property, percent signs and line feeds in the message';
};

subtest 'the summary states the score and the count of every status' => sub {
    my $text = Test::Mutation::Report::GitHub::summary(
        result( [ entry('Killed'), entry('Killed'), entry('Survived'), entry('Timeout'), entry('NoVerdict') ] ) );
    like $text, qr/^## Mutation testing$/m,                            'heading';
    like $text, qr/^Score: \*\*66\.7%\*\* \(2 of 3 valid mutants\)$/m, 'score';
    like $text,
      qr/^\| Killed \| Survived \| No coverage \| Timeout \| Compile error \| No verdict \| Ignored \| Pending \|$/m,
      'table heading';
    like $text, qr/^\| --- \| --- \| --- \| --- \| --- \| --- \| --- \| --- \|$/m,    'table rule';
    like $text, qr/^\| 2 \| 1 \| 0 \| 1 \| 0 \| 1 \| 0 \| 0 \|$/m,                    'table row';
    like Test::Mutation::Report::GitHub::summary( result( [] ) ), qr/^Score: none$/m, 'no score without a valid mutant';
    like Test::Mutation::Report::GitHub::summary( result( [ entry('Killed') ] ) ),
      qr/^Score: \*\*100\.0%\*\* \(1 of 1 valid mutant\)$/m, 'one valid mutant';
};

subtest 'the summary names a sample of the gaps and the full report' => sub {
    my @entries;
    for my $status (qw(Survived Timeout)) {
        push @entries,
          map { entry( $status, mutant => { id => sprintf( '%012x', @entries + $_ ), path => 'lib/A|B.pm' } ) } 1 .. 12;
    }
    my $result   = result( \@entries );
    my $commands = Test::Mutation::Report::GitHub::annotations($result);
    is scalar( () = $commands =~ /^::warning /mg ), 10, 'ten warnings';
    is scalar( () = $commands =~ /^::notice /mg ),  10, 'ten notices';
    my $summary = Test::Mutation::Report::GitHub::summary( $result, 85, ['artifacts/mutation.json'] );
    like $summary, qr/Gate: .*85%/,       'the summary includes the threshold decision';
    like $summary, qr/^Undetected: 12$/m, 'the full count excludes timeouts';
    my @sample = $summary =~ /^\| ([0-9a-f]{12}) \|/mg;
    is \@sample, [ map { sprintf '%012x', $_ } 1 .. 5 ], 'the table lists the first five undetected changes in order';
    unlike $summary, qr/00000000000c/,              'the sample leaves room for the report location';
    like $summary,   qr{artifacts/mutation[.]json}, 'the summary names the published file';
    unlike $summary, qr/\| lib\/A\|B[.]pm \|/,      'a pipe in a filename cannot split a table cell';
};

subtest 'the step limit counts encoded bytes' => sub {
    my $huge    = "\x{65e5}" x 400_000;
    my $saved   = result( [ entry( 'Survived', mutant => { description => $huge } ) ] );
    my $summary = Test::Mutation::Report::GitHub::summary( $saved, 90, ['reports/mutation.html'] );
    cmp_ok length( Encode::encode( 'UTF-8', $summary ) ), '<=', 1024 * 1024, 'the Markdown fits one step';
    like $summary, qr/^Undetected: 1$/m,        'the count survives an oversized example';
    like $summary, qr{reports/mutation[.]html}, 'the file location survives an oversized example';
};

subtest 'the sample skips oversized changes and fits as many later rows as the step allows' => sub {
    my $result = result(
        [
            entry('Killed'),
            entry( 'Survived', mutant => { id => '000000000001', description => 'x' x 2000 } ),
            map { entry( 'Survived', mutant => { id => sprintf( '%012x', $_ ), description => "\x{754c}" x 200 } ) }
              2 .. 5
        ]
    );
    my $bytes = 1600;
    my $text  = Test::Mutation::Report::GitHub::summary( $result, 70, [], 1024 * 1024 - $bytes );
    my @rows  = $text =~ /^\| ([0-9a-f]{12}) \|/mg;
    is \@rows, ['000000000002'], 'the first row that fits follows a detected change and an oversized example';
    is scalar( () = $text =~ /^### Undetected changes$/mg ), 1, 'the table has a single heading';
    like $text, qr/^\| ID \| Location \| Change \| Status \|$/m, 'the sample identifies its four columns';
    cmp_ok length( Encode::encode( 'UTF-8', $text ) ), '<=', $bytes, 'every included row uses its encoded byte length';
};

subtest 'large selections reserve room for the gate and report location' => sub {
    my $case = Test::Mutation::Result->new( result( [ entry('Survived') ] )->%*,
        selection => { paths => { ( 'a' x 1200 ) => [] } } );
    my $text = Test::Mutation::Report::GitHub::summary( $case, 70, ['reports/mutation.json'], 1024 * 1024 - 512 );
    cmp_ok length( Encode::encode( 'UTF-8', $text ) ), '<=', 512, 'existing step text uses the same byte budget';
    like $text, qr/Gate: failed/,            'a large selection still shows the gate';
    like $text, qr{reports/mutation[.]json}, 'the destination remains available when paths must be abbreviated';
    my $compact = Test::Mutation::Report::GitHub::summary( $case, 70, ['reports/mutation.json'], 1024 * 1024 - 160 );
    cmp_ok length( Encode::encode( 'UTF-8', $compact ) ), '<=', 160, 'the compact report fits the remaining bytes';
    like $compact, qr/Gate: failed/,            'the threshold decision remains in the compact report';
    like $compact, qr{reports/mutation[.]json}, 'the report path takes precedence over the follow-up command';
};

subtest 'a full step summary needs no measurement traversal' => sub {
    my $case  = result( [ entry('Survived') ] );
    my $tally = Test::Mutation::Result->can('tally');
    my $calls = 0;
    no warnings 'redefine';
    local *Test::Mutation::Result::tally = sub ($self) { $calls++; return $tally->($self) };
    for my $used ( 1024 * 1024, 1024 * 1024 + 1 ) {
        is Test::Mutation::Report::GitHub::summary( $case, 70, [], $used ), q{}, 'the step has no room for text';
    }
    is $calls, 0, 'the occupied summary requires no mutant counts';
};

done_testing;
