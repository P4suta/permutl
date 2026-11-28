use v5.36;
use Test2::V0;
use File::Temp  ();
use Config      qw(%Config);
use Cwd         ();
use Digest::SHA ();
use Time::HiRes ();
use lib 't/lib';
use Bounded;
use Raised;
use lib 't/e2e/lib';
use Fixture qw(run_fixture write_file);
use Test::Mutation::Error;
use Test::Mutation::Record;
use Test::Mutation::Runner;
use Test::Mutation::Select;
use Test::Mutation::Settings;
use Test::Mutation::Source;
use Test::Mutation::Store;
use Test::Mutation::Store::Key;
use Test::Mutation::Syntax::PPI;
use Test::Mutation::Workspace;

my $root = File::Temp::tempdir( CLEANUP => 1 );
write_file( "$root/A.pm",     "1;\n" );
write_file( "$root/data.txt", "first\n" );
my $original = Test::Mutation::Store::Key::tree( $root, ['A.pm'] );
write_file( "$root/A.pm", "2;\n" );
is Test::Mutation::Store::Key::tree( $root, ['A.pm'] ), $original, 'targets have a separate digest';
write_file( "$root/data.txt", "other\n" );
isnt Test::Mutation::Store::Key::tree( $root, ['A.pm'] ), $original, 'a same-size change to a data file counts';
write_file( "$root/data.txt", "first\n" );
chmod 0755, "$root/data.txt" or die $!;
isnt Test::Mutation::Store::Key::tree( $root, ['A.pm'] ), $original, 'an executable bit changes the project input';

subtest 'a project or workspace fingerprint visits each included file once' => sub {
    my $file = Test::Mutation::Store::Key->can('file');
    my @visited;
    no warnings 'redefine';
    local *Test::Mutation::Store::Key::file = sub ($path) {
        push @visited, $path;
        return $file->($path);
    };
    my $project = Test::Mutation::Store::Key::tree( $root, ['A.pm'] );
    is \@visited, ["$root/data.txt"], 'the project scans its data file once with the default output policy';
    @visited = ();
    my $copy = Test::Mutation::Store::Key::workspace( $root, ['A.pm'], [] );
    is \@visited, ["$root/data.txt"], 'the workspace scans its data file once without a separate original';
    is $copy,     $project,           'the same data has the same fingerprint in either workspace';
};

my $env = Test::Mutation::Store::Key::environment( { ANSWER => '1', SHLVL => '2' } );
is Test::Mutation::Store::Key::environment( { ANSWER => '1', SHLVL => '3' } ), $env, 'shell nesting is volatile';
isnt Test::Mutation::Store::Key::environment( { ANSWER => '2', SHLVL => '2' } ), $env, 'a test can read any variable';
isnt Test::Mutation::Store::Key::environment( { ANSWER => q{} } ), Test::Mutation::Store::Key::environment( {} ),
  'an empty variable differs from an absent variable';

subtest 'a search directory retains its identity when missing parents appear' => sub {
    my $project = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my $library = "$project/dependencies/vendor/lib";
    my $search  = { PERL5LIB => $library };
    my ( $ended, $missing ) =
      Bounded::ended( 3, sub { return Test::Mutation::Store::Key::environment( $search, $project ) } );
    ok $ended, 'looking up a missing directory reaches an existing ancestor';
    bail_out('the missing library search path did not resolve') unless $ended;
    write_file( "$library/Module.pm", "1;\n" );
    is Test::Mutation::Store::Key::environment( $search, $project ), $missing,
      'creating the library directory preserves its path in the environment fingerprint';
};

subtest 'search paths inside a checkout compare by their relative names' => sub {
    my $input = sub ( $root, @dirs ) {
        return Test::Mutation::Store::Key::environment( { PERL5LIB => join( $Config{path_sep}, @dirs ) }, $root );
    };
    my $first = $input->( '/a', '/shared', '/a', '/a/lib' );
    is $input->( '/b', '/shared', '/b', '/b/lib' ), $first, 'relocating the checkout keeps the search path';
    is $input->( '/', '/test-mutation-library' ), $input->( $root, "$root/test-mutation-library" ),
      'a project mounted at the filesystem root retains its library search path after relocation';
    isnt $input->( '/b', '/shared', '/b/lib', '/b' ),         $first, 'the order remains significant';
    isnt $input->( '/b', '/shared', '/b',     '/b-old/lib' ), $first, 'an adjacent directory stays external';

    my $checkout = File::Temp::tempdir( CLEANUP => 1 );
    mkdir "$checkout/lib" or die "create project library: $!";
    is $input->( $checkout, "$checkout/lib" ), '7db3e51c744ef23390d35f375428ecf0e9b99254bf401c9ed854356180e79e12',
      'the project library matches the environment fingerprint used by saved shards';
};

subtest 'an unresolved search directory keeps its checkout location' => sub {
    my @keys;
    for ( 1 .. 2 ) {
        my $project = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
        symlink 'missing/parent/lib', "$project/library" or die "link missing library: $!";
        push @keys, Test::Mutation::Store::Key::environment( { PERL5LIB => "$project/library" }, $project );
    }
    isnt $keys[0], $keys[1], 'dangling library links in different checkouts have different fingerprints';
};

subtest 'a search directory outside the checkout keeps its location' => sub {
    my $base = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    for my $site (qw(first second)) {
        write_file( "$base/$site/repo/bin/tool", 'local' );
        write_file( "$base/$site/tools/tool",    'external' );
        symlink '../tools',          "$base/$site/repo/tool-link" or die "link external search directory: $!";
        symlink 'bin',               "$base/$site/repo/alias"     or die "link local search directory: $!";
        symlink "$base/first/tools", "$base/$site/repo/shared"    or die "link shared search directory: $!";
    }
    my $alias = "$base/linked-project";
    symlink "$base/first/repo", $alias or die "link project root: $!";
    is Test::Mutation::Store::Key::environment( { PERL5LIB => "$alias/bin" }, $alias ),
      Test::Mutation::Store::Key::environment( { PERL5LIB => "$base/second/repo/bin" }, "$base/second/repo" ),
      'a library in a checkout reached through a symlink relocates with the project';
    for my $name (qw(PATH PERL5LIB PERLLIB)) {
        my $key = sub ( $site, $entry ) {
            my $project = "$base/$site/repo";
            $entry =~ s{^ROOT}{$project};
            return Test::Mutation::Store::Key::environment( { $name => $entry }, $project );
        };
        for my $external (qw(ROOT/../tools ROOT/tool-link ROOT/tool-link/absent/lib ../tools tool-link)) {
            isnt $key->( 'first', $external ), $key->( 'second', $external ), "$name distinguishes $external";
        }
        for my $local (qw(ROOT/bin ROOT/bin/../bin ROOT/absent/lib bin)) {
            is $key->( 'first', $local ), $key->( 'second', $local ), "$name relocates $local";
        }
        isnt $key->( 'first', 'ROOT/bin' ), $key->( 'first', 'ROOT/alias' ), "a test can read the $name spelling";
        is $key->( 'first', 'ROOT/shared' ), $key->( 'second', 'ROOT/shared' ),
          "$name can refer to the same external directory from both checkouts";
    }
};

subtest 'a fingerprint frames UTF-8 bytes and distinguishes run metadata from test inputs' => sub {
    is Test::Mutation::Store::Key::digest( q{}, '0', "\x{2603}" ), Digest::SHA::sha256_hex("0:1:03:\xe2\x98\x83"),
      'the length of a non-ASCII input counts its encoded bytes';
    my $base = Test::Mutation::Store::Key::environment( { INPUT => 'value' } );
    for my $name (
        qw(PWD OLDPWD SHLVL _ TMPDIR GITHUB_RUN_ID GITHUB_RUN_NUMBER GITHUB_RUN_ATTEMPT
        GITHUB_STEP_SUMMARY RUNNER_TEMP RUNNER_TRACKING_ID CI_JOB_ID CI_PIPELINE_ID
        TEST_MUTATION_SPEC_G12 TEST_MUTATION_RECORD_G0)
      )
    {
        is Test::Mutation::Store::Key::environment( { INPUT => 'value', $name => 'later run' } ), $base,
          "$name does not invalidate an otherwise identical shell or CI measurement";
    }
    for my $name (qw(TEST_MUTATION_SPEC_GX XTEST_MUTATION_RECORD_G1 TEST_MUTATION_SPEC_G1_SUFFIX)) {
        isnt Test::Mutation::Store::Key::environment( { INPUT => 'value', $name => 'test setting' } ), $base,
          "$name remains available as an ordinary test input";
    }
    is Test::Mutation::Store::Key::environment( { INPUT => 'value', UNSET => undef } ), $base,
      'an undefined environment value contributes no input';
    like dies { Test::Mutation::Store::Key::digest( [] ) }, qr/type constraint/, 'a digest part must contain bytes';
    like dies { Test::Mutation::Store::Key::environment( [] ) }, qr/type constraint/,
      'the environment maps names to values';
};

subtest 'a cached file digest needs both a stable identity and an old change time' => sub {
    my $scratch = File::Temp::tempdir( CLEANUP => 1 );
    my $path    = "$scratch/input";
    my $now     = 1_700_000_000;
    my $changed = $now;
    my $reads   = 0;
    my $addfile = Digest::SHA->can('addfile');
    no warnings 'redefine';
    local *Time::HiRes::time = sub () { return $now };
    local *Time::HiRes::stat = sub {
        my @metadata = CORE::stat( $_[0] );
        @metadata[ 9, 10 ] = ( $changed, $changed );
        return @metadata;
    };
    local *Digest::SHA::addfile = sub ( $sha, $input ) {
        ++$reads;
        return $sha->$addfile($input);
    };
    write_file( $path, 'one' );
    is Test::Mutation::Store::Key::file($path), Digest::SHA::sha256_hex('one'), 'the first access reads the contents';
    write_file( $path, 'two' );
    is Test::Mutation::Store::Key::file($path), Digest::SHA::sha256_hex('two'),
      'an immediate same-size edit on a coarse clock invalidates the digest';
    $now += 2;
    write_file( $path, 'six' );
    is Test::Mutation::Store::Key::file($path), Digest::SHA::sha256_hex('six'),
      'the boundary of the two-second grace period still reads the bytes';
    ++$now;
    is Test::Mutation::Store::Key::file($path), Digest::SHA::sha256_hex('six'),
      'an old unchanged file keeps its digest';
    is $reads, 3, 'the stable lookup avoids reading the contents again';
    ++$changed;
    $now += 5;
    write_file( $path, 'ten' );
    is Test::Mutation::Store::Key::file($path), Digest::SHA::sha256_hex('ten'),
      'a different old identity also invalidates the digest';
    is $reads, 4, 'the replacement was read once';
    isa_ok dies { Test::Mutation::Store::Key::file( $path, 'extra' ) }, ['Error::TypeTiny'],
      'the file lookup rejects an extra argument at its boundary';
};

subtest 'the project key follows directory aliases independently and terminates at ancestor links' => sub {
    my $scratch = File::Temp::tempdir( CLEANUP => 1 );
    my $tree    = "$scratch/project";
    mkdir $tree or die $!;
    write_file( "$scratch/external/item", 'data' );
    chmod oct '644', "$scratch/external/item" or die $!;
    for my $name (qw(a b)) {
        symlink '../external', "$tree/$name" or die $!;
    }
    symlink q{.},     "$tree/loop"    or die $!;
    symlink 'absent', "$tree/missing" or die $!;
    my $data = Digest::SHA::sha256_hex('data');
    my @expected;
    for my $name (qw(a b)) {
        push @expected, 'link', $name, '../external', 'directory', $name, 'file', "$name/item", 0, $data;
    }
    push @expected, 'link', 'loop', q{.}, 'directory', 'loop', 'link', 'missing', 'absent';
    is Test::Mutation::Store::Key::tree( $tree, [] ), Test::Mutation::Store::Key::digest(@expected),
      'the names, link destinations, independent descendants, mode and contents all contribute';
    my $empty = Test::Mutation::Store::Key::tree( $tree, [qw(a b loop missing)] );
    is $empty, Test::Mutation::Store::Key::digest(), 'an explicitly excluded subtree contributes nothing';
    isnt Test::Mutation::Store::Key::tree( "$tree/absent", [] ), $empty, 'a missing library differs from an empty one';
    like dies { Test::Mutation::Store::Key::tree( $tree, {} ) }, qr/type constraint/, 'exclusions must be a list';
    is Raised::error( sub { Test::Mutation::Store::Key::file("$tree/absent") } )->[1], 'file-unreadable',
      'an unavailable file cannot supply a digest';
};

subtest 'the interpreter key requires the binary and configuration of the Perl that actually ran' => sub {
    my $scratch       = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my $perl          = Cwd::abs_path($^X);
    my $binary        = Test::Mutation::Store::Key::file($perl);
    my $configuration = Config::config_sh();
    is Test::Mutation::Store::Key::interpreter($perl),
      Test::Mutation::Store::Key::digest( $perl, $binary, $perl, $binary, $configuration ),
      'the active interpreter includes its binary and compiled configuration';
    my $program = "$scratch/project perl";
    write_file( $program, "#!$perl\nexec {q{$perl}} q{$perl}, \@ARGV or die \$!;\n" );
    chmod oct '755', $program or die $!;
    {
        local $ENV{PERL5OPT} = '-MUnknown::MeasurementOption';
        is Test::Mutation::Store::Key::interpreter($program),
          Test::Mutation::Store::Key::digest( $program, Test::Mutation::Store::Key::file($program),
            $perl, $binary, $configuration ),
          'the wrapper and the resolved Perl are independent inputs even with caller startup options';
        is $ENV{PERL5OPT}, '-MUnknown::MeasurementOption', 'querying the interpreter restores the environment';
    }
    for my $body (
        'exit 3;', q{print q{};},
        q{print q{incomplete};},
        qq{print q{$perl}, "\\0", q{configuration}; exit 3;},
        qq{print q{$scratch/missing}, "\\0", q{configuration};},
        qq{print q{$perl}, "\\0";}
      )
    {
        write_file( $program, "#!$perl\n$body\n" );
        my $error = Raised::error( sub { Test::Mutation::Store::Key::interpreter($program) } );
        is $error->[1], 'interpreter-invalid', 'an incomplete or failed interpreter query cannot key a verdict';
    }
    isa_ok dies { Test::Mutation::Store::Key::interpreter( $perl, 'extra' ) }, ['Error::TypeTiny'],
      'the interpreter lookup rejects an extra argument at its boundary';
};

subtest 'a narrowed run keeps other cached verdicts and only reads additional inputs for the cache' => sub {
    my $project = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my ( $chosen, $support ) = qw(lib/Chosen.pm lib/Support.pm);
    write_file( "$project/$chosen",    "package Chosen;\nsub total { return \$_[0] + 2 }\n1;\n" );
    write_file( "$project/$support",   "package Support;\nsub total { return \$_[0] - 2 }\n1;\n" );
    write_file( "$project/t/totals.t", <<'PERL' );
use Test::More tests => 2;
use Chosen;
use Support;
is Chosen::total(5), 7;
is Support::total(5), 3;
PERL
    my %settings = ( root => $project, jobs => 1, equivalence => 0 );
    my $enabled  = Test::Mutation::Settings::of_call( { %settings, cache => 1 } );
    Test::Mutation::Runner::run( $enabled, sub { return } );
    my $file   = "$project/.mutation/measurement.sqlite";
    my $before = Test::Mutation::Store::load($file);
    my @other  = sort grep { $before->{$_}{path} eq $support } keys %$before;
    ok @other, 'the complete run saved verdicts outside the selection';

    for my $cache ( 0, 1 ) {
        my $config    = Test::Mutation::Settings::of_call( { %settings, cache => $cache } );
        my $selection = Test::Mutation::Select::resolve( config => $config, paths => { $chosen => [] } );
        my $read      = Test::Mutation::Source->can('read_bytes');
        my $locate    = Test::Mutation::Syntax::PPI->can('witness_offsets');
        my ( @reads, @observed, $phase );
        no warnings 'redefine';
        local *Test::Mutation::Source::read_bytes = sub ($path) {
            push @reads, $path if $phase eq 'plan' && ( $path eq "$project/$chosen" || $path eq "$project/$support" );
            return $read->($path);
        };
        local *Test::Mutation::Syntax::PPI::witness_offsets = sub ($source) {
            push @observed, $source->path;
            return $locate->($source);
        };
        my $result = Test::Mutation::Runner::run(
            $config,
            sub ( $event, $data ) { $phase = $data->{name} if $event eq 'phase'; return },
            { selection => $selection }
        );
        is \@reads, $cache ? ["$project/$support"] : [],
          'the selected bytes are reused and other inputs follow the cache setting';
        is \@observed, $cache ? [ $chosen, $support ] : [$chosen],
          'the baseline observes the required sources in path order';
        is [ sort keys $result->sources->%* ], [$chosen], 'the report contains the selected source';
    }
    my $uncached = Test::Mutation::Settings::of_call( { %settings, cache => 0 } );
    my $later    = Test::Mutation::Select::resolve( config => $uncached, paths => { $support => [] } );
    is [ sort keys $later->sources->%* ], [$support], 'an earlier unselected file leaves later sources available';
    my $after = Test::Mutation::Store::load($file);
    is [ @{$after}{@other} ], [ @{$before}{@other} ], 'a narrowed run retains every cached verdict outside its scope';
};

subtest 'a verdict depends on a complete original test and its external include directories' => sub {
    my $parent  = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my $project = "$parent/project";
    my $outside = "$parent/project-extra";
    write_file( "$project/lib/Value.pm", "package Value;\n1;\n" );
    write_file( "$outside/Extra.pm",     "package Extra;\n1;\n" );
    my $workspace = Test::Mutation::Workspace::acquire($project);
    my $private   = $workspace->directory;
    symlink $outside, "$parent/alias" or die "symlink: $!";
    my $missing = "$parent/unavailable/lib";
    my $target  = "$project/lib/Value.pm";
    my $run     = {
        root       => $project,
        project    => $project,
        workspace  => $workspace,
        perl       => $^X,
        config     => Test::Mutation::Settings::of_call( { root => $project } ),
        sources    => { 'lib/Value.pm' => 1 },
        test_paths => ['t/value.t'],
    };
    my $passing;

    for my $case (
        [ 'a passing test',    {},               q{},                1 ],
        [ 'a failed test',     { passed => 0 },  q{},                0 ],
        [ 'a stopped test',    { stopped => 1 }, q{},                0 ],
        [ 'an early exit',     { early => 1 },   q{},                0 ],
        [ 'a load elsewhere',  {},               "outside\t$target", 0 ],
        [ 'a bypassed module', {},               "around\t$target",  0 ],
      )
    {
        my ( $label, $changes, $extra, $eligible ) = @$case;
        my $log    = join "\n", grep { length } "begin\t1", "seen\t$target", $extra, "end\t1";
        my $record = Test::Mutation::Record::parse( [$log] );
        $record->{includes} = [ $project, "$project/lib", $private, "$parent/alias", $missing ];
        my $result  = { passed      => 1, early => 0, stopped => 0, duration => 1, %$changes };
        my $outcome = { 't/value.t' => { result => $result, record => $record } };
        my ($tests) = Test::Mutation::Runner::_baseline_records( $run, ['t/value.t'], ['lib/Value.pm'], $outcome );    ## no critic (Subroutines::ProtectPrivateSubs)
        my $fact    = $tests->{'t/value.t'};
        $passing = $tests if $eligible;
        is !!$fact->{reusable}, !!$eligible,            "$label determines whether a verdict can reuse the test";
        is $fact->{includes},   [ $outside, $missing ], 'external libraries retain their canonical or unavailable path';
    }
    my $fingerprint = sub ($command) {
        local $run->{build} = $command;
        return Test::Mutation::Runner::_fingerprint( $run, { tests => $passing } );                                    ## no critic (Subroutines::ProtectPrivateSubs)
    };
    my $before_edit = $fingerprint->( [] );
    write_file( "$outside/Extra.pm", "package Extra;\nsub value { 2 }\n1;\n" );
    my $changed = $fingerprint->( [] );
    isnt $changed, $before_edit, 'an edit to an external library changes the key for a previously passing test';
    isnt $fingerprint->( [ $^X, 'Build' ] ), $changed, 'running an incremental build changes the key';
    {
        local $run->{config} =
          Test::Mutation::Settings::of_call( { root => $project, in_place => 1, report_dir => 'spec' } );
        write_file( "$project/spec/operand", 'first' );
        my $stored = $fingerprint->( [] );
        write_file( "$project/spec/operand", 'other' );
        isnt $fingerprint->( [] ), $stored, 'in-place cached observations depend on data inside the report directory';
    }
    {
        local $run->{config} =
          Test::Mutation::Settings::of_call( { root => $project, link => ['linked'], report_dir => 'linked/reports' } );
        write_file( "$project/linked/reports/value", 'first' );
        my $cache_key   = $fingerprint->( [] );
        my $project_key = Test::Mutation::Store::Key::project( $project, ['linked/reports'], ['linked'] )->{digest};
        write_file( "$project/linked/reports/value", 'other' );
        isnt $fingerprint->( [] ), $cache_key, 'a linked directory exposes report data to cached tests';
        isnt Test::Mutation::Store::Key::project( $project, ['linked/reports'], ['linked'] )->{digest}, $project_key,
          'shard inputs include report data nested under an explicitly linked directory';
    }
    ok $workspace->release(0), 'the original test observation releases its workspace';
};

subtest 'a missing fingerprint input disables cache reuse while other failures propagate' => sub {
    my $project = File::Temp::tempdir( CLEANUP => 1 );
    write_file( "$project/lib/Value.pm", "package Value;\nsub next_value { return \$_[0] + 1 }\n1;\n" );
    write_file( "$project/t/value.t",    "use Test::More tests => 1;\nuse Value;\nis Value::next_value(3), 4;\n" );
    my %options  = ( cache => 1, jobs => 1, equivalence => 0 );
    my ($first)  = run_fixture( $project, %options );
    my @measured = map { [ $_->{mutant}->id, $_->{status} ] } $first->entries->@*;
    ok @measured, 'the project produces a verdict to cache';
    my ($warm) = run_fixture( $project, %options );
    is $warm->reused, scalar @measured, 'the same inputs can reuse every verdict';

    for my $failure (qw(file-unreadable directory-unopenable file-unclosable)) {
        no warnings 'redefine';
        local *Test::Mutation::Store::Key::tree = sub {
            Test::Mutation::Error::raise( $failure, path => 'inputs', reason => 'read failed' );
        };
        if ( $failure eq 'file-unclosable' ) {
            my $error = Raised::error( sub { run_fixture( $project, %options ) } );
            is $error->[1], $failure, 'a failed close stops the run with its original error';
            next;
        }
        my ($fresh) = run_fixture( $project, %options );
        is $fresh->reused, 0, "$failure prevents reuse of the old verdicts";
        is [ map { [ $_->{mutant}->id, $_->{status} ] } $fresh->entries->@* ], \@measured,
          'the tests still measure the complete inventory';
    }
    no warnings 'redefine';
    local *Test::Mutation::Store::Key::tree = sub { die "unexpected fingerprint failure\n" };
    like dies { run_fixture( $project, %options ) }, qr/\Aunexpected fingerprint failure\n\z/,
      'an unexpected failure keeps its diagnostic';
};

done_testing;
