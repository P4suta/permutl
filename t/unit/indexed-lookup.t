use v5.36;
use Test2::V0;
use File::Temp ();
use JSON::PP   ();
use lib 't/e2e/lib', 't/contract/lib';
use Fixture qw(copy_of write_file);
use World;
use Test::Mutation::Mutant::Generator;
use Test::Mutation::Report::Json;
use Test::Mutation::Runner;
use Test::Mutation::Settings;
use Test::Mutation::Store::History;
use Test::Mutation::Store::Key;

subtest 'an updated analysis rule appears in the catalog while previous verdicts remain visible' => sub {
    my $project = File::Temp::tempdir( CLEANUP => 1 );
    write_file( "$project/lib/Span.pm", "package Span;\nsub values { return 1 .. 3 }\n1;\n" );
    write_file( "$project/t/values.t",
        "use Test::More tests => 1;\nuse Span;\nis_deeply [Span::values()], [1, 2, 3];\n" );
    my $config   = Test::Mutation::Settings::of_call( { root => $project, profile => 'extended', jobs => 1 } );
    my $generate = Test::Mutation::Mutant::Generator->can('generate');
    my $prior;
    {
        no warnings 'redefine';
        local $Test::Mutation::Select::ANALYSIS_REVISION   = 'without range boundaries';
        local *Test::Mutation::Mutant::Generator::generate = sub (@arguments) {
            my $made = $generate->(@arguments);
            $made->{mutants} = [ grep { $_->mutator ne 'range-boundary' } $made->{mutants}->@* ];
            return $made;
        };
        $prior = Test::Mutation::Runner::run( $config, sub { } );
        Test::Mutation::Store::History::record( $config, $prior, 1 );
    }
    ok !( grep { $_->{mutant}->mutator eq 'range-boundary' } $prior->entries->@* ),
      'the stored catalog predates the range rule';
    my ($observed) = grep { $_->{status} eq 'Killed' } $prior->entries->@*;
    my @profile    = ( '--profile', 'extended', '--enable', 'range-boundary' );
    my $fresh      = World::observe( [ 'list', @profile, '--no-cache' ], cwd => $project );
    like $fresh->{stdout}, qr/\brange-boundary\b/, 'the current rule generates a range from the source';
    my $indexed = World::observe( [ 'list', @profile ], cwd => $project );
    is [ $indexed->{stdout} =~ /^([0-9a-f]{12})  /mg ], [ $fresh->{stdout} =~ /^([0-9a-f]{12})  /mg ],
      'a saved analysis yields the current list of identifiers on upgrade';
    my $show = World::observe( [ 'show', $observed->{mutant}->id, @profile ], cwd => $project );
    like $show->{stdout}, qr/^Last result: Killed\nMeasured at: \S+/m,
      'the dated verdict of an unchanged mutant survives';
    my $current = Test::Mutation::Runner::run( $config, sub { } );
    isnt $current->catalog_digest, $prior->catalog_digest, 'a prior report cannot refresh a different catalog';
    isnt $current->measurement_digest, $prior->measurement_digest,
      'shards made under different analysis rules have different inputs';
};

subtest 'a catalog that omitted an overload callback cannot hide its mutant' => sub {
    my $project = File::Temp::tempdir( CLEANUP => 1 );
    my $path    = 'lib/Weighted.pm';
    write_file( "$project/$path", <<'PERL' );
package Weighted;
use overload q{+} => do {
    my $weight = 1 + 1;
    sub { $_[1] * $weight }
};
1;
PERL
    write_file( "$project/t/plus.t", <<'PERL' );
use Test::More tests => 1;
use Weighted;
is((bless {}, 'Weighted') + 3, 6);
PERL
    my $config   = Test::Mutation::Settings::of_call( { root => $project, jobs => 1 } );
    my $previous = do {
        local $Test::Mutation::Select::ANALYSIS_REVISION = 1;
        Test::Mutation::Select::resolve( config => $config, read_only => 1 );
    };
    my $identity =
      Test::Mutation::Store::Key::digest( $previous->analysis_rules_digest, $path, $previous->digests->{$path} );
    my $empty = { problem => undef, left_out => 0, rejected => [], refusals => [], mutants => [] };
    Test::Mutation::Store::Analysis::publish( Test::Mutation::Store::path($config), [ [ $identity, $empty ] ] );
    my $measured = Test::Mutation::Runner::run( $config, sub { } );
    is [
        map  { [ $_->{mutant}->original, $_->{mutant}->replacement, $_->{status}, $_->{by} ] }
        grep { $_->{mutant}->mutator eq 'arithmetic' } $measured->entries->@*
      ],
      [ [ q{*}, q{/}, 'Killed', 't/plus.t' ] ], 'the project test detects the changed calculation with a warm index';
};

subtest 'two removed changes with the same historical prefix stay ambiguous' => sub {
    my $project = File::Temp::tempdir( CLEANUP => 1 );
    my $source  = "package Example;\nsub sum { return \$_[0] + \$_[1] }\n1;\n";
    my @files   = map { write_file( "$project/lib/Unit$_.pm", $source ) } 71, 314;
    write_file( "$project/t/smoke.t", "use Test::More tests => 1; pass('smoke');\n" );
    my $config   = Test::Mutation::Settings::of_call( { root => $project, jobs => 1 } );
    my $initial  = Test::Mutation::Runner::run( $config, sub { } );
    my @matching = grep { $_->{mutant}->id =~ /\A1917/ && $_->{status} eq 'NoCoverage' } $initial->entries->@*;
    is scalar @matching, 2, 'the completed measurement records both uncovered changes';
    write_file( $_, "1;\n" ) for @files;
    my $recheck = World::observe( [qw(run --undetected --mutant 1917 --jobs 1)], cwd => $project );
    is [ $recheck->@{qw(exit stderr)} ], [ 2, "mutation: more than one mutant has the identifier 1917\n" ],
      'the command requires a longer prefix before naming a file to remeasure';
};

subtest 'a cached identifier is resolved against the current source and settings' => sub {
    my $project       = File::Temp::tempdir( CLEANUP => 1 );
    my $source        = "package Example;\nsub sum { return \$_[0] + \$_[1] }\n1;\n";
    my $measured_file = write_file( "$project/lib/Unit71.pm", $source );
    my $config        = Test::Mutation::Settings::of_call( { root => $project } );
    Test::Mutation::Select::resolve( config => $config );
    my $show = sub (@options) { return World::observe( [ 'show', '1917', @options ], cwd => $project ) };
    like $show->()->{stdout}, qr/1917052cc06c/, 'the prefix identifies the measured file';
    my $added_file = write_file( "$project/lib/Unit314.pm", $source );
    is [ $show->()->@{qw(exit stderr)} ], [ 2, "mutation: more than one mutant has the identifier 1917\n" ],
      'a new file makes the same prefix ambiguous';
    unlink $measured_file or die "remove $measured_file: $!";
    like $show->()->{stdout}, qr/1917d1188d5e/, 'a removed file leaves only the new candidate';
    Test::Mutation::Select::resolve( config => $config );
    my ( $accessed, $modified ) = ( stat $added_file )[ 8, 9 ];
    write_file( $added_file, $source =~ s/[+]/-/r );
    utime $accessed, $modified, $added_file or die "restore the source timestamp: $!";
    is [ $show->()->@{qw(exit stderr)} ], [ 2, "mutation: no mutant has the identifier 1917\n" ],
      'a same-size edit at the recorded time invalidates the identifier';
    write_file( $added_file, $source );
    like $show->( '--test', 't/missing.t' )->{stderr}, qr/pattern "t\/missing[.]t" matches no project file/,
      'a missing configured test still fails the lookup';
    like $show->( '--perl', './absent-perl' )->{stderr}, qr/cannot use "[.]\/absent-perl" as the Perl interpreter/,
      'a missing configured interpreter still fails the lookup';
};

subtest 'catalog planning reads an existing store without initializing it' => sub {
    my $project = copy_of('calc');
    my $store   = write_file( "$project/.mutation/measurement.sqlite", q{} );
    my $plan    = World::observe( [ 'list', 'lib/Calc.pm' ], cwd => $project, run => 'cheap' )->{plan};
    ok scalar $plan->{selection}->mutants->@*, 'the source supplies the catalog when the index is empty';
    is -s $store, 0, 'planning leaves the uninitialized database untouched';
    my $config = $plan->{config};
    Test::Mutation::Select::resolve( config => $config );
    my $read = Test::Mutation::Store::Analysis->can('read_files');
    my @write_errors;
    no warnings 'redefine';
    local *Test::Mutation::Store::Analysis::read_files = sub ( $db, @query ) {
        my $error = dies { $db->do('UPDATE setting SET data = data WHERE 0') };
        push @write_errors, $error ? "$error" : q{};
        return $read->( $db, @query );
    };
    my $cached = World::observe( [ 'list', 'lib/Calc.pm' ], cwd => $project, run => 'cheap' )->{plan};
    is $cached->{selection}->inventory, $plan->{selection}->inventory,
      'planning reads the previously published catalog';
    is \@write_errors, [ match qr/readonly database/ ], 'SQLite denies writes through the catalog reader';
};

subtest 'planning a path run leaves the catalog to execution' => sub {
    my $project = copy_of('calc');
    my @args    = ( 'run', 'lib/Calc.pm:12', '--format', 'terminal', '--jobs', 1 );
    my $plan    = World::observe( \@args, cwd => $project, run => 'cheap' )->{plan};
    ok !$plan->{refused},        'the plan accepts the file and range';
    ok !-e "$project/.mutation", 'planning creates no cache in the project';
    is World::observe( \@args, cwd => $project )->{exit}, 0, 'the selected range runs';
    ok -f "$project/.mutation/measurement.sqlite", 'execution publishes the file analysis';
    my $parsed  = 0;
    my $analyze = Test::Mutation::Syntax::PPI->can('analyze');
    no warnings 'redefine';
    local *Test::Mutation::Syntax::PPI::analyze = sub (@arguments) { $parsed++; return $analyze->(@arguments) };
    is World::observe( [ 'list', 'lib/Calc.pm:12' ], cwd => $project )->{exit}, 0, 'the measured range can be listed';
    is $parsed, 0, 'the next lookup reads the warm file analysis';
};

subtest 'queries can use a read-only project with an uninitialized history' => sub {
    my $project = copy_of('calc');
    my $store   = write_file( "$project/.mutation/measurement.sqlite", q{} );
    chmod oct('444'), $store or die "protect $store: $!";
    my $list = World::observe( [ 'list', 'lib/Calc.pm' ], cwd => $project );
    is $list->{exit}, 0, 'the catalog can be listed without initializing its history';
    my $id    = $list->{plan}{selection}->mutants->[0]->id;
    my $shown = World::observe( [ 'show', $id ], cwd => $project );
    like $shown->{stdout}, qr/^Last result: unmeasured$/m, 'show displays a mutant without recorded observations';
    my $rerun = World::observe( [ 'run', '--undetected' ], cwd => $project );
    like $rerun->{stderr}, qr/no completed measurement/, 'the empty history reports that no measurement is available';
    is -s $store, 0, 'querying history leaves the empty file untouched';
};

my $root = copy_of('equivalent');
write_file( "$root/lib/Other.pm", 'package Other; sub inc { return $_[0] + 1 } 1;' );
my $config = Test::Mutation::Settings::of_call( { root => $root, jobs => 1 } );
my $result = Test::Mutation::Runner::run( $config, sub { } );
Test::Mutation::Store::History::record( $config, $result, 1 );
write_file( "$root/mutation-report/mutation.json",
    Test::Mutation::Report::Json::render( $result, low => 60, high => 80 ) );
my ($entry) = grep { $_->{status} eq 'Survived' } $result->entries->@*;
my $id = $entry->{mutant}->id;
subtest 'a parser already loaded by the application takes precedence over disk metadata' => sub {
    my $parsed  = 0;
    my $analyze = Test::Mutation::Syntax::PPI->can('analyze');
    local @INC                   = grep { !ref } @INC;
    local $PPI::VERSION          = '9.001';
    local $PPIx::Regexp::VERSION = undef;
    no warnings 'redefine';
    local *Test::Mutation::Syntax::PPI::analyze = sub (@arguments) { ++$parsed; return $analyze->(@arguments) };
    is World::observe( [ 'show', $id ], cwd => $root )->{exit}, 0, 'the current parser can analyze the sources';
    ok $parsed, 'the earlier parser version cannot supply cached results';
};
subtest 'lookup reads the current file identities in one group' => sub {
    my @queries;
    my $connect = Test::Mutation::Store->can('_connect');
    no warnings 'redefine';
    local *Test::Mutation::Store::_connect = sub (@arguments) {    ## no critic (Variables::ProtectPrivateVars)
        my $connection = $connect->(@arguments);
        $connection->sqlite_trace( sub ($sql) { push @queries, $sql if $sql =~ /\bFROM (?:analysis|candidate)\b/i } );
        return $connection;
    };
    for my $arguments ( [ 'show', $id ], ['list'], [ 'run', '--mutant', $id, '--jobs', 1, '--format', 'terminal' ] ) {
        @queries = ();
        is World::observe( $arguments, cwd => $root )->{exit}, 0, "$arguments->[0] reads existing file analyses";
        is scalar @queries, 2, "$arguments->[0] uses one catalog query and one candidate query across both files";
    }
};
subtest 'a lookup with directory-based module loading uses disk metadata' => sub {
    my $probe = <<'PERL';
END { print "loaded $_\n" for sort keys %INC }
require Test::Mutation::CLI;
local @INC = grep { !ref } @INC;
do './bin/mutation';
die $@ || $!;
PERL
    for my $arguments ( [ 'show', $id ], ['list'] ) {
        open my $child, q{-|}, $^X, '-Ilib', '-e', $probe, '--', '--root', $root, @$arguments
          or die "start the lookup: $!";
        my @output = readline $child;
        ok close($child),                        "$arguments->[0] exits successfully";
        ok scalar( grep { /\Q$id\E/ } @output ), "$arguments->[0] displays the measured mutant";
        my @modules = grep { m{\Aloaded Test/Mutation/(?:Runner|Merge)[.]pm\n\z} } @output;
        is \@modules, [], "$arguments->[0] runs without loading the test runner or merging reports";
        my @analysis =
          grep { m{\Aloaded (?:PPI|PPIx/Regexp|Test/Mutation/(?:Syntax/PPI|Mutant/Generator))[.]pm\n\z} } @output;
        is \@analysis, [], "$arguments->[0] uses the installed analyzer versions without loading the parsers";
        my @harness = grep { m{\Aloaded TAP/(?:Harness|Parser/SourceHandler/Perl)[.]pm\n\z} } @output;
        is \@harness, [], "$arguments->[0] does not start the test harness";
        my @writers = grep { m{\Aloaded Test/Mutation/Report/(?:Json|Html)[.]pm\n\z} } @output;
        is \@writers, [], "$arguments->[0] formats the indexed result without opening an earlier report";
    }
};
subtest 'a loader-supplied parser version determines which catalog can be used' => sub {
    my $probe = <<'PERL';
our ($parser_path, $parser_version) = splice @ARGV, 0, 2;
my $module = q{
    do $main::parser_path or die $@ || $!;
    $PPIx::Regexp::VERSION = $main::parser_version;
    1;
};
unshift @INC, sub { return $_[1] eq 'PPIx/Regexp.pm' ? \$module : () };
END {
    print "parser ", $PPIx::Regexp::VERSION // 'unloaded', "\n";
    print "generated ", (exists $INC{'Test/Mutation/Mutant/Generator.pm'} ? 1 : 0), "\n";
}
do './bin/mutation';
die $@ || $!;
PERL
    my $installed = $PPIx::Regexp::VERSION;
    for my $case ( [ $installed, 0 ], [ "${installed}_01", 1 ] ) {
        my ( $version, $generated ) = @$case;
        for my $arguments ( [ 'show', $id ], ['list'] ) {
            my $label = "$arguments->[0] with parser $version";
            open my $child, q{-|}, $^X, '-Ilib', '-e', $probe, '--', $INC{'PPIx/Regexp.pm'}, $version,
              '--root', $root, @$arguments
              or die "start the lookup: $!";
            my @output = readline $child;
            ok close($child),                        "$label exits successfully";
            ok scalar( grep { /\Q$id\E/ } @output ), "$label displays the measured mutant";
            is [ grep { /\A(?:parser|generated) / } @output ], [ "parser $version\n", "generated $generated\n" ],
              "$label only regenerates a catalog made with a different parser";
        }
    }
};
my ( $parsed, $reports, $restored ) = ( 0, 0, 0 );
my $make    = Test::Mutation::Mutant->can('new');
my $parse   = Test::Mutation::Report::Json->can('parse');
my $analyze = Test::Mutation::Syntax::PPI->can('analyze');
my $decode  = Test::Mutation::Source->can('from_bytes');
my @decoded;
{
    no warnings 'redefine';
    local *Test::Mutation::Source::from_bytes = sub ( $class, %given ) {
        push @decoded, $given{path};
        return $decode->( $class, %given );
    };
    local *Test::Mutation::Mutant::new          = sub (@arguments) { $restored++; return $make->(@arguments) };
    local *Test::Mutation::Report::Json::parse  = sub (@arguments) { $reports++;  return $parse->(@arguments) };
    local *Test::Mutation::Syntax::PPI::analyze = sub (@arguments) { $parsed++;   return $analyze->(@arguments) };
    my $shown = World::observe( [ 'show', substr( $id, 0, 8 ) ], cwd => $root );
    is $shown->{exit}, 0, 'show finds a prefix in the indexed measurement';
    like $shown->{stdout}, qr/^Last result: Survived\nMeasured at: (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)$/m,
      'show dates the observed status';
    is [ $parsed, $reports, $restored ], [ 0, 0, 1 ], 'show restores one mutant without a parse or full report read';
    is \@decoded,                        [ $entry->{mutant}->path ], 'only the displayed file is decoded for its patch';
    my $row_decodes = 0;
    my $decode_row  = JSON::PP->can('decode');
    local *JSON::PP::decode = sub (@arguments) {
        $row_decodes++ if caller =~ /\ATest::Mutation::Store/;
        return $decode_row->(@arguments);
    };
    my $listed = World::observe( ['list'], cwd => $root );
    like $listed->{stdout}, qr/^\Q$id\E .* \[Survived\] \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/m,
      'list dates each historical status';
    is [ $parsed, $reports ], [ 0, 0 ], 'list reads the index and skips both parsers';
    is $row_decodes, 0,
      'listing the warm catalog avoids pure Perl JSON decoding for every stored candidate and verdict';
    my $loads = 0;
    my $load  = Test::Mutation::Store->can('load');
    local *Test::Mutation::Store::load = sub (@arguments) { $loads++; return $load->(@arguments) };
    $restored = 0;
    my $run = World::observe( [ 'run', '--mutant', $id, '--jobs', '1', '--format', 'terminal' ], cwd => $root );
    is $run->{exit}, 0, 'the named mutant is remeasured through the CLI';
    is [ $parsed, $reports, $loads ], [ 0, 0, 0 ],
      'rerunning one mutant skips analysis, full reports, and bulk verdict reads';
    is $restored, 1, 'the rerun restores exactly the requested mutant';
}
subtest 'combined selectors read one completed scope' => sub {
    my $snapshots = 0;
    my $select    = DBI::db->can('selectall_arrayref');
    no warnings 'redefine';
    local *DBI::db::selectall_arrayref = sub ( $connection, $sql, @options ) {
        $snapshots++ if $sql =~ /WITH scope AS/;
        return $select->( $connection, $sql, @options );
    };
    my $rerun = World::observe(
        [ 'run', '--undetected', '--mutant', $id, $entry->{mutant}->path, '--jobs', 1, '--format', 'terminal' ],
        cwd => $root );
    is $rerun->{exit}, 0, 'the combined selection measures the previous survivor';
    is $snapshots,     1, 'all selectors use the same database snapshot even if another measurement finishes';
};
done_testing;
