package Test::Mutation::Store::History;
use v5.36;
use Cwd              ();
use Cpanel::JSON::XS ();
use Types::Standard  qw(ArrayRef Bool Dict HashRef InstanceOf Maybe Num Str Undef);
use Type::Params     qw(signature_for);
use Test::Mutation::Diff;
use Test::Mutation::Store;
use Test::Mutation::Store::Key;
use Test::Mutation::Types qw(PathSelection StatusName);

our $VERSION = '0.001';

my $CONFIG = InstanceOf ['Test::Mutation::Config'];
my $JSON   = Cpanel::JSON::XS->new->canonical;

signature_for record => (
    positional => [
        $CONFIG, InstanceOf ['Test::Mutation::Result'],
        Bool,
        Maybe [ Dict [ completed => Num, measured => HashRef [Num] ] ],
        { default => undef }
    ],
    returns => Undef,
);

sub record ( $config, $result, $anchor, $merge ) {
    return unless $config->cache;
    my $db       = Test::Mutation::Store::database( Test::Mutation::Store::path($config) );
    my $complete = !defined $result->shard && !defined $result->interrupted && !$result->baseline_failures->@*;
    my $project  = Cwd::abs_path( $config->root );
    my %sources  = map { $_ => Test::Mutation::Store::Key::digest( $result->sources->{$_} ) } keys $result->sources->%*;
    Test::Mutation::Store::transaction(
        $db,
        sub {
            $db->do(
                'CREATE INDEX IF NOT EXISTS completed_scope ON measurement(project,finished DESC,run DESC) WHERE anchor = 1'
            );
            $db->do(
                'INSERT INTO measurement(project,finished,anchor,complete) VALUES (?,?,?,?)',
                undef, $project,
                $merge               ? $merge->{completed} : $result->finished,
                $anchor && $complete ? 1                   : 0,
                $complete            ? 1                   : 0
            );
            my $run   = $db->sqlite_last_insert_rowid;
            my $write = $db->prepare('INSERT INTO observation VALUES (?,?,?,?,?,?,?)');
            my $order = 0;
            for my $entry ( $result->entries->@* ) {
                my ( $mutant, %facts ) = ( $entry->{mutant}, $entry->%* );
                delete $facts{mutant};
                my $path = $mutant->path;
                my $id   = $mutant->id;
                $facts{lines} = $mutant->line_span;
                if ($merge) {
                    my $observed = $merge->{measured}{$id};
                    $facts{measured} = 0 + ( $observed // $result->finished );
                }
                $write->execute( $run, $order++, $id, $path, $sources{$path}, $entry->{status},
                    $JSON->encode( \%facts ) );
            }
            return;
        }
    );
    return;
}

signature_for entries => (
    positional => [
        $CONFIG, HashRef [ InstanceOf ['Test::Mutation::Source'] ], ArrayRef [ InstanceOf ['Test::Mutation::Mutant'] ]
    ],
    returns => Maybe [
        HashRef [ Dict [ status => StatusName, finished => Num, covered_by => ArrayRef [Str], by => Maybe [Str] ] ]
    ],
);

sub entries ( $config, $sources, $mutants ) {
    return unless $config->cache;
    my $db      = Test::Mutation::Store::read_database( Test::Mutation::Store::path( $config, 0 ) ) or return;
    my $project = Cwd::abs_path( $config->root );
    my ( %digests, %requested );
    for my $mutant (@$mutants) {
        my $file   = $mutant->path;
        my $digest = $digests{$file} ||= Test::Mutation::Store::Key::digest( $sources->{$file}->text );
        push $requested{$digest}->@*, $mutant->id;
    }
    my $rows = $db->selectall_arrayref( <<'SQL', undef, $project, $JSON->encode( \%requested ) );
WITH measured AS (
    SELECT project FROM measurement WHERE project = ? LIMIT 1
), latest AS (
    SELECT found.id, found.status, json_extract(found.data, '$.covered_by') AS covered,
           json_extract(found.data, '$.by') AS detector,
           coalesce(json_extract(found.data, '$.measured'), measurement.finished) AS finished
    FROM json_each(?) files CROSS JOIN json_each(files.value) requested
    CROSS JOIN observation found JOIN measurement USING(run)
    WHERE found.rowid = (
        SELECT prior.rowid FROM observation prior JOIN measurement seen USING(run)
        WHERE prior.id = requested.value AND prior.source = files.key AND prior.status <> 'Pending'
          AND seen.project = (SELECT project FROM measured)
        ORDER BY coalesce(json_extract(prior.data, '$.measured'), seen.finished) DESC, seen.run DESC LIMIT 1
    )
)
SELECT latest.* FROM measured LEFT JOIN latest ON 1
SQL
    return unless @$rows;
    my %entries;
    for my $row (@$rows) {
        my ( $id, $status, $covered, $by, $finished ) = @$row;
        $entries{$id} = { status => $status, covered_by => $JSON->decode($covered), by => $by, finished => $finished }
          if defined $id;
    }
    return \%entries;
}

my $GAPS = ArrayRef [ Dict [ id => Str, path => Str, source => Str ] ];

signature_for undetected => (
    positional => [ $CONFIG, ArrayRef [PathSelection], { default => sub { [] } } ],
    returns    => Maybe [$GAPS]
);

sub undetected ( $config, $filters ) {
    my $scope = undetected_scope( $config, $filters );
    return $scope ? $scope->{selected} : undef;
}

signature_for undetected_scope => (
    positional => [ $CONFIG, ArrayRef [PathSelection] ],
    returns    => Maybe [ Dict [ selected => $GAPS, identifiers => ArrayRef [Str] ] ]
);

sub undetected_scope ( $config, $filters ) {
    return unless $config->cache;
    my $db      = Test::Mutation::Store::read_database( Test::Mutation::Store::path( $config, 0 ) ) or return;
    my $project = Cwd::abs_path( $config->root );
    my $rows    = $db->selectall_arrayref( <<'SQL', { Slice => {} }, $project );
WITH scope AS (
    SELECT run, project, finished FROM measurement WHERE project = ? AND anchor = 1
    ORDER BY finished DESC, run DESC LIMIT 1
), eligible AS (
    SELECT observation.id, observation.source, observation.status, run, measurement.project,
           coalesce(json_extract(observation.data, '$.measured'), measurement.finished) AS measured
    FROM observation JOIN measurement USING(run)
    WHERE measurement.complete = 1 AND observation.status NOT IN ('NoVerdict', 'Pending', 'Timeout')
), gaps AS (
    SELECT member.id, member.path, member.source, member.ordinal, json_extract(member.data, '$.lines') AS lines
    FROM scope CROSS JOIN observation member USING(run)
    WHERE (
        SELECT status FROM eligible
        WHERE eligible.project = scope.project AND eligible.id = member.id AND eligible.source = member.source
          AND (eligible.measured, eligible.run) >= (coalesce(json_extract(member.data, '$.measured'), scope.finished), scope.run)
        ORDER BY eligible.measured DESC, eligible.run DESC LIMIT 1
    ) IN ('Survived', 'NoCoverage')
)
SELECT gaps.id, gaps.path, gaps.source, gaps.lines FROM scope LEFT JOIN gaps ON 1 ORDER BY gaps.ordinal
SQL
    return unless @$rows;
    my $scope = { selected => [], identifiers => [] };
    return $scope unless defined $rows->[0]{id};

    for my $row (@$rows) {
        push $scope->{identifiers}->@*, $row->{id};
        my $lines = delete $row->{lines};
        my $span  = defined $lines ? $JSON->decode($lines) : undef;
        next if grep {
            my $ranges = $_->{ $row->{path} };
            !$ranges || ( @$ranges && $span && !Test::Mutation::Diff::touches( $ranges, @$span ) )
        } @$filters;
        push $scope->{selected}->@*, $row;
    }
    return $scope;
}

1;

__END__

=head1 NAME

Test::Mutation::Store::History - keep dated observations and the last completed measurement scope

=head1 FUNCTIONS

=head2 record

Records the measured entries and finish time atomically.
A true third argument makes a completed run the scope of the next search for undetected changes.
For a merge, an optional fourth argument supplies the completion time and the measurement time for each mutant identifier.

=head2 undetected

Returns the identifiers, files, and source digests of the gaps still present in the latest completed scope.
Optional file and line filters intersect the recorded locations.
An empty array marks a measured scope with no gaps.
An undefined value marks missing history.

=head2 undetected_scope

Returns the selected gaps and the identifiers of every remaining gap from one database snapshot.

=head2 entries

Returns the latest matching observation and finish time for each requested mutant.
The result is undefined when the project has no indexed measurement.

=cut
