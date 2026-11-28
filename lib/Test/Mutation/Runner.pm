package Test::Mutation::Runner;
use v5.36;
use Cwd             ();
use Digest::SHA     ();
use Errno           ();
use File::Basename  ();
use File::Find      ();
use File::Spec      ();
use List::Util      ();
use Time::HiRes     ();
use Types::Standard qw(ArrayRef Bool CodeRef Dict HashRef InstanceOf Int Maybe Optional Str Tuple);
use Type::Params    qw(signature_for);
use Test::Mutation::Attribution;
use Test::Mutation::Build;
use Test::Mutation::Config;
use Test::Mutation::Store;
use Test::Mutation::Store::History;
use Test::Mutation::Coverage;
use Test::Mutation::Error;
use Test::Mutation::Event;
use Test::Mutation::Git;
use Test::Mutation::Message;
use Test::Mutation::Launch;
use Test::Mutation::Once;
use Test::Mutation::Pool;
use Test::Mutation::Record;
use Test::Mutation::Evidence;
use Test::Mutation::Result;
use Test::Mutation::Signals;
use Test::Mutation::Schedule;
use Test::Mutation::Select;
use Test::Mutation::Source;
use Test::Mutation::Status;
use Test::Mutation::Tree;
use Test::Mutation::Types qw(PathSelection);
use Test::Mutation::Try;
use Test::Mutation::Verdict;
use Test::Mutation::Witness;
use Test::Mutation::Syntax::PPI;
use Test::Mutation::Workspace;
use Test::Mutation::Workspace::Slot;
use Test::Mutation::Workspace::Processes;

our $VERSION = '0.001';

my $SHIM_FILE     = 'Test/Mutation/Shim.pm';
my $COMPILER_FILE = 'Test/Mutation/CompilerInputs.pm';
my $DRIVER_LIB    = Cwd::abs_path( File::Basename::dirname(__FILE__) . '/../..' );
my %UNDETECTED    = map { $_->name => 1 } grep { $_->role eq 'undetected' } Test::Mutation::Status::rows()->@*;
my $CHANGES_NAMED = 5;
my $TYPED         = InstanceOf ['Test::Mutation::Error'];
my $INTERRUPTION  = InstanceOf ['Test::Mutation::Interrupted'];

# A test that prints a quarter of a gigabyte prints without end, as a loop that warns does, and the pool ends it.
# The bytes stay in no file, and a test that prints a hundred megabytes and then fails still fails on its own.
my $OUTPUT_LIMIT   = 268_435_456;
my $COMPILE_FACTOR = 10;
my $COMPILE_FLOOR  = 10;

signature_for phases => ( positional => [], returns => ArrayRef [Str] );

sub phases () {
    return Test::Mutation::Event::phases();
}

my $ANALYSIS = Dict [
    sources   => HashRef [ InstanceOf ['Test::Mutation::Source'] ],
    mutants   => ArrayRef [ InstanceOf ['Test::Mutation::Mutant'] ],
    problems  => ArrayRef [ Dict [ path => Str, problem => Str ] ],
    left_out  => HashRef [Int],
    rejected  => ArrayRef [ Dict [ path => Str, mutator => Str, line => Int, rule => Str ] ],
    inventory => Dict [ mutants => Int, digest => Str ],
];

signature_for analyze =>
  ( positional => [ InstanceOf ['Test::Mutation::Config'], Optional [ Maybe [PathSelection] ] ], returns => $ANALYSIS );

sub analyze ( $config, $paths = undef ) {
    my $selected = Test::Mutation::Select::resolve( config => $config, paths => $paths, read_only => 1 );
    return {
        sources   => $selected->sources,
        mutants   => $selected->mutants,
        problems  => $selected->unanalyzed,
        rejected  => $selected->rejected,
        left_out  => $selected->left_out,
        inventory => $selected->inventory,
    };
}

signature_for run => (
    positional => [
        InstanceOf ['Test::Mutation::Config'],
        CodeRef,
        Dict [
            paths          => Optional [ Maybe [PathSelection] ],
            selection      => Optional [ InstanceOf ['Test::Mutation::Selection'] ],
            baseline_only  => Optional [Bool],
            detector_hints => Optional [ HashRef [Str] ],
            reports        => Optional [Bool],
            summary        => Optional [ Maybe [Str] ]
        ],
        { default => sub { {} } }
    ],
    returns => InstanceOf ['Test::Mutation::Result'],
);

sub run ( $config, $notify, $options = {} ) {
    ( $config, $options ) = _recheck( $config, $options ) if $config->undetected && !$options->{baseline_only};
    my %events   = ( analyzed => 'resolved', baseline => 'baseline_finished', mutant => 'mutant_finished' );
    my $listener = sub ( $event, $data ) {
        $notify->( $event,          $data );
        $notify->( $events{$event}, $data ) if exists $events{$event};
        return;
    };
    my $started = Time::HiRes::time();
    Test::Mutation::Event::phase( $listener, 'resolve' );
    my $project  = Cwd::abs_path( $config->root );
    my %options  = $options->%*;
    my $hints    = delete $options{detector_hints};
    my @filters  = ( $config->since, $config->shard, $config->mutant->@*, @options{qw(paths selection)} );
    my $filtered = grep { defined } @filters;
    my $run      = {
        config         => $config,
        options        => \%options,
        detector_hints => $config->cache || $filtered ? {} : $hints,
        project        => $project,
        root           => $project,
        listener       => $listener,
        jobs           => $config->jobs,
        sequence       => 0,
        first          => {},
        warnings       => {},
        free           => {},
        stats          => { map { $_ => 0 } qw(copies walks compiles spawns listings baseline_tests verifications) },
    };
    my $release = sub {
        Test::Mutation::Try::with_cleanup(
            sub { return [ Test::Mutation::Event::phase( $listener, 'release' ) ] },
            sub { _release_workspace($run) },
        );
        return;
    };
    my $result = Test::Mutation::Signals::watch(
        sub {
            Test::Mutation::Event::during(
                $listener,
                sub {
                    Test::Mutation::Try::with_cleanup( sub { _measure( $run, $started ) }, $release );
                }
            );
        }
    );
    my $measurement = Test::Mutation::Result->new(
        $result->%*,
        min_score => $config->min_score,
        warnings  => [ sort keys $run->{warnings}->%* ],
        finished  => Time::HiRes::time()
    );
    $listener->( 'finished', $measurement->tally );
    Test::Mutation::Store::History::record( $config, $measurement,
        !$config->mutant->@* && !$config->undetected ? 1 : 0 )
      unless $options->{baseline_only};
    return $measurement;
}

sub _recheck ( $config, $options ) {
    my $paths   = $options->{selection}  ? $options->{selection}->selection->{paths} : $options->{paths};
    my $changed = defined $config->since ? Test::Mutation::Git::changed( $config->root, $config->since ) : undef;
    my $scope   = Test::Mutation::Store::History::undetected_scope( $config, [ grep { defined } $paths, $changed ] );
    Test::Mutation::Error::raise('measurement-history-missing') unless defined $scope;
    my $historical = { map { $_->{id} => $_->{path} } $scope->{selected}->@* };
    my @ids        = map { $_->{id} } $scope->{selected}->@*;
    if ( $config->mutant->@* ) {
        my %wanted = _explicit_gaps( $config, $historical, $scope->{identifiers} );
        @ids = grep { $wanted{$_} } @ids;
    }
    my $named     = Test::Mutation::Settings::for_mutants( $config, \@ids );
    my $selection = Test::Mutation::Select::resolve(
        config           => $named,
        reports          => $options->{reports} || 0,
        summary          => $options->{summary},
        changed          => $changed,
        identifiers      => \@ids,
        historical_paths => $historical,
        paths            => $paths
    );
    return (
        $named,
        {
            selection => Test::Mutation::Selection->new(
                $selection->%*, selection => { $selection->selection->%*, mutants => \@ids, undetected => 1 }
            )
        }
    );
}

sub _explicit_gaps ( $config, $historical, $all ) {
    my @request;
    for my $prefix ( $config->mutant->@* ) {
        my @known = grep { index( $_, $prefix ) == 0 } @$all;
        next if length($prefix) >= 4 && @known == 1 && !exists $historical->{ $known[0] };
        push @request, $prefix;
    }
    return unless @request;
    my $catalog  = Test::Mutation::Settings::for_mutants( $config, \@request, undef );
    my $explicit = Test::Mutation::Select::resolve(
        config           => $catalog,
        historical_paths => $historical,
        read_only        => 1
    );
    return map { $_ => 1 } map { @$_ } values $explicit->matches->{mutant}->%*;
}

# The tests run in a copy of the project, so a file that a test writes or removes leaves the project as it was.
sub _copy_project ($run) {
    my $config  = $run->{config};
    my $project = $run->{project};

    my $directory = $run->{workspace}->directory;
    $run->{copies} = "$directory/slot";
    my @skip = _copy_exclusions($run);
    $run->{listener}->( 'copy_started', { project => $project } );
    my $copied = Test::Mutation::Try::attempt(
        sub { $run->{root} = _new_copy( $run, "$directory/tree", $project, \@skip, $config->link ) } );
    if ( exists $copied->{value} ) {
        $run->{listener}->( 'copy_finished', { root => $run->{root} } );
        return;
    }

    # A failure of the system names its path, and the run adds what the user can do about it.
    my $error = $copied->{error};
    die $error if !$TYPED->check($error);    ## no critic (ErrorHandling::RequireCarping)
    return Test::Mutation::Error::raise( 'project-uncopyable', reason => $error->message );
}

sub _prepare_project ( $run, $selection ) {
    unless ( $run->{config}->in_place ) {
        _copy_project($run);
        $selection->verify_copy( $run->{root} );
        _verify_copy_inputs($run);
        _prepare_build( $run, [ sort keys $selection->sources->%* ] );
        return;
    }
    _prepare_build( $run, [ sort keys $selection->sources->%* ] );
    _warn( $run, Test::Mutation::Message::warning('in-place-observation') );
    my $root     = $run->{project};
    my $backup   = $run->{workspace}->directory . '/tree/original';
    my $original = _tree($run);
    my @skip     = ( '.git', map { _inside( $root, $_ ) } $run->{config}->cache_dir, $run->{config}->report_dir );
    my @opaque   = grep { !-l "$root/$_" && ( !-r _ || !( -f _ || -d _ && -x _ ) ) } keys $original->%*;
    Test::Mutation::Tree::copy( from => $root, to => $backup, skip => [ @skip, @opaque ], link => [] );
    $run->{stats}{copies}++;
    $run->{guard} = { backup => $backup, state => $original, opaque => \@opaque };
    return;
}

sub _prepare_build ( $run, $targets ) {
    my $root    = $run->{root};
    my $options = Test::Mutation::Launch::interpreter_options( $root, $run->{config}->lib, $run->{config}->switch );
    $run->{build} = Test::Mutation::Build::prepare(
        root      => $root,
        native    => Test::Mutation::Build::native($root),
        perl      => $run->{perl} || $run->{config}->perl,
        libraries => $options->{lib},
        targets   => $targets,
        in_place  => !defined $run->{copies},
        run       => sub ( $where, $command ) { _build_command( $run, $where, $command ) },
    );
    return;
}

sub _build_command ( $run, $root, $command ) {
    my $work  = $run->{workspace}->directory;
    my @tasks = (
        {
            command         => $command,
            cwd             => $root,
            env             => { PWD => $root, TMPDIR => "$work/work" },
            lease           => "$work/processes",
            timeout         => $run->{config}->baseline_timeout,
            output_limit    => $OUTPUT_LIMIT,
            stop_on_failure => 0,
        }
    );
    my $result;
    Test::Mutation::Pool::run(
        jobs => 1,
        work => ( $run->{stats} ||= {} ),
        next => sub { shift @tasks },
        done => sub ( $task, $outcome ) { $result = $outcome; return }
    );
    return unless $result->{exit} || $result->{signal} || $result->{timed_out} || $result->{overflowed};
    my $detail = join q{ }, grep { length } $result->@{qw(output errors)};
    $detail =~ s/\s+/ /g;
    $detail =~ s/\s+\z//;
    $detail = substr $detail, -480 if length($detail) > 480;
    return Test::Mutation::Error::raise(
        'build-command-failed',
        command => join( q{ }, @$command ),
        reason => length $detail ? $detail
        : $result->{timed_out}  ? 'time limit'
        : $result->{overflowed} ? 'output limit'
        :                         "exit $result->{exit}, signal $result->{signal}"
    );
}

# The path from the project to a place inside it, and nothing for a place outside.
sub _inside ( $project, $path ) {
    my $absolute = File::Spec->canonpath( File::Spec->rel2abs( $path, $project ) );
    my $prefix   = "$project/";
    return substr( $absolute, 0, length $prefix ) eq $prefix ? substr $absolute, length $prefix : ();
}

# Each copy has the name of the project inside a directory of its own.
sub _new_copy ( $run, $directory, $from, $skip, $link, $state = undef ) {
    my $to = "$directory/" . File::Basename::basename( $run->{project} );
    Test::Mutation::Tree::copy(
        from => $from,
        to   => $to,
        skip => $skip,
        link => $link,
        $state ? ( state => $state ) : ()
    );
    $run->{stats}{copies}++;
    return $to;
}

sub _walk ( $run, $root, @skip ) {
    $run->{stats}{walks}++;
    return Test::Mutation::Tree::snapshot( root => $root, skip => \@skip );
}

# Every mutant starts from the state that the unmodified run left, so each job works in a copy of its own.
# A job takes a copy that no job uses, or a new one, and records the state it finds.
sub _job_root ( $run, $job ) {
    return $run->{root}       if !defined $run->{copies};
    return $job->{copy}{root} if $job->{copy};
    my $reference = $job->{starting_tree} || $run->{root};
    my $available = $run->{free}{$reference} ||= [];
    my $copy      = shift $available->@*;
    if ( !$copy ) {
        my $state = {};
        my $root  = _new_copy( $run, "$run->{copies}/" . ++$run->{slots}, $reference, [], [], $state );
        $copy = { root => $root, reference => $reference, state => $state };
    }
    $job->{copy} = $copy;
    return $copy->{root};
}

# A mutant may leave a changed copy behind, so the copy returns to its state before the next job takes it.
# A copy that fails to return stays out of use, and the next job makes a new one.
sub _release ( $run, $job ) {
    if ( $run->{guard} && delete $job->{used_project} ) {
        my $guard   = $run->{guard};
        my $changes = Test::Mutation::Tree::changes( $guard->{state}, _tree($run) );
        _restore_changes( $run, $guard, $changes );
        if ( $changes->@* && !$run->{setup_tests} ) {
            _changed_paths( $run, $changes );
            _confirm_after_restore( $run, $job, $guard );
        }
        return;
    }
    my $copy    = delete $job->{copy} or return;
    my $root    = $copy->{root};
    my $changes = Test::Mutation::Tree::changes( $copy->{state}, _walk( $run, $root ) );
    my $restore = sub {
        Test::Mutation::Tree::restore(
            from    => $copy->{reference},
            to      => $root,
            changes => $changes,
            state   => $copy->{state}
        );
    };
    if ( $changes->@* ) {
        my $restored = Test::Mutation::Try::attempt($restore);
        if ( exists $restored->{error} ) {
            $job->{restore_error} = "$restored->{error}";
            return;
        }
    }
    push $run->{free}{ $copy->{reference} }->@*, $copy;
    return;
}

# A test may leave a directory without any right, and such a leftover must not end the run.
sub _discard (@paths) {
    for my $path (@paths) {
        Test::Mutation::Try::attempt( sub { Test::Mutation::Tree::remove($path) } );
    }
    return;
}

sub _measure ( $run, $started ) {
    my $config   = $run->{config};
    my $listener = $run->{listener};
    my $root     = $run->{root};
    Test::Mutation::Event::phase( $listener, 'analyze' );
    my $selection =
      $run->{options}{selection} || Test::Mutation::Select::resolve( config => $config, $run->{options}->%* );
    Test::Mutation::Event::phase( $listener, 'plan' );
    my @tests   = $selection->tests->@*;
    my @active  = grep { !$_->suppressed } $selection->mutants->@*;
    my %targets = map  { $_->path => 1 } @active;
    $run->{sources} = { $selection->sources->%* };

    if ( $config->cache ) {
        for my $path ( keys $selection->digests->%* ) {
            $run->{sources}{$path} ||= Test::Mutation::Source->from_bytes(
                path  => $path,
                bytes => Test::Mutation::Source::read_bytes("$root/$path")
            );
        }
    }
    $run->{narrowed} = $selection->narrowed;
    $run->{perl}     = $selection->perl;

    for my $path ( sort keys $selection->left_out->%* ) {
        my $count = $selection->left_out->{$path};
        _warn( $run,
            $count == 1
            ? Test::Mutation::Message::warning( 'analysis-left-out-place',  path => $path )
            : Test::Mutation::Message::warning( 'analysis-left-out-places', path => $path, count => $count ) );
    }
    $listener->(
        'analyzed',
        { mutants => scalar( $selection->mutants->@* ), files => scalar( keys %targets ), tests => scalar(@tests) }
    );

    my %result = (
        root               => $run->{project},
        sources            => { map { $_ => $selection->sources->{$_}->text } keys $selection->sources->%* },
        tests              => [],
        entries            => [],
        problems           => $selection->unanalyzed,
        baseline_failures  => [],
        parallel_safe      => 1,
        shard              => $config->shard,
        inventory          => $selection->inventory,
        selection          => $selection->selection,
        catalog_digest     => $selection->catalog_digest,
        measurement_digest => scalar _available_digest( sub { _measurement_digest( $run, $selection ) } ),
        started            => $started,
    );

    my $needs_tests = @active || $run->{options}{baseline_only};
    if ( $needs_tests && @tests ) {
        $run->{targets}    = [ sort keys $run->{sources}->%* ];
        $run->{test_paths} = \@tests;
        my $plan = _plan_originals($run);
        if ( $run->{options}{baseline_only} && !$plan->{missing}->@* ) {
            $result{tests} = _test_list( $plan->{tests} );
            $listener->( 'baseline', { tests => scalar(@tests), jobs => $run->{jobs} } );
        }
        else {
            %result = ( %result, _measure_tests( $run, $selection, $plan )->%* );
        }
    }
    else {
        $result{entries} = _empty_entries( $run, $selection, $needs_tests );
    }

    Test::Mutation::Event::phase( $listener, 'conclude' );
    $result{measurement_digest} = undef if $run->{missing_compiler_inputs};
    my $compiler = $run->{compiler_inputs} || {};
    return {
        %result,
        jobs            => $run->{jobs},
        interrupted     => $run->{interrupted},
        cache_mismatch  => $run->{cache_mismatch} || 0,
        compiler_inputs => { map { ( Test::Mutation::Store::Key::digest($_), $compiler->{$_} ) } keys %$compiler },
        reused          => $run->{reused} || 0,
        in_copies       => $config->in_place ? 0 : 1,
        stats           => $run->{stats},
    };
}

sub _compiler_parser_versions () {
    return ( PPI->VERSION, PPIx::QuoteLike->VERSION, PPIx::Regexp->VERSION );
}

sub _measurement_digest ( $run, $selection ) {
    my $config  = $run->{config};
    my $project = $run->{project};
    my @sources = sort( keys $selection->sources->%*, map { $_->{path} } $selection->unanalyzed->@* );
    my @separate =
      ( @sources, $selection->tests->@*, defined $config->config ? _inside( $project, $config->config ) : () );
    my @skip  = ( _input_exclusions($run), @separate );
    my %tests = map { $_ => Test::Mutation::Store::Key::file("$project/$_") } $selection->tests->@*;
    my $project_digest;
    if ( $config->in_place ) {
        $project_digest = Test::Mutation::Store::Key::tree( $project, \@skip );
    }
    else {
        my $view = Test::Mutation::Store::Key::project( $project, \@skip, $config->link );
        $run->{report_outputs} = $view->{outputs};
        $project_digest = $view->{digest};
        $run->{copy_inputs} =
          { project => $project_digest, tests => \%tests, sources => $selection->digests, separate => \@separate };
    }
    return Test::Mutation::Store::Key::digest(
        Test::Mutation::Select::measurement_rules( $config, $selection ),
        _compiler_parser_versions(),
        Test::Mutation::Store::Key::digest( map { ( $_, $selection->digests->{$_} ) } @sources ),
        Test::Mutation::Store::Key::interpreter_build( $selection->perl ),
        $project_digest,
        Test::Mutation::Store::Key::environment( \%ENV, $project ),
        _module_text($SHIM_FILE),
        _module_text($COMPILER_FILE),
        _module_text('Test/Mutation/Witness.pm'),
        $config->mutant->@* ? 1 : 0,
        $config->coverage,
        $config->equivalence,
        $config->in_place,
        $config->baseline_timeout,
        $config->timeout_factor,
        $config->timeout_floor,
        ( map { Test::Mutation::Store::Key::digest(@$_) } $config->lib, $config->switch, $config->link ),
        map { ( $_, $tests{$_} ) } $selection->tests->@*
    );
}

sub _verify_copy_inputs ($run) {
    my $expected = $run->{copy_inputs} or return;
    my $root     = $run->{root};
    for my $test ( sort keys $expected->{tests}->%* ) {
        my $path = "$root/$test";
        Test::Mutation::Error::raise( 'measurement-inputs-changed', path => $test )
          if !-f $path || Test::Mutation::Store::Key::file($path) ne $expected->{tests}{$test};
    }
    my $digest =
      Test::Mutation::Store::Key::workspace( $root, $expected->{separate}, $run->{config}->link, $run->{project} );
    Test::Mutation::Error::raise( 'measurement-inputs-changed', path => $run->{project} )
      if $digest ne $expected->{project};
    if ( $run->{config}->cache ) {
        my @separate = ( keys $run->{sources}->%*, $run->{test_paths}->@* );
        my $cache_digest =
          Test::Mutation::Store::Key::workspace( $root, \@separate, $run->{config}->link, $run->{project} );
        Test::Mutation::Error::raise( 'measurement-inputs-changed', path => $run->{project} )
          if defined $expected->{cache_project} && $cache_digest ne $expected->{cache_project};
        $expected->{cache_project} = $cache_digest;
    }
    return;
}

sub _input_exclusions ($run) {
    my $config = $run->{config};
    my @skip   = ( '.git', _inside( $run->{project}, $config->cache_dir ) );
    return @skip if $config->in_place;
    push @skip, _inside( $run->{project}, $config->report_dir );
    return grep {
        my $path = $_;
        !grep { index( $path, "$_/" ) == 0 } $config->link->@*;
    } @skip;
}

sub _copy_exclusions ($run) {
    my $config  = $run->{config};
    my $project = $run->{project};
    my @skip    = ( '.git', map { _inside( $project, $_ ) } $config->cache_dir, $config->report_dir );
    return @skip if $config->in_place;
    $run->{report_outputs} ||= Test::Mutation::Store::Key::published_outputs( $project, \@skip, $config->link );
    return @skip, $run->{report_outputs}->@*;
}

sub _measure_tests ( $run, $selection, $plan ) {
    my $listener = $run->{listener};
    $run->{rules} = Test::Mutation::Schedule::rules( $run->{project} );
    Test::Mutation::Event::phase( $listener, 'acquire' );
    $run->{workspace} = Test::Mutation::Workspace::acquire( $run->{project} );
    Test::Mutation::Event::phase( $listener, 'build' );
    _prepare_project( $run, $selection );
    _prepare_work($run);
    _prepare_witnesses($run) if defined $run->{copies};
    Test::Mutation::Event::phase( $listener, 'baseline' );
    my $baseline = _complete_baseline( $run, $plan );
    my $result   = _baseline_facts($baseline);

    if ( $baseline->{failures}->@* ) {
        $listener->( 'baseline_finished', { failures => $baseline->{failures} } );
        return $result;
    }
    _begin_in_place( $run, $baseline ) if $run->{guard} && !$run->{options}{baseline_only};
    $listener->( 'baseline', { tests => scalar $run->{test_paths}->@*, jobs => $run->{jobs} } );
    return $result if $run->{options}{baseline_only};
    Test::Mutation::Event::phase( $listener, 'mutants' );
    my $entries = _mutants( $run, $selection->mutants, $baseline );
    $listener->( 'mutants_finished', { total => scalar @$entries } );
    $result = _baseline_facts( $run->{rechecked_baseline} ) if $run->{rechecked_baseline};
    return { $result->%*, entries => $entries };
}

sub _baseline_facts ($baseline) {
    return {
        parallel_safe     => $baseline->{parallel_safe},
        baseline_failures => $baseline->{failures},
        tests             => _test_list( $baseline->{tests} ),
        dependency_digest => scalar _available_digest( sub { _dependencies( $baseline->{tests} ) } ),
    };
}

sub _dependencies ($tests) {
    my %libraries;
    my @inputs;
    for my $test ( sort keys %$tests ) {
        my @paths = @{ $tests->{$test}{includes} || [] };
        push @inputs, $test,
          Test::Mutation::Store::Key::digest(
            map { ( $_, $libraries{$_} ||= Test::Mutation::Store::Key::tree( $_, [] ) ) } @paths );
    }
    return Test::Mutation::Store::Key::digest(@inputs);
}

sub _test_list ($records) {
    my @tests;
    for my $name ( sort keys %$records ) {
        my $record = $records->{$name};
        my $test   = { name => $name, duration => $record->{duration} };
        $test->{neutral} = 1 if $record->{reusable} && !keys $record->{files}->%*;
        push @tests, $test;
    }
    return \@tests;
}

sub _plan_originals ($run) {
    my $all  = $run->{test_paths};
    my $cold = { tests => {}, missing => $all };
    return $cold unless $run->{config}->cache;
    my $saved = Test::Mutation::Store::originals( _cache_path($run) );
    my %tests = map { $_ => $saved->{tests}{$_} } grep { exists $saved->{tests}{$_} } @$all;
    return $cold unless keys %tests;
    local $run->{build} = $saved->{build};
    _prepare_build( $run, $run->{targets} ) if $run->{config}->in_place;
    my $shared = _run_inputs( $run, { tests => \%tests } );
    return $cold unless defined $shared;
    my %verified;

    for my $test ( sort keys %tests ) {
        my $record = $tests{$test};
        my $key    = _original_key( $run, $shared, $test, $record );
        next unless defined $key && $key eq $record->{inputs};
        $verified{$test} = { %$record, anomalies => {}, reusable => 1 };
    }
    return { tests => \%verified, missing => [ grep { !exists $verified{$_} } @$all ], shared => $shared };
}

sub _complete_baseline ( $run, $plan ) {
    my $all      = $run->{test_paths};
    my $hits     = $plan->{tests};
    my $missing  = $plan->{missing};
    my $baseline = { tests => {}, parallel_safe => 1, failures => [] };
    if ( @$missing && keys %$hits && defined $run->{copies} ) {
        my $trial = _control_copy( $run, $run->{root} );
        {
            local $run->{root} = $trial;
            $baseline = _observed_baseline( $run, $missing );
        }
        _discard($trial);
    }
    elsif (@$missing) {
        $hits     = {};
        $baseline = _observed_baseline( $run, $all );
    }
    my %combined = ( %$hits, $baseline->{tests}->%* );
    my $shared   = keys %$hits && @$missing ? _run_inputs( $run, { tests => \%combined } ) : undef;
    if (
           keys %$hits
        && @$missing
        && (   $run->{baseline_changed}
            || !$baseline->{parallel_safe}
            || $baseline->{failures}->@*
            || !defined $shared
            || $shared ne $plan->{shared} )
      )
    {
        $hits     = {};
        $baseline = _observed_baseline( $run, $all );
        %combined = $baseline->{tests}->%*;
    }
    $baseline->{tests}       = \%combined;
    $run->{reused_originals} = $hits;
    my %breakable;
    for my $record ( values %combined ) {
        for my $path ( keys $record->{breakable}->%* ) {
            my $lines = $record->{breakable}{$path};
            $breakable{$path}{$_} = $lines->{$_} for keys %$lines;
        }
    }
    $baseline->{breakable} = \%breakable;
    _save_originals( $run, $baseline ) if $run->{config}->cache && @$missing;
    return $baseline;
}

sub _empty_entries ( $run, $selection, $needs_tests ) {
    _warn( $run, Test::Mutation::Message::warning('tests-unmatched') ) if $needs_tests;
    if ( $run->{config}->cache && !$selection->narrowed && !$run->{options}{baseline_only} ) {
        my $path = _cache_path($run);
        Test::Mutation::Store::save( $path, {}, [] ) if -f $path;
    }
    return [ map { $_->suppressed ? _suppressed($_) : _entry( $_, 'NoCoverage', 'unreached', undef, undef, [], 0, 0 ) }
          $selection->mutants->@* ];
}

sub _spew ( $path, $content ) {
    open my $handle, '>:raw', $path or Test::Mutation::Error::raise( 'file-unwritable', path => $path, reason => "$!" );
    print {$handle} $content or Test::Mutation::Error::raise( 'file-unwritable', path => $path, reason => "$!" );
    close $handle            or Test::Mutation::Error::raise( 'file-unclosable', path => $path, reason => "$!" );
    return;
}

sub _entry ( $mutant, $status, $reason, $detail, $by, $covered_by, $tests_run, $duration ) {
    return {
        mutant     => $mutant,
        status     => $status,
        reason     => $reason,
        detail     => $detail,
        by         => $by,
        covered_by => $covered_by,
        tests_run  => $tests_run,
        duration   => $duration,
    };
}

sub _suppressed ($mutant) {
    my $reason = $mutant->suppression_reason;
    my $detail = 'suppressed by a comment' . ( defined $reason ? ": $reason" : q{} );
    return _entry( $mutant, 'Ignored', 'suppressed', $detail, undef, [], 0, 0 );
}

# Tasks end in an order that changes from run to run, so the warnings form a set that the result sorts.
sub _warn ( $run, $text ) {
    $run->{warnings}{$text} = 1;
    return;
}

sub _release_workspace ($run) {
    my $workspace = delete $run->{workspace} or return;
    if ( my $guard = delete $run->{guard} ) {
        my $restored = Test::Mutation::Try::attempt( sub { _restore_project( $run, $workspace, $guard ) } );
        if ( exists $restored->{error} ) {
            $workspace->release(1);
            die $restored->{error};    ## no critic (ErrorHandling::RequireCarping)
        }
    }
    _warn( $run, Test::Mutation::Message::warning( 'work-directory-stays', path => $workspace->directory ) )
      unless $workspace->release( $run->{config}->keep_work );
    return;
}

sub _restore_project ( $run, $workspace, $guard ) {
    Test::Mutation::Error::raise(
        'directory-unopenable',
        path   => $guard->{backup},
        reason => 'test processes still hold the workspace'
    ) unless Test::Mutation::Workspace::Processes::finish( $workspace->directory . '/processes' );
    my $changes = Test::Mutation::Tree::changes( $guard->{state}, _tree($run) );
    return _restore_changes( $run, $guard, $changes );
}

sub _restore_changes ( $run, $guard, $changes ) {
    for my $change ( $changes->@* ) {
        my $path = $change =~ s/\A\w+[ ]//r;
        Test::Mutation::Error::raise(
            'file-unreadable',
            path   => $path,
            reason => 'the original could not be backed up'
          )
          if grep { $_ eq $path || index( "$_/", "$path/" ) == 0 || index( "$path/", "$_/" ) == 0 }
          $guard->{opaque}->@*;
    }
    return Test::Mutation::Tree::restore( from => $guard->{backup}, to => $run->{project}, changes => $changes );
}

sub _prepare_work ($run) {
    my $work       = $run->{work} = $run->{workspace}->directory . '/work';
    my $outer      = $ENV{TEST_MUTATION_GENERATION};
    my $generation = defined $outer ? $outer + 1 : 1;
    Test::Mutation::Tree::make(
        map { "$work/$_" } 'shim/Test/Mutation/Shim',
        'compiler/Test/Mutation/CompilerInputs',
        'mutants', 'records', 'tmp'
    );
    my $shim = shim_text($generation);
    _spew( "$work/shim/Test/Mutation/Shim/G$generation.pm", $shim );

    # A standalone target can load its own module under the name used for the preloaded shim.
    my $trace = Test::Mutation::Witness::trace_package($work);
    $shim =~ s/^ \Qpackage Test::Mutation::Shim::G$generation;\E $/package $trace;/mx;
    _spew( "$work/trace.pl", $shim );
    _spew( "$work/compiler/Test/Mutation/CompilerInputs/G$generation.pm",
        _generation_text( $COMPILER_FILE, $generation ) );
    $run->{generation} = $generation;
    return;
}

signature_for shim_text => ( positional => [Str], returns => Str );

sub shim_text ($generation) {
    my $text = _generation_text( $SHIM_FILE, $generation );
    $text =~ s/^my \$GENERATION = 0;$/my \$GENERATION = $generation;/m
      or die Test::Mutation::Message::text_of( 'shim-unprepared', generation => $generation ) . "\n";
    return $text;
}

sub _generation_text ( $file, $generation ) {
    my $text    = _module_text($file);
    my $package = join '::', split m{/}, substr $file, 0, -length '.pm';
    $text =~ s/^package \Q$package\E;$/package ${package}::G$generation;/m
      or die Test::Mutation::Message::text_of( 'shim-unprepared', generation => $generation ) . "\n";
    return $text;
}

sub _module_text ($file) {
    my $compiler = $file eq $COMPILER_FILE;
    my @entries  = $compiler ? ( ( grep { ref } @INC ), $DRIVER_LIB ) : @INC;

    # The outer shim resolves the requested name in @INC before selecting the source to serve.
    local @INC = ( $DRIVER_LIB, @INC ) if $compiler;
    for my $entry (@entries) {
        if ( ref $entry eq 'CODE' ) {
            my @served = $entry->( $entry, $file );
            next          if !@served;
            shift @served if ref $served[0] eq 'SCALAR';
            my $handle = shift @served;
            next if ref $handle ne 'GLOB';
            my $filter = ref $served[0] eq 'CODE' ? $served[0] : undef;
            my $text   = q{};
            while ( defined( my $line = readline $handle ) ) {
                if ($filter) {
                    local $_ = $line;
                    $filter->();
                }
                $text .= $line;
            }
            if ($filter) {
                local $_ = q{};
                $filter->();
            }
            return $text;
        }
        next                                                      if ref $entry;
        return Test::Mutation::Source::read_bytes("$entry/$file") if -f "$entry/$file";
    }
    die Test::Mutation::Message::text_of( 'shim-missing', file => $file ) . "\n";
}

sub _first_line ( $run, $path ) {
    if ( !exists $run->{first}{$path} ) {
        open my $handle, '<', "$run->{root}/$path"
          or Test::Mutation::Error::raise( 'file-unreadable', path => $path, reason => "$!" );
        $run->{first}{$path} = readline $handle;
        close $handle or Test::Mutation::Error::raise( 'file-unclosable', path => $path, reason => "$!" );
    }
    return $run->{first}{$path};
}

sub _remove_disk_spec ($spec) {
    my $path = "$spec.disk";
    unlink $path
      or $! == Errno::ENOENT()
      or Test::Mutation::Error::raise( 'file-unremovable', path => $path, reason => "$!" );
    return;
}

sub _spec ( $run, $root, $name, $trace, $targets ) {
    my $path  = "$run->{work}/$name.spec";
    my @lines = ( "trace\t" . ( $trace ? 1 : 0 ) );
    push @lines, "includes\t1"   if $name !~ m{\Amutants/};
    push @lines, "placed\t1"     if defined $run->{copies};
    push @lines, "trace_eval\t1" if $run->{trace_eval};
    _remove_disk_spec($path);
    for my $target ( $targets->@* ) {
        my @original = $root ne $run->{project} ? $run->{project} . substr( $target->[0], length $root ) : ();
        push @lines, join "\t", 'target', $target->@*, @original;
        my $relative = substr $target->[0], length($root) + 1;
        next unless defined $run->{copies};
        push @lines, "extract\t$target->[0]"
          if $run->{witness}{$relative} && defined $run->{witness}{$relative}{extract};
        next unless $trace && $relative =~ m{\A(?:bin|script)/} && -f $target->[0];
        my $headers = Test::Mutation::Workspace::Slot::twins( $root, $relative,
            Test::Mutation::Source::read_bytes( $target->[0] ) );
        push @lines, map { "command\t$target->[0]\t$root/$_" } sort keys %$headers;
    }
    _spew( $path, join q{}, map { "$_\n" } @lines );
    return $path;
}

signature_for target_pairs => (
    positional => [ Str, ArrayRef [Str], Str, Str ],
    returns    => ArrayRef [ Tuple [ Str, Str ] ],
);

sub target_pairs ( $root, $paths, $mutated, $file ) {
    my %listed = map { $_ => 1 } $paths->@*;
    my @paths  = ( $paths->@*, $listed{$mutated} ? () : $mutated );
    return [ map { [ "$root/$_", $_ eq $mutated ? $file : "$root/$_" ] } @paths ];
}

sub _place ( $run, $root, $path, $before, $after ) {
    my $products = Test::Mutation::Workspace::Slot::products( $root, $path, $before );
    Test::Mutation::Workspace::Slot::install( $root, $path, $after, $products->{twins} );
    my $generated = $products->{generated};
    return unless keys %$generated;
    _build_command( $run, $root, $run->{build} ) if $run->{build} && $run->{build}->@*;
    for my $copy ( sort keys %$generated ) {
        return $copy if !-f "$root/$copy" || Test::Mutation::Source::read_bytes("$root/$copy") eq $generated->{$copy};
    }
    return;
}

sub _changed_source ( $run, $source, $mutant ) {
    my $file  = "$run->{work}/mutants/" . $mutant->id . '.pm';
    my $text  = $source->replace_span( $mutant->start, $mutant->end, $mutant->replacement );
    my $bytes = $source->to_bytes($text);
    _spew( $file, $bytes );
    return ( $file, $text, $bytes );
}

sub _observed_bytes ( $run, $source, $mutant, $root, $text ) {
    my $witness = $run->{witness}{ $mutant->path };
    my $at;
    if ($witness) {
        $at = $witness->{offset};
        if ( $mutant->end <= $at ) {
            $at += length( $mutant->replacement ) - ( $mutant->end - $mutant->start );
        }
        elsif ( $mutant->start < $at ) {
            $at = $mutant->start;
        }
    }
    if ( my $call = $mutant->introduced_call ) {
        my ( $name, $position ) = @$call;
        my $statement = Test::Mutation::Witness::binding( $name, $run->{generation}, "$root/" . $mutant->path,
            "$run->{work}/records", defined $run->{task_descriptor} ? fileno( $run->{task_descriptor} ) : undef );
        substr $text, $position, 0, $statement;
        $at += length $statement if defined $at && $position < $at;
    }
    return defined $at ? _marked_bytes( $run, $source, $text, $at ) : $source->to_bytes($text);
}

sub _write_mutant ( $run, $source, $mutant, $root, $raw = 0 ) {
    my ( $file, $text, $bytes ) = _changed_source( $run, $source, $mutant );
    my $placed = !$raw && $run->{targets} ? _observed_bytes( $run, $source, $mutant, $root, $text ) : $bytes;
    my $served = $file;
    my $stale;
    if ( defined $run->{copies} ) {
        $stale  = _place( $run, $root, $mutant->path, $source->to_bytes( $source->text ), $placed );
        $served = "$root/" . $mutant->path;
    }
    elsif ( $placed ne $bytes ) {
        $served = "$file.observed";
        _spew( $served, $placed );
    }
    my $targets = target_pairs( $root, $run->{targets} ? $run->{targets} : [], $mutant->path, $served );
    my $spec    = _spec( $run, $root, 'mutants/' . $mutant->id, 0, $targets );
    return ( $file, $spec, $stale );
}

signature_for run_command => (
    positional => [
        InstanceOf ['Test::Mutation::Config'],
        InstanceOf ['Test::Mutation::Source'],
        InstanceOf ['Test::Mutation::Mutant'],
        ArrayRef [Str]
    ],
    returns => Int,
);

sub run_command ( $config, $source, $mutant, $command ) {
    my $root = Cwd::abs_path( $config->root );
    my $run  = { config => $config, project => $root, root => $root, listener => sub { return } };
    my $work = sub {
        $run->{workspace} = Test::Mutation::Workspace::acquire($root);
        _copy_project($run);
        my $where = $run->{root};
        Test::Mutation::Error::raise( 'source-changed', path => $source->path )
          if Test::Mutation::Source::read_bytes( "$where/" . $source->path ) ne $source->to_bytes( $source->text );
        _prepare_build( $run, [ $source->path ] );
        _prepare_work($run);
        my ( undef, undef, $stale ) = _write_mutant( $run, $source, $mutant, $where );
        Test::Mutation::Error::raise( 'build-copy-not-updated', path => $stale, source => $source->path )
          if defined $stale;
        my $environment = Test::Mutation::Launch::test_command(
            perl    => $^X,
            root    => $where,
            program => $command->[0],
            tmp     => "$run->{work}/tmp",
            lib     => $config->lib,
            switch  => $config->switch,
            env     => \%ENV,
        )->{env};
        delete $environment->@{qw(HARNESS_ACTIVE HARNESS_VERSION)};
        local %ENV = ( %ENV, $environment->%* );
        my $lease = Test::Mutation::Workspace::Processes::inherit( $run->{workspace}->directory . '/processes' );

        # A command that cannot start ends exec with one line of the tool, and the warning of Perl would add another.
        no warnings 'exec';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
        my $previous = Cwd::getcwd();
        chdir $where or Test::Mutation::Error::raise( 'test-directory-closed', directory => $where, reason => "$!" );
        return Test::Mutation::Try::with_cleanup(
            sub {
                my $status = system { $command->[0] } $command->@*;
                return [ $status, $! == Errno::ENOENT(), "$!" ];
            },
            sub {
                chdir $previous
                  or Test::Mutation::Error::raise( 'test-directory-closed', directory => $previous, reason => "$!" );
            },
        );
    };

    # A signal for the tool alone waits while the command runs, and it ends the work once the work directory is gone.
    my $ran = Test::Mutation::Signals::watch(
        sub {
            Test::Mutation::Try::with_cleanup( $work, sub { _release_workspace($run) } );
        }
    );
    my ( $status, $missing, $reason ) = $ran->@*;
    if ( $status == -1 ) {
        Test::Mutation::Error::raise( 'command-not-found',    command => $command->[0], reason => $reason ) if $missing;
        Test::Mutation::Error::raise( 'command-not-runnable', command => $command->[0], reason => $reason );
    }
    return 128 + ( $status & 127 ) if $status & 127;
    return $status >> 8;
}

sub _launch ( $run, $root, $tmp, $source, %task ) {
    return Test::Mutation::Launch::test_command(
        perl   => $run->{perl},
        root   => $root,
        tmp    => $tmp,
        env    => \%ENV,
        lib    => $run->{config}->lib,
        switch => $run->{config}->switch,
        first  => _first_line( $run, $source ),
        %task,
    );
}

sub _test_task ( $run, %arg ) {
    my $sequence = ++$run->{sequence};
    my $work     = $run->{work};
    my $tmp      = "$work/tmp/$sequence";
    Test::Mutation::Tree::make($tmp);
    my @identity = ( stat $tmp )[ 0, 1 ];
    my $record   = "$work/records/" . join( '-', @identity );
    Test::Mutation::Tree::make($record);
    my $spec = $arg{spec};

    if ( $run->{try_disk} || $run->{disk_test}{ $arg{test} } ) {
        my $disk = "$spec.disk";
        _spew( $disk, Test::Mutation::Source::read_bytes($spec) . "observe\t1\n" ) unless -e $disk;
        $spec = $disk;
    }
    my $launch = _launch(
        $run, $arg{root}, $tmp, $arg{test},
        program => $arg{test},
        shim    => { generation => $run->{generation}, directory => "$work/shim", record => $record, spec => $spec },
    );
    return {
        $launch->%*,
        cwd => $arg{root},
        $run->{task_descriptor}
        ? ( observation => { directory => $tmp, descriptor => fileno( $run->{task_descriptor} ) } )
        : (),
        lease           => $run->{workspace}->directory . '/processes',
        timeout         => $arg{timeout},
        output_limit    => $OUTPUT_LIMIT,
        stop_on_failure => $arg{stop_on_failure},
        payload         => {
            $arg{payload}->%*,
            test    => $arg{test},
            record  => $record,
            tmp     => $tmp,
            targets => [ map { "$arg{root}/$_" } $run->{targets}->@* ]
        },
    };
}

sub _collect ($task) {
    my $payload = $task->{payload};
    my $record  = Test::Mutation::Record::read_directory( $payload->{record}, $payload->{targets} );
    _discard( $payload->{record}, $payload->{tmp} );
    return $record;
}

# Runs tests against the unmodified sources, which the hook serves as it serves a mutant.
# `counted` names the count of the work that the runs of these tests add to.
sub _unmodified ( $run, $name, $trace, $jobs, $tests, $counted, $isolated = 0 ) {
    my $root     = $run->{root};
    my $spec_for = sub ( $directory, $label ) {
        return _spec( $run, $directory, $label, $trace,
            [ map { [ "$directory/$_", "$directory/$_" ] } $run->{targets}->@* ] );
    };
    my $shared = $isolated ? undef : $spec_for->( $root, $name );
    my $queue  = Test::Mutation::Schedule::queue( $run->{rules}, $tests );
    my %outcome;
    Test::Mutation::Pool::run(
        jobs             => $jobs,
        retry_after_done => 1,
        work             => $run->{stats},
        next             => sub {
            my $scheduled = $queue->get_job or return;
            return if $scheduled->is_spinner;
            my $directory = $isolated ? _control_copy( $run, $root )                             : $root;
            my $spec      = $isolated ? $spec_for->( $directory, "$name-" . ++$run->{sequence} ) : $shared;
            $run->{stats}{$counted}++;
            return _test_task(
                $run,
                root            => $directory,
                test            => $scheduled->filename,
                spec            => $spec,
                timeout         => $run->{config}->baseline_timeout,
                stop_on_failure => 0,
                payload         => { scheduled => $scheduled },
            );
        },
        done => sub ( $task, $result ) {
            my $payload = $task->{payload};
            $outcome{ $payload->{test} } = { result => $result, record => _collect($task), root => $task->{cwd} };
            $payload->{scheduled}->finish;
            $run->{listener}->( 'baseline_test', { test => $payload->{test}, passed => $result->{passed} } )
              if $counted eq 'baseline_tests';
            _discard( $task->{cwd} ) if $isolated;
            return;
        },
    );
    return \%outcome;
}

sub _prepare_witnesses ($run) {
    $run->{task_descriptor} = Test::Mutation::Witness::reserve( $run->{workspace}->directory . '/processes' );
    my $targets = $run->{targets};
    for my $index ( keys $targets->@* ) {
        my $path = $targets->[$index];
        my $at   = Test::Mutation::Syntax::PPI::witness_offsets( $run->{sources}{$path} );
        $run->{witness}{$path} = { index => $index, first => $at->[0], offset => $at->[1], extract => $at->[2] } if $at;
    }
    return;
}

sub _marked_bytes ( $run, $source, $text, $at ) {
    my $witness = $run->{witness}{ $source->path };
    return $source->to_bytes(
        Test::Mutation::Witness::insert(
            $text,                  $at,
            $run->{generation},     $witness->{index},
            "$run->{work}/records", fileno( $run->{task_descriptor} )
        )
    );
}

sub _mark_originals ( $run, $root, $install, @paths ) {
    for my $path ( @paths ? @paths : sort keys $run->{witness}->%* ) {
        my $source = $run->{sources}{$path};
        my $raw    = $source->to_bytes( $source->text );
        my $marked = _marked_bytes( $run, $source, $source->text, $run->{witness}{$path}{offset} );
        my ( $before, $after ) = $install ? ( $raw, $marked ) : ( $marked, $raw );
        next if !-f "$root/$path" || Test::Mutation::Source::read_bytes("$root/$path") ne $before;
        my $stale = _place( $run, $root, $path, $before, $after );
        $run->{stale}{$path} = $stale if $install && defined $stale;
    }
    return;
}

sub _observed_baseline ( $run, $tests ) {
    _mark_originals( $run, $run->{root}, 1 ) if $run->{task_descriptor};
    my $original =
      defined $run->{copies} ? _tree($run) : $run->{config}->cache && $run->{guard} ? $run->{guard}{state} : undef;
    my $baseline = _baseline( $run, $tests, $run->{targets} );
    if ( defined $original ) {
        my $after = _tree($run);
        $run->{baseline_changed} = Test::Mutation::Tree::changes( $original, $after )->@* ? 1 : 0;
        $run->{tree}             = $after if !defined $run->{copies};
    }
    _mark_originals( $run, $run->{root}, 0 ) if $run->{task_descriptor};
    return $baseline;
}

sub _disk_baseline ( $run, $pass, $outcome, $failed ) {
    my @completed = grep { _ending( $outcome->{$_}{result} ) eq 'fail' } $failed->@*;
    return unless @completed;
    my $disk;
    {
        local $run->{try_disk} = 1;
        $disk = $pass->( 1, \@completed, 'verifications' );
    }
    my @passed = grep { $disk->{$_}{result}{passed} } @completed;
    return unless @passed;
    my $hooked = $pass->( 1, \@passed, 'verifications' );
    for my $test (@passed) {
        next if $hooked->{$test}{result}{passed};
        $outcome->{$test} = $disk->{$test};
        $run->{disk_test}{$test} = 1;
    }
    return;
}

sub _baseline ( $run, $tests, $targets ) {
    my $pass = sub ( $jobs, $names, $counted ) {
        return _unmodified( $run, 'baseline', $run->{config}->coverage eq 'line', $jobs, $names, $counted );
    };

    my $outcome       = $pass->( $run->{jobs}, $tests, 'baseline_tests' );
    my @failed        = grep { !$outcome->{$_}{result}{passed} } $tests->@*;
    my $parallel_safe = 1;
    if ( @failed && $run->{jobs} > 1 ) {
        my $serial = $pass->( 1, \@failed, 'verifications' );
        $outcome->{$_} = $serial->{$_} for @failed;
        @failed = grep { !$outcome->{$_}{result}{passed} } @failed;
        if ( !@failed ) {
            my $isolated =
              defined $run->{copies}
              ? _unmodified( $run, 'separate', $run->{config}->coverage eq 'line',
                $run->{jobs}, $tests, 'verifications', 1 )
              : undef;
            if ( $isolated && !grep { !$isolated->{$_}{result}{passed} } $tests->@* ) {
                $outcome = $isolated;
            }
            else {
                $parallel_safe = 0;
                $run->{jobs} = 1;
                _warn( $run, Test::Mutation::Message::warning('tests-conflict') );
            }
        }
    }

    if ( @failed && defined $run->{copies} ) {
        _disk_baseline( $run, $pass, $outcome, \@failed );
        @failed = grep { !$outcome->{$_}{result}{passed} } @failed;
    }
    if ( @failed && $run->{task_descriptor} ) {
        _raw_baseline( $run, \@failed, $outcome );
        @failed = grep { !$outcome->{$_}{result}{passed} } @failed;
    }
    _trace_blind( $run, $outcome ) if !@failed && $run->{task_descriptor} && $run->{config}->coverage eq 'line';
    _observe_in_place_loads( $run, $tests, $targets, $outcome ) if !@failed && $run->{guard};
    my $records = _baseline_records( $run, $tests, $targets, $outcome );
    return {
        tests         => $records,
        parallel_safe => $parallel_safe,
        failures      => [ map { _failure( $_, $outcome->{$_}{result} ) } @failed ],
    };
}

sub _observe_in_place_loads ( $run, $tests, $targets, $outcome ) {
    my $project = $run->{project};
    my %unknown;
    for my $test (@$tests) {
        my $record  = $outcome->{$test}{record};
        my @missing = grep {
            my $path = "$project/$_";
            !$record->{served}{$path} && !$record->{bypassed}{$path} && !$record->{outside}{$path};
        } @$targets;
        $unknown{$test} = \@missing if @missing;
    }
    my @probe_tests = sort keys %unknown;
    return unless @probe_tests;
    local $run->{name} = File::Basename::basename($project);
    my $probe = _control_copy( $run, $run->{guard}{backup} );
    local $run->{root}            = $probe;
    local $run->{copies}          = $probe;
    local $run->{first}           = {};
    local $run->{witness}         = {};
    local $run->{task_descriptor} = undef;
    _prepare_witnesses($run);
    _mark_originals( $run, $probe, 1 );
    my $observed = _unmodified( $run, 'in-place-loads', 0, 1, \@probe_tests, 'verifications' );

    for my $test (@probe_tests) {
        next unless $observed->{$test}{result}{passed};
        for my $path ( $unknown{$test}->@* ) {
            my $record = $observed->{$test}{record};
            $outcome->{$test}{record}{bypassed}{"$project/$path"} = 1 if $record->{compiled}{"$probe/$path"};
        }
    }
    _discard($probe);
    return;
}

sub _reusable_baseline ( $run, $test, $result, $record, $anomalies ) {
    return
         $result->{passed}
      && !$result->{stopped}
      && !$result->{early}
      && !$run->{disk_test}{$test}
      && !keys %$anomalies
      && !keys $record->{load_failed}->%*
      && !keys $record->{bypassed}->%*;
}

sub _baseline_records ( $run, $tests, $targets, $outcome ) {
    my %tests;
    for my $test ( $tests->@* ) {
        my ( $result, $record ) = $outcome->{$test}->@{qw(result record)};
        my ( %files, %breakable, %anomalies );
        for my $path ( $targets->@* ) {
            my $absolute = ( $outcome->{$test}{root} || $run->{root} ) . "/$path";
            my $evidence = Test::Mutation::Evidence::target( $record, $absolute );
            $files{$path} = $evidence->{coverage}       if $evidence->{coverage};
            $files{$path} = { traced => 0, hits => {} } if $run->{sensitive}{$test}{$path};
            my $lines = $evidence->{breakable};
            $breakable{$path} = $lines if $lines;
            my $anomaly = $evidence->{anomaly} or next;
            if ( $anomaly->{reason} eq 'loaded-around-hook' ) {
                _warn( $run, Test::Mutation::Message::warning( 'loaded-around-hook', test => $test, path => $path ) );
                next unless $run->{guard};
            }
            $anomalies{$path} = $anomaly;
            $files{$path}     = { traced => 0, hits => {} };
        }
        my $workspace = $run->{workspace}->directory;
        my @includes  = grep { index( "$_/", "$workspace/" ) != 0 && index( "$_/", "$run->{project}/" ) != 0 }
          map { Cwd::abs_path($_) || $_ } @{ $record->{includes} || [] };
        $tests{$test} = {
            includes  => \@includes,
            breakable => \%breakable,
            duration  => $result->{duration},
            files     => \%files,
            anomalies => \%anomalies,
            reusable  => _reusable_baseline( $run, $test, $result, $record, \%anomalies )
        };
    }
    return \%tests;
}

sub _trace_blind ( $run, $outcome ) {
    my $original = $run->{root};
    my ( %tests, %paths );
    for my $test ( sort keys $outcome->%* ) {
        my $served = $outcome->{$test}{record}{served};
        for my $path ( keys $run->{witness}->%* ) {
            my $coverage = $served->{ ( $outcome->{$test}{root} || $original ) . "/$path" };
            next if !$coverage || $coverage->{traced} || $run->{sensitive}{$test}{$path};
            push $tests{$test}->@*, $path;
            $paths{$path} = 1;
        }
    }
    return unless keys %tests;
    my $probe = _control_copy( $run, $original );
    for my $path ( sort keys %paths ) {
        my $source = Test::Mutation::Source->from_bytes(
            path  => $path,
            bytes => Test::Mutation::Source::read_bytes("$probe/$path"),
        );
        my $witness = $run->{witness}{$path};
        my $text    = $source->text;
        for my $at ( grep { defined } $witness->@{qw(extract first)} ) {
            $text = Test::Mutation::Witness::trace(
                text       => $text,
                offset     => $at,
                line       => $source->position_of($at)->[0],
                generation => $run->{generation},
                index      => $witness->{index},
                target     => "$probe/$path",
                work       => $run->{work},
                descriptor => fileno( $run->{task_descriptor} ),
            );
        }
        _place( $run, $probe, $path, $source->to_bytes( $source->text ), $source->to_bytes($text) );
    }
    local $run->{root}       = $probe;
    local $run->{first}      = {};
    local $run->{trace_eval} = 1;
    my $observed = _unmodified( $run, 'trace-lines', 1, $run->{jobs}, [ sort keys %tests ], 'verifications' );
    for my $test ( sort keys %tests ) {
        next unless $observed->{$test}{result}{passed};
        my $record = $observed->{$test}{record};
        for my $path ( $tests{$test}->@* ) {
            my $read = Test::Mutation::Evidence::target( $record, "$probe/$path" );
            next if $read->{anomaly} || !$read->{coverage} || !$read->{coverage}{traced};
            my $absolute = ( $outcome->{$test}{root} || $original ) . "/$path";
            $outcome->{$test}{record}{served}{$absolute}    = $read->{coverage};
            $outcome->{$test}{record}{breakable}{$absolute} = $read->{breakable} if $read->{breakable};
        }
    }
    _discard($probe);
    return;
}

sub _raw_trial ( $run, $root, $test ) {
    local $run->{root}     = $root;
    local $run->{first}    = {};
    local $run->{try_disk} = 1;
    my $outcome = _unmodified( $run, 'source-check-' . ++$run->{sequence}, 0, 1, [$test], 'verifications' );
    return { $outcome->{$test}->%*, root => $root };
}

sub _raw_baseline ( $run, $tests, $outcome ) {
    my @tests = grep { _ending( $outcome->{$_}{result} ) eq 'fail' } $tests->@*;
    return unless @tests;
    my $clean = _control_copy( $run, $run->{root} );
    _mark_originals( $run, $clean, 0 );
    for my $test (@tests) {
        my $trial = _control_copy( $run, $clean );
        my $raw   = _raw_trial( $run, $trial, $test );
        _discard($trial);
        next unless $raw->{result}{passed};
        for my $path ( sort keys $run->{witness}->%* ) {
            my $probe = _control_copy( $run, $clean );
            _mark_originals( $run, $probe, 1, $path );
            my $observation = _raw_trial( $run, $probe, $test );
            _discard($probe);
            $run->{sensitive}{$test}{$path} = 1 if _ending( $observation->{result} ) eq 'fail';
        }
        if ( keys $run->{sensitive}{$test}->%* ) {
            $outcome->{$test} = $raw;
            $run->{disk_test}{$test} = 1;
        }
    }
    _discard($clean);
    return;
}

sub _fresh_job ( $mutant, $tests, $duration = 0 ) {
    return {
        mutant   => $mutant,
        tests    => $tests,
        index    => 0,
        verdict  => Test::Mutation::Verdict::start(),
        duration => $duration
    };
}

sub _eligible_detector ( $rules, $tests, $hint ) {
    return       unless defined $hint;
    return       unless List::Util::first { $tests->[$_] eq $hint } 1 .. $#$tests;
    return $hint unless $rules;
    my $queue = Test::Mutation::Schedule::queue( $rules, $tests );
    while ( my $job = $queue->get_job ) {
        return       if $job->is_spinner;
        return $hint if $job->filename eq $hint;
    }
    return;
}

sub _measurement_jobs ( $run, $mutants, $baseline, $cache, $entries ) {
    my $config   = $run->{config};
    my $coverage = Test::Mutation::Coverage->new(
        mode      => $config->coverage,
        breakable => $baseline->{breakable},
        tests     => { map { $_ => { $baseline->{tests}{$_}->%{qw(duration files)} } } keys $baseline->{tests}->%* },
    );

    my $tests_for = sub ($mutant) {
        my $tests = $coverage->tests_for($mutant);
        $tests = [ sort keys $baseline->{tests}->%* ] if !$tests->@* && exists $run->{stale}{ $mutant->path };
        $tests = [ map { $_->filename } Test::Mutation::Schedule::queue( $run->{rules}, $tests )->get_all ]
          if $run->{rules};
        my $killer = $run->{sample_killers}{ $mutant->id };
        return defined $killer ? [$killer] : $tests;
    };
    for my $mutant ( $mutants->@* ) {
        my $id = $mutant->id;
        if    ( $mutant->suppressed ) { $entries->{$id} = _suppressed($mutant) }
        elsif ( $cache && $cache->{records}{$id} ) {
            $entries->{$id} = _reused_entry( $run, $cache, $mutant, $tests_for->($mutant) );
        }
    }
    my $position = 0;
    return sub {
        while ( $position < @$mutants ) {
            my $mutant = $mutants->[ $position++ ];
            next if $entries->{ $mutant->id };
            my $tests = $tests_for->($mutant);
            my $hint  = _eligible_detector( $run->{rules}, $tests, $run->{detector_hints}{ $mutant->id } );
            my $job   = _fresh_job( $mutant, $tests );
            $job->{detector} = $hint if defined $hint;
            return $job;
        }
        return;
    };
}

sub _check_reused ( $run, $cache, $baseline, $entries ) {
    my @hits   = grep { defined $entries->{$_} && !$entries->{$_}{mutant}->suppressed } sort keys %$entries;
    my $sample = Test::Mutation::Store::sample( \@hits, join q{/}, $$, Time::HiRes::time() );
    my $observations;
    {
        local $run->{listener} = sub { return };
        local $run->{sample_killers} =
          { map { $_ => $entries->{$_}{by} } grep { $entries->{$_}{status} eq 'Killed' } @$sample };
        $observations = _mutants( $run, [ map { $entries->{$_}{mutant} } @$sample ], $baseline, 1 );
    }
    $run->{stats}{verifications} += scalar @$observations;
    return $observations if $run->{interrupted};
    for my $fresh (@$observations) {
        my $id      = $fresh->{mutant}->id;
        my $cached  = $entries->{$id};
        my $changed = grep {
            my ( $before, $after ) = ( $cached->{$_}, $fresh->{$_} );
            defined $before ? !defined $after || $before ne $after : defined $after;
        } qw(status reason by);
        next unless $changed;
        Test::Mutation::Store::save( $cache->{path}, {}, [], {}, { build => [], tests => {}, reset => 1 } );
        $run->{cache_mismatch} = 1;
        $run->{reused}         = 0;
        $run->{code_of_mutant} = {};
        _warn( $run, Test::Mutation::Message::warning( 'cache-verdict-changed', id => $id ) );
        return;
    }
    $run->{listener}->( 'mutant', $entries->{$_} ) for @hits;
    return;
}

sub _mutants ( $run, $mutants, $baseline, $sample_only = 0 ) {
    my $cache = !$sample_only && $run->{config}->cache ? _open_cache( $run, $baseline, $mutants ) : undef;
    my %entry_of;
    my $next_job = _measurement_jobs( $run, $mutants, $baseline, $cache, \%entry_of );
    if ( $cache && $run->{reused} ) {
        my $interrupted = _check_reused( $run, $cache, $baseline, \%entry_of );
        if ( $run->{cache_mismatch} && keys $run->{reused_originals}->%* ) {
            $baseline = _complete_baseline( $run, { tests => {}, missing => $run->{test_paths} } );
            $run->{rechecked_baseline} = $baseline;
            return [] if $baseline->{failures}->@*;
            $cache = _open_cache( $run, $baseline, $mutants );
        }
        if ( $run->{cache_mismatch} || $interrupted ) {
            %entry_of = ();
            $next_job = _measurement_jobs( $run, $mutants, $baseline, undef, \%entry_of );
        }
        if ($interrupted) {
            $run->{reused} = 0;
            $entry_of{ $_->{mutant}->id } = $_ for @$interrupted;
            _pending_jobs( $next_job, \%entry_of );
            return [ map { $entry_of{ $_->id } } @$mutants ];
        }
    }
    local $run->{sampling_verdicts} = $sample_only;
    _execute_jobs( $run, $baseline, $next_job, \%entry_of, $cache );

    my @entries = map { $entry_of{ $_->id } } $mutants->@*;
    if ( $cache && !$run->{interrupted} ) {
        my $inventory = $run->{narrowed} ? undef : [ map { $_->id } @$mutants ];
        Test::Mutation::Store::save( $cache->{path}, {}, $inventory, $cache->{targets} );
    }
    for my $entry (@entries) {
        my $code = $run->{code_of_mutant}{ $entry->{mutant}->id };
        $entry->{compiled_digest} = $code if defined $code;
    }
    return \@entries if $sample_only || defined $run->{config}->shard;
    return Test::Mutation::Verdict::conclude_inventory( \@entries );
}

sub _execute_jobs ( $run, $baseline, $next_job, $entries, $cache ) {
    my ( %unfinished, @checkpoints );
    my $schedule = { ready => [], active => {}, retrying => {}, locked => {}, compatible => {} };
    my $finish   = sub ($job) {
        _release( $run, $job );
        my $publish = _publish_finished( $run, $cache, _finish( $run, $job ), $entries, \%unfinished );
        if ($cache) { push @checkpoints, $publish }
        else        { $publish->(1) }
        return;
    };
    my $measure = sub {
        my $once = Test::Mutation::Once::coalesce(
            sub {
                while (1) {
                    my $prepared = _take_ready( $schedule, $run->{rules} );
                    return $prepared if $prepared;
                    return           if keys %unfinished >= $run->{jobs};
                    my $job = $next_job->() or return;
                    $cache->{checkpoint} ||= Test::Mutation::Store::checkpoints( $cache->{path} ) if $cache;
                    $unfinished{ $job->{mutant}->id } = $job;
                    my $task = $job->{tests}->@* ? _next_test( $run, $job, $baseline ) : _next_code( $run, $job );
                    if ($task) { push $schedule->{ready}->@*, $task }
                    else       { $finish->($job) }
                }
            },
            sub ( $task, $result ) {
                my $follow = _scheduled_result( $run, $baseline, $schedule, $task, $result );
                if ($follow) { push $schedule->{ready}->@*, $follow }
                else         { $finish->( $task->{payload}{job} ) }
                return;
            },
            sub ($task) {
                my $payload = $task->{payload};
                return unless defined $payload->{original};
                return join "\0", $payload->{original}, $payload->{imports};
            },
        );
        return Test::Mutation::Pool::run(
            jobs             => $run->{jobs},
            retry_after_done => 1,
            checkpoints      => \@checkpoints,
            work             => $run->{stats},
            done             => $once->{done},
            next             => sub {
                my $task = $once->{next}->() or return;
                $run->{stats}{compiles}++ if $task->{payload}{compile};
                return $task;
            },
        );
    };

    # A signal ends the measurement, and the mutants that it measured keep their results.
    my $attempt = Test::Mutation::Try::attempt( $measure, 'interruption' );
    return if exists $attempt->{value};
    my $error = $attempt->{error};
    die $error if !$INTERRUPTION->check($error);    ## no critic (ErrorHandling::RequireCarping)
    $run->{interrupted} = $error->signal;
    $_->(1) for @checkpoints;
    _pending_jobs( $next_job, $entries, values %unfinished );
    return;
}

sub _publish_finished ( $run, $cache, $entry, $entries, $unfinished ) {
    my $id = $entry->{mutant}->id;
    return sub ($may_wait) {
        return 1 if $entries->{$id};
        return 0 if $cache && !_save_observation( $run, $cache, $entry, $may_wait );
        $entries->{$id} = $entry;
        delete $unfinished->{$id};
        $run->{listener}->( 'mutant', $entry );
        return 1;
    };
}

sub _pending_jobs ( $next_job, $entries, @unfinished ) {
    while ( my $job = @unfinished ? pop @unfinished : $next_job->() ) {
        next if $entries->{ $job->{mutant}->id };
        my $tests_run = $job->{verdict}{tests};
        $tests_run += $job->{first}{tests} if $job->{first};
        my $entry = _entry( $job->{mutant}, 'Pending', 'interrupted', 'the run was interrupted',
            undef, $job->{tests}, $tests_run, $job->{duration} );
        $entry->{observations} = $job->{observations} if exists $job->{observations};
        $entries->{ $job->{mutant}->id } = $entry;
    }
    return;
}

sub _may_overlap ( $schedule, $rules, $test, $other ) {
    my $known = $schedule->{compatible}{$test} ||= {};
    return $known->{$other} if exists $known->{$other};
    return $known->{$other} = Test::Mutation::Schedule::compatible( $rules, $test, $other );
}

sub _take_ready ( $schedule, $rules ) {
    my $ready  = $schedule->{ready};
    my $active = $schedule->{active};
    for my $at ( keys $ready->@* ) {
        my $payload = $ready->[$at]{payload};
        if ( $payload->{kind} eq 'test' ) {
            my $test = $payload->{test};
            next if $schedule->{retrying}{$test}                           && !$payload->{isolated};
            next if ( $schedule->{locked}{$test} || $payload->{isolated} ) && $active->{$test};
            next if $rules && grep { !_may_overlap( $schedule, $rules, $test, $_ ) } keys $active->%*;
            my $peers = $active->{$test} ||= {};
            if ( keys $peers->%* ) {
                $_->{overlapped} = 1 for $payload, values $peers->%*;
            }
            $peers->{$payload} = $payload;
        }
        my ($task) = splice $ready->@*, $at, 1;
        return $task;
    }
    return;
}

sub _scheduled_result ( $run, $baseline, $schedule, $task, $result ) {
    my $payload = $task->{payload};
    return _after_task( $run, $baseline, $task, $result ) if $payload->{kind} ne 'test';
    my $test   = $payload->{test};
    my $active = $schedule->{active};
    delete $active->{$test}{$payload};
    delete $active->{$test} unless keys $active->{$test}->%*;
    if ( $payload->{isolated} ) {
        $schedule->{retrying}{$test}--;
        if ( $result->{passed} ) {
            $schedule->{locked}{$test} = 1;
            $payload->{conflict} = 1;
            _warn( $run, Test::Mutation::Message::warning( 'conflicting-test', test => $test ) );
        }
    }
    elsif ( $payload->{overlapped} && !$result->{passed} && !$result->{overflowed} ) {
        my $job = $payload->{job};
        _collect($task);
        $job->{duration} += $result->{duration};
        _release( $run, $job );
        delete $job->{spec};
        if ( $job->{restore_error} ) {
            return unless defined $job->{detector};
            _discard_detector( $run, $job );
            return _next_test( $run, $job, $baseline );
        }
        my $repeat = _next_test( $run, $job, $baseline ) or return;
        $repeat->{payload}{isolated}     = 1;
        $repeat->{payload}{confirm_read} = 1 if $payload->{confirm_read};
        $schedule->{retrying}{$test}++;
        $run->{stats}{verifications}++;
        return $repeat;
    }
    return _after_task( $run, $baseline, $task, $result );
}

sub _tree ($run) {
    return _walk(
        $run, $run->{root}, '.git',
        map { _inside( $run->{project}, $_ ) } $run->{config}->cache_dir,
        $run->{config}->report_dir
    );
}

sub _begin_in_place ( $run, $baseline ) {
    my $guard = $run->{guard};
    $run->{jobs} = 1;
    my $changes = Test::Mutation::Tree::changes( $guard->{state}, delete $run->{tree} || _tree($run) );
    return unless $changes->@*;
    _restore_changes( $run, $guard, $changes );
    $run->{setup_tests} = [ sort keys $baseline->{tests}->%* ];
    return;
}

sub _prepare_in_place_test ( $run, $job, $test ) {
    _release( $run, $job ) if $run->{setup_tests};
    $job->{used_project} = 1;
    my @earlier = grep { $_ lt $test } @{ $run->{setup_tests} || [] };
    return unless @earlier;
    my $outcome = _unmodified( $run, 'setup-' . ++$run->{sequence}, 0, 1, \@earlier, 'verifications' );
    my ($failed) = grep { !$outcome->{$_}{result}{passed} } @earlier;
    return unless defined $failed;
    return { reason => 'unstable-test', detail => "$failed failed while preparing the original state for $test" };
}

sub _confirm_after_restore ( $run, $job, $guard ) {
    my $verdict = $job->{verdict};
    return unless ( $verdict->{status} || q{} ) eq 'Killed';
    my $test     = $verdict->{by};
    my $observed = _unmodified( $run, 'restored-' . ++$run->{sequence}, 0, 1, [$test], 'verifications' );
    my $changes  = Test::Mutation::Tree::changes( $guard->{state}, _tree($run) );
    _restore_changes( $run, $guard, $changes );
    return if $observed->{$test}{result}{passed};
    $verdict->@{qw(status reason detail)} =
      ( 'NoVerdict', 'project-changed', "$test still fails without a mutant after restoring the project" );
    return;
}

sub _changed_paths ( $run, $changes ) {
    my @named   = $changes->@[ 0 .. List::Util::min( $changes->$#*, $CHANGES_NAMED - 1 ) ];
    my $rest    = $changes->@* - @named;
    my $changed = join( ', ', @named ) . ( $rest ? " and $rest more" : q{} );
    _warn( $run, Test::Mutation::Message::warning( 'project-changed', changes => $changed ) );

    return;
}

sub _discard_detector ( $run, $job ) {
    $run->{stats}{verifications}++;
    $job->%* = _fresh_job( $job->{mutant}, $job->{tests}, $job->{duration} )->%*;
    return;
}

sub _record_observation ( $run, $job ) {
    $job->{verdict} = Test::Mutation::Verdict::step( $job->{verdict}, $job->{outcome} );
    if ( defined $job->{detector} ) {
        _release( $run, $job );
        if ( $job->{restore_error} || Test::Mutation::Verdict::final( $job->{verdict} ) ne 'Killed' ) {
            return _discard_detector( $run, $job );
        }
    }
    push $job->{observations}[ $job->{first} ? 1 : 0 ]->@*, $job->{outcome};
    $job->{index}++;
    return;
}

sub _after_task ( $run, $baseline, $task, $result ) {
    my $job  = $task->{payload}{job};
    my $kind = $task->{payload}{kind};
    if ( $task->{payload}{compile} ) {
        my $retry = _remember_compiler_inputs( $run, $job, $task, $result );
        if ($retry) {
            _discard( $task->{payload}{tmp} );
            return $retry;
        }
    }
    if ( defined( my $path = $task->{payload}{original} ) ) {
        my $ok = _compiled($result);
        $run->{original_compile}{$path} = {
            inputs   => $result->{compiler_inputs},
            passed   => $ok ? 1 : 0,
            duration => $result->{duration},
            code     => $ok && length $result->{output} ? $result->{digest}       : q{},
            opaque   => length $result->{output}        ? $result->{opaque_reads} : undef,
        };
    }
    _discard( $task->{payload}{tmp} ) if $kind ne 'test';
    my $check =
        $kind eq 'test'      ? _after_test( $run, $baseline, $task, $result )
      : $kind =~ /\Asyntax-/ ? _after_syntax( $run, $baseline, $task, $result )
      :                        _after_code( $run, $task, $result );
    return $check if $check;

    if ( $kind !~ /\Acode-/ ) {
        _record_observation( $run, $job );
        return _next_test( $run, $job, $baseline )
          if !defined $job->{verdict}{status} && $job->{index} < $job->{tests}->@*;
        my $trial = Test::Mutation::Verdict::conclude( $job->{verdict} );
        if ( my $first = delete $job->{first} ) {
            $job->{verdict} = Test::Mutation::Verdict::confirm( $first, $trial );
        }
        elsif ( $run->{config}->mutant->@* && ( $trial->{status} eq 'Killed' || $trial->{status} eq 'Survived' ) ) {
            _release( $run, $job );

            # A failed restore retires the slot, so confirmation starts from a new copy of the reference tree.
            delete $job->{restore_error};
            delete $job->{spec};
            $job->{first}   = $trial;
            $job->{index}   = 0;
            $job->{verdict} = Test::Mutation::Verdict::start();
            return _next_test( $run, $job, $baseline );
        }
    }
    return _next_code( $run, $job );
}

sub _run_inputs ( $run, $baseline ) {
    return _available_digest( sub { _fingerprint( $run, $baseline ) } );
}

sub _available_digest ($compute) {
    my $found = Test::Mutation::Try::attempt($compute);
    return $found->{value} if exists $found->{value};
    my $error = $found->{error};
    return if $TYPED->check($error) && ( $error->id eq 'file-unreadable' || $error->id eq 'directory-unopenable' );
    die $error;    ## no critic (ErrorHandling::RequireCarping)
}

sub _fingerprint ( $run, $baseline ) {
    my $config    = $run->{config};
    my @targets   = sort keys $run->{sources}->%*;
    my @tests     = sort keys $baseline->{tests}->%*;
    my %include   = map { $_ => 1 } map { @{ $baseline->{tests}{$_}{includes} || [] } } @tests;
    my @libraries = map { ( $_, Test::Mutation::Store::Key::tree( $_, [] ) ) } sort keys %include;
    my @launch    = (
        $config->in_place,
        $config->coverage,
        $config->equivalence,
        $config->timeout_floor,
        $config->timeout_factor,
        $config->baseline_timeout,
        $config->jobs,
        (
            map { Test::Mutation::Store::Key::digest(@$_) } $config->lib,
            $config->switch, $config->link, $run->{build} || []
        ),
        @targets
    );
    return Test::Mutation::Store::Key::digest(
        $VERSION,                                                    Test::Mutation::Store::format_version(),
        Test::Mutation::Result::supported_compiler_input_protocol(), _module_text($SHIM_FILE),
        _module_text($COMPILER_FILE),                                _module_text('Test/Mutation/Witness.pm'),
        Test::Mutation::Store::Key::interpreter( $run->{perl} ),     Test::Mutation::Store::Key::digest(@libraries),
        Test::Mutation::Store::Key::digest(@launch),                 Test::Mutation::Store::Key::environment( \%ENV ),
        _cache_project( $run, \@targets ),                           _compiler_parser_versions(),
    );
}

sub _cache_project ( $run, $targets ) {
    my $inputs = $run->{copy_inputs};
    return $inputs->{cache_project} if $inputs && defined $inputs->{cache_project};
    my @skip = ( _input_exclusions($run), @{ $run->{report_outputs} || [] }, @$targets, $run->{test_paths}->@* );
    return Test::Mutation::Store::Key::tree( $run->{project}, \@skip ) unless $inputs;
    $inputs->{cache_project} = Test::Mutation::Store::Key::workspace( $run->{project}, \@skip, $run->{config}->link );
    return $inputs->{cache_project};
}

sub _cache_path ($run) {
    return Test::Mutation::Store::path( $run->{config} );
}

sub _original_key ( $run, $shared, $test, $record ) {
    my @paths = sort keys $record->{files}->%*;
    return if grep { !exists $run->{sources}{$_} } @paths;
    my $inputs      = $run->{copy_inputs};
    my $test_digest = $inputs ? $inputs->{tests}{$test} : Test::Mutation::Store::Key::file("$run->{project}/$test");
    my @digests =
      map { ( $_, $inputs ? $inputs->{sources}{$_} : Test::Mutation::Store::Key::file("$run->{project}/$_") ) } @paths;
    return unless defined $test_digest;
    return if grep { !defined } @digests;
    return Test::Mutation::Store::Key::digest( $shared, $test, $test_digest, @digests );
}

sub _save_originals ( $run, $baseline ) {
    my $shared = _run_inputs( $run, $baseline );
    return unless defined $shared;
    my %updates;
    for my $test ( keys $baseline->{tests}->%* ) {
        my $record = $baseline->{tests}{$test};
        $updates{$test} = undef;
        next
          if !$baseline->{parallel_safe}
          || $run->{baseline_changed}
          || $baseline->{failures}->@*
          || !$record->{reusable};
        $updates{$test} = {
            $record->%{qw(duration includes files breakable)},
            inputs => _original_key( $run, $shared, $test, $record )
        };
    }
    return if !grep( {defined} values %updates ) && !-f _cache_path($run);
    Test::Mutation::Store::save( _cache_path($run), {}, undef, {}, { build => $run->{build}, tests => \%updates } );
    return;
}

sub _open_cache ( $run, $baseline, $mutants = undef ) {
    my $shared = _run_inputs( $run, $baseline );
    return unless defined $shared;
    my $path   = _cache_path($run);
    my %target = map { $_ => Test::Mutation::Store::Key::file("$run->{root}/$_") } keys $run->{sources}->%*;
    my %facts;
    for my $test ( sort keys $baseline->{tests}->%* ) {
        my $record = $baseline->{tests}{$test};
        next unless $record->{reusable};
        $facts{$test} = _original_key( $run, $shared, $test, $record );
    }
    my $ids = $run->{narrowed} && $mutants ? [ map { $_->id } @$mutants ] : undef;
    return {
        path    => $path,
        shared  => $shared,
        targets => \%target,
        facts   => \%facts,
        records => $run->{config}->mutant->@* ? {} : Test::Mutation::Store::load( $path, $ids )
    };
}

sub _verdict_key ( $cache, $mutant, $tests, $status, $killer ) {
    my $mutation = Test::Mutation::Store::Key::digest(
        $mutant->id, $mutant->replacement, $cache->{targets}{ $mutant->path },
        $mutant->scope->@*,
        $mutant->comparable || 0,
        @{ $mutant->introduced_call || [] }
    );
    return Test::Mutation::Store::Key::digest( $cache->{shared}, $mutation, 'none' ) if $status eq 'NoCoverage';
    my @needed = @$tests;
    if ( $status eq 'Killed' ) {
        return unless defined $killer && exists $cache->{facts}{$killer};
        my ($index) = grep { $needed[$_] eq $killer } 0 .. $#needed;
        return unless defined $index;
        return Test::Mutation::Store::Key::digest( $cache->{facts}{$killer}, $mutation ) if !$index;
        splice @needed, $index + 1;
        $mutation = Test::Mutation::Store::Key::digest( $mutation, 'through-detector' );
    }
    return if grep { !exists $cache->{facts}{$_} } @needed;
    return Test::Mutation::Store::Key::digest( $mutation, map { ( $_, $cache->{facts}{$_} ) } @needed );
}

sub _source_read_operands ( $run, $path ) {
    return $run->{source_reads}{$path} if exists $run->{source_reads}{$path};
    my $source = $run->{sources}{$path};
    return $run->{source_reads}{$path} = _encode_read_operands( $source, $source->text, 1 );
}

sub _may_read_at_compile_time ( $run, $path ) {
    return $run->{sources}{$path}->text =~ /\b(?:use|no)\b/ || length _source_read_operands( $run, $path );
}

sub _reused_entry ( $run, $cache, $mutant, $tests ) {
    return if $run->{config}->mutant->@*;
    my $record = $cache->{records}{ $mutant->id } or return;
    return if $record->{status} eq 'NoCoverage' && $tests->@*;
    my $key = _verdict_key( $cache, $mutant, $tests, $record->{status}, $record->{by} );
    return unless defined $key && $key eq $record->{inputs};
    return if !defined $record->{compiler_inputs} && _may_read_at_compile_time( $run, $mutant->path );
    my $inputs = $record->{compiler_inputs} || {};
    for my $path ( keys %$inputs ) {
        my $digest = _compiler_input_digest( $run, $path );
        return unless defined $digest && $digest eq $inputs->{$path};
    }
    $run->{compiler_inputs}{$_} = $inputs->{$_} for keys %$inputs;
    $run->{code_of_mutant}{ $mutant->id } = $record->{code} if defined $record->{code};
    $run->{reused}++;
    my $entry = _entry( $mutant, $record->@{qw(status reason detail by)}, $tests, $record->@{qw(tests_run duration)} );
    $entry->{observations} = $record->{observations} if exists $record->{observations};
    return $entry;
}

sub _save_observation ( $run, $cache, $entry, $may_wait = 1 ) {
    my $mutant = $entry->{mutant};
    return 1 if $mutant->suppressed || $run->{unbound_compiler}{ $mutant->id };
    my $key = _verdict_key( $cache, $mutant, $entry->{covered_by}, $entry->{status}, $entry->{by} );
    return 1 unless defined $key;
    my $record = {
        inputs => $key,
        path   => $mutant->path,
        source => $cache->{targets}{ $mutant->path },
        $entry->%{qw(status reason detail by tests_run duration)},
        code => $run->{code_of_mutant}{ $mutant->id },
        defined $run->{compiler_of_mutant}{ $mutant->id }
        ? ( compiler_inputs => $run->{compiler_of_mutant}{ $mutant->id } )
        : (),
        exists $entry->{observations} ? ( observations => $entry->{observations} ) : ()
    };
    my $checkpoint = $cache->{checkpoint} ||= Test::Mutation::Store::checkpoints( $cache->{path} );
    return $checkpoint->( $mutant->id, $record, $may_wait );
}

sub _next_code ( $run, $job ) {
    return if defined $job->{stale};
    my $mutant   = $job->{mutant};
    my $path     = $mutant->path;
    my $original = $run->{original_compile}{$path};
    my $compare =
         $run->{config}->equivalence
      && !defined $job->{code}
      && $mutant->comparable
      && $UNDETECTED{ Test::Mutation::Verdict::final( $job->{verdict} ) };
    if ( !$original ) {
        return unless $compare || _observe_original_inputs( $run, $path );
        return _compile_task( $run, $job, 'code-original', "$run->{root}/$path", '-MO=Deparse' );
    }
    return unless $compare;
    if ( !$original->{passed} ) {
        _warn( $run, Test::Mutation::Message::warning( 'syntax-check-failed', path => $path ) );
        return;
    }
    if ( !length $original->{code} ) {
        return if $original->{opaque};
        _warn( $run, Test::Mutation::Message::warning( 'decompiled-code-unstable', path => $path ) );
        return;
    }
    if ( !defined $job->{file} ) {
        ( $job->{file} ) = _changed_source( $run, $run->{sources}{$path}, $mutant );
    }
    return _compile_task( $run, $job, 'code-mutant', $job->{file}, '-MO=Deparse' );
}

sub _observe_original_inputs ( $run, $path ) {
    return if $run->{sampling_verdicts};
    return unless $run->{config}->equivalence || defined $run->{config}->shard || $run->{options}{reports};
    return _may_read_at_compile_time( $run, $path );
}

sub _after_code ( $run, $task, $result ) {
    return if $task->{payload}{original};
    my $usable = _compiled($result);
    $task->{payload}{job}{code} = $usable && length $result->{output} ? $result->{digest} : q{};
    return;
}

sub _control_copy ( $run, $from ) {
    my @skip = $from eq $run->{project} ? _copy_exclusions($run) : ();
    my $link = $from eq $run->{project} ? $run->{config}->link   : [];
    return _new_copy( $run, "$run->{work}/controls/" . ++$run->{control_sequence}, $from, \@skip, $link );
}

sub _control_pass ( $run, $root, $tests ) {
    local $run->{root}  = $root;
    local $run->{first} = {};
    my $outcomes = _unmodified( $run, 'control-' . ++$run->{sequence}, 0, 1, $tests, 'verifications' );
    return !grep { !$outcomes->{$_}{result}{passed} } $tests->@*;
}

sub _verified_reference ( $run, $baseline, $test ) {
    my $after  = _control_copy( $run, $run->{root} );
    my $passed = _control_pass( $run, $after, [$test] );
    _discard($after);
    return { same => 1 } if $passed;
    my $clean = $run->{pristine} ||= _control_copy( $run, $run->{project} );
    my $trial = _control_copy( $run, $clean );
    $passed = _control_pass( $run, $trial, [$test] );
    _discard($trial);
    return { root => $clean } if $passed;

    my @earlier = sort grep { $_ lt $test } keys $baseline->{tests}->%*;
    if (@earlier) {
        my $ordered = _control_copy( $run, $clean );
        if ( _control_pass( $run, $ordered, \@earlier ) ) {
            my $check = _control_copy( $run, $ordered );
            my $ok    = _control_pass( $run, $check, [$test] );
            _discard($check);
            return { root => $ordered } if $ok;
        }
        _discard($ordered);
    }
    return { unstable => 1 };
}

sub _after_test ( $run, $baseline, $task, $result ) {
    my $payload  = $task->{payload};
    my $job      = $payload->{job};
    my $path     = $job->{mutant}->path;
    my $absolute = _job_root( $run, $job ) . "/$path";
    my $evidence = Test::Mutation::Evidence::target( _collect($task), $absolute );
    $job->{duration} += $result->{duration};
    $job->{outcome} = {
        test         => $payload->{test},
        result       => _ending($result),
        served       => $evidence->{coverage} ? 1 : 0,
        load_failed  => $evidence->{load_failed},
        bypassed     => 0,
        anomaly      => $evidence->{anomaly} || $payload->{baseline_anomaly},
        syntax       => $job->{syntax},
        invalid_call => $evidence->{unresolved} ? $job->{mutant}->introduced_call->[0] : undef,
    };
    if ( $payload->{conflict} && ( !$evidence->{coverage} || $evidence->{load_failed} ) ) {
        $job->{outcome}{anomaly} = {
            reason => 'conflicting-test',
            detail => "$payload->{test} passed alone without a confirmed target load after an overlapping failure"
        };
        return;
    }
    if ( $payload->{confirm_read} ) {
        $job->{outcome}{read_check} = _ending($result);
        return;
    }
    if (   !$result->{passed}
        && !$job->{outcome}{anomaly}
        && !$run->{guard}
        && ( $run->{baseline_changed} || $run->{reused_originals}{ $payload->{test} } ) )
    {
        my $test  = $payload->{test};
        my $proof = $run->{controls}{$test} ||= _verified_reference( $run, $baseline, $test );
        if ( $proof->{unstable} ) {
            $job->{outcome}{anomaly} = { reason => 'unstable-test', detail => "$test failed without the mutant" };
        }
        elsif ( defined $proof->{root}
            && ( !defined $job->{starting_tree} || $job->{starting_tree} ne $proof->{root} ) )
        {
            _release( $run, $job );
            return if defined $job->{restore_error};
            $run->{stats}{verifications}++;
            $job->{starting_tree} = $proof->{root};
            delete $job->{spec};
            return _next_test( $run, $job, $baseline );
        }
    }
    return _check_load( $run, $baseline, $job );
}

sub _check_load ( $run, $baseline, $job ) {
    return if $job->{outcome}{anomaly};
    my $path = $job->{mutant}->path;
    if ( !$job->{outcome}{served} ) {
        return unless defined $run->{copies} && $job->{outcome}{result} eq 'fail';
        $job->{check_read} = 1;
        return _verify_read( $run, $baseline, $job ) if defined $job->{syntax};
    }
    else {
        return if !$job->{outcome}{load_failed} || defined $job->{syntax};
    }
    my $known = $run->{original_compile}{$path};
    return _compile_task( $run, $job, 'syntax-original', "$run->{root}/$path", '-c' ) if !defined $known;
    return _compile_task( $run, $job, 'syntax-mutant',   $job->{file}, '-c' ) if $known->{passed} || $job->{check_read};
    $job->{outcome}{syntax} = $job->{syntax} = 'standalone';
    return;
}

# A failed check of the original says that the source does not compile alone, so its mutants say nothing more.
sub _after_syntax ( $run, $baseline, $task, $result ) {
    my $job      = $task->{payload}{job};
    my $path     = $job->{mutant}->path;
    my $ok       = _compiled($result);
    my $original = $task->{payload}{kind} eq 'syntax-original';
    if ($original) {
        return _compile_task( $run, $job, 'syntax-mutant', $job->{file}, '-c' ) if $ok || $job->{check_read};
        _warn( $run, Test::Mutation::Message::warning( 'syntax-check-failed', path => $path ) );
    }
    my $mutant = $job->{mutant};
    my $end;
    if ( $result->{errors} =~ /\ABareword /
        && Test::Mutation::Syntax::PPI::inside_begin( $run->{sources}{$path}, $mutant->start ) )
    {
        $end = $mutant->from->[0] + ( $mutant->replacement =~ tr/\n// );
    }
    $job->{outcome}{syntax} = $job->{syntax} = Test::Mutation::Attribution::compilation(
        $run->{original_compile}{$path}{passed},
        $ok ? 1 : 0,
        $result->{errors}, $job->{file}, $end
    );
    return _verify_read( $run, $baseline, $job ) if $job->{check_read};
    return;
}

sub _verify_read ( $run, $baseline, $job ) {
    delete $job->{check_read};
    if ( $job->{syntax} eq 'compile-phase' || $job->{syntax} eq 'parse' ) {
        $job->{outcome}{read_check} = 'compile-error';
        return;
    }
    _release( $run, $job );
    return if defined $job->{restore_error};
    delete $job->{spec};
    my $repeat = _next_test( $run, $job, $baseline );
    $repeat->{payload}{confirm_read} = 1;
    $run->{stats}{verifications}++;
    return $repeat;
}

sub _next_test ( $run, $job, $baseline ) {
    my $config    = $run->{config};
    my $mutant    = $job->{mutant};
    my $test      = defined $job->{detector} ? $job->{detector}                       : $job->{tests}[ $job->{index} ];
    my $raw       = $run->{sensitive}{$test} && keys $run->{sensitive}{$test}->%* ? 1 : 0;
    my $proof     = $run->{controls}{$test};
    my $reference = $proof && $proof->{root} ? $proof->{root} : $run->{root};
    if ( defined $job->{spec} && ( $raw != $job->{raw} || $job->{copy} && $job->{copy}{reference} ne $reference ) ) {
        _release( $run, $job );
        return if defined $job->{restore_error};
        delete $job->{spec};
    }
    $job->{starting_tree} = $reference;
    if ( !defined $job->{spec} ) {
        $job->@{qw(file spec stale)} =
          _write_mutant( $run, $run->{sources}{ $mutant->path }, $mutant, _job_root( $run, $job ), $raw );
        $job->{raw} = $raw;
    }
    return if defined $job->{stale};
    my $setup    = $run->{guard} ? _prepare_in_place_test( $run, $job, $test ) : undef;
    my $anomaly  = $setup || $baseline->{tests}{$test}{anomalies}{ $mutant->path };
    my $duration = $baseline->{tests}{$test}{duration} * $config->timeout_factor;
    return _test_task(
        $run,
        root            => _job_root( $run, $job ),
        test            => $test,
        spec            => $job->{spec},
        timeout         => List::Util::max( $duration, $config->timeout_floor ),
        stop_on_failure => 1,
        payload         => { kind => 'test', job => $job, $anomaly ? ( baseline_anomaly => $anomaly ) : () },
    );
}

sub _compiler_exited ($result) {
    return !$result->{signal} && !$result->{timed_out} && !$result->{overflowed};
}

sub _compiled ($result) {
    return !$result->{exit} && _compiler_exited($result);
}

sub _compiler_input_digest ( $run, $path ) {
    return $run->{compiler_digests}{$path} if exists $run->{compiler_digests}{$path};
    return $run->{compiler_digests}{$path} = _available_digest(
        sub {
            return Test::Mutation::Store::Key::file($path) if -f $path;
            return Test::Mutation::Store::Key::tree( $path, [] );
        }
    );
}

sub _loaded_read_operands ( $run, $file ) {
    return $run->{module_reads}{$file} if exists $run->{module_reads}{$file};
    my $bytes = _available_digest( sub { Test::Mutation::Source::read_bytes($file) } );
    return q{?} unless defined $bytes;
    my $source = Test::Mutation::Source->from_bytes( path => $file, bytes => $bytes );
    return $run->{module_reads}{$file} = _encode_read_operands( $source, $source->text, 1 );
}

sub _compiler_inputs ( $run, $tmp, $result ) {
    return unless -f "$tmp/inputs";
    my @lines = split /\n/, Test::Mutation::Source::read_bytes("$tmp/inputs");
    return unless @lines && pop(@lines) eq q{.};
    my %inputs;
    for my $line (@lines) {
        if ( $line =~ /\Am((?:[0-9a-f]{2})+)\z/ ) {
            my $file  = pack 'H*', $1;
            my $reads = _loaded_read_operands( $run, $file );
            $result->{module_reads}{$_} = 1 for split /,/, $reads;
            next;
        }
        return unless $line =~ /\A(?:[0-9a-f]{2})+\z/;
        my $path  = File::Spec->canonpath( pack 'H*', $line );
        my @roots = ( $run->{project}, $run->{workspace}->directory );
        if ( grep { index( "$path/", "$_/" ) == 0 } @roots ) {
            $path = Cwd::abs_path($path) || $path;
            next if grep { index( "$path/", "$_/" ) == 0 } @roots;
        }
        my $digest = _compiler_input_digest( $run, $path );
        return unless defined $digest;
        $inputs{$path} = $digest;
    }
    return \%inputs;
}

sub _remember_compiler_inputs ( $run, $job, $task, $result ) {
    my $payload       = $task->{payload};
    my $read_operands = $task->{env}{TEST_MUTATION_COMPILER_READS};
    if ( !_compiled($result) ) {
        $job->{unbound_compiler}   = 1;
        $result->{compiler_inputs} = undef unless $payload->{kind} eq 'syntax-mutant' && _compiler_exited($result);
    }
    $result->{compiler_inputs} = _compiler_inputs( $run, $payload->{tmp}, $result )
      unless exists $result->{compiler_inputs};
    my %requested = map  { $_ => 1 } split /,/, $read_operands;
    my $missing   = grep { !$requested{$_} } keys %{ $result->{module_reads} || {} };
    if ($missing) {
        my $original = $payload->{original};
        if ( defined $original && !length $payload->{imports} && !$result->{module_reads}{q{?}} ) {
            $run->{compiler_imports}{$original} = join q{,}, sort keys $result->{module_reads}->%*;
            return _compile_task( $run, $job, $payload->{kind}, "$run->{root}/$original", '-MO=Deparse' );
        }
        $result->{compiler_inputs} = undef;
        $result->{opaque_reads}    = 1;
    }
    my $inputs = $result->{compiler_inputs};
    if ( defined $inputs ) {
        $run->{compiler_inputs}{$_} = $job->{compiler_inputs}{$_} = $inputs->{$_} for keys %$inputs;
    }
    else {
        $run->{missing_compiler_inputs} = 1 if $payload->{kind} ne 'code-mutant';
        $result->{opaque_reads}         = 1 if length $read_operands;
        $result->{digest}               = q{};
        $job->{unbound_compiler}        = 1;
    }
    return;
}

sub _compiler_read_operands ( $run, $job, $original ) {
    my $mutant = $job->{mutant};
    my $source = $run->{sources}{ $mutant->path };
    my $text   = $source->text;
    my $reads  = _source_read_operands( $run, $mutant->path );
    return $reads if $original || $reads eq q{?} || $text !~ /\b(?:BEGIN|UNITCHECK|CHECK)\b/;
    $text = $source->replace_span( $mutant->start, $mutant->end, $mutant->replacement );
    return _encode_read_operands( $source, $text );
}

sub _encode_read_operands ( $source, $text, $check_load = 0 ) {
    my $reads = Test::Mutation::Syntax::PPI::compile_reads( $text, $check_load );
    return q{?} unless defined $reads;
    return join q{,}, map { substr( $_->[0], 0, 1 ) . unpack( 'H*', $source->to_bytes( $_->[1] ) ) } @$reads;
}

sub _hint_line ($line) {
    my $table = qr{charnames_(?:inverse_ords|name_aliases|ord_aliases)}x;
    my $key   = qr{(?:charnames'\} [ ]=[ ] 'CODE | $table'\} [ ]=[ ] 'HASH)}x;
    return $line =~ s{\A ([ \t]* \$\^H\{' $key \( ) 0x[0-9a-fA-F]+ (?= \)'; \n? \z ) }{$1*}xr;
}

sub _compile_task ( $run, $job, $kind, $file, $switch ) {
    my $path     = $job->{mutant}->path;
    my $original = $kind eq 'code-original' || $kind eq 'syntax-original';
    my $measured = $run->{original_compile}{$path};
    my $timeout =
      $measured
      ? List::Util::max( $COMPILE_FLOOR, $COMPILE_FACTOR * $measured->{duration} )
      : $run->{config}->baseline_timeout;
    my $root = $original || !$job->{copy} ? $run->{root} : $job->{copy}{root};
    my $tmp  = "$run->{work}/tmp/" . ++$run->{sequence};
    Test::Mutation::Tree::make($tmp);
    my $option = $switch;
    $option = $run->{config}->equivalence ? '-MO=Deparse' : '-c' if $original;
    my $source         = $run->{sources}{$path}->text;
    my $standard_hints = $option eq '-MO=Deparse' && $source =~ /\buse\s+charnames\b/ && $source !~ /[\$%]\^H/;
    my $imports        = $run->{compiler_imports}{$path} || q{};
    my $launch         = _launch(
        $run, $root, $tmp, $path,
        program   => $file,
        arguments => [ "-I$run->{work}/compiler", "-MTest::Mutation::CompilerInputs::G$run->{generation}", $option ]
    );
    return {
        command => $launch->{command},
        env     => {
            $launch->{env}->%*,
            PERL_HASH_SEED                => '0',
            PERL_PERTURB_KEYS             => '0',
            TEST_MUTATION_COMPILER_INPUTS => "$tmp/inputs",
            TEST_MUTATION_COMPILER_READS  =>
              join( q{,}, grep { length } $imports, _compiler_read_operands( $run, $job, $original ) ),
        },
        cwd             => $job->{tests}->@* ? $root : $tmp,
        lease           => $run->{workspace}->directory . '/processes',
        timeout         => $timeout,
        output_limit    => $OUTPUT_LIMIT,
        stop_on_failure => 0,
        ( $standard_hints ? ( digest_line => \&_hint_line ) : () ),
        payload => {
            kind    => $kind,
            job     => $job,
            tmp     => $tmp,
            compile => 1,
            imports => $imports,
            $original ? ( original => $path ) : ()
        },
    };
}

# A failing test of the unmodified run, with the reason of the limit that ended it.
sub _failure ( $test, $result ) {
    my $reason = Test::Mutation::Verdict::limit( _ending($result) );
    return { test => $test, $result->%{qw(output errors)}, defined $reason ? ( reason => $reason ) : () };
}

# The outcome of a test: the limit of the pool that ended it, or its own verdict.
sub _ending ($result) {
    return 'timeout'  if $result->{timed_out};
    return 'overflow' if $result->{overflowed};
    return $result->{passed} ? 'pass' : 'fail';
}

sub _finish ( $run, $job ) {
    _remove_disk_spec( $job->{spec} ) if defined $job->{spec};
    unlink grep { defined } $job->@{qw(file spec)};
    my $verdict  = Test::Mutation::Verdict::conclude( $job->{verdict} );
    my $mutant   = $job->{mutant};
    my $original = $run->{original_compile}{ $mutant->path };
    if ( $job->{unbound_compiler} || ( $original && !defined $original->{inputs} ) ) {
        $run->{unbound_compiler}{ $mutant->id } = 1;
    }
    else {
        my %inputs = ( %{ $original && $original->{inputs} || {} }, %{ $job->{compiler_inputs} || {} } );
        $run->{compiler_of_mutant}{ $mutant->id } = \%inputs if $original || %inputs;
    }
    my $code = !$run->{unbound_compiler}{ $mutant->id } && defined $job->{code} ? $job->{code} : q{};
    my ( $status, $reason, $detail ) = $verdict->@{qw(status reason detail)};
    if ( defined $job->{restore_error} ) {
        ( $status, $reason, $detail ) = ( 'NoVerdict', 'slot-not-restored', $job->{restore_error} );
    }
    elsif ( defined $job->{stale} ) {
        ( $status, $reason, $detail ) =
          ( 'NoVerdict', 'build-copy-not-updated', "the build did not update $job->{stale}" );
    }
    elsif ( length $code ) {
        $run->{code_of_mutant}{ $mutant->id } = $code;
        ( $status, $reason, $detail ) =
          ( 'Ignored', 'same-code-as-original', 'compiles to the same code as the original' )
          if $code eq $run->{original_compile}{ $mutant->path }{code};
    }
    my $entry =
      _entry( $mutant, $status, $reason, $detail, $verdict->{by}, $job->{tests}, $verdict->{tests}, $job->{duration} );
    $entry->{observations} = $job->{observations} || [];
    return $entry;
}

1;

__END__

=head1 NAME

Test::Mutation::Runner - run the tests against every mutant

=head1 SYNOPSIS

    my $result = Test::Mutation::Runner::run( $config, sub ( $event, $data ) { } );

=head1 DESCRIPTION

The runner finds the source and test files, generates the mutants, and measures each one.
It first runs every test against the unmodified sources through the same hook that later serves the mutants.
That run proves the hook leaves the tests passing, times each test, and records which test reaches which line.
The runner serves each mutant to its covering tests in project-relative path order until a test decides its verdict.
When a run names mutant identifiers, it bypasses cached verdicts and repeats the covering tests for each candidate C<Killed> or C<Survived> in the same order.
In copy mode both attempts start from the tree that the unmodified tests left.
Conflicting observations give C<NoVerdict> and the result names both observations.
It writes temporary files under the work directory and leaves the project files unchanged.
The tests run in copies of the project: the unmodified run in one copy, and each job in a copy of the result.
After every mutant, the runner restores a copy that the tests changed.

=head1 FUNCTIONS

=head2 analyze

Returns the sources, the mutants, and the files that could not be analyzed, without running a test.
The C<left_out> key maps a file to the number of its places that the analysis left out, and a run warns about each such file.
The C<rejected> key holds every change that the generator refused, with the file, the mutator, the line, and the rule.
The C<inventory> key holds the count and the digest of the mutants before C<shard> takes its part.
A suppression comment that L<Test::Mutation::Suppression> refuses, in any analyzed file, ends the analysis with one usage error that lists every refusal.
The mutants of every mutator decide whether a comment suppresses one, so the choice of mutators changes no refusal.

=head2 run

Runs the measurement and returns a L<Test::Mutation::Result>.
The optional C<detector_hints> argument maps mutant identifiers to project-relative test paths.
When the runner resolves the full project with caching disabled, it can try a suggested covering test first if the harness rules allow it.
The suggested test must establish C<Killed> against the current mutant.
An inconclusive trial starts the ordinary test order from a clean workspace with the full timeout budget.
The listener receives C<phase> with its name and time, C<resolved>, C<copy_started>, C<copy_finished>, C<baseline_started>, C<baseline_test>, C<baseline_finished>, C<mutants_started>, C<mutant_finished>, C<mutants_finished>, C<tick>, and C<finished>.
The original C<analyzed>, C<baseline>, and C<mutant> notifications remain available.
The final event contains the measurement tally.
Each C<phase> event gives the stage name and its start time.

=head2 phases

Returns the ordered names of the phases a complete measurement can enter.

=head2 run_command

    my $status = Test::Mutation::Runner::run_command( $config, $source, $mutant, [ 'prove', '-l', 't/a.t' ] );

Runs a command with one mutant active and returns its exit status.
The command runs in a private copy containing the replacement, including when the command starts a tainted Perl process.

=head2 target_pairs

    my $pairs = Test::Mutation::Runner::target_pairs( $root, \@paths, $mutated_path, $mutant_file );

Returns the targets of a mutant run as pairs of an original file and the file to serve in its place.
Every source file goes through the hook, so a mutant run differs from the unmodified run in the text of one file alone.

=head2 shim_text

Returns the source of L<Test::Mutation::Shim> renamed for a generation.
A run inside another run uses the next generation, so both shims work in one process.

=cut
