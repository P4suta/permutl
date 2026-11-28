use v5.36;
use Test2::V0;
use JSON::PP ();
use lib 't/e2e/lib', 't/contract/lib';
use Fixture qw(copy_of with_driver_shims write_file);
use World;
use Test::Mutation;
use Test::Mutation::Store;

sub traced ($operation) {
    my %counts =
      ( writes => 0, writers => 0, totals => 0, history => 0, pruning => 0, connections => 0, verdict_files => {} );
    my $connect = Test::Mutation::Store->can('_connect');
    my $fetch   = DBI::st->can('fetchrow_arrayref');
    my $json    = JSON::PP->new;
    my $save    = Test::Mutation::Store->can('save');
    my $phase   = {};
    no warnings 'redefine';
    local *DBI::st::fetchrow_arrayref = sub ( $statement, @args ) {
        my $row = $fetch->( $statement, @args );
        if ( $row && $statement->{Statement} =~ /\ASELECT id, data FROM verdict\b/ ) {
            $counts{verdict_files}{ $json->decode( $row->[1] )->{path} }++;
        }
        return $row;
    };
    local *Test::Mutation::Store::save = sub (@args) {
        local $phase->{inventory} = ref $args[2] eq 'ARRAY' && $args[2]->@*;
        return $save->(@args);
    };
    local *Test::Mutation::Store::_connect = sub (@arguments) {    ## no critic (Variables::ProtectPrivateVars)
        my $db = $connect->(@arguments);
        $counts{connections}++;
        my $writes = 0;
        $db->sqlite_trace(
            sub ($sql) {
                if ( $sql =~ /INSERT OR REPLACE INTO verdict/ ) {
                    $counts{writers}++ unless $writes++;
                    $counts{writes}++;
                }
                $counts{totals}++  if $writes && $sql =~ /SELECT count\(\*\) FROM verdict/i;
                $counts{history}++ if $sql =~ /SELECT/i && $sql =~ /\bobservation\b/;
                $counts{pruning}++ if $phase->{inventory} && $sql =~ /\A(?:CREATE|DROP|INSERT|DELETE)/i;
                return 0;
            }
        );
        return $db;
    };
    my $result = with_driver_shims($operation);
    return ( $result, \%counts );
}

my $root = copy_of('calc');
write_file( "$root/mutation.toml", q{} );
write_file( "$root/lib/Other.pm",  'package Other; sub inc { return $_[0] + 1 } 1;' );
my ( $cold, $work ) = traced( sub { Test::Mutation::run( root => $root, jobs => 1 ) } );
ok $work->{writes} > 1, 'the measurement publishes multiple reusable verdicts';
is $work->{writers}, 1, 'all checkpoints in one measurement use one writer';
is $work->{totals},  0, 'a committed checkpoint does not count the entire verdict table';
my ( $warm, $repeat ) = traced( sub { Test::Mutation::run( root => $root, jobs => 1 ) } );
ok $warm->reused > 1, 'the warm measurement verifies cached observations';
is $repeat->{pruning}, 2, 'a complete inventory prunes obsolete identifiers and source revisions in two statements';
my ( $listed, $queries ) = traced( sub { World::observe( ['list'], cwd => $root ) } );
is $listed->{exit},     0, 'the measured catalog can be listed';
is $queries->{history}, 1, 'listing the catalog reads its dated observations in one query';
my ( $narrow, $subset ) = traced(
    sub {
        World::observe( [ 'run', 'lib/Other.pm', '--jobs', 1, '--format', 'terminal' ], cwd => $root );
    }
);
is $narrow->{exit}, 0, 'a single-file measurement consults the warm cache';
is [ sort keys $subset->{verdict_files}->%* ], ['lib/Other.pm'],
  'the database returns verdicts only for the selected file';
my ( $uncached, $private ) = traced(
    sub {
        World::observe( [ 'run', 'lib/Other.pm', '--no-cache', '--jobs', 1, '--format', 'terminal' ], cwd => $root );
    }
);
is $uncached->{exit},       0, 'a file can also be measured without the cache';
is $private->{connections}, 0, 'an uncached command opens no existing SQLite store for reading or writing';
subtest 'an unfinished mutant keeps the timestamp of its last verdict' => sub {
    my @killed  = grep { $_->{status} eq 'Killed' } $warm->entries->@*;
    my $sent    = 0;
    my $stopped = with_driver_shims(
        sub {
            Test::Mutation::run(
                root     => $root,
                jobs     => 1,
                mutant   => [ map { $_->{mutant}->id } @killed ],
                on_event => sub ( $event, $value ) { kill 'TERM', $$ if $event eq 'mutant' && !$sent++ }
            );
        }
    );
    is $stopped->interrupted, 'TERM', 'the repeated measurement stops after a committed mutant';
    my ($waiting) = grep { $_->{status} eq 'Pending' } $stopped->entries->@*;
    ok $waiting, 'another requested mutant still awaits completion';
    my $config   = Test::Mutation::Settings::of_call( { root => $root } );
    my $id       = $waiting->{mutant}->id;
    my $selected = Test::Mutation::Select::resolve( config => $config, identifiers => [$id], read_only => 1 );
    my $past     = Test::Mutation::Store::History::entries( $config, $selected->sources, $selected->mutants )->{$id};
    is [ $past->@{qw(status finished)} ], [ 'Killed', $warm->finished ],
      'the unfinished rerun preserves the last measured status and finish time';
};

subtest 'a damaged build setting allows the next measurement to finish' => sub {
    my $config = Test::Mutation::Settings::of_call( { root => $root } );
    my $db     = Test::Mutation::Store::database( Test::Mutation::Store::path($config) );
    $db->do( q{UPDATE setting SET data = ? WHERE id = 'build'}, undef, '{' );
    my $run = World::observe( [ 'run', '--jobs', 1, '--format', 'terminal' ], cwd => $root );
    is $run->{exit}, 0, 'the baseline and mutation tests finish after reading malformed build arguments';
};

done_testing;
