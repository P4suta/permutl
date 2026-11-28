use v5.36;
use Test2::V0;
use File::Temp ();
use lib 't/lib';
use ManualClock;
use lib 't/e2e/lib';
use Fixture qw(copy_of);
use lib 't/shim/lib';
use ShimHarness qw(project write_file write_spec run_bare run_perl lib_dir);
use Test::Mutation::Runner;
use Test::Mutation::Select;
use Test::Mutation::Settings;
use Test::Mutation::Source;
use Test::Mutation::Store::Key;
use Test::Mutation::Workspace;

my $root      = copy_of('calc');
my $config    = Test::Mutation::Settings::of_call( { root => $root, baseline_timeout => 37 } );
my $selection = Test::Mutation::Select::resolve( config => $config );
my @mutants   = $selection->mutants->@*;

# A compiler task exposes the exact command and working directory passed to the pool.
## no critic (Subroutines::ProtectPrivateSubs)
subtest 'the outer shim can replace the compiler observer of an installed driver' => sub {
    my $area       = project();
    my $installed  = "$area/blib/lib";
    my $project    = "$area/project/lib";
    my $library    = lib_dir();
    my $runner     = 'Test/Mutation/Runner.pm';
    my $observer   = 'Test/Mutation/CompilerInputs.pm';
    my $generation = 1 + ( $ENV{TEST_MUTATION_GENERATION} || 0 );
    for my $name ( $runner, $observer ) {
        write_file( "$installed/$name", Test::Mutation::Source::read_bytes("$library/$name") );
    }
    my $change = "package Test::Mutation::CompilerInputs;\nour \$CHANGED = 1;\n1;\n";
    write_file( "$project/$observer", "package Test::Mutation::CompilerInputs 0.100;\n1;\n" );
    write_file( "$area/changed.pm",   $change );
    write_file( "$area/shim/Test/Mutation/Shim/G$generation.pm", Test::Mutation::Runner::shim_text($generation) );
    write_spec( "$area/spec", targets => [ [ "$installed/$observer", "$area/changed.pm" ] ] );
    write_file( "$area/read.pl", <<'PERL' );
use lib 'project/lib', 'blib/lib';
use Cwd ();
use Test::Mutation::Runner;
print Cwd::abs_path($INC{'Test/Mutation/Runner.pm'}), "\n";
print Test::Mutation::Runner::_module_text('Test/Mutation/CompilerInputs.pm');
PERL
    my $run = run_perl(
        root => $area,
        env  => {
            PERL5LIB                          => join( q{:}, "$area/shim", $library ),
            "TEST_MUTATION_SPEC_G$generation" => "$area/spec",
        },
        args => [ "-MTest::Mutation::Shim::G$generation", 'read.pl' ],
    );
    is $run->{status}, 0, 'the installed driver can read the observer' or diag $run->{stderr};
    is $run->{stdout}, "$installed/$runner\n$change", 'the installed copy receives the replacement from the outer shim';
};

subtest 'compilation retains the selected interpreter, file and working tree' => sub {
    my $workspace = Test::Mutation::Workspace::acquire($root);
    my $run       = { root => $root, project => $root, config => $config, workspace => $workspace, perl => $^X };
    my $outer     = 2 + ( $ENV{TEST_MUTATION_GENERATION} || 0 );
    local $ENV{TEST_MUTATION_GENERATION} = $outer;
    Test::Mutation::Runner::_prepare_work($run);
    my $inner    = $outer + 1;
    my $observer = "$run->{work}/compiler/Test/Mutation/CompilerInputs/G$inner.pm";
    is Test::Mutation::Source::read_bytes("$run->{work}/shim/Test/Mutation/Shim/G$inner.pm"),
      Test::Mutation::Runner::shim_text($inner), 'the child test loads the shim for the next generation';
    like Test::Mutation::Source::read_bytes($observer), qr/^package Test::Mutation::CompilerInputs::G$inner;/m,
      'the standalone compiler loads the observer for the same generation';
    my $private = copy_of('calc');
    my $job     = { mutant => $mutants[0], copy => { root => $private }, tests => ['t/add.t'] };
    my $path    = $mutants[0]->path;

    for my $case (
        [ 'syntax-original', '-c',          1, q{use charnames ':full';},              1 ],
        [ 'code-original',   '-MO=Deparse', 1, q{use strict;},                         0 ],
        [ 'code-mutant',     '-MO=Deparse', 1, q{use charnames ':full';},              1 ],
        [ 'code-mutant',     '-MO=Deparse', 1, q{use charnames ':full'; my $h = $^H;}, 0 ],
        [ 'code-mutant',     '-MO=Deparse', 1, q{use charnames ':full'; my %h = %^H;}, 0 ],
        [ 'syntax-mutant',   '-c',          1, q{use charnames ':full';},              0 ],
        [ 'code-mutant',     '-MO=Deparse', 0, q{use charnames ':full';},              1 ],
      )
    {
        my ( $kind, $request, $covered, $source, $normalize ) = @$case;
        my $original = $kind =~ /-original\z/;
        my $file     = ( $original ? $root : $private ) . "/$path";
        $job->{tests} = $covered ? ['t/add.t'] : [];
        $run->{sources}{$path} = Test::Mutation::Source->from_bytes( path => $path, bytes => $source );
        my $task   = Test::Mutation::Runner::_compile_task( $run, $job, $kind, $file, $request );
        my $option = $original ? '-MO=Deparse' : $request;
        is [ grep { $_ eq '-MO=Deparse' || $_ eq '-c' } $task->{command}->@* ], [$option],
          'the original is deparsed once for both syntax and equivalence';
        is $task->{command}[-1], $file, 'the compiler reads the intended source';
        is $task->{cwd}, !$covered ? $task->{payload}{tmp} : $original ? $root : $private,
          'an uncovered source runs alone and a covered source runs in its own project state';
        is ref( $task->{digest_line} ), $normalize ? 'CODE' : q{}, 'only standard character name hints are normalized';
        is $task->{payload}{original},  $original  ? $path  : undef, 'only the original can supply shared work';
        is $task->{timeout},            37, 'the first compile uses the configured baseline deadline';
    }
    $run->{targets} = [$path];
    my $schedule_test = sub {
        return Test::Mutation::Runner::_test_task(
            $run,
            root            => $root,
            test            => 't/add.t',
            spec            => "$run->{work}/observed.spec",
            timeout         => 2,
            stop_on_failure => 1,
            payload         => {}
        );
    };
    my $file        = "$private/$path";
    my $first_test  = $schedule_test->();
    my $compile     = Test::Mutation::Runner::_compile_task( $run, $job, 'code-mutant', $file, '-MO=Deparse' );
    my $second_test = $schedule_test->();
    my %directories = map { $_->{payload}{tmp} => 1 } $first_test, $compile, $second_test;
    is scalar keys %directories, 3, 'interleaved live compilers and tests cannot share a temporary directory';
    for my $key (qw(charnames charnames_inverse_ords charnames_name_aliases charnames_ord_aliases)) {
        my $type = $key eq 'charnames' ? 'CODE' : 'HASH';
        my $line = "  \$^H{'$key'} = '$type(0xDeF0)';\n";
        is $compile->{digest_line}->($line), $line =~ s/0xDeF0/*/r,
          'standard character name addresses compare equally across Perl processes';
    }
    my $other_hint = q{$^H{'another_plugin'} = 'CODE(0x2a)';};
    is $compile->{digest_line}->($other_hint), $other_hint, 'custom hints retain the full deparsed line';
    for my $duration ( 0.2, 2.5 ) {
        $run->{original_compile}{$path} = { duration => $duration };
        my $task = Test::Mutation::Runner::_compile_task( $run, $job, 'syntax-mutant', $file, '-c' );
        is $task->{timeout}, $duration < 1 ? 10 : 25, 'a measured compile supplies a deadline with a floor';
    }
    my $dependency = write_file( "$private/Imported.pm", q{BEGIN { open my $input, '<', '/table' or die $! }} );
    my $original   = Test::Mutation::Runner::_compile_task( $run, $job, 'code-original', "$root/$path", '-MO=Deparse' );
    my $previous   = $original->{payload}{tmp};
    write_file( "$previous/inputs", 'm' . unpack( 'H*', $dependency ) . "\n.\n" );
    my $retry = Test::Mutation::Runner::_after_task( $run, {}, $original, {} );
    is $retry->{env}{TEST_MUTATION_COMPILER_READS}, 'f' . unpack( 'H*', '/table' ), 'the retry binds the imported read';
    ok !-e $previous,             'the first compiler directory has been released before the retry runs';
    ok -d $retry->{payload}{tmp}, 'the retry has its own live directory';
    ok $workspace->release(0),    'the compiler leaves its workspace releasable';
};

subtest 'compiler input records distinguish a rejection from an interrupted compiler' => sub {
    my $tmp = File::Temp::tempdir( CLEANUP => 1 );
    for my $case (
        [ 'syntax-mutant',   { exit       => 25 },                 ".\n",  1, 0 ],
        [ 'syntax-mutant',   { exit       => 25 },                 "ab\n", 0, 1 ],
        [ 'syntax-mutant',   { signal     => 9 },                  ".\n",  0, 1 ],
        [ 'syntax-mutant',   { timed_out  => 1 },                  ".\n",  0, 1 ],
        [ 'syntax-mutant',   { overflowed => 1 },                  ".\n",  0, 1 ],
        [ 'syntax-mutant',   { exit       => 25, timed_out => 1 }, ".\n",  0, 1 ],
        [ 'code-mutant',     { exit       => 25 },                 ".\n",  0, 0 ],
        [ 'syntax-original', { exit       => 25 },                 ".\n",  0, 1 ],
        [ 'code-original',   { exit       => 25 },                 ".\n",  0, 1 ],
      )
    {
        my ( $kind, $outcome, $record, $known, $missing ) = @$case;
        write_file( "$tmp/inputs", $record );
        my ( $run, $job, $result ) = ( {}, {}, {%$outcome} );
        my $task = { payload => { tmp => $tmp, kind => $kind }, env => { TEST_MUTATION_COMPILER_READS => q{} } };
        Test::Mutation::Runner::_remember_compiler_inputs( $run, $job, $task, $result );
        my $label = join q{ }, $kind, sort keys %$outcome;
        is $result->{compiler_inputs}, $known ? {} : undef, "$label checks the record of the performed compilation";
        is $run->{missing_compiler_inputs} || 0, $missing,  "$label preserves the completeness of the run";
        ok $job->{unbound_compiler}, "$label requires the mutant to be checked again";
    }
};

subtest 'the absence of compiler reads is remembered for the next mutant of the source' => sub {
    my $path        = 'lib/Bound.pm';
    my $source      = Test::Mutation::Source->from_bytes( path => $path, bytes => "package Bound;\nCHECK { }\n1;\n" );
    my $run         = { sources => { $path => $source } };
    my $inspections = 0;
    my $parse       = \&PPI::Document::new;
    no warnings 'redefine';
    local *PPI::Document::new = sub (@args) {
        $inspections++ if ref $args[1] eq 'SCALAR';
        return $parse->(@args);
    };
    ok !Test::Mutation::Runner::_may_read_at_compile_time( $run, $path ), 'an empty CHECK block reads no files';
    ok !Test::Mutation::Runner::_may_read_at_compile_time( $run, $path ), 'a second mutant shares the result';
    is $inspections, 1, 'the unchanged source needs one inspection';
};

subtest 'an imported module keeps its unknown inputs across inspections and removal' => sub {
    my $area   = project();
    my $module = write_file( "$area/modules/Threshold.pm", <<'MODULE' );
package Threshold;
my $path = $ENV{LIMIT_FILE};
open my $input, '<', $path or die $!;
my $limit = <$input>;
close $input or die $!;
sub limit { return $limit }
1;
MODULE
    write_file( "$area/selected.pl", "use Threshold (); 1;\n" );
    my $compiled = run_bare(
        root => $area,
        env  => { TEST_MUTATION_COMPILER_INPUTS => "$area/inputs", LIMIT_FILE => write_file( "$area/limit", "7\n" ) },
        args => [ '-I' . lib_dir(), "-I$area/modules", '-MTest::Mutation::CompilerInputs', '-c', 'selected.pl' ],
    );
    is $compiled->{status}, 0, 'the target Perl actually loaded the data reader' or diag $compiled->{stderr};
    my $consult = sub ($run) {
        my $result = {};
        Test::Mutation::Runner::_compiler_inputs( $run, $area, $result );
        return $result->{module_reads};
    };
    my $run = {};
    is $consult->($run), { q{?} => 1 }, 'the loaded code can read an indirect path';
    is $consult->($run), { q{?} => 1 }, 'the next compilation retains the same uncertainty';
    unlink $module or die $!;
    is $consult->( {} ), { q{?} => 1 }, 'a recorded module that disappeared cannot establish the absence of reads';
};

subtest 'one comparison ends when the original and the uncovered mutant have compiled' => sub {
    local $ENV{PERL5OPT} = '-Mstrict';
    my ($mutant)  = grep { $_->comparable } @mutants;
    my $workspace = Test::Mutation::Workspace::acquire($root);
    my $run       = {
        root      => $root,
        project   => $root,
        config    => $config,
        workspace => $workspace,
        perl      => $^X,
        sources   => $selection->sources
    };
    Test::Mutation::Runner::_prepare_work($run);
    my $job     = { mutant => $mutant, tests => [], verdict => Test::Mutation::Verdict::start() };
    my @pending = Test::Mutation::Runner::_next_code( $run, $job );
    my ( @completed, $extra );
    Test::Mutation::Pool::run(
        jobs => 1,
        next => sub { return shift @pending },
        done => sub ( $task, $result ) {
            push @completed, $task->{payload}{kind};
            my $next = Test::Mutation::Runner::_after_task( $run, {}, $task, $result );
            return $next if @completed < 2;
            $extra = $next;
            return;
        },
    );
    is \@completed, [qw(code-original code-mutant)], 'the target Perl compiled both sides of the comparison';
    is $extra,      undef,                           'the completed comparison schedules no further compiler';
    like $job->{code}, qr/\A[0-9a-f]{64}\z/, 'the result keeps the real mutant fingerprint';
    ok $workspace->release(0), 'the workspace is released after the comparison';
};

subtest 'every original compiler observation records the result before the job continues' => sub {
    my $path   = $mutants[0]->path;
    my $inputs = { '/external/modules' => 'de' x 32 };
    for my $case ( [ 0, 'code', 'hash' ], [ 0, q{}, q{} ], [ 0, '0', 'hash' ], [ 2, 'compiler output', q{} ], ) {
        my ( $exit, $output, $digest ) = @$case;
        my $run    = {};
        my $result = {
            compiler_inputs => $inputs,
            exit            => $exit,
            signal          => 0,
            timed_out       => 0,
            overflowed      => 0,
            duration        => 2.5,
            output          => $output,
            digest          => 'hash'
        };
        my $task = {
            env     => { TEST_MUTATION_COMPILER_READS => q{} },
            payload => {
                compile  => 1,
                job      => {},
                kind     => 'code-original',
                original => $path,
                tmp      => "$root/unused-compiler-directory"
            }
        };
        no warnings 'redefine';
        local *Test::Mutation::Runner::_after_code = sub { return 'handled' };    ## no critic (Variables::ProtectPrivateVars)
        is Test::Mutation::Runner::_after_task( $run, {}, $task, $result ), 'handled', 'the job can resume';
        is [ $run->{original_compile}{$path}->@{qw(passed duration code inputs opaque)} ],
          [ $exit ? 0 : 1, 2.5, $digest, $exit ? undef : $inputs, undef ],
          'syntax and equivalence share the same completed original compiler observation';
        my $shared = $run->{original_compile}{$path};
        delete $task->{payload}{original};
        $task->{payload}{kind} = 'code-mutant';
        Test::Mutation::Runner::_after_task( $run, {}, $task, { %$result, duration => 9 } );
        is $run->{original_compile}, { $path => $shared }, 'a subsequent mutant never alters the original result';
    }
};

subtest 'only a completed nonempty mutant deparse provides a digest for comparison' => sub {
    for my $case (
        [ {}, 1 ],
        [ { exit       => 1 },   0 ],
        [ { signal     => 9 },   0 ],
        [ { timed_out  => 1 },   0 ],
        [ { overflowed => 1 },   0 ],
        [ { output     => q{} }, 0 ],
        [ { output     => '0' }, 1 ],
      )
    {
        my ( $changes, $usable ) = @$case;
        my $result = {
            exit       => 0,
            signal     => 0,
            timed_out  => 0,
            overflowed => 0,
            digest     => 'fingerprint',
            output     => 'sub answer { 42 }',
            %$changes
        };
        my $job  = {};
        my $task = { payload => { job => $job, original => $mutants[0]->path } };
        Test::Mutation::Runner::_after_code( {}, $task, $result );
        ok !exists $job->{code}, 'the original result stays out of the mutant fingerprint';
        delete $task->{payload}{original};
        Test::Mutation::Runner::_after_code( {}, $task, $result );
        is $job->{code}, $usable ? 'fingerprint' : q{}, 'a failed or empty deparse cannot establish equivalence';
    }
};

subtest 'a durable published result completes its checkpoint without another wait' => sub {
    my $mutant = $mutants[0];
    my $path   = project() . '/measurement.sqlite';
    my $cache  = { path => $path, targets => { $mutant->path => 'source' }, facts => { 't/add.t' => 'observed' } };
    my $entry =
      Test::Mutation::Runner::_entry( $mutant, 'Killed', undef, 'sum changed', 't/add.t', ['t/add.t'], 1, 0.1 );
    my @published;
    my $run = {
        listener => sub ( $event, $record ) {
            push @published, Test::Mutation::Store::load($path)->{ $record->{mutant}->id }{status};
            return;
        }
    };
    my $save  = Test::Mutation::Runner::_publish_finished( $run, $cache, $entry, {}, {} );
    my $count = Test::Mutation::Pool::run(
        jobs        => 1,
        clock       => ManualClock->new( limit => 0 ),
        checkpoints => [$save],
        next        => sub { return },
        done        => sub { die 'unexpected test completion' }
    );
    is $count,      0,          'the completed checkpoint needs no child process';
    is \@published, ['Killed'], 'the observer receives the durable result once';
};

subtest 'interruptions retain completed verdicts and account for every attempted test' => sub {
    my ( $finished, $started, $repeated ) = @mutants;
    my $done    = { status        => 'Killed', by => 't/known.t' };
    my $entries = { $finished->id => $done };
    my $pass    = sub ($test) {
        return { test => $test, result => 'pass', served => 1, load_failed => 0, bypassed => 0, syntax => undef };
    };
    my $observations = [ [ map { $pass->($_) } qw(t/add.t t/compare.t) ], [ $pass->('t/add.t') ] ];
    my @unfinished   = (
        { mutant => $finished },
        {
            mutant       => $repeated,
            verdict      => { tests => 1 },
            first        => { tests => 2 },
            tests        => [qw(t/add.t t/compare.t)],
            duration     => 3,
            observations => $observations,
        },
    );
    my @waiting = ( { mutant => $started, verdict => { tests => 0 }, tests => [], duration => 0 } );
    Test::Mutation::Runner::_pending_jobs( sub { return shift @waiting }, $entries, @unfinished );
    is $entries->{ $finished->id },               $done,         'a completed detection retains its test';
    is $entries->{ $repeated->id }{observations}, $observations, 'a partial repeat retains its completed observations';

    for my $pair ( [ $started, [], 0, 0 ], [ $repeated, [qw(t/add.t t/compare.t)], 3, 3 ] ) {
        my ( $mutant, $tests, $count, $duration ) = @$pair;
        my $entry = $entries->{ $mutant->id };
        is [ $entry->@{qw(mutant status reason by covered_by tests_run duration)} ],
          [ $mutant, 'Pending', 'interrupted', undef, $tests, $count, $duration ],
          'an interrupted attempt retains its coverage, test count and elapsed time';
    }
};

## use critic

# The observers supply controlled test results while the runner manages the temporary project directory.
## no critic (Variables::ProtectPrivateVars Subroutines::ProtectPrivateSubs)
subtest 'original test writes invalidate saved observations in the applicable execution modes' => sub {
    for my $case (
        [ 'a private copy',           1, 0, 1 ],
        [ 'an in-place cache',        0, 1, 1 ],
        [ 'an uncached in-place run', 0, 0, 0 ],
      )
    {
        my ( $label, $copied, $cached, $observes ) = @$case;
        my $project = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
        my $settings =
          Test::Mutation::Settings::of_call( { root => $project, cache => $cached, in_place => !$copied } );
        my $run = { root => $project, project => $project, config => $settings, stats => {}, targets => [] };
        if   ($copied) { $run->{copies} = "$project/slots" }
        else           { $run->{guard}  = { state => Test::Mutation::Runner::_tree($run) } }
        no warnings 'redefine';
        local *Test::Mutation::Runner::_baseline = sub {
            Fixture::write_file( "$project/observation.txt", "new contents\n" );
            return { tests => {} };
        };
        is Test::Mutation::Runner::_observed_baseline( $run, [] ), { tests => {} }, "$label returns the test facts";
        is $run->{baseline_changed}, $observes ? 1   : undef, "$label records the project change when it affects reuse";
        is exists $run->{tree},      $cached   ? T() : F(), "$label retains the updated state only for a guarded cache";
    }
};

subtest 'a complete or fully reused baseline needs no partial-input comparison' => sub {
    my ( $cached, $changed ) = qw(t/cached.t t/changed.t);
    my @all  = ( $cached, $changed );
    my $fact = { breakable => {} };
    for my $case (
        [ 'an in-place update', 1, { $cached => $fact },         [$changed], 1 ],
        [ 'a cold measurement', 1, {},                           [@all],     1 ],
        [ 'a disabled cache',   0, {},                           [@all],     0 ],
        [ 'a complete cache',   1, { map { $_ => $fact } @all }, [],         0 ],
      )
    {
        my ( $label, $enabled, $hits, $missing, $save ) = @$case;
        my $settings = Test::Mutation::Settings::of_call( { root => $root, cache => $enabled } );
        my $run      = { root => $root, config => $settings, test_paths => \@all };
        my ( @runs, @writes, $compared );
        no warnings 'redefine';
        local *Test::Mutation::Runner::_observed_baseline = sub ( $context, $tests ) {
            push @runs, [@$tests];
            return { tests => { map { $_ => $fact } @$tests }, failures => [], parallel_safe => 1 };
        };
        local *Test::Mutation::Runner::_run_inputs = sub { ++$compared; return 'observed' };
        local *Test::Mutation::Runner::_save_originals =
          sub ( $context, $baseline ) { push @writes, $baseline; return };
        my $result = Test::Mutation::Runner::_complete_baseline( $run, { tests => $hits, missing => $missing } );
        is \@runs,                   @$missing ? [ \@all ] : [], "$label controls whether the complete suite must run";
        is $run->{reused_originals}, @$missing ? {} : $hits, "$label only reuses facts from accepted original tests";
        is [ sort keys $result->{tests}->%* ], [ sort @all ], "$label reports every test";
        ok !$compared, "$label needs no second fingerprint for a mixture of old and new test facts";
        is \@writes, $save ? [$result] : [], "$label writes only newly measured facts when caching is enabled";
    }
};
subtest 'partial original results are reused only when the two observations agree' => sub {
    my ( $cached_test, $changed_test ) = qw(t/first.t t/second.t);
    my $record = sub ($line) { return { duration => $line, breakable => { 'lib/Calc.pm' => { $line => 1 } } } };
    for my $case (
        [ 'matching inputs',    0, 1, 0, 'same',      1 ],
        [ 'a changed project',  1, 1, 0, 'same',      0 ],
        [ 'a test conflict',    0, 0, 0, 'same',      0 ],
        [ 'a failed original',  0, 1, 1, 'same',      0 ],
        [ 'unavailable inputs', 0, 1, 0, undef,       0 ],
        [ 'different inputs',   0, 1, 0, 'different', 0 ]
      )
    {
        my ( $label, $changed, $safe, $failed, $shared, $reuse ) = @$case;
        my $run =
          { root => $root, copies => 'available', config => $config, test_paths => [ $cached_test, $changed_test ] };
        my $plan = { tests => { $cached_test => $record->(1) }, missing => [$changed_test], shared => 'same' };
        my ( $trial, @reads, @saved );
        no warnings 'redefine';
        local *Test::Mutation::Runner::_control_copy      = sub { return $trial = File::Temp::tempdir( CLEANUP => 1 ) };
        local *Test::Mutation::Runner::_observed_baseline = sub ( $context, $names ) {
            push @reads, [ $context->{root}, [@$names] ];
            if ( @$names == 1 ) {
                $context->{baseline_changed} = $changed;
                return {
                    tests         => { $changed_test => $record->(2) },
                    parallel_safe => $safe,
                    failures      => $failed ? [ { test => $changed_test } ] : []
                };
            }
            return {
                tests         => { $cached_test => $record->(3), $changed_test => $record->(4) },
                parallel_safe => 1,
                failures      => []
            };
        };
        local *Test::Mutation::Runner::_run_inputs     = sub { return $shared };
        local *Test::Mutation::Runner::_save_originals = sub ( $context, $baseline ) {
            push @saved, $baseline;
            return;
        };
        my $result = Test::Mutation::Runner::_complete_baseline( $run, $plan );
        is \@reads, [ [ $trial, [$changed_test] ], $reuse ? () : [ $root, [ $cached_test, $changed_test ] ] ],
          "$label determines which original tests must be measured";
        ok !-e $trial, "$label releases the temporary copy before returning";
        is [ sort keys $run->{reused_originals}->%* ], $reuse ? [$cached_test] : [],
          "$label retains the verified tests";
        is [ sort keys $result->{breakable}{'lib/Calc.pm'}->%* ], $reuse ? [ 1, 2 ] : [ 3, 4 ],
          "$label publishes the executable lines from the accepted observations";
        is \@saved, [$result], "$label saves the completed baseline once";
    }
};
## use critic

subtest 'a fresh baseline after a cache mismatch supplies every original test fact' => sub {
    my $old     = { tests => { 't/cached.t' => { duration => 1 } }, parallel_safe => 1, failures => [] };
    my $failure = { test  => 't/current.t', output => "1..1\nnot ok 1\n", errors => "changed input\n" };
    my $fresh   = { tests => { 't/current.t' => { duration => 4.5 } }, parallel_safe => 0, failures => [$failure] };
    no warnings 'redefine';
    local *Test::Mutation::Runner::_complete_baseline = sub { return $old };                                         ## no critic (Variables::ProtectPrivateVars)
    local *Test::Mutation::Runner::_mutants = sub ( $run, @ ) { $run->{rechecked_baseline} = $fresh; return [] };    ## no critic (Variables::ProtectPrivateVars)
    my $result = Test::Mutation::Runner::run( $config, sub { return }, { selection => $selection } );
    is $result->tests, [ { name => 't/current.t', duration => 4.5 } ],
      'the report uses the newly measured test and duration';
    is $result->parallel_safe,     0,          'the new observation determines whether tests can run concurrently';
    is $result->baseline_failures, [$failure], 'the failure from the new original run reaches the result';
    is $result->dependency_digest,
      Test::Mutation::Store::Key::digest( 't/current.t', Test::Mutation::Store::Key::digest() ),
      'the dependency fingerprint belongs to the original run that supplied the result';
};

done_testing;
