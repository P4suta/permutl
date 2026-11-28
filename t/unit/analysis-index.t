use v5.36;
use Test2::V0;
use DBD::SQLite::Constants qw(SQLITE_LIMIT_EXPR_DEPTH SQLITE_LIMIT_VARIABLE_NUMBER);
use File::Temp             ();
use lib 't/e2e/lib';
use Fixture qw(copy_of write_file);
use Test::Mutation::Select;
use Test::Mutation::Settings;

my $root = copy_of('calc');
write_file( "$root/lib/Other.pm", 'package Other; sub plus { return $_[0] + 1 } 1;' );
my $config   = sub (%given) { Test::Mutation::Settings::of_call( { root => $root, %given } ) };
my $all      = Test::Mutation::Select::resolve( config => $config->() );
my $id       = $all->mutants->[0]->id;
my $uncached = Test::Mutation::Select::resolve( config => $config->( cache => 0, mutant => [$id] ) );
is [ map { $_->id } $uncached->mutants->@* ], [$id],      'an uncached lookup resolves the requested identifier';
is [ sort keys $uncached->sources->%* ], ['lib/Calc.pm'], 'unrelated source files stay outside the uncached result';
my $analyze = Test::Mutation::Syntax::PPI->can('analyze');
my @parsed;
{
    no warnings 'redefine';
    local *Test::Mutation::Syntax::PPI::analyze = sub ($source) {
        push @parsed, $source->path;
        return $analyze->($source);
    };
    my $named = Test::Mutation::Select::resolve( config => $config->( mutant => [$id] ) );
    is [ map { $_->id } $named->mutants->@* ], [$id],           'the index resolves the selected mutant';
    is [ sort keys $named->sources->%* ],      ['lib/Calc.pm'], 'a named result exposes the source of the selected ID';
    is \@parsed,                               [],              'an indexed named measurement parses no source';
    write_file( "$root/lib/Other.pm", 'package Other; sub plus { return $_[0] - 1 } 1;' );
    my $listed = Test::Mutation::Select::resolve( config => $config->() );
    is \@parsed, ['lib/Other.pm'], 'a changed source reparses only that file';
    @parsed = ();
    Test::Mutation::Select::resolve( config => $config->( disable => ['arithmetic'] ) );
    is \@parsed, [qw(lib/Calc.pm lib/Other.pm)], 'a changed operator selection invalidates the cached analysis';
    @parsed = ();
    Test::Mutation::Select::resolve( config => $config->( cache => 0 ) );
    is \@parsed, [qw(lib/Calc.pm lib/Other.pm)], 'disabling the cache forces fresh analysis';
}
subtest 'the index refreshes ranges whose left operand starts with a method' => sub {
    my $project = File::Temp::tempdir( CLEANUP => 1 );
    my $path    = 'lib/Range.pm';
    write_file( "$project/$path", 'sub values { my ($rule, $a, $b) = @_; my @range = $rule->if + $a ... $b; @range }' );
    my $settings = Test::Mutation::Settings::of_call( { root => $project, profile => 'extended' } );
    {
        local $Test::Mutation::Select::ANALYSIS_REVISION = 2;
        Test::Mutation::Select::resolve( config => $settings );
    }
    my @reads;
    no warnings 'redefine';
    local *Test::Mutation::Syntax::PPI::analyze = sub ($source) {
        push @reads, $source->path;
        return $analyze->($source);
    };
    my $current = Test::Mutation::Select::resolve( config => $settings );
    is \@reads, [$path], 'the earlier precedence rules require one fresh analysis';
    is [ grep { $_->mutator eq 'range-boundary' } $current->mutants->@* ], [], 'a list range has no scalar flip-flop';
    Test::Mutation::Select::resolve( config => $settings );
    is \@reads, [$path], 'the corrected index serves the next lookup without reparsing';
};

subtest 'a missing historical identifier names its previous file' => sub {
    my @refused;
    no warnings 'redefine';
    local *Test::Mutation::Error::raise = sub ( $id, %fields ) {
        @refused = ( $id, \%fields );
        die "selection refused\n";
    };
    my $prefix = '123456789abc';
    ok dies {
        Test::Mutation::Select::resolve(
            config           => $config->( mutant => [$prefix] ),
            historical_paths => { $prefix => 'lib/Previous.pm' }
        );
    }, 'a stale selection stops before testing';
    is \@refused, [ 'mutant-history-stale', { identifier => $prefix, path => 'lib/Previous.pm' } ],
      'the diagnostic carries the identifier and the file to remeasure';
};
subtest 'an unfiltered catalog decodes candidates as it reads them' => sub {
    my $db = Test::Mutation::Store::database( Test::Mutation::Store::path( $config->(), 0 ) );
    my ($analysis) =
      $db->selectrow_array( 'SELECT analysis FROM candidate WHERE id = ? ORDER BY analysis LIMIT 1', undef, $id );
    my @events;
    my $sorts;
    my $fetch     = DBI::st->can('fetchrow_array');
    my $construct = Test::Mutation::Mutant->can('new');
    no warnings 'redefine';
    local *DBI::st::fetchrow_array = sub ( $query, @arguments ) {
        if ( $query->{Statement} =~ /\bFROM candidate\b/i ) {
            push @events, 'read';
            $sorts = $query->sqlite_st_status->{sort};
        }
        return $fetch->( $query, @arguments );
    };
    local *Test::Mutation::Mutant::new = sub (@arguments) {
        push @events, 'decode';
        return $construct->(@arguments);
    };
    my $file = Test::Mutation::Store::Analysis::read_file( $db, $analysis, [] );
    cmp_ok scalar $file->{mutants}->@*, '>', 1, 'the file contains multiple candidates';
    is [ @events[ 0 .. 3 ] ], [qw(read decode read decode)],
      'the cursor releases each encoded row before fetching another';
    is $sorts, 0, 'SQLite streams the catalog in its stored order without a temporary sort';
};
subtest 'invalid catalog operations fail at the requested interface' => sub {
    my $directory = File::Temp::tempdir( CLEANUP => 1 );
    my $path      = "$directory/catalog.sqlite";
    isa_ok dies { Test::Mutation::Store::Analysis::publish( $path, [ [ 'source', {} ] ] ) }, ['Error::TypeTiny'],
      'incomplete analysis facts are rejected';
    ok !-e $path, 'an invalid batch creates no database';
    my $db = Test::Mutation::Store::database($path);
    isa_ok dies { Test::Mutation::Store::Analysis::read_file( $db, 'source' ) }, ['Error::TypeTiny'],
      'a single-file lookup requires a prefix filter';
    isa_ok dies { Test::Mutation::Store::Analysis::read_files( undef, [], [] ) }, ['Error::TypeTiny'],
      'an empty batch still requires an open database';
};
subtest 'retrying a partially stored batch keeps both file analyses' => sub {
    my $directory = File::Temp::tempdir( CLEANUP => 1 );
    my $path      = "$directory/catalog.sqlite";
    my ( $stored_mutant, $queued_mutant ) = $all->mutants->@[ 0, 1 ];
    my $saved = { problem => undef, left_out => 0, refusals => [], rejected => [], mutants => [$stored_mutant] };
    my $next  = { %$saved, left_out => 3, mutants => [$queued_mutant] };
    Test::Mutation::Store::Analysis::publish( $path, [ [ 'existing', $saved ] ] );
    Test::Mutation::Store::Analysis::publish( $path, [ [ 'existing', $next ], [ 'later', $next ] ] );
    my $db    = Test::Mutation::Store::read_database($path);
    my $files = Test::Mutation::Store::Analysis::read_files( $db, [qw(existing later)], [] );
    is $files->{existing}, $saved, 'the existing file retains its first analysis and candidate';
    is $files->{later},    $next,  'the later file and its candidate are committed in the same retry';
};
subtest 'a failed candidate write rolls back the entire catalog batch' => sub {
    my $directory = File::Temp::tempdir( CLEANUP => 1 );
    my $path      = "$directory/catalog.sqlite";
    my $db        = Test::Mutation::Store::database($path);
    $db->do(<<'SQL');
CREATE TRIGGER refuse_candidate BEFORE INSERT ON candidate WHEN NEW.analysis = 'later'
BEGIN SELECT RAISE(ABORT, 'refused candidate'); END
SQL
    my $facts = { problem => undef, left_out => 0, refusals => [], rejected => [], mutants => [ $all->mutants->[0] ] };
    my $batch = [ map { [ $_, $facts ] } qw(first later) ];
    like dies { Test::Mutation::Store::Analysis::publish( $path, $batch ) }, qr/refused candidate/,
      'a write error reaches the caller';
    is Test::Mutation::Store::Analysis::read_files( $db, [qw(first later)], [] ), {},
      'a separate connection sees no part of the failed batch';
    $db->do('DROP TRIGGER refuse_candidate');
    is Test::Mutation::Store::Analysis::publish( $path, $batch ), undef, 'a successful retry returns no value';
    is Test::Mutation::Store::Analysis::read_files( $db, [qw(first later)], [] ), { first => $facts, later => $facts },
      'both file analyses and their candidates are visible after the commit';
};
subtest 'thousands of named mutants fit within SQLite query limits' => sub {
    my $project = File::Temp::tempdir( CLEANUP => 1 );
    my $methods = join "\n", map { sprintf 'sub sum%03d { return $_[0] + $_[1] }', $_ } 1 .. 96;
    for my $number ( 1 .. 7 ) {
        write_file( "$project/lib/Arithmetic$number.pm", "package Arithmetic$number;\n$methods\n1;\n" );
    }
    my $settings = Test::Mutation::Settings::of_call( { root => $project } );
    my @ids      = map { $_->id } Test::Mutation::Select::resolve( config => $settings )->mutants->@*;
    is scalar @ids, 2016, 'each of the 672 sums has three mutants';
    my $candidate_queries = 0;
    my $database          = Test::Mutation::Store->can('database');
    no warnings 'redefine';
    local *Test::Mutation::Store::database = sub (@arguments) {
        my $db = $database->(@arguments);
        $db->sqlite_limit( SQLITE_LIMIT_VARIABLE_NUMBER, 999 );
        $db->sqlite_limit( SQLITE_LIMIT_EXPR_DEPTH,      100 );
        $db->sqlite_trace( sub ($sql) { ++$candidate_queries if $sql =~ /\bFROM candidate\b/i } );
        return $db;
    };
    my $selected =
      Test::Mutation::Select::resolve( config => $settings, identifiers => [ reverse @ids, @ids[ 0, 1 ] ] );
    is [ map { $_->id } $selected->mutants->@* ], \@ids,
      'complete identifiers retain inventory order without duplicates';
    cmp_ok $candidate_queries, '<=', 5, 'two thousand complete identifiers use at most five candidate queries';
    my @prefixes = map { substr $_, 0, 11 } @ids;
    my $id_reads = 0;
    my $read_id  = Test::Mutation::Mutant->can('id');
    {
        local *Test::Mutation::Mutant::id = sub (@arguments) { ++$id_reads; return $read_id->(@arguments) };
        $selected =
          Test::Mutation::Select::resolve( config => $settings, identifiers => [ reverse @prefixes, $ids[0] ] );
    }
    is [ map { $_->id } $selected->mutants->@* ], \@ids, 'short prefixes and an overlapping complete identifier agree';
    cmp_ok $id_reads, '<=', 8 * @ids, 'a batch of short prefixes makes a bounded number of passes over the candidates';
    $selected = Test::Mutation::Select::resolve( config => $settings, identifiers => [] );
    is $selected->mutants, [], 'an explicitly empty list selects zero mutants';
    my $db       = Test::Mutation::Store::database( Test::Mutation::Store::path( $settings, 0 ) );
    my $analyses = $db->selectcol_arrayref('SELECT identity FROM analysis');
    $candidate_queries = 0;
    my $invalid = Test::Mutation::Store::Analysis::read_files( $db, $analyses, [ q{}, 'G', 'bad?/', 'ff*' ] );
    is [ sort keys %$invalid ], [ sort @$analyses ], 'cached file facts survive a request with no valid prefixes';
    ok !grep( { $_->{mutants}->@* } values %$invalid ), 'an invalid prefix never expands to every mutant';
    is $candidate_queries, 0, 'a request with no valid prefixes skips candidate queries';
    my $leading_zero = Test::Mutation::Store::Analysis::read_files( $db, $analyses, ['0'] );
    is [
        sort map {
            map { $_->id }
              $_->{mutants}->@*
        } values %$leading_zero
      ],
      [ sort grep { /\A0/ } @ids ],
      'the hexadecimal zero remains a valid prefix';
    my @missing = map { "missing-$_" } 1 .. 1200;
    my $found   = Test::Mutation::Store::Analysis::read_files( $db, [ @missing, @$analyses ], [ $ids[0] ] );
    is [ sort keys %$found ], [ sort @$analyses ], 'a large file catalog returns facts only for current analyses';
    is [
        map {
            map { $_->id }
              $_->{mutants}->@*
        } values %$found
      ],
      [ $ids[0] ],
      'a large file catalog still resolves the requested mutant';
};
subtest 'two candidates with the same complete identifier are ambiguous' => sub {
    my $collision = '111111111111';
    no warnings 'redefine';
    local *Test::Mutation::Mutant::id = sub ($mutant) { return $collision };
    like dies {
        Test::Mutation::Select::resolve( config => $config->( cache => 0, mutant => [$collision] ) );
    }, qr/more than one mutant has the identifier $collision/,
      'a full identifier cannot silently select two candidates';
};
done_testing;
