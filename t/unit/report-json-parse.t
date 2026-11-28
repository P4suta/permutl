use v5.36;
use Test2::V0;
use lib 't/lib';
use Raised;
use Test::Mutation::Mutant;
use Test::Mutation::Report::Json;
use Test::Mutation::Result;
use Test::Mutation::Status;

my $source = "sub is_positive {\n    my (\$n) = \@_;\n    return \$n > 0 ? 1 : 0;\n}\n";

sub entry ( $status, %fields ) {
    my $mutant = Test::Mutation::Mutant->new(
        id          => delete $fields{id},
        path        => 'lib/Calc.pm',
        mutator     => 'comparison',
        start       => 50,
        end         => 51,
        original    => q{>},
        replacement => q{>=},
        description => 'replaced > with >=',
        from        => [ 3, 15 ],
        to          => [ 3, 16 ],
        scope       => [ 2, 3 ],
        suppressed  => $status eq 'Ignored' ? 1 : 0,
        comparable  => $status eq 'Pending' ? 0 : 1,
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
    sources => { 'lib/Calc.pm' => $source },
    tests   => [ { name => 't/sign.t', duration => 0.5 } ],
    entries => [
        entry(
            'Killed',
            id         => '000000000001',
            by         => 't/sign.t',
            covered_by => ['t/sign.t'],
            tests_run  => 1,
            duration   => 0.25
        ),
        entry( 'Ignored', id => '000000000002', detail => 'suppressed by a comment' ),
        entry( 'Pending', id => '000000000003' ),
    ],
    problems          => [ { path => 'lib/Odd.pm', problem => 'the file has carriage returns' } ],
    warnings          => ['t/direct.t loads lib/Direct.pm around the hook and cannot detect its mutants'],
    baseline_failures => [ { test => 't/broken.t', output => 'not ok 1', errors => 'died' } ],
    jobs              => 3,
    parallel_safe     => 0,
    interrupted       => 'INT',
    reused            => 2,
    shard             => '2/4',
    inventory         => { mutants => 12, digest => 'ab' x 32 },
    started           => 100,
    finished          => 103.5,
    stats             =>
      { copies => 1, walks => 2, compiles => 3, spawns => 4, listings => 5, baseline_tests => 6, verifications => 7 },
);
my $text = Test::Mutation::Report::Json::render( $result, high => 80, low => 60 );
my $back = Test::Mutation::Report::Json::parse($text);

is Test::Mutation::Report::Json::document( $back, high => 80, low => 60 ),
  Test::Mutation::Report::Json::document( $result, high => 80, low => 60 ),
  'the rebuilt result renders the same document';

my ( $killed, $ignored, $pending ) = map { $_->{mutant} } $back->entries->@*;
is [ $killed->start, $killed->end, $killed->original, $killed->path ], [ 50, 51, q{>}, 'lib/Calc.pm' ],
  'the span and the original text come from the source in the report';
is [ map { [ $_->suppressed, $_->comparable ] } $killed, $ignored, $pending ], [ [ 0, 1 ], [ 1, 1 ], [ 0, 0 ] ],
  'the flags of each mutant';
is $back->entries->[0], hash { field by => 't/sign.t'; field duration => 0.25; field tests_run => 1; etc },
  'the deciding test, the duration, and the test count';
is $back->baseline_failures, [ { test => 't/broken.t', output => q{}, errors => q{} } ],
  'a failing test of the unmodified run keeps its name';
is $back->sources, { 'lib/Calc.pm' => $source }, 'the sources';
is $back->stats, $result->stats, 'the work of the run';

subtest 'an inconclusive verdict keeps the test that decided its reason' => sub {
    for my $status (qw(Timeout NoVerdict CompileError)) {
        my $original = Test::Mutation::Result->new( $result->%*,
            entries => [ entry( $status, id => '000000000001', by => 't/sign.t' ) ] );
        my $json = Test::Mutation::Report::Json::render( $original, high => 80, low => 60 );
        is Test::Mutation::Report::Json::parse($json)->entries->[0]{by}, 't/sign.t',
          "the JSON report keeps the deciding test for $status";
        unlike $json, qr/"killedBy"/, 'only a detecting test occupies the schema detection field';
    }
};

like Raised::message( sub { Test::Mutation::Report::Json::parse('{') } ), qr/\Athe text is no JSON document/,
  'broken JSON is refused';
like Raised::message(
    sub { Test::Mutation::Report::Json::parse('{"schemaVersion":"2","thresholds":{"high":80,"low":60},"files":{}}') } ),
  qr/\Athe report holds no facts of a mutation run\z/, 'a report of another tool is refused';

like dies { Test::Mutation::Report::Json::parse(undef) }, qr/did not pass type constraint "Str"/,
  'the text is a string';

sub refusal ($change) {
    my $changed = $change->($text);
    die 'the change matches nothing' if $changed eq $text;
    return Raised::message( sub { Test::Mutation::Report::Json::parse($changed) } );
}

subtest 'conflicting JSON fields are refused before deciding a verdict' => sub {
    for my $change ( sub ($t) { $t =~ s/"jobs" : 3/"jobs" : 1, "jobs" : 3/r },
        sub ($t) { $t =~ s/"status" : "Killed"/"status" : "Survived", "status" : "Killed"/r } )
    {
        is refusal($change), 'the report is malformed: a JSON object repeats a field name',
          'a repeated field has no unambiguous value';
    }
};

subtest 'a truncated mutant identifier is rejected as a malformed report' => sub {
    my $changed = $text =~ s/"id" : "000000000001"/"id" : "1234abcd"/r;
    my $error   = dies { Test::Mutation::Report::Json::parse($changed) };
    isa_ok $error, ['Test::Mutation::Error'], 'the parser raises a report error' or return;
    is [ $error->kind, $error->id ], [qw(usage report-malformed)], 'the error identifies an invalid saved report';
    like $error->message,   qr/"1234abcd"/,          'the reason identifies the rejected value';
    unlike $error->message, qr/\n| at \S+ line \d+/, 'the public message omits the internal source location';
};

subtest 'a value of the wrong type is refused with its place in the report' => sub {
    my $mutant = q{->{"files"}->{"lib/Calc.pm"}->{"mutants"}->[0]};
    my %cases  = (
        'a count that is no number' =>
          [ sub ($t) { $t =~ s/"jobs" : 3/"jobs" : "many"/r }, q{->{"testMutation"}->{"jobs"}} ],
        'a run without a test process' =>
          [ sub ($t) { $t =~ s/"jobs" : 3/"jobs" : 0/r }, q{->{"testMutation"}->{"jobs"}} ],
        'a count that is missing' => [ sub ($t) { $t =~ s/"jobs" : 3,//r }, q{->{"testMutation"}->{"jobs"}} ],
        'an unknown status'       =>
          [ sub ($t) { $t =~ s/"status" : "Killed"/"status" : "Eaten"/r }, $mutant . q{->{"status"}} ],
        'an unknown status of the run' => [
            sub ($t) {
                $t =~ s/("reason" : "interrupted",\s+"scope" : \[[^\]]*\],\s+"status" : )"Pending"/$1"Waiting"/r;
            },
            q{->{"files"}->{"lib/Calc.pm"}->{"mutants"}->[2]->{"testMutation"}->{"status"}}
        ],
        'a status of the schema that differs from the status of the run' =>
          [ sub ($t) { $t =~ s/"status" : "Killed"/"status" : "Survived"/r }, $mutant ],
        'a reason of another status' =>
          [ sub ($t) { $t =~ s/"reason" : "suppressed"/"reason" : "interrupted"/r }, $mutant =~ s/0\]\z/1]/r ],
        'a status without its reason' =>
          [ sub ($t) { $t =~ s/"reason" : "interrupted"/"reason" : null/r }, $mutant =~ s/0\]\z/2]/r ],
        'an unknown reason' => [
            sub ($t) { $t =~ s/"reason" : "suppressed"/"reason" : "bored"/r },
            q{->{"files"}->{"lib/Calc.pm"}->{"mutants"}->[1]->{"testMutation"}->{"reason"}}
        ],
        'a line that is no number' =>
          [ sub ($t) { $t =~ s/"line" : 3/"line" : "third"/r }, $mutant . q{->{"location"}->{"end"}->{"line"}} ],
        'an unknown signal' => [
            sub ($t) { $t =~ s/"interrupted" : "INT"/"interrupted" : "USR1"/r },
            q{->{"testMutation"}->{"interrupted"}}
        ],
        'a part without a number' =>
          [ sub ($t) { $t =~ s{"shard" : "2/4"}{"shard" : "second"}r }, q{->{"testMutation"}->{"shard"}} ],
        'a digest of another length' => [
            sub ($t) { $t =~ s/"digest" : "(?:ab){32}"/"digest" : "abab"/r },
            q{->{"testMutation"}->{"inventory"}->{"digest"}}
        ],
        'a warning that is no text' => [
            sub ($t) { $t =~ s/"warnings" : \[/"warnings" : [ "first", {},/r },
            q{->{"testMutation"}->{"warnings"}->[1]}
        ],
        'a count of work that is negative' =>
          [ sub ($t) { $t =~ s/"spawns" : 4/"spawns" : -4/r }, q{->{"testMutation"}->{"stats"}->{"spawns"}} ],
        'a count of work that is missing' =>
          [ sub ($t) { $t =~ s/"listings" : 5,//r }, q{->{"testMutation"}->{"stats"}->{"listings"}} ],
    );
    for my $name ( sort keys %cases ) {
        my ( $change, $place ) = $cases{$name}->@*;
        is refusal($change), "the report is malformed: no valid value at \$report$place", $name;
    }
};

subtest 'a location outside the source is refused' => sub {
    my %cases = (
        'a line after the last one' =>
          [ sub ($t) { $t =~ s/"line" : 3/"line" : 6/r }, 'a location lies outside the source of lib/Calc.pm' ],
        'a column after the end of the text' =>
          [ sub ($t) { $t =~ s/"line" : 3/"line" : 5/r }, 'a location lies outside the source of lib/Calc.pm' ],
        'a column that points into the next line' =>
          [ sub ($t) { $t =~ s/"column" : 16/"column" : 28/r }, 'a location lies outside the source of lib/Calc.pm' ],
        'an end before its start' =>
          [ sub ($t) { $t =~ s/"column" : 16/"column" : 2/r }, 'a location ends before its start in lib/Calc.pm' ],
    );
    for my $name ( sort keys %cases ) {
        my ( $change, $reason ) = $cases{$name}->@*;
        is refusal($change), "the report is malformed: $reason", $name;
    }
};

sub read_back (%fields) {
    my $written = Test::Mutation::Result->new(
        root              => '/project',
        sources           => { 'lib/Calc.pm' => $source },
        tests             => [],
        entries           => [],
        problems          => [],
        warnings          => [],
        baseline_failures => [],
        jobs              => 1,
        parallel_safe     => 1,
        started           => 1,
        finished          => 2,
        %fields,
    );
    return Test::Mutation::Report::Json::parse(
        Test::Mutation::Report::Json::render( $written, high => 80, low => 60 ) );
}

subtest 'a saved cache disagreement prevents a passing score gate' => sub {
    my $detected =
      entry( 'Killed', id => '000000000001', by => 't/sign.t', covered_by => ['t/sign.t'], tests_run => 1 );
    my %measured = (
        entries   => [$detected],
        tests     => [ { name => 't/sign.t', duration => 1 } ],
        min_score => 100,
    );
    my $success  = read_back(%measured)->assessment;
    my $mismatch = read_back( %measured, cache_mismatch => 1 )->assessment;
    is [ $success->@{qw(score gate exitCode)} ], [ 100, 'passed', 0 ], 'the detected mutant meets the threshold';
    is [ $mismatch->@{qw(score gate exitCode)} ], [ 100, 'unavailable', 4 ],
      'the same tally cannot pass when rechecking the cached verdict disagreed';
};

subtest 'locations at the edges of a source are read, and the entries keep the order of the report' => sub {
    my %text = ( 'lib/Calc.pm' => $source, 'lib/Zero.pm' => "1;\n" );
    my $at   = sub ( $id, $path, $start, $end, $from, $to ) {
        return {
            entry( 'Survived', id => $id )->%*,
            mutant => Test::Mutation::Mutant->new(
                id          => $id,
                path        => $path,
                mutator     => 'statement',
                start       => $start,
                end         => $end,
                original    => substr( $text{$path}, $start, $end - $start ),
                replacement => q{},
                description => 'removed',
                from        => $from,
                to          => $to,
                scope       => [ $from->[0], $to->[0] ],
            ),
        };
    };
    my $length = length $source;
    my $read   = read_back(
        sources => \%text,
        entries => [
            $at->( '00000000000a', 'lib/Zero.pm', 0,           1,       [ 1, 1 ], [ 1, 2 ] ),
            $at->( '00000000000b', 'lib/Calc.pm', 0,           3,       [ 1, 1 ], [ 1, 4 ] ),
            $at->( '00000000000c', 'lib/Calc.pm', $length - 2, $length, [ 4, 1 ], [ 5, 1 ] ),
            $at->( '00000000000d', 'lib/Calc.pm', 4,           4,       [ 1, 5 ], [ 1, 5 ] ),
        ],
    );
    is [ map { [ $_->id, $_->path, $_->start, $_->end, $_->original ] } map { $_->{mutant} } $read->entries->@* ],
      [
        [ '00000000000b', 'lib/Calc.pm', 0,           3,       'sub' ],
        [ '00000000000c', 'lib/Calc.pm', $length - 2, $length, "}\n" ],
        [ '00000000000d', 'lib/Calc.pm', 4,           4,       q{} ],
        [ '00000000000a', 'lib/Zero.pm', 0,           1,       '1' ],
      ],
      'the first character, the end of the text, and a place without width, file by file';
};

subtest 'every status, every reason, and every signal of a result is read back' => sub {
    my @pairs;
    for my $status ( Test::Mutation::Status::rows()->@* ) {
        push @pairs, map { [ $status->name, $_ ] } $status->reasons->@* ? $status->reasons->@* : (undef);
    }
    my $read = read_back(
        entries => [
            map { entry( $pairs[$_][0], id => sprintf( '%012d', $_ ), reason => $pairs[$_][1], detail => "detail $_" ) }
              0 .. $#pairs
        ]
    );
    is [ map { [ $_->@{qw(status reason detail)} ] } $read->entries->@* ],
      [ map { [ $pairs[$_]->@*, "detail $_" ] } 0 .. $#pairs ], 'the statuses, the reasons, and the details';
    is scalar @pairs, 22, 'every status with each of its reasons';
    is [ map { read_back( interrupted => $_ )->interrupted } qw(HUP INT TERM) ], [qw(HUP INT TERM)], 'the signals';
};

done_testing;
