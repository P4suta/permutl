use v5.36;
use Test2::V0;
use File::Temp ();
use JSON::PP   ();
use lib 't/e2e/lib';
use Fixture qw(copy_of write_file);
use Fcntl   qw(:flock);
use Test::Mutation::Runner;
use Test::Mutation::Settings;
use Test::Mutation::Store;
use Test::Mutation::Store::Key;
use Test::Mutation::Status;

my $dir = File::Temp::tempdir( CLEANUP => 1 );

{
    my $parent = File::Temp::tempdir( CLEANUP => 1 );
    my $empty  = "$parent/empty";
    mkdir $empty or die "mkdir $empty: $!";
    write_file( "$parent/neighbor", "outside the project\n" );
    is(
        Test::Mutation::Store::Key::tree( $empty, ['../..'] ),
        Test::Mutation::Store::Key::digest(),
        'an empty project has no file or directory inputs'
    ) or do { done_testing; exit 1 };
}

sub record (%fields) {
    return {
        inputs    => 'k',
        status    => 'Killed',
        reason    => undef,
        detail    => 't/a.t failed',
        by        => 't/a.t',
        tests_run => 1,
        duration  => 0.5,
        code      => undef,
        %fields
    };
}

{
    my $path            = "$dir/first/measurement.sqlite";
    my $completed       = record( path => 'lib/Calc.pm', source => 'measured' );
    my $checkpoint      = Test::Mutation::Store::checkpoints($path);
    my $acknowledgement = $checkpoint->( 'first', $completed, 0 );
    is(
        [ $acknowledgement, Test::Mutation::Store::load($path) ],
        [ 1,                { first => $completed } ],
        'a nonblocking checkpoint acknowledges the verdict visible to the next reader'
    ) or do { done_testing; exit 1 };
}

sub write_text ( $name, $text ) {
    open my $handle, '>', "$dir/$name" or die "open: $!";
    print {$handle} $text or die "print: $!";
    close $handle         or die "close: $!";
    return "$dir/$name";
}

subtest 'a key depends on every part and on the order of the parts' => sub {
    my $key = Test::Mutation::Store::Key::digest( 'a', 'b' );
    like $key, qr/\A[0-9a-f]{64}\z/, 'a key is a digest';
    is Test::Mutation::Store::Key::digest( 'a', 'b' ), $key, 'equal parts give an equal key';
    isnt Test::Mutation::Store::Key::digest( 'a', 'c' ), $key, 'a changed part changes the key';
    isnt Test::Mutation::Store::Key::digest( 'b', 'a' ), $key, 'the order matters';
    isnt Test::Mutation::Store::Key::digest('ab'), Test::Mutation::Store::Key::digest( 'a', 'b' ),
      'parts do not run together';
    like Test::Mutation::Store::Key::digest("\x{3042}"), qr/\A[0-9a-f]{64}\z/, 'a part outside ASCII is accepted';
};

subtest 'records survive a round trip' => sub {
    my $path    = "$dir/nested/cache.json";
    my %records = (
        aaaaaaaaaaaa => record(),
        bbbbbbbbbbbb => record( status => 'Survived', detail => undef, by => undef, code => 'c' x 64 ),
        cccccccccccc => record(
            status => 'Ignored',
            reason => 'same-code-as-original',
            detail => 'compiles to the same code as the original',
            by     => undef
        ),
        dddddddddddd => record( status => 'CompileError', reason => 'compile-phase' ),
    );
    is Test::Mutation::Store::save( $path, \%records ), 4,         'save returns the number of stored records';
    is Test::Mutation::Store::load($path),              \%records, 'the loaded records equal the saved records';
    my $selected = 'bbbbbbbbbbbb';
    is Test::Mutation::Store::load( $path, [ 'ffffffffffff', $selected ] ), { $selected => $records{$selected} },
      'a JSON lookup returns the requested verdict and omits missing and unrequested identifiers';
    is Test::Mutation::Store::load( $path, [] ), {}, 'an empty selection returns no JSON verdicts';

    open my $handle, '<', $path or die "open: $!";
    my $text = do { local $/ = undef; readline $handle };
    close $handle or die "close: $!";
    unlike $text, qr/"[^"]*(?:key|token|secret|password|credential|auth)[^"]*":/i,
      'no field has a name that a secret scanner reads as a credential';
};

subtest 'the cache keeps the statuses that the catalog marks as stable' => sub {
    my $path = "$dir/partial.json";
    my @rows = Test::Mutation::Status::rows()->@*;
    Test::Mutation::Store::save( $path,
        { map { $_->name => record( status => $_->name, reason => $_->reasons->[0] ) } @rows } );
    is [ sort keys Test::Mutation::Store::load($path)->%* ], [qw(CompileError Ignored Killed NoCoverage Survived)],
      'a result that depends on the machine or on an unfinished run is left out';
    is [ sort map { $_->name } grep { $_->cached } @rows ], [qw(CompileError Ignored Killed NoCoverage Survived)],
      'and the catalog names the same statuses';
};

subtest 'an unusable file is an empty cache' => sub {
    is Test::Mutation::Store::load("$dir/missing.json"),                         {}, 'a missing file';
    is Test::Mutation::Store::load( write_text( 'broken.json', '{ not json' ) ), {}, 'a file that is not JSON';
    my $format = Test::Mutation::Store::format_version();
    my $valid  = '{"inputs":"k","status":"Killed","reason":null,"detail":null,"by":null,"tests_run":1,"duration":1,'
      . '"code":null}';
    my $reasonless = $valid =~ s/"Killed"/"Timeout"/r;
    my $old        = '{"inputs":"k","status":"Killed","reason":null,"by":null,"tests_run":1,"duration":1,"code":null}';
    is Test::Mutation::Store::load( write_text( 'version.json', qq({"version":2,"mutants":{"aaaaaaaaaaaa":$old}}) ) ),
      {}, 'a file of the earlier format, whose reasons are sentences';
    is Test::Mutation::Store::load( write_text( 'list.json', qq({"version":$format,"mutants":[]}) ) ), {},
      'a file whose records are a list';
    is Test::Mutation::Store::load( write_text( 'array.json', '[1]' ) ), {}, 'a file that holds a list';
    my $records = qq({"version":$format,"mutants":{"aaaaaaaaaaaa":{"inputs":"k"},"bbbbbbbbbbbb":$valid,)
      . qq("cccccccccccc":$reasonless}});
    is [ keys Test::Mutation::Store::load( write_text( 'record.json', $records ) )->%* ], ['bbbbbbbbbbbb'],
      'a malformed record and a record without the reason of its status are left out';
};

subtest 'partial baseline writes retain independent observations and measured verdicts' => sub {
    my $facts = {
        inputs    => 'one',
        includes  => ['lib'],
        duration  => 0.25,
        files     => { 'lib/One.pm' => { traced => 1, hits => { 2 => 1 } } },
        breakable => { 'lib/One.pm' => { 2      => 1 } }
    };
    my $other  = { %$facts, inputs => 'two', files => {}, breakable => {} };
    my $build  = [ 'perl', 'Makefile.PL' ];
    my $first  = { 't/one.t' => $facts, 't/two.t' => $other };
    my $update = { 't/one.t' => undef, 't/three.t' => $facts };
    my $kept   = { 't/two.t' => $other, 't/three.t' => $facts };
    for my $format (qw(json sqlite)) {
        subtest $format => sub {
            my $path  = "$dir/originals.$format";
            my $prior = record();
            Test::Mutation::Store::save( $path, { prior => $prior }, undef, {}, { build => $build, tests => $first } );
            is $prior, record(), 'saving a verdict preserves absent source fields in the caller';
            is Test::Mutation::Store::originals($path), { build => $build, tests => $first },
              'build arguments, duration and traced lines survive a round trip';
            Test::Mutation::Store::save( $path, {}, undef, {}, { build => [], tests => $update } );
            is Test::Mutation::Store::originals($path), { build => [], tests => $kept },
              'a partial write replaces the build, adds a new test and forgets the invalid observation';
            Test::Mutation::Store::save( $path, {}, undef, {}, { build => $build, tests => {}, reset => 1 } );
            is Test::Mutation::Store::originals($path), { build => $build, tests => {} },
              'a reset clears every original even when no replacement tests are supplied';
            is Test::Mutation::Store::load($path), { prior => record() }, 'baseline updates preserve verdicts';
        };
    }
    my $broken = JSON::PP->new->encode(
        {
            version => Test::Mutation::Store::format_version(),
            build   => 'invalid',
            tests   => { valid => $facts, malformed => { %$facts, duration => [] } },
        }
    );
    is Test::Mutation::Store::originals( write_text( 'broken-originals.json', $broken ) ),
      { build => [], tests => { valid => $facts } }, 'malformed observations or build arguments cannot be reused';
    isa_ok dies { Test::Mutation::Store::originals( "$dir/originals.json", 'extra' ) }, ['Error::TypeTiny'],
      'the original lookup checks its path arguments';
};

subtest 'verification samples vary by seed and include one verdict per fifty' => sub {
    for my $case ( [ 0, 0 ], [ 1, 1 ], [ 3, 3 ], [ 50, 3 ], [ 150, 3 ], [ 151, 4 ] ) {
        my ( $count, $expected ) = @$case;
        my @ids    = map { sprintf '%012x', $_ } 1 .. $count;
        my $sample = Test::Mutation::Store::sample( \@ids, 'first' );
        is scalar @$sample, $expected, "$count available verdicts give $expected observations";
        my %id = map { $_ => 1 } @ids;
        ok !grep( { !$id{$_} } @$sample ), 'every sampled verdict belongs to the run';
        is $sample, Test::Mutation::Store::sample( [ reverse @ids ], 'first' ), 'input order leaves the sample stable';
        isnt $sample, Test::Mutation::Store::sample( \@ids, 'second' ), 'a later seed changes the sample'
          if $count > $expected;
    }
};

subtest 'writing an inventory checks each known source while holding the writer lock' => sub {
    my $file    = "$dir/inventory.json";
    my $current = record( path => 'lib/Changed.pm',   source => 'current' );
    my $distant = record( path => 'lib/Elsewhere.pm', source => 'other' );
    my $legacy  = record();
    my %records = (
        current => $current,
        other   => $distant,
        legacy  => $legacy,
        stale   => record( path => 'lib/Changed.pm', source => 'earlier' ),
        removed => $legacy,
    );
    Test::Mutation::Store::save( $file, \%records );
    my $available = sub {
        open my $another, '>>', "$file.lock" or die "open: $!";
        my $obtained = flock $another, LOCK_EX | LOCK_NB;
        close $another or die "close: $!";
        return $obtained ? 1 : 0;
    };
    my @during_write;
    my $merge = Test::Mutation::Store->can('_merge_records');
    no warnings 'redefine';
    local *Test::Mutation::Store::_merge_records = sub (@arguments) {    ## no critic (Variables::ProtectPrivateVars)
        push @during_write, $available->();
        return $merge->(@arguments);
    };
    is Test::Mutation::Store::save( $file, {}, [qw(current other legacy stale)], { 'lib/Changed.pm' => 'current' } ),
      3, 'a removed mutant and a verdict with outdated source bytes leave the inventory';
    is Test::Mutation::Store::load($file), { current => $current, other => $distant, legacy => $legacy },
      'a matching source, an unexamined source and a record without source metadata survive';
    is \@during_write, [0], 'a competing handle cannot acquire the same lock while the inventory is updated';
    ok $available->(), 'the next writer can acquire the lock after publication';
};

subtest 'the cache format and the ordering of a verification sample are reproducible' => sub {
    my $file = "$dir/format.json";
    Test::Mutation::Store::save( $file, {} );
    open my $input, '<:raw', $file or die "open: $!";
    my $json = do { local $/ = undef; readline $input };
    close $input or die "close: $!";
    my ($version) = $json =~ /"version":([1-9][0-9]*)/;
    ok defined $version, 'the written format has a positive schema version';
    is Test::Mutation::Store::format_version(), $version, 'the cache fingerprint uses the version written to disk';
    isa_ok dies { Test::Mutation::Store::format_version('extra') }, ['Error::TypeTiny'],
      'the format takes no arguments';
    isa_ok dies { Test::Mutation::Store::sample( {}, 'seed' ) }, ['Error::TypeTiny'],
      'sampling requires a list of identifiers';
    my %ranks = ( a => 'middle', b => 'earlier', c => 'earlier', d => 'trailing' );
    no warnings 'redefine';
    local *Test::Mutation::Store::Key::digest = sub ( $seed, $id ) {
        is $seed, 'selected run', 'the seed participates in every ranking';
        return $ranks{$id};
    };
    is Test::Mutation::Store::sample( [qw(d c b a)], 'selected run' ), [qw(b c a)],
      'ascending digest rank selects the sample and the identifier breaks ties';
};

# These checks use the cache between the runner's original-test and measurement stages.
## no critic (Subroutines::ProtectPrivateSubs)
subtest 'each saved verdict requires the observations that justify its status' => sub {
    my $project = copy_of('calc');
    write_file( "$project/lib/Fixed.pm",
        "package Fixed;\nsub sum { return \$_[0] + 1 }    ## no mutate (arithmetic): the increment is fixed\n1;\n" );
    my $config   = Test::Mutation::Settings::of_call( { root => $project } );
    my $analysis = Test::Mutation::Runner::analyze($config);
    my ( $hit, $uncovered, $unknown, $unrelated, $unrecorded ) =
      grep { $_->path eq 'lib/Calc.pm' } $analysis->{mutants}->@*;
    my ($excluded) = grep { $_->suppressed } $analysis->{mutants}->@*;
    my $run =
      { root => $project, project => $project, config => $config, perl => $^X, sources => $analysis->{sources} };
    my $baseline = {
        tests => {
            't/00-volatile.t' => { reusable => 0 },
            map { $_ => { reusable => 1, files => { 'lib/Calc.pm' => {} } } } qw(t/add.t t/sign.t)
        }
    };
    $run->{test_paths} = [ sort keys $baseline->{tests}->%* ];
    my $cache = Test::Mutation::Runner::_open_cache( $run, $baseline );
    is [ sort keys $cache->{facts}->%* ], [qw(t/add.t t/sign.t)],
      'an unusable observation before the passing tests does not hide their input digests';
    my @entries;

    for my $case (
        [ $excluded,  'Ignored',    'suppressed', undef,             [] ],
        [ $unknown,   'Killed',     undef,        't/00-volatile.t', ['t/00-volatile.t'] ],
        [ $unrelated, 'Killed',     undef,        't/sign.t',        ['t/add.t'] ],
        [ $hit,       'Killed',     undef,        't/add.t',         ['t/add.t'] ],
        [ $uncovered, 'NoCoverage', 'not-loaded', undef,             [] ],
      )
    {
        my ( $mutant, $status, $reason, $by, $tests ) = @$case;
        push @entries,
          {
            mutant     => $mutant,
            status     => $status,
            reason     => $reason,
            by         => $by,
            covered_by => $tests,
            tests_run  => scalar @$tests,
            duration   => 1,
            detail     => undef,
          };
    }
    $run->{compiler_of_mutant} = { map { ( $_->id, {} ) } $hit, $uncovered };
    Test::Mutation::Runner::_save_observation( $run, $cache, $_ ) for @entries;
    $cache->{records} = Test::Mutation::Store::load( $cache->{path} );
    is [ sort keys $cache->{records}->%* ], [ sort map { $_->id } $hit, $uncovered ],
      'suppression, an unverified detector and a detector outside coverage leave independent verdicts intact';
    my $prior_key = $cache->{records}{ $hit->id }{inputs};
    $cache->{records}{ $hit->id }{inputs} = 'older input';
    my $reuse = sub ( $context, $mutant, $tests ) {
        return Test::Mutation::Runner::_reused_entry( $run, $context, $mutant, $tests );
    };
    is $reuse->( $cache, $hit, ['t/add.t'] ), undef, 'a recorded detection with changed inputs must be measured again';
    $cache->{records}{ $hit->id }{inputs} = $prior_key;
    my $proof = delete $cache->{records}{ $hit->id }{compiler_inputs};
    is $reuse->( $cache, $hit, ['t/add.t'] ), undef,
      'a legacy detection with unverified module imports needs new tests';
    $cache->{records}{ $hit->id }{compiler_inputs} = $proof;
    is $reuse->( $cache, $hit, ['t/add.t'] )->{by}, 't/add.t', 'the verified detecting test is retained';
    my $binding = Test::Mutation::Mutant->new( $hit->%*, introduced_call => [ 'Calc::adjust', $hit->start ] );
    is $reuse->( $cache, $binding, ['t/add.t'] ), undef,
      'a candidate that probes a different function needs fresh tests';
    my $scope = Test::Mutation::Mutant->new( $hit->%*, scope => [ $hit->scope->[0], $hit->scope->[1] + 1 ] );
    is $reuse->( $cache, $scope, ['t/add.t'] ), undef, 'a different covering statement needs fresh observations';
    my $description = Test::Mutation::Mutant->new( $hit->%*, description => 'Reworded replacement description' );
    is $reuse->( $cache, $description, ['t/add.t'] )->{by}, 't/add.t',
      'rewording the description preserves the detection';
    is $reuse->( $cache, $uncovered, [] )->{status}, 'NoCoverage', 'unchanged inputs can reuse an uncovered result';
    is $reuse->( $cache, $uncovered, ['t/add.t'] ),  undef, 'a newly covering test invalidates an uncovered result';
    is $reuse->( { %$cache, shared => 'another environment' }, $uncovered, [] ), undef,
      'an uncovered result still depends on the original project and interpreter';
    my $saved = $reuse->( $cache, $uncovered, [] );
    $saved->{mutant} = Test::Mutation::Mutant->new( $uncovered->%*, comparable => 0 );
    Test::Mutation::Runner::_save_observation( $run, $cache, $saved );
    $cache->{records} = Test::Mutation::Store::load( $cache->{path} );
    my @values       = map { Test::Mutation::Mutant->new( $uncovered->%*, comparable => $_ ) } ( q{}, undef );
    my @observations = map { $reuse->( $cache, $_, [] ) } @values;
    is [ map { $_ && $_->{status} } @observations ],
      [qw(NoCoverage NoCoverage)], 'empty and undefined false values reuse a verdict recorded with numeric zero';
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_; return };
    is $reuse->( $cache, $unrecorded, [] ), undef, 'an unknown mutant needs a fresh measurement';
    is \@warnings,                          [],    'a normal cache miss has no diagnostic';
};
## use critic

subtest 'rechecking cached verdicts publishes only verified results and retains the detecting test' => sub {
    my $project = File::Temp::tempdir( CLEANUP => 1 );
    write_file( "$project/lib/Sample.pm", <<'PERL' );
package Sample;
sub answer { return $_[0] + 2 }
sub fixed { return $_[0] + 1 }    ## no mutate (arithmetic): the increment is fixed
1;
PERL
    my $settings = Test::Mutation::Settings::of_call( { root => $project } );
    my @selected = Test::Mutation::Runner::analyze($settings)->{mutants}->@*;
    my ( $detected, $other ) = grep { !$_->suppressed } @selected;
    my ($excluded) = grep { $_->suppressed } @selected;
    my ( $detected_id, $other_id ) = map { $_->id } $detected, $other;
    my $cache_path = "$project/verdicts.json";
    my $covered    = { duration  => 1, files => { $detected->path => { traced => 0, hits => {} } } };
    my $baseline   = { breakable => {}, tests => { 't/also.t' => $covered, 't/detect.t' => $covered } };
    my $sample_run = { config    => $settings, sample_killers => { $detected_id => 't/detect.t' } };
    my %entries;
    ## no critic (Subroutines::ProtectPrivateSubs)
    my $next_job = Test::Mutation::Runner::_measurement_jobs( $sample_run, [ $detected, $other, $excluded ],
        $baseline, { records => {} }, \%entries );
    ## use critic
    is [ keys %entries ], [ $excluded->id ], 'cache misses occupy no result slots before the first job is requested';
    my @jobs;
    while ( my $job = $next_job->() ) { push @jobs, $job }
    is [ map { [ $_->{mutant}->id, $_->{tests} ] } @jobs ],
      [ [ $detected_id, ['t/detect.t'] ], [ $other_id, [qw(t/also.t t/detect.t)] ] ],
      'the sample uses the recorded detector and keeps all covering tests for an undetected mutant';
    is $entries{ $excluded->id }{reason}, 'suppressed', 'a suppressed change stays outside the measurement queue';

    for my $case ( [ 0, 0, 0 ], [ 1, 1, 2 ], [ 1, 0, 0 ] ) {
        my ( $enabled, $sampling, $reused ) = @$case;
        my $config = Test::Mutation::Settings::of_call( { root => $project, cache => $enabled } );
        my $run    = { config => $config, jobs => 1, stats => {}, reused => $reused };
        my $opened = 0;
        no warnings 'redefine';
        ## no critic (Variables::ProtectPrivateVars, Subroutines::ProtectPrivateSubs)
        local *Test::Mutation::Runner::_open_cache = sub {
            ++$opened;
            return { path => $cache_path, targets => {}, records => {} };
        };
        local *Test::Mutation::Runner::_check_reused = sub { die "no cached verdict to verify\n" };
        my $fresh = Test::Mutation::Runner::_mutants( $run, [$excluded], $baseline, $sampling );
        ## use critic
        is $opened, $enabled && !$sampling ? 1 : 0, "cache=$enabled and sample=$sampling open the expected cache";
        is [ map { $_->{reason} } @$fresh ], ['suppressed'], 'a suppressed change keeps its reason';
    }

    for my $case (
        [ 'agreement',             {},                                        0, 0 ],
        [ 'another reason',        { reason => 'same-code-as-mutant' },       0, 1 ],
        [ 'a different verdict',   { status => 'Survived', reason => undef }, 0, 1 ],
        [ 'an interrupted sample', { status => 'Survived', reason => undef }, 1, 0 ],
      )
    {
        my ( $label, $changes, $interrupted, $mismatch ) = @$case;
        my %cached = (
            $detected_id  => { mutant => $detected, status => 'Killed', reason => undef, by => 't/detect.t' },
            $other_id     => { mutant => $other, status => 'Ignored', reason => 'same-code-as-original', by => undef },
            $excluded->id => { mutant => $excluded, status => 'Ignored', reason => 'suppressed' },
            'unknown'     => undef,
        );
        my @events;
        my $run = {
            reused         => 2,
            code_of_mutant => { $other_id     => 'code' },
            stats          => { verifications => 4 },
            listener       => sub ( $event, $data ) { push @events, [ $event, $data ]; return }
        };
        my $saved = { 'aaaaaaaaaaaa' => record() };
        Test::Mutation::Store::save( $cache_path, $saved );
        my @fresh = ( $cached{$detected_id}, { $cached{$other_id}->%*, %$changes } );
        no warnings 'redefine';
        local *Test::Mutation::Runner::_mutants = sub ( $context, $sample, $baseline, $sample_only ) {    ## no critic (Variables::ProtectPrivateVars)
            is [ sort map { $_->id } @$sample ], [ sort $detected_id, $other_id ],
              "$label samples only available verdicts";
            is $context->{sample_killers}, { $detected_id => 't/detect.t' },
              'only a detection reruns its recorded test';
            ok $sample_only, 'checking a sample requests fresh observations';
            $context->{listener}->( 'mutant', $fresh[0] );
            $context->{interrupted} = $interrupted;
            return \@fresh;
        };
        my $result = Test::Mutation::Runner::_check_reused( $run, { path => $cache_path }, {}, \%cached );    ## no critic (Subroutines::ProtectPrivateSubs)
        is $result, $interrupted ? \@fresh : undef, "$label returns the observations available after interruption";
        is $run->{stats}{verifications}, 6,         'each fresh observation adds one verification';
        is [ sort keys $run->{warnings}->%* ], $mismatch ? [ match qr/\Q$other_id\E/ ] : [],
          "$label reports the discrepant verdict";
        is !!$run->{cache_mismatch}, !!$mismatch, "$label determines whether the entire cache must be discarded";
        is $run->{reused}, $mismatch ? 0 : 2, "$label accounts for the reused verdicts";
        is $run->{code_of_mutant}, $mismatch ? {} : { $other_id => 'code' },
          "$label retains only verified deparsed code";
        is Test::Mutation::Store::load($cache_path), $mismatch ? {} : $saved, "$label determines what is left on disk";
        my @expected = $interrupted || $mismatch ? () : map { [ 'mutant', $cached{$_} ] } sort $detected_id, $other_id;
        is \@events, \@expected, 'only the accepted cached results reach the listener';
    }
};

done_testing;
