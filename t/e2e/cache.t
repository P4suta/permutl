use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use lib 't/e2e/lib';
use Fixture qw(copy_of run_fixture statuses write_file);
use Test::Mutation::Report::Terminal;
use Test::Mutation::Store;

my $root     = copy_of('calc');
my ($first)  = run_fixture($root);
my $measured = grep { $_->{status} =~ /\A(?:Killed|Survived|NoCoverage)\z/ } $first->entries->@*;
my $boundary = 'lib/Calc.pm:12 replaced > with >=';

sub append ( $path, $text ) {
    open my $handle, '>>', "$root/$path" or die "append $path: $!";
    print {$handle} $text or die "append $path: $!";
    close $handle         or die "close $path: $!";
    return;
}

subtest 'a new compiler input protocol rechecks the original tests and their verdicts' => sub {
    my $project = copy_of('calc');
    {
        no warnings qw(once redefine);
        local *Test::Mutation::Result::supported_compiler_input_protocol = sub { return 1 };
        my ($earlier) = run_fixture($project);
        is $earlier->compiler_input_protocol, 1, 'the earlier measurement uses its own compiler rules';
    }
    my ($current) = run_fixture($project);
    is $current->stats->{baseline_tests}, scalar $first->tests->@*, 'the current rules measure every original test';
    is $current->reused,   0,                'the previous protocol supplies no reusable verdicts';
    is statuses($current), statuses($first), 'remeasurement preserves the independently verified verdicts';
    my ($again) = run_fixture($project);
    is $again->reused, $measured, 'a second run with the current rules reuses the fresh observations';
};

subtest 'a legacy cache reuses only independently verifiable observations' => sub {
    my $directory = "$root/.mutation";
    my $database  = "$directory/measurement.sqlite";
    my $records   = Test::Mutation::Store::load($database);
    my $originals = Test::Mutation::Store::originals($database);
    delete $_->{observations} for values %$records;
    my ( $unidentified, $different ) = sort keys %$records;
    delete $records->{$unidentified}->@{qw(path source)};
    $records->{$different}{inputs} = 'previous inputs';
    Test::Mutation::Store::save( "$directory/cache.json", $records, undef, {}, $originals );
    unlink $database or die "unlink $database: $!";
    my ($imported) = run_fixture( $root, cache => 1 );
    is $imported->stats->{baseline_tests}, 0,             'matching original coverage survives migration';
    is $imported->reused,                  $measured - 2, 'the two verdicts without matching inputs are measured again';
    is statuses($imported), statuses($first), 'the migrated and newly measured verdicts agree with the clean run';
};

subtest 'a second run reuses every measured result' => sub {
    is $first->reused, 0, 'the first run measures every mutant';
    ok -f "$root/.mutation/measurement.sqlite", 'and writes the cache file';
    is statuses($first)->{$boundary}, 'Survived', 'the boundary mutant survives';

    my ( $rerun, $events ) = run_fixture( $root, cache => 1 );
    is statuses($rerun), statuses($first), 'the statuses are unchanged';
    is scalar( grep { $_ eq 'mutant' } $events->@* ), scalar( $rerun->entries->@* ),
      'the listener hears of each mutant once, reused or not';
    is $rerun->reused, $measured, 'every measured result comes from the cache';
    is [ map { $_->{by} } $rerun->entries->@* ], [ map { $_->{by} } $first->entries->@* ],
      'the detecting tests are unchanged';
    like Test::Mutation::Report::Terminal::render( $rerun, color => 0 ), qr/, $measured results from the cache$/m,
      'the summary states the number of reused results';
    unlike Test::Mutation::Report::Terminal::render( $first, color => 0 ), qr/from the cache/,
      'and stays silent without them';
};

subtest 'a run with caching disabled measures again' => sub {
    my ($plain) = run_fixture( $root, cache => 0 );
    is $plain->reused, 0, 'no result comes from the cache';
};

subtest 'a changed test invalidates the mutants it reaches' => sub {
    append( 't/add.t', "# a comment\n" );
    my ($third) = run_fixture( $root, cache => 1 );
    is statuses($third), statuses($first), 'the statuses are unchanged';
    ok $third->reused > 0,         'the mutants of the other test come from the cache';
    ok $third->reused < $measured, 'the mutants of the changed test run again';
};

subtest 'a new test that reaches a survivor replaces its cached result' => sub {
    write_file( "$root/t/zero.t", "use Test::More tests => 1;\nuse Calc;\nok !Calc::is_positive(0), 'zero';\n" );
    my ($fourth) = run_fixture( $root, cache => 1 );
    is statuses($fourth)->{$boundary}, 'Killed', 'the survivor is detected';
};

subtest 'a changed helper under the test directory invalidates every result' => sub {
    run_fixture( $root, cache => 1 );
    write_file( "$root/t/lib/Helper.pm", "package Helper;\n1;\n" );
    my ($fifth) = run_fixture( $root, cache => 1 );
    is $fifth->reused, 0, 'no result comes from the cache';
};

subtest 'a changed source invalidates the results of its tests' => sub {
    run_fixture( $root, cache => 1 );
    append( 'lib/Calc.pm', "# a comment\n" );
    my ($sixth) = run_fixture( $root, cache => 1 );
    is $sixth->reused, 0, 'no result comes from the cache';
};

subtest 'ignored survivors keep their statuses and reasons in a reused run' => sub {
    my $project  = copy_of('equivalent');
    my ($before) = run_fixture( $project, cache => 1 );
    my ($after)  = run_fixture( $project, cache => 1 );
    is statuses($after), statuses($before), 'the statuses are unchanged';
    is [ map { [ $_->@{qw(reason detail)} ] } $after->entries->@* ],
      [ map { [ $_->@{qw(reason detail)} ] } $before->entries->@* ], 'the reasons and the details are unchanged';
    is scalar( grep { $_->{status} eq 'Ignored' } $after->entries->@* ), 2,  'both ignored mutants stay ignored';
    is $after->reused,                                                   10, 'every result comes from the cache';
};

subtest 'changing whether Perl can compare a mutant invalidates its old equivalence verdict' => sub {
    my $project    = copy_of('equivalent');
    my ($before)   = run_fixture( $project, cache => 1 );
    my ($ignored)  = grep { defined $_->{reason} && $_->{reason} eq 'same-code-as-original' } $before->entries->@*;
    my $id         = $ignored->{mutant}->id;
    my $comparable = Test::Mutation::Mutant->can('comparable');
    my $sample     = Test::Mutation::Store->can('sample');
    no warnings 'redefine';
    local *Test::Mutation::Mutant::comparable = sub ($mutant) {
        return $mutant->id eq $id ? 0 : $comparable->($mutant);
    };
    local *Test::Mutation::Store::sample = sub ( $ids, $seed ) {
        return $sample->( [ grep { $_ ne $id } @$ids ], $seed );
    };
    my ($fresh)    = run_fixture( $project, cache => 0 );
    my ($warm)     = run_fixture( $project, cache => 1 );
    my ($observed) = grep { $_->{mutant}->id eq $id } $fresh->entries->@*;
    is $observed->{status}, 'Survived',   'the current candidate must be judged by the tests';
    is statuses($warm), statuses($fresh), 'the stored result agrees without waiting to sample the changed candidate';
    my @unchanged = grep { $_->{mutant}->id ne $id } $before->entries->@*;
    is $warm->reused, scalar @unchanged, 'the other candidate observations still qualify for reuse';
};

subtest 'a changed source without a mutant of its own invalidates the tests that load it' => sub {
    my $project = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my $inner   = sub ($limit) {
        return "package Inner;\nuse strict;\nuse warnings;\nuse constant LIMIT => $limit;\n1;\n";
    };
    write_file( "$project/lib/Inner.pm", $inner->(10) );
    write_file( "$project/lib/Outer.pm",
        "package Outer;\nuse strict;\nuse warnings;\nuse Inner;\nsub total { my (\$n) = \@_; return \$n + Inner::LIMIT }\n1;\n"
    );
    write_file( "$project/t/outer.t", "use Test::More tests => 1;\nuse Outer;\nok Outer::total(1) > 1, 'total';\n" );

    run_fixture( $project, cache => 1 );
    my ($warm) = run_fixture( $project, cache => 1 );
    ok $warm->reused > 0, 'the unchanged project reuses its results';
    write_file( "$project/lib/Inner.pm", $inner->(20) );
    my ($changed) = run_fixture( $project, cache => 1 );
    is $changed->reused, 0, 'a change to the loaded file measures the mutants again';

    my @narrow = ( cache => 1, source => ['lib/Outer.pm'] );
    run_fixture( $project, @narrow );
    my ($narrow) = run_fixture( $project, @narrow );
    ok $narrow->reused > 0, 'a run on one file reuses its results';
    write_file( "$project/lib/Inner.pm", $inner->(30) );
    my ($outside) = run_fixture( $project, @narrow );
    is $outside->reused, 0, 'a change to a file outside the selection measures the mutants again';
};

subtest 'a named interpreter is keyed by its resolved executable' => sub {
    my $project = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    write_file( "$project/lib/One.pm", "package One; sub next_value { return \$_[0] + 1 } 1;\n" );
    write_file( "$project/t/count.t",  "use Test::More tests => 1;\nuse One;\nis One::next_value(1), 2;\n" );
    my $portable = "#!$^X\nexec {q{$^X}} q{$^X}, \@ARGV or die \$!;\n";
    my $program  = write_file( "$project/tools/runner", $portable );
    chmod 0700, $program or die $!;
    local $ENV{PATH} = "$project/tools:$ENV{PATH}";
    my @options = ( cache => 1, perl => 'runner' );
    run_fixture( $project, @options );
    my ($warm) = run_fixture( $project, @options );
    ok $warm->reused, 'a stable program found on the search path can reuse measurements';
    write_file( $program, $portable . "# Rebuilt interpreter wrapper.\n" );
    my ($rebuilt) = run_fixture( $project, @options );
    is $rebuilt->reused, 0, 'replacing that executable invalidates its cached verdicts';
};

done_testing;
