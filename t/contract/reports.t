use v5.36;
use Test2::V0;
use lib 't/contract/lib', 't/e2e/lib', 't/lib';
use Encode   ();
use JSON::PP ();
use Fcntl    qw(:flock O_RDONLY);
use Fixture  qw(write_file);
use Capability;
use Gate;
use Invariants;
use Samples;
use Space;
use World;
use Test::Mutation::Report::GitHub;
use Test::Mutation::Report::Html;
use Test::Mutation::Report::Json;
use Test::Mutation::Report::Terminal;
use Test::Mutation::Runner;
use Test::Mutation::Source;
use Test::Mutation::Status;
use Test::Mutation::Store::Key;

# S6, the reports: results of every outcome, with each status present and absent, in every shape of source and every format.
# Every format states the same counts, the report file reads back as it was written, and its score is the score of the run.

my @statuses  = Test::Mutation::Status::rows()->@*;
my %status_of = map { $_->word => $_->name } @statuses;
my $format    = Samples::type('Format');
my @formats   = sort ( 'github', $format->{valid}->@* );
my @sets      = Space::result_sets()->@*;
my @shapes    = Space::shapes()->@*;
my $failure   = [ { test => 't/sample.t', output => "not ok 1\n", errors => q{} } ];
my %violations;

sub violation ( $gate, $what, $one, $format ) {
    push $violations{$gate}->@*, [ $what, $one, $format ];
    return;
}

sub tallied (@names) {
    my %count;
    $count{$_}++ for @names;
    return \%count;
}

sub mutants_of ($document) {
    return map { $_->{mutants}->@* } values $document->{files}->%*;
}

# The counts of the statuses of the run, which a report file keeps beside the name of the schema.
sub document_counts ($document) {
    return tallied( map { $_->{testMutation}{status} } mutants_of($document) );
}

# The documents of the report files, as a viewer reads them.
my %document_of = (
    json => sub ($result) {
        return JSON::PP->new->decode( Test::Mutation::Report::Json::render( $result, high => 80, low => 60 ) );
    },
    html => sub ($result) {
        my ($data) =
          Test::Mutation::Report::Html::render( $result, high => 80, low => 60 ) =~
          m{<script id="report" type="application/json">(.*?)</script>}s
          or die "the HTML report holds no document\n";
        return JSON::PP->new->decode($data);
    },
);

# The counts that each format states, by status, or nothing for a report without counts.
my %stated = (
    terminal => sub ($result) {
        my ($summary) = Test::Mutation::Report::Terminal::render( $result, color => 0 ) =~ /^\d+ mutants?(:[^\n]*)?\n/m
          or return;
        return { map { /(\d+) (.+)\z/ ? ( $status_of{$2} => $1 ) : () } split /, /, defined $summary ? $summary : q{} };
    },
    json   => sub ($result) { return document_counts( $document_of{json}->($result) ) },
    html   => sub ($result) { return document_counts( $document_of{html}->($result) ) },
    github => sub ($result) {
        my ( $heads, $values ) =
          Test::Mutation::Report::GitHub::summary($result) =~ /^([|] Killed [|][^\n]*)\n[|][^\n]*\n([|][^\n]*)$/m;
        my @heads  = map  { $status_of{ lc $_ } } grep { length } split /\s*[|]\s*/, $heads;
        my @values = grep { length } split /\s*[|]\s*/, $values;
        return { map { $heads[$_] => $values[$_] } 0 .. $#heads };
    },
);

sub facts ($result) {
    return [ map { { id => $_->{mutant}->id, $_->%{qw(status reason detail)} } } $result->entries->@* ];
}

# The report file as the command writes it and as the merge reads it: UTF-8 on the way out and on the way in.
sub read_again ($result) {
    my $bytes = Encode::encode( 'UTF-8', Test::Mutation::Report::Json::render( $result, high => 80, low => 60 ) );
    return Test::Mutation::Report::Json::parse( Encode::decode( 'UTF-8', $bytes ) );
}

subtest 'the readers of the reports reject a count that a format leaves out' => sub {
    my $result = Samples::result( statuses => [qw(Killed Killed Timeout Ignored)] );
    my %counts = ( Killed => 2, Timeout => 1, Ignored => 1 );
    is $stated{$_}->($result), \%counts, "the counts of the $_ report" for qw(terminal json html);
    is $stated{github}->($result), { ( map { $_->name => 0 } @statuses ), %counts }, 'the counts of the summary';
    is [ Invariants::counts( \%counts, { Killed => 2, Timeout => 1 } ) ],
      [ [ 'the report states no count', 'Ignored' ] ],
      'a report that leaves a status out';
    is tallied( map { $_->{status} } mutants_of( $document_of{json}->($result) ) ), { Killed => 2, Ignored => 2 },
      'the report file writes the names of the schema, which a viewer counts';
    is [ Invariants::round_trip( facts($result), facts( read_again($result) ) ) ], [], 'the report file reads back';
};

subtest 'a report update excludes a second writer until both formats are saved' => sub {
    my $root      = Space::scratch();
    my $directory = "$root/locked-reports";
    my $available = sub {
        sysopen my $writer, $directory, O_RDONLY or die "open the report directory: $!";
        return 1 if flock $writer, LOCK_EX | LOCK_NB;
        die "lock the report directory: $!" unless $!{EWOULDBLOCK} || $!{EAGAIN};
        return 0;
    };
    my $sample      = Samples::result( statuses => ['Killed'], letters => 'latin1' );
    my $stage       = Test::Mutation::CLI->can('_stage_report');
    my $description = Test::Mutation::Mutant->can('description');
    my $inputs      = Test::Mutation::Store::Key::tree( $root, [], 1 );
    my $described   = 0;
    my @locks;
    no warnings 'redefine';
    local *Test::Mutation::Runner::run         = sub { return $sample };
    local *Test::Mutation::Mutant::description = sub ($self) { $described++; return $description->($self) };
    local *Test::Mutation::CLI::_stage_report  = sub ( $path, $name ) {                                        ## no critic (Variables::ProtectPrivateVars)
        push @locks, [ $name, $available->() ];
        return $stage->( $path, $name );
    };
    my $observed = World::observe( [ 'run', '--report-dir', 'locked-reports', '--format', 'json', '--format', 'html' ],
        cwd => $root );
    is $observed->{exit}, 0, 'the writer saved both reports';
    is $described,        1, 'publishing the same mutant to JSON and HTML encodes it once';
    my $bytes      = Test::Mutation::Source::read_bytes("$directory/mutation.json");
    my $html       = Test::Mutation::Source::read_bytes("$directory/mutation.html");
    my ($embedded) = $html =~ m{<script id="report" type="application/json">(.+?)</script>}s;
    is JSON::PP->new->utf8->decode($embedded), JSON::PP->new->utf8->decode($bytes),
      'the viewer and the standalone report receive the same measurement';
    is JSON::PP->new->utf8->decode($bytes)->{files}{'lib/Sample.pm'}{source}, $sample->sources->{'lib/Sample.pm'},
      'a UTF-8 reader recovers the original accented source from the published report';
    is \@locks, [ [ 'locked-reports/mutation.json', 0 ], [ 'locked-reports/mutation.html', 0 ] ],
      'another writer cannot enter during either write';
    ok $available->(), 'another writer can update the directory after publication';
    is Test::Mutation::Store::Key::tree( $root, [], 1 ), $inputs, 'publishing both reports adds no test inputs';
};

subtest 'publishing a measurement streams its own scope regardless of earlier reports' => sub {
    my $root     = Space::scratch();
    my $path     = "$root/scoped/mutation.json";
    my $original = Samples::result( statuses => [qw(Survived Survived)] );
    my $id       = $original->entries->[0]{mutant}->id;
    my $previous = Test::Mutation::Report::Json::render( $original, high => 80, low => 60 );
    my $document = \&Test::Mutation::Report::Json::document;
    my $parse    = \&Test::Mutation::Report::Json::parse;

    for my $case (
        [ 'whole project', {},                                     undef, $previous ],
        [ 'named mutant',  { mutants => [$id] },                   undef, $previous ],
        [ 'source path',   { paths => { 'lib/Sample.pm' => [] } }, undef, q{} ],
        [ 'changed lines', { since => 'HEAD' },                    undef, '{' ],
        [ 'shard',         {},                                     '1/2', $previous ],
      )
    {
        my ( $name, $selection, $shard, $saved ) = @$case;
        write_file( $path,                        $saved );
        write_file( "$root/scoped/mutation.html", '<html></html>' );
        my $result = Samples::result(
            statuses       => ['Killed'],
            selection      => $selection,
            shard          => $shard,
            catalog_digest => 'ac' x 32,
        );
        my ( $parsed, $built ) = ( 0, 0 );
        {
            no warnings 'redefine';
            local *Test::Mutation::Runner::run            = sub { return $result };
            local *Test::Mutation::Report::Json::parse    = sub (@args) { $parsed++; return $parse->(@args) };
            local *Test::Mutation::Report::Json::document = sub (@args) { $built++;  return $document->(@args) };
            my $run = World::observe( [ 'run', '--report-dir', 'scoped', '--format', 'json', '--format', 'html' ],
                cwd => $root );
            is $run->{exit}, 0, "$name publishes both formats";
        }
        is [ $parsed, $built ], [ 0, 0 ], "$name reads and builds zero whole report documents";
        my $written = $parse->( Test::Mutation::Source::read_bytes($path) );
        is [ map { $_->{status} } $written->entries->@* ], ['Killed'], "$name scores only the current observation";
    }
};

subtest 'GitHub uses the remaining space in a shared step summary' => sub {
    my $root   = Space::scratch();
    my $file   = "$root/step.md";
    my @args   = ( 'run', '--github', '--format', 'json', '--report-dir', 'saved' );
    my $sample = Samples::result( statuses => ['Survived'] );
    no warnings 'redefine';
    local *Test::Mutation::Runner::run = sub { return $sample };
    my $first = World::observe( \@args, cwd => $root, env => { GITHUB_STEP_SUMMARY => $file } );
    is $first->{exit},     0,  'the summary is written';
    is $first->{warnings}, [], 'starting an empty step summary emits no Perl warning';
    like Test::Mutation::Source::read_bytes($file), qr{saved/mutation[.]json}, 'the summary points to the actual file';
    my $limit = 1024 * 1024;
    write_file( $file, 'x' x ( $limit - 80 ) );
    my $repeat = World::observe( \@args, cwd => $root, env => { GITHUB_STEP_SUMMARY => $file } );
    is $repeat->{exit}, 0, 'a nearly full summary keeps its measurement outcome';
    ok -s $file <= $limit, 'the append respects the bytes already present';
    like Test::Mutation::Source::read_bytes($file), qr/Undetected: 1/, 'the compact summary still reports the gap';

    my $brief = "Undetected: 1\nScore: **0.0%** (0 of 1 valid mutant)\n";
    my $last  = Encode::encode( 'UTF-8', "\x{65e5}" );
    for my $case (
        [
            $last,      length($brief) + 1,
            "\n$brief", 'a final Japanese character and the brief report occupy separate lines'
        ],
        [ $last, length($brief), q{},    'the report needs space for the missing line ending' ],
        [ "\n",  length($brief), $brief, 'a terminated line leaves every remaining byte for the report' ],
        [ "\r",  length($brief), $brief, 'a carriage return already ends a Markdown line' ],
      )
    {
        my ( $ending, $remaining, $expected, $label ) = @$case;
        my $before = 'x' x ( $limit - $remaining - length $ending ) . $ending;
        write_file( $file, $before );
        my $append = World::observe( \@args, cwd => $root, env => { GITHUB_STEP_SUMMARY => $file } );
        is $append->{exit}, 0, 'a bounded append preserves the measurement outcome';
        my $bytes = Test::Mutation::Source::read_bytes($file);
        is substr( $bytes, length($before) - length($ending) ), $ending . $expected, $label;
    }

    subtest 'an append-only writer can use a step summary it cannot read' => sub {
        Capability::need( 'unprivileged', $> != 0, 'the superuser can read write-only files' );
        write_file( $file, 'earlier output' );
        chmod 0200, $file or die "protect the existing summary: $!";
        my $append = World::observe( \@args, cwd => $root, env => { GITHUB_STEP_SUMMARY => $file } );
        chmod 0600, $file or die "read the appended summary: $!";
        is $append->{exit},     0,  'write permission is sufficient for a step summary';
        is $append->{warnings}, [], 'the append emits no warning about the unreadable file';
        like Test::Mutation::Source::read_bytes($file), qr/\Aearlier output\n## Mutation testing\n/,
          'the report starts a new line when the earlier text cannot be read';
    };
};

my $count = 0;
my %seen;
for my $shape (@shapes) {
    for my $case ( ( map { ( [ $_->@*, undef ], [ $_->@*, 'INT' ] ) } @sets ), [ 'failing', [], undef ] ) {
        my ( $label, $names, $signal ) = $case->@*;
        my $failing = $label eq 'failing';
        my $result  = Samples::result(
            statuses    => $names,
            interrupted => $signal,
            letters     => $shape->{letters},
            lines       => $shape->{lines},
            ( $failing ? ( baseline_failures => $failure ) : () ),
        );
        my $counts = tallied( $names->@* );
        for my $format (@formats) {
            $count++;
            $seen{format}{$format} = $seen{shape}{ $shape->{label} } = $seen{set}{$label} = 1;
            my $stated = $stated{$format}->($result) or next;
            violation( 'counts', $_->[0], $_->[1], $format ) for Invariants::counts( $counts, $stated );
        }

        # A viewer of the report file computes the score from the statuses that the file holds.
        for my $format ( sort keys %document_of ) {
            my $held = tallied( map { $_->{status} } mutants_of( $document_of{$format}->($result) ) );
            violation( 'role', $_, $label, $format ) for Invariants::role( $held, $result->tally->{score} );
        }
        my $again = read_again($result);
        my @lost  = Invariants::round_trip( facts($result), facts($again) );

        push @lost, 'the text of a source changes' if Space::differences( $result->sources, $again->sources )->@*;
        push @lost, 'the signal of the run changes'
          if ( defined $signal ? $signal : 'none' ) ne ( defined $again->interrupted ? $again->interrupted : 'none' );
        violation( 'round-trip', $_, $shape->{label}, 'json' ) for @lost;
    }
}

is $count,       @shapes * @formats * ( 2 * @sets + 1 ), 'every result in every shape and every format';
is scalar @sets, 2 + 2 * @statuses,                      'no status, every status, and each status alone and left out';
is [ sort keys $seen{format}->%* ], \@formats,                            'every report format and the GitHub summary';
is [ sort keys $seen{shape}->%* ],  [ sort map { $_->{label} } @shapes ], 'every shape';
Gate::checked( 'reports', $count, at_least => 800 );

subtest 'the bytes of the terminal report through the command' => sub {
    for my $shape (@shapes) {
        my $result =
          Samples::result( statuses => [qw(Survived Killed)], letters => $shape->{letters}, lines => $shape->{lines} );
        my $report = Test::Mutation::Report::Terminal::render( $result, color => 0 );
        no warnings 'redefine';
        local *Test::Mutation::Runner::run = sub { return $result };
        my $observation = World::observe( [ 'run', '--format', 'terminal' ], cwd => Space::scratch() );
        is $observation->{exit}, 0, "the run of $shape->{label} succeeds";
        violation( 'stdout', $_, $shape->{label}, 'terminal' )
          for Invariants::encoded( $observation->{stdout}, $report );
        violation( 'no-leak', $_, $shape->{label}, 'terminal' ) for Invariants::no_leak($observation);
    }
    Gate::checked( 'shapes through the command', scalar @shapes, at_least => 6 );
};

Gate::findings( 'contract-counts-reports',     Space::folded( $violations{counts} || [], 'statuses',     'formats' ) );
Gate::findings( 'contract-role-reports',       Space::folded( $violations{role}   || [], 'results',      'formats' ) );
Gate::findings( 'contract-round-trip-reports', Space::folded( $violations{'round-trip'} || [], 'shapes', 'formats' ) );
Gate::findings( 'contract-stdout-reports',     Space::folded( $violations{stdout}       || [], 'shapes', 'formats' ) );
Gate::findings( 'contract-no-leak-reports',    Space::folded( $violations{'no-leak'}    || [], 'shapes', 'formats' ) );

done_testing;
