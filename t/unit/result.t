use v5.36;
use Test2::V0;
use Test::Mutation::Mutant;
use Test::Mutation::Outcome;
use Test::Mutation::Result;
use Test::Mutation::Status;

my $mutant = Test::Mutation::Mutant->new(
    id          => 'abcdefabcdef',
    path        => 'lib/A.pm',
    mutator     => 'arithmetic',
    start       => 0,
    end         => 1,
    original    => q{+},
    replacement => q{-},
    description => 'replaced + with -',
    from        => [ 1, 1 ],
    to          => [ 1, 2 ],
    scope       => [ 1, 1 ],
);

sub entry ( $status, %fields ) {
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

sub result ( $statuses, %fields ) {
    return Test::Mutation::Result->new(
        root              => '/project',
        sources           => { 'lib/A.pm' => 'a + b' },
        tests             => [ { name => 't/a.t', duration => 0.5 } ],
        entries           => [ map { entry($_) } $statuses->@* ],
        problems          => [],
        warnings          => [],
        baseline_failures => [],
        jobs              => 1,
        parallel_safe     => 1,
        started           => 1,
        finished          => 2,
        %fields,
    );
}

subtest 'the supported compiler input protocol identifies which digest a reader can verify' => sub {
    my $protocol = Test::Mutation::Result::supported_compiler_input_protocol();
    isa_ok dies { Test::Mutation::Result::supported_compiler_input_protocol('extra') }, ['Error::TypeTiny'],
      'the protocol depends only on the installed driver';
    my $digest = 'ac' x 32;
    is result( [], measurement_digest => $digest )->verified_measurement_digest, $digest,
      'the current protocol verifies the measured inputs';
    my $future = result( [], compiler_input_protocol => $protocol + 1, measurement_digest => $digest );
    is $future->measurement_digest,          $digest, 'a reader can display a digest written by a newer driver';
    is $future->verified_measurement_digest, undef,   'unknown compiler rules cannot verify the inputs';
};

subtest 'tally' => sub {
    my $tally = result( [qw(Killed Killed Survived Timeout)] )->tally;
    is $tally->{counts}{Killed}, 2, 'killed';
    is $tally->{valid},          3, 'valid';
    ok abs( $tally->{score} - 200 / 3 ) < 1e-9, 'score';
};

subtest 'the public assessment applies the threshold to this scope' => sub {
    my $report = result( [qw(Killed Survived)], min_score => 75 );
    isa_ok dies { Test::Mutation::Outcome::assessment( $report, 'unavailable' ) }, ['Error::TypeTiny'],
      'an assessment rejects a nonnumeric minimum score';
    is $report->assessment,
      { $report->tally->%*, minimum => 75, outcome => 'measured', gate => 'failed', exitCode => 1 },
      'the API includes the same tally and exit status as the command';
    my $part = result( ['Survived'], min_score => 75, shard => '1/2' )->assessment;
    is [ $part->@{qw(score gate exitCode)} ], [ 0, 'deferred until merge', 0 ],
      'a shard records its deferred threshold';
};

subtest 'an assessment decides and reports from one count of the entries' => sub {
    my $report = result( [qw(Killed Survived)], min_score => 60 );
    my $tally  = Test::Mutation::Result->can('tally');
    my $calls  = 0;
    no warnings 'redefine';
    local *Test::Mutation::Result::tally = sub ($self) { $calls++; return $tally->($self) };
    my $assessment = $report->assessment;
    is [ $assessment->{score}, $assessment->{gate}, $calls ], [ 50, 'failed', 1 ],
      'the score that failed the gate comes from the same traversal';
};

subtest 'conclusive' => sub {
    ok result( [qw(Killed Survived)] )->conclusive,       'valid mutants and nothing wrong';
    ok result( [] )->conclusive,                          'no mutant at all';
    ok result( [qw(Ignored Ignored)] )->conclusive,       'every mutant suppressed';
    ok !result( [qw(Killed NoVerdict)] )->conclusive,     'a mutant without a verdict';
    ok !result( [qw(Timeout CompileError)] )->conclusive, 'mutants ran and none is valid';
    isa_ok dies { result( ['Killed'] )->invalid_entry('extra') }, ['Error::TypeTiny'],
      'a result checks the arguments of its invalid entry lookup';
    for my $cause (qw(parse compile-phase standalone)) {
        my $result = result( [], entries => [ entry('Killed'), entry( 'CompileError', reason => $cause ) ] );
        is $result->conclusive, $cause eq 'parse' ? 0 : 1, "a measured result with a $cause error";
        is defined $result->invalid_entry ? 1 : 0, $cause eq 'parse' ? 1 : 0, 'only a generator defect is invalid';
    }
    ok !result( ['Killed'], baseline_failures => [ { test => 't/a.t', output => q{}, errors => q{} } ] )->conclusive,
      'the unmodified run failed';
};

subtest 'a cached disagreement or an unanalyzed source makes a scored run inconclusive' => sub {
    isa_ok dies { Test::Mutation::Outcome::of( {}, 0 ) }, ['Error::TypeTiny'], 'a decision requires a measured result';
    for my $mismatch ( 0, 1 ) {
        for my $unparsed ( 0, 1 ) {
            my $report = result(
                ['Killed'],
                cache_mismatch => $mismatch,
                problems       => $unparsed ? [ { path => 'lib/Incomplete.pm', problem => 'unreadable source' } ] : []
            );
            my $tally = Test::Mutation::Result->can('tally');
            my $calls = 0;
            no warnings 'redefine';
            local *Test::Mutation::Result::tally = sub ($self) { $calls++; return $tally->($self) };
            my $decision = Test::Mutation::Outcome::of( $report, 0 );
            is [ $decision->{name}, $decision->{exit}->name ],
              $mismatch || $unparsed ? [qw(inconclusive inconclusive)] : [qw(measured success)],
              "cache mismatch $mismatch and source problem $unparsed decide the whole measurement";
            is $calls, $mismatch || $unparsed ? 0 : 1,
              "cache mismatch $mismatch and source problem $unparsed determine whether a score is needed";
        }
    }
};

subtest 'construction checks the entries' => sub {
    my $made = sub (@entries) {
        return dies { result( [], entries => \@entries ) };
    };
    like $made->( { entry('Killed')->%*, status => 'Dead' } ), qr/entries/, 'an unknown status is refused';
    like $made->( { entry('Killed')->%*, status => 'RuntimeError' } ), qr/entries/,
      'and so is a name of the schema alone';
    like $made->( entry( 'Timeout', reason => undef ) ),        qr/entries/, 'a timeout without its reason';
    like $made->( entry( 'Timeout', reason => 'unreached' ) ),  qr/entries/, 'a reason of another status';
    like $made->( entry( 'Killed',  reason => 'time-limit' ) ), qr/entries/, 'a killed mutant with a reason';
    is $made->( entry( 'NoVerdict', reason => 'project-changed', detail => 't/a.t fails without a mutant' ) ), undef,
      'a reason of the status, with a detail';
};

subtest 'the work of a run' => sub {
    my %none = map { $_ => 0 } qw(copies walks compiles spawns listings baseline_tests verifications);
    is result( [] )->stats, \%none, 'a result that names no work counts none';
    my %some = ( %none, spawns => 4, walks => 6 );
    is result( [], stats => \%some )->stats, \%some, 'a result keeps the counts that it names';
    like dies { result( [], stats => { %none, turns  =>  3 } ) }, qr/stats/, 'a count of another name is refused';
    like dies { result( [], stats => { %none, spawns => -1 } ) }, qr/stats/, 'a negative count is refused';
};

done_testing;
