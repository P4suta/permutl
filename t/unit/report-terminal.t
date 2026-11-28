use v5.36;
use Test2::V0;
use Test::Mutation::Mutant;
use Test::Mutation::Report::GitHub;
use Test::Mutation::Report::Results;
use Test::Mutation::Report::Terminal;
use Test::Mutation::Result;
use Test::Mutation::Source;
use Test::Mutation::Status;

my $source = "sub is_positive {\n    my (\$n) = \@_;\n    return \$n > 0 ? 1 : 0;\n}\n";

sub mutant (%fields) {
    return Test::Mutation::Mutant->new(
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
        %fields,
    );
}

sub entry ( $status, %fields ) {
    return {
        mutant     => mutant(),
        status     => $status,
        reason     => Test::Mutation::Status::of($status)->reasons->[0],
        detail     => undef,
        by         => undef,
        covered_by => ['t/sign.t'],
        tests_run  => 1,
        duration   => 0.1,
        %fields,
    };
}

sub result ( $entries, %fields ) {
    return Test::Mutation::Result->new(
        root              => '/project',
        sources           => { 'lib/Calc.pm' => $source },
        tests             => [ { name => 't/sign.t', duration => 0.5 } ],
        entries           => $entries,
        problems          => [],
        warnings          => [],
        baseline_failures => [],
        jobs              => 2,
        parallel_safe     => 1,
        started           => 100,
        finished          => 103.5,
        %fields,
    );
}

subtest 'the summary counts every status and states the score' => sub {
    my $text = Test::Mutation::Report::Terminal::render(
        result( [ entry('Killed'), entry('Killed'), entry('Survived'), entry('Timeout') ] ),
        color => 0 );
    like $text, qr/^4 mutants: 2 killed, 1 survived, 1 timeout$/m, 'counts leave out statuses with no mutant';
    like $text, qr/^Score: 66\.7% \(2 of 3 valid mutants\)$/m,     'score';
    like $text, qr/^Timeouts are inconclusive and count toward neither side\.$/m, 'the timeout note';
    like $text, qr/^1 test, 2 jobs, 3\.5 s$/m,                                    'the run facts';
};

subtest 'the scope and the gaps precede their evidence' => sub {
    my $selected = result( [ entry('Survived'), entry('NoCoverage') ],
        selection => { paths => { 'lib/Calc.pm' => [ [ 3, 3 ], [ 8, 10 ] ] } } );
    my $text = Test::Mutation::Report::Terminal::render( $selected, color => 0 );
    like $text, qr{\AScope: lib/Calc[.]pm:3,8-10\nUndetected: 2\n},
      'the heading identifies the measured lines and gap count';
    like $text, qr{reached by t/sign.t\n    Recheck: mutation run --mutant abcdefabcdef},
      'the command follows the test evidence';
    like $text, qr{Exercise the mutated line in a test}, 'an uncovered change suggests how to reach it';
    my $since = result( [], selection => { since => 'HEAD~2' } );
    like Test::Mutation::Report::Terminal::render( $since, color => 0 ), qr/\AScope: changes since HEAD~2\n/,
      'the revision stays visible';
};

subtest 'the summary of a part names the part and the size of the whole run' => sub {
    my %part = ( shard => '2/4', inventory => { mutants => 7, digest => 'ab' x 32 } );
    my $text =
      Test::Mutation::Report::Terminal::render( result( [ entry('Killed'), entry('Survived') ], %part ), color => 0 );
    like $text, qr{\AScope: shard 2/4 of configured sources\n}, 'the heading identifies the measured shard';
    like $text, qr/^2 mutants: 1 killed, 1 survived\nPart 2 of 4 of a run with 7 mutants\.\nScore: /m,
      'the part follows the counts';
    unlike Test::Mutation::Report::Terminal::render( result( [ entry('Killed') ] ), color => 0 ), qr/^Part /m,
      'a whole run names no part';
    unlike Test::Mutation::Report::Terminal::render( result( [ entry('Killed') ], shard => '2/4' ), color => 0 ),
      qr/^Part /m,
      'a part without an inventory names no part either';
};

subtest 'a survived mutant shows its place, change, and tests' => sub {
    my $text = Test::Mutation::Report::Terminal::render( result( [ entry('Survived') ] ), color => 0 );
    like $text, qr/^lib\/Calc[.]pm$/m, 'source section heading';
    like $text, qr/^  abcdefabcdef  lib\/Calc[.]pm:3:15  comparison  replaced > with >=  \[Survived\]$/m,
      'place, description, identifier';
    like $text, qr/^    -     return \$n > 0 \? 1 : 0;$/m,   'the original line';
    like $text, qr/^    \+     return \$n >= 0 \? 1 : 0;$/m, 'the mutated line';
    like $text, qr/^    reached by t\/sign\.t$/m,            'the tests that reached it';
    my $missing =
      Test::Mutation::Report::Terminal::render( result( [ entry('Survived') ], sources => {} ), color => 0 );
    like $missing, qr{\[Survived\]\n    reached by t/sign[.]t$}m,
      'the coverage evidence follows the heading when source text is unavailable';
};

subtest 'many changes to one source share its lines' => sub {
    my $sources = Test::Mutation::Result->can('sources');
    my @reads;
    for my $count ( 1, 64 ) {
        my $result = result( [ map { entry('Survived') } 1 .. $count ] );
        my $reads  = 0;
        no warnings 'redefine';
        local *Test::Mutation::Result::sources = sub ($self) { $reads++; return $sources->($self) };
        my $text = Test::Mutation::Report::Terminal::render( $result, color => 0 );
        is scalar( () = $text =~ /Recheck: mutation run --mutant/g ), $count, 'every change has a recheck command';
        push @reads, $reads;
    }
    is $reads[1], $reads[0], 'source reads depend on files rather than mutant count';
};

subtest 'the changed line matches a literal edit for each shape of span' => sub {
    my $mixed = "ab\x{e9}\r\n\nlast";
    for my $case (
        [ $mixed,   0,  0,  "\n" ],
        [ $mixed,   1,  7,  "X\nY\nZ" ],
        [ $mixed,   3,  6,  q{} ],
        [ $mixed,   4,  5,  '!' ],
        [ $mixed,   10, 10, '?' ],
        [ "\nlast", 0,  0,  'first' ]
      )
    {
        my ( $text, $start, $end, $replacement ) = @$case;
        my $document = Test::Mutation::Source->new( path => 'lib/Calc.pm', text => $text, encoding => 'UTF-8' );
        my $from     = $document->position_of($start);
        my $edit     = mutant(
            start       => $start,
            end         => $end,
            from        => $from,
            to          => $document->position_of($end),
            original    => substr( $text, $start, $end - $start ),
            replacement => $replacement
        );
        my $report = Test::Mutation::Report::Terminal::render(
            result( [ entry( 'Survived', mutant => $edit ) ], sources => { 'lib/Calc.pm' => $text } ),
            color => 0 );
        my $changed  = $document->replace_span( $start, $end, $replacement );
        my $index    = $from->[0] - 1;
        my $before   = ( split /\n/, $text,    -1 )[$index];
        my $after    = ( split /\n/, $changed, -1 )[$index];
        my $ellipsis = $edit->original =~ /\n/ ? ' ...' : q{};
        like $report, qr{^    - \Q$before$ellipsis\E\n    \+ \Q$after\E\n    reached by t/sign[.]t$}m,
          "the preview matches editing $start to $end";
    }
};

subtest 'a mutant that spans lines shows its first line' => sub {
    my $body = mutant(
        start       => 17,
        end         => 63,
        original    => substr( $source, 17, 46 ),
        replacement => "\n\n\n",
        description => 'removed the body of is_positive',
        from        => [ 1, 18 ],
        to          => [ 4, 1 ],
        scope       => [ 1, 4 ]
    );
    my $text =
      Test::Mutation::Report::Terminal::render( result( [ entry( 'Survived', mutant => $body ) ] ), color => 0 );
    like $text, qr/^    - sub is_positive \{ \.\.\.$/m, 'the first original line with an ellipsis';
    like $text, qr/^    \+ sub is_positive \{$/m,       'the first mutated line';
};

subtest 'sections appear for the statuses that need attention' => sub {
    my $text = Test::Mutation::Report::Terminal::render(
        result(
            [
                entry('Killed'),
                entry( 'NoCoverage', covered_by => [] ),
                entry( 'NoVerdict',  detail     => 't/a.t loaded the target without the hook' ),
                ( map { entry($_) } qw(CompileError Ignored Pending) ),
            ]
        ),
        color => 0,
    );
    unlike $text, qr/^Killed \(/m,                                       'killed mutants are not listed';
    like $text,   qr/\[NoCoverage\]$/m,                                  'no coverage section';
    like $text,   qr/^    reached by no test$/m,                         'a mutant without tests says so';
    like $text,   qr/\[NoVerdict\]$/m,                                   'a section for the mutants without a verdict';
    like $text,   qr/^    t\/a\.t loaded the target without the hook$/m, 'the sentence about the case';
    like $text,   qr/^    parse$/m,                                      'the reported compile error names its cause';
    is [ $text =~ /^  abcdefabcdef  [^\n]*  \[(\w+)\]$/mg ], [qw(NoCoverage NoVerdict CompileError)],
      'the statuses without a heading in the catalog have no section';
    like $text, qr/^6 mutants: 1 killed, 1 no coverage, 1 compile error, 1 no verdict, 1 ignored, 1 pending$/m,
      'the summary counts every status in the order of the catalog';
};

subtest 'warnings, problems, and baseline failures are reported' => sub {
    my $text = Test::Mutation::Report::Terminal::render(
        result(
            [],
            warnings          => ['the tests fail when they run side by side'],
            problems          => [ { path => 'lib/Odd.pm', problem => 'the file has carriage returns' } ],
            baseline_failures => [ { test => 't/broken.t', output  => "1..1\nnot ok 1\n", errors => "# failed\n" } ],
        ),
        color => 0,
    );
    like $text,   qr/^The unmodified run fails, so no mutant ran\.$/m,        'the baseline failure heading';
    like $text,   qr/^  t\/broken\.t$/m,                                      'the failing test';
    like $text,   qr/^    not ok 1$/m,                                        'its output';
    like $text,   qr/^    # failed$/m,                                        'its errors';
    like $text,   qr/^warning: the tests fail when they run side by side$/m,  'a warning';
    like $text,   qr/^skipped lib\/Odd\.pm: the file has carriage returns$/m, 'a skipped file';
    unlike $text, qr/^Score:/m,                                               'no score without a measurement';
};

subtest 'a failing unmodified run shows the lines that explain the failure' => sub {
    my $output =
      "ok 1 - loads\n    ok 1 - inner step\n    1..1\nok 2 - a subtest\nnot ok 3 - adds\nok 4 # skip no network\n1..4\n";
    my $text = Test::Mutation::Report::Terminal::render(
        result(
            [], baseline_failures => [ { test => 't/add.t', output => $output, errors => "#   Failed test 'adds'\n" } ]
        ),
        color => 0
    );
    is $text,
      "Scope: configured sources\nUndetected: unknown (original tests failed)\nResult: baseline-failed\n\nThe unmodified run fails, so no mutant ran.\n  t/add.t\n    not ok 3 - adds\n    1..4\n    #   Failed test 'adds'\n\nNext: mutation baseline\n",
      'the passing assertions and the plan of a subtest are left out';

    my $copied = Test::Mutation::Report::Terminal::render(
        result(
            [],
            in_copies         => 1,
            baseline_failures => [ { test => 't/add.t', output => "not ok 1\n", errors => q{} } ]
        ),
        color => 0
    );
    is $copied,
      "Scope: configured sources\nUndetected: unknown (original tests failed)\nResult: baseline-failed\n\nThe unmodified run fails, so no mutant ran.\n  t/add.t\n    not ok 1\n"
      . "The tests ran in a copy of the project, which holds no .git directory.\n"
      . "--in-place runs them in the project itself.\n\nNext: mutation baseline\n",
      'a run in copies names the other place for the tests';

    my $limited = Test::Mutation::Report::Terminal::render(
        result(
            [],
            baseline_failures => [ { test => 't/slow.t', output => "1..1\n", errors => q{}, reason => 'time-limit' } ]
        ),
        color => 0
    );
    is $limited,
      "Scope: configured sources\nUndetected: unknown (original tests failed)\nResult: baseline-failed\n\nThe unmodified run fails, so no mutant ran.\n  t/slow.t (time-limit)\n    1..1\n\nNext: mutation baseline\n",
      'a test that a limit ended names the reason of the limit';
};

subtest 'color wraps the score when asked' => sub {
    my $plain = Test::Mutation::Report::Terminal::render( result( [ entry('Killed') ] ), color => 0 );
    my $color = Test::Mutation::Report::Terminal::render( result( [ entry('Killed') ] ), color => 1 );
    unlike $plain, qr/\e\[/,                  'no escape sequence without color';
    like $color,   qr/\e\[32mScore: 100\.0%/, 'a full score is green';
};

subtest 'the whole report keeps its order' => sub {
    my $text = Test::Mutation::Report::Terminal::render(
        result(
            [
                entry('Killed'),
                entry( 'Survived',   covered_by => [qw(t/a.t t/b.t t/c.t t/d.t t/e.t)] ),
                entry( 'NoCoverage', covered_by => [] ),
                entry( 'Timeout',    detail     => 'slow' ),
            ],
            warnings    => [ 'first warning', 'second warning' ],
            problems    => [ { path => 'lib/Bad.pm', problem => 'unreadable' } ],
            interrupted => 'INT',
            reused      => 2,
        ),
        color => 0,
    );
    my $change = "    -     return \$n > 0 ? 1 : 0;\n    +     return \$n >= 0 ? 1 : 0;\n";
    my $place  = '  abcdefabcdef  lib/Calc.pm:3:15  comparison  replaced > with >=';
    is $text,
      join( "\n",
        "Scope: configured sources\nUndetected: 2 observed before interruption\nResult: interrupted\n",
        "4 mutants: 1 killed, 1 survived, 1 no coverage, 1 timeout\nScore: 33.3% (1 of 3 valid mutants)\n"
          . "Timeouts are inconclusive and count toward neither side.\nThe run was interrupted by SIGINT.\n"
          . "1 test, 2 jobs, 3.5 s, 2 results from the cache\n",
        'lib/Calc.pm',
        "$place  [Survived]\n$change    reached by t/a.t, t/b.t, t/c.t and 2 more\n    Recheck: mutation run --mutant abcdefabcdef",
        "$place  [NoCoverage]\n$change    reached by no test\n    Exercise the mutated line in a test.\n    Recheck: mutation run --mutant abcdefabcdef",
        "$place  [Timeout]\n$change    reached by t/sign.t\n    slow\n",
        'File  Score  Killed  Survived  No coverage  Other',
        'lib/Bad.pm  none  0  0  0  -',
        "lib/Calc.pm  33.3%  1  1  1  1 timeout\n",
        "warning: first warning\nwarning: second warning\nskipped lib/Bad.pm: unreadable\n",
        "Next: rerun the interrupted measurement\n",
      ),
      'outcome, summary, file scores, changes, notes and next step';

    my $failed = Test::Mutation::Report::Terminal::render(
        result(
            [],
            baseline_failures => [
                { test => 't/a.t', output => "not ok 1\n", errors => "died\n" },
                { test => 't/b.t', output => "not ok 2\n", errors => q{} },
            ],
        ),
        color => 0,
    );
    is $failed,
      "Scope: configured sources\nUndetected: unknown (original tests failed)\nResult: baseline-failed\n\nThe unmodified run fails, so no mutant ran.\n  t/a.t\n    not ok 1\n    died\n  t/b.t\n    not ok 2\n\nNext: mutation baseline\n",
      'baseline failures';
};

subtest 'the list of tests is cut after the third' => sub {
    my $listed = sub (@tests) {
        my ($line) = Test::Mutation::Report::Terminal::render( result( [ entry( 'Survived', covered_by => \@tests ) ] ),
            color => 0 ) =~ /^    reached by (.*)$/m;
        return $line;
    };
    is $listed->(qw(t/a.t t/b.t t/c.t)),       't/a.t, t/b.t, t/c.t',            'three tests are listed in full';
    is $listed->(qw(t/a.t t/b.t t/c.t t/d.t)), 't/a.t, t/b.t, t/c.t and 1 more', 'a fourth test is counted';
};

subtest 'the color follows the thresholds at their boundaries' => sub {
    my $at = sub ( $killed, %thresholds ) {
        my @entries = ( ( map { entry('Killed') } 1 .. $killed ), ( map { entry('Survived') } $killed + 1 .. 5 ) );
        my ($code) =
          Test::Mutation::Report::Terminal::render( result( \@entries ), color => 1, %thresholds ) =~ /\e\[(\d+)mScore/;
        return $code;
    };
    is $at->(4),                          32, 'a score at the high threshold is green';
    is $at->(3),                          33, 'a score at the low threshold is yellow';
    is $at->(2),                          31, 'a score below the low threshold is red';
    is $at->( 4, high => 90 ),            33, 'a higher high threshold';
    is $at->( 4, high => 90, low => 85 ), 31, 'a higher low threshold';
    is $at->( 2, high => 50, low => 40 ), 33, 'a lower pair of thresholds';
};

subtest 'the source summary and the next command describe the same survivor' => sub {
    my $report = Test::Mutation::Report::Terminal::render(
        result( [ entry('Killed'), entry('Survived') ] ),
        color => 0,
        floor => 80
    );
    like $report, qr/^Result: measured$/m,                  'the measured outcome';
    like $report, qr/^Gate: .+80%/m,                        'the requested gate';
    like $report, qr/^lib\/Calc[.]pm  50[.]0%  1  1  0  /m, 'the file score, killed, survived and uncovered counts';
    like $report, qr/^  abcdefabcdef  lib\/Calc[.]pm:3:15  comparison  replaced > with >=  \[Survived\]/m,
      'the file details identify the place and mutator';
    like $report, qr/^Next: mutation show abcdefabcdef$/m, 'the command addresses the displayed survivor';
};

subtest 'the terminal and the job summary give the same threshold decision and next step' => sub {
    my $half    = result( [ entry('Survived'), entry('Killed') ] );
    my $empty   = result( [] );
    my $narrow  = result( [], selection => { since => 'HEAD' } );
    my $problem = result( [], problems  => [ { path => 'lib/Missing.pm', problem => 'cannot read the file' } ] );
    my $signal  = result(
        [],
        interrupted       => 'TERM',
        baseline_failures => [ { test => 't/sign.t', output => "not ok 1\n", errors => q{} } ]
    );
    my $show  = 'mutation show abcdefabcdef';
    my $merge = 'merge the shard reports with mutation merge FILE...';
    for my $case (
        [ $half,    50, 'measured',     'passed',              $show ],
        [ $half,    51, 'measured',     'failed',              $show ],
        [ $empty,   0,  'nothing',      'unavailable',         'mutation list' ],
        [ $narrow,  0,  'nothing',      'no mutants selected', 'mutation list' ],
        [ $problem, 0,  'inconclusive', 'unavailable', 'resolve the reported source problems and rerun mutation' ],
        [ $signal,  0,  'interrupted',  'unavailable', 'rerun the interrupted measurement' ],
        [ result( [ entry('Killed') ], shard => '1/2' ), 100, 'measured', 'deferred until merge', $merge ],
        [ result( [], shard => '2/2' ),                  100, 'nothing',  'deferred until merge', $merge ],
      )
    {
        my ( $result, $floor, $outcome, $gate, $next ) = @$case;
        for my $text (
            Test::Mutation::Report::Terminal::render( $result, color => 0, floor => $floor ),
            Test::Mutation::Report::GitHub::summary( $result, $floor ),
          )
        {
            is [ $text =~ /^(?:Result|Gate|Next): (.*)$/mg ],
              [ $outcome, "$gate (minimum $floor%)", $next ],
              "the $outcome report gives the $gate decision with its next step";
        }
    }
};

subtest 'the file table keeps empty sources and source problems alongside measured files' => sub {
    my $killed  = entry('Killed');
    my $problem = { path => 'lib/Missing.pm', problem => 'cannot read the file' };
    my $result  = result(
        [$killed],
        sources  => { 'lib/Calc.pm' => $source, 'lib/Empty.pm' => q{} },
        problems => [ $problem, $problem, { %$problem, path => 'lib/Calc.pm' } ],
    );
    is Test::Mutation::Report::Results::files($result),
      [
        { path => 'lib/Calc.pm',    entries => [$killed], cells => [ 'lib/Calc.pm',    '100.0%', 1, 0, 0, '-' ] },
        { path => 'lib/Empty.pm',   entries => [],        cells => [ 'lib/Empty.pm',   'none',   0, 0, 0, '-' ] },
        { path => 'lib/Missing.pm', entries => [],        cells => [ 'lib/Missing.pm', 'none',   0, 0, 0, '-' ] },
      ],
      'each path has one row with its own data';
};

subtest 'report formatting checks inputs at the public boundary' => sub {
    my $result = result( [] );
    isa_ok dies { Test::Mutation::Report::Results::heading($result) }, ['Error::TypeTiny'],
      'a heading requires a mutant';
    isa_ok dies { Test::Mutation::Report::Results::files( [] ) }, ['Error::TypeTiny'], 'file rows require a result';
    isa_ok dies { Test::Mutation::Report::Results::columns('extra') }, ['Error::TypeTiny'],
      'columns takes no arguments';
    isa_ok dies { Test::Mutation::Report::Results::decision( $result, 50, 80 ) }, ['Error::TypeTiny'],
      'a decision takes a single threshold';
    isa_ok dies { Test::Mutation::Report::Results::next_step( $result, 'invalid' ) }, ['Error::TypeTiny'],
      'a next step checks its threshold';
};

done_testing;
