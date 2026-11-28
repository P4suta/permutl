package Test::Mutation::Report::Json;
use v5.36;
use Cpanel::JSON::XS ();
use JSON::PP         ();
use Types::Standard  qw(ArrayRef CodeRef Dict Enum HashRef InstanceOf Int Maybe Num Optional Str StrMatch Tuple Undef);
use Types::Common::Numeric qw(PositiveInt PositiveOrZeroInt);
use Type::Params           qw(signature_for);
use Test::Mutation::Error;
use Test::Mutation::Exit;
use Test::Mutation::Mutant;
use Test::Mutation::Result;
use Test::Mutation::Source;
use Test::Mutation::Status;
use Test::Mutation::Try;
use Test::Mutation::Types qw(Assessment Observations Reason ReportSelection StatusName);

our $VERSION = '0.001';

my $MILLISECONDS = 1000;

# The counts of the work of a run under the names of the report, which writes its keys in camel case.
my %WORK_KEY = (
    copies         => 'copies',
    walks          => 'walks',
    compiles       => 'compiles',
    spawns         => 'spawns',
    listings       => 'listings',
    baseline_tests => 'baselineTests',
    verifications  => 'verifications',
);

# The document names the values that a result accepts, so that a refusal points at a place in the report.
# The status of a mutant is the name of the schema, and the facts beside it keep the status of the run and its reason.
my $FLAG     = InstanceOf ['JSON::PP::Boolean'];
my $POSITION = Dict [ line => PositiveInt, column => PositiveInt ];
my $MUTANT   = (
    Dict [
        id             => Str,
        mutatorName    => Str,
        replacement    => Str,
        description    => Str,
        location       => Dict [ start => $POSITION, end => $POSITION ],
        status         => Enum [ map { $_->schema } Test::Mutation::Status::rows()->@* ],
        statusReason   => Optional [Str],
        coveredBy      => ArrayRef [Str],
        killedBy       => Optional [ ArrayRef [Str] ],
        testsCompleted => Int,
        duration       => Num,
        static         => $FLAG,
        testMutation   => Dict [
            status         => StatusName,
            reason         => Maybe [Reason],
            scope          => Tuple [ Int, Int ],
            suppressed     => $FLAG,
            comparable     => $FLAG,
            compiledDigest => Optional [ StrMatch [qr/\A[0-9a-f]{64}\z/] ],
            observations   => Optional [Observations],
            decidingTest   => Optional [Str],
        ],
    ]
)->where( sub { _consistent($_) } );
my $DOCUMENT = Dict [
    schemaVersion => Str,
    thresholds    => Dict [ high => Int, low => Int ],
    projectRoot   => Str,
    framework     => Dict [ name => Str, version => Str ],
    files         => HashRef [ Dict [ language => Str, source => Str, mutants => ArrayRef [$MUTANT] ] ],
    testFiles     => HashRef [ Dict [ tests    => ArrayRef [ Dict [ id => Str, name => Str ] ] ] ],
    testMutation  => Dict [
        assessment        => Optional [Assessment],
        selection         => Optional [ReportSelection],
        measuredScope     => Optional [ReportSelection],
        catalogDigest     => Optional [Str],
        measurementDigest => Optional [ StrMatch [qr/\A[0-9a-f]{64}\z/] ],
        dependencyDigest  => Optional [ StrMatch [qr/\A[0-9a-f]{64}\z/] ],
        compilerInputs    => Optional [ HashRef [ StrMatch [qr/\A[0-9a-f]{64}\z/] ] ],
        shard             => Maybe [ StrMatch [qr{\A[1-9][0-9]*/[1-9][0-9]*\z}] ],
        inventory         => Maybe [ Dict [ mutants => Int, digest => StrMatch [qr/\A[0-9a-f]{64}\z/] ] ],
        jobs              => PositiveInt,
        parallelSafe      => $FLAG,
        interrupted       => Maybe [ Enum [ Test::Mutation::Exit::signals()->@* ] ],
        cacheMismatch     => Optional [$FLAG],
        reused            => Int,
        started           => Num,
        finished          => Num,
        warnings          => ArrayRef [Str],
        problems          => ArrayRef [ Dict [ path => Str, problem => Str ] ],
        baselineFailures  => ArrayRef [Str],
        tests             => ArrayRef [ Dict [ name => Str, duration => Num, neutral => Optional [$FLAG] ] ],
        stats             => Dict [ map { $_ => PositiveOrZeroInt } values %WORK_KEY ],

        compilerInputProtocol => Optional [PositiveInt],
    ],
];

# A mutant holds the name that the schema gives its status in the run, and the reason that the status calls for.
sub _consistent ($mutant) {
    my ( $status, $reason ) = $mutant->{testMutation}->@{qw(status reason)};
    return Test::Mutation::Status::of($status)->schema eq $mutant->{status}
      && Test::Mutation::Status::fits( $status, $reason );
}

signature_for document => (
    head    => [ InstanceOf ['Test::Mutation::Result'] ],
    named   => [ high => Num, low => Num ],
    returns => $DOCUMENT,
);

sub document ( $result, $arg ) {
    my %files;
    _each_file(
        $result,
        sub ( $path, $source, $entries ) {
            $files{$path} = { language => 'perl', source => $source, mutants => [ map { _mutant($_) } @$entries ] };
        }
    );
    return { _metadata( $result, $arg )->%*, files => \%files };
}

sub _each_file ( $result, $visit ) {
    my %entries;
    push $entries{ $_->{mutant}->path }->@*, $_ for $result->entries->@*;
    for my $path ( sort keys $result->sources->%* ) {
        $visit->( $path, $result->sources->{$path}, $entries{$path} || [] );
    }
    return;
}

sub _metadata ( $result, $arg ) {
    return {
        schemaVersion => '2',
        thresholds    => { high => int( $arg->high + 0.5 ), low => int( $arg->low + 0.5 ) },
        projectRoot   => $result->root,
        framework     => { name => 'Test::Mutation', version => $VERSION },
        testFiles     =>
          { map { $_->{name} => { tests => [ { id => $_->{name}, name => $_->{name} } ] } } $result->tests->@* },
        testMutation => _facts($result),
    };
}

sub _boolean ($value) {
    return $value ? JSON::PP::true : JSON::PP::false;
}

# The schema has no place for these facts, and a merge of several reports needs them.
sub _facts ($result) {
    my $inventory = $result->inventory;
    return {
        shard     => $result->shard,
        selection => $result->selection,
        defined $result->measured_scope ? ( measuredScope => $result->measured_scope ) : (),
        assessment => $result->assessment,
        defined $result->catalog_digest     ? ( catalogDigest     => $result->catalog_digest )     : (),
        defined $result->measurement_digest ? ( measurementDigest => $result->measurement_digest ) : (),
        defined $result->dependency_digest  ? ( dependencyDigest  => $result->dependency_digest )  : (),
        keys $result->compiler_inputs->%*   ? ( compilerInputs    => $result->compiler_inputs )    : (),
        inventory    => $inventory ? { mutants => 0 + $inventory->{mutants}, digest => $inventory->{digest} } : undef,
        jobs         => 0 + $result->jobs,
        parallelSafe => _boolean( $result->parallel_safe ),
        interrupted  => $result->interrupted,
        $result->cache_mismatch ? ( cacheMismatch => _boolean(1) ) : (),
        reused           => 0 + $result->reused,
        started          => 0 + $result->started,
        finished         => 0 + $result->finished,
        warnings         => [ $result->warnings->@* ],
        problems         => [ map { { path => $_->{path}, problem => $_->{problem} } } $result->problems->@* ],
        baselineFailures => [ map { $_->{test} } $result->baseline_failures->@* ],
        tests            => [
            map {
                { name => $_->{name}, duration => 0 + $_->{duration}, $_->{neutral} ? ( neutral => _boolean(1) ) : () }
            } $result->tests->@*
        ],
        stats => { map { $WORK_KEY{$_} => 0 + $result->stats->{$_} } keys %WORK_KEY },
        defined $result->compiler_input_protocol
        ? ( compilerInputProtocol => 0 + $result->compiler_input_protocol )
        : (),
    };
}

sub _mutant ($entry) {
    my $mutant = $entry->{mutant};
    my %mutant = (
        id             => $mutant->id,
        mutatorName    => $mutant->mutator,
        replacement    => $mutant->replacement,
        description    => $mutant->description,
        location       => { start => _position( $mutant->from ), end => _position( $mutant->to ) },
        status         => Test::Mutation::Status::of( $entry->{status} )->schema,
        coveredBy      => [ $entry->{covered_by}->@* ],
        testsCompleted => 0 + $entry->{tests_run},
        duration       => int( $entry->{duration} * $MILLISECONDS + 0.5 ),
        static         => JSON::PP::false,
        testMutation   => {
            status     => $entry->{status},
            reason     => $entry->{reason},
            scope      => [ map { 0 + $_ } $mutant->scope->@* ],
            suppressed => _boolean( $mutant->suppressed ),
            comparable => _boolean( $mutant->comparable ),
            defined $entry->{compiled_digest} ? ( compiledDigest => $entry->{compiled_digest} ) : (),
            exists $entry->{observations}     ? ( observations   => $entry->{observations} )    : (),
        },
    );
    $mutant{statusReason}               = $entry->{detail} if defined $entry->{detail};
    $mutant{killedBy}                   = [ $entry->{by} ] if $entry->{status} eq 'Killed' && defined $entry->{by};
    $mutant{testMutation}{decidingTest} = $entry->{by}     if $entry->{status} ne 'Killed' && defined $entry->{by};
    return \%mutant;
}

sub _position ($pair) {
    return { line => 0 + $pair->[0], column => 0 + $pair->[1] };
}

signature_for render => (
    head    => [ InstanceOf ['Test::Mutation::Result'] ],
    named   => [ high => Num, low => Num ],
    returns => Str,
);

sub render ( $result, $arg ) {
    my $document = document( $result, high => $arg->high, low => $arg->low );
    return JSON::PP->new->canonical->pretty->encode($document);
}

signature_for stream => (
    head    => [ InstanceOf ['Test::Mutation::Result'] ],
    named   => [ high => Num, low => Num, write => CodeRef ],
    returns => Undef,
);

sub stream ( $result, $arg ) {
    my $json  = Cpanel::JSON::XS->new->canonical->allow_nonref;
    my $write = $arg->write;
    $write->('{"files":{');
    my $separator = q{};
    _each_file(
        $result,
        sub ( $path, $source, $entries ) {
            $write->( $separator . $json->encode($path) . ':{"language":"perl","mutants":[' );
            my $comma = q{};
            for my $entry (@$entries) {
                $write->( $comma . $json->encode( _mutant($entry) ) );
                $comma = ',';
            }
            $write->( '],"source":' . $json->encode($source) . '}' );
            $separator = ",\n";
        }
    );
    $write->('}');
    my $meta = _metadata( $result, $arg );
    for my $name ( sort keys %$meta ) {
        $write->( ",\n" . $json->encode($name) . q{:} . $json->encode( $meta->{$name} ) );
    }
    $write->("}\n");
    return;
}

signature_for parse => ( positional => [Str], returns => InstanceOf ['Test::Mutation::Result'] );

sub parse ($text) {
    my $read = Test::Mutation::Try::attempt( sub { return [ Cpanel::JSON::XS->new->decode($text) ] } );
    Test::Mutation::Error::raise( 'report-malformed', reason => 'a JSON object repeats a field name' )
      if $read->{error} && $read->{error} =~ /\ADuplicate keys not allowed/;
    my ($document) = ( $read->{value} || [] )->@*;
    Test::Mutation::Error::raise('report-not-json')      if ref $document ne 'HASH';
    Test::Mutation::Error::raise('report-without-facts') if !exists $document->{testMutation};
    my $problem = $DOCUMENT->validate_explain( $document, '$report' );
    Test::Mutation::Error::raise( 'report-invalid-value', place => _place($problem) ) if $problem;
    my $made = Test::Mutation::Try::attempt( sub { _result($document) } );
    return $made->{value} if exists $made->{value};

    # A location outside its source has its own message, and every other fault is a value that fits no result.
    my $error = $made->{error};
    die $error if ( InstanceOf ['Test::Mutation::Error'] )->check($error);    ## no critic (ErrorHandling::RequireCarping)
    my ($reason) = split /\n/, "$error";
    return Test::Mutation::Error::raise( 'report-malformed', reason => $reason =~ s/ at \S+ line \d+[.]?\z//r );
}

# The explanation of the type library walks from the document down to the value that fails.
# A line names the place of a value, and a line about a key of a hash names the next step.
sub _place ($explanation) {
    my $place = q{$report};
    for my $line ( $explanation->@* ) {
        if    ( $line =~ /[(]in (.+)[)]\z/ ) { $place = $1 }
        elsif ( $line =~ /(?: constrains [ ] value [ ] at | requires ) [ ] key [ ] "([^"]+)"/x ) {
            $place .= qq{->{"$1"}};
        }
    }
    return $place;
}

sub _result ($document) {
    my $facts = $document->{testMutation};
    my ( %sources, @entries );
    my @tests;
    for my $observed ( $facts->{tests}->@* ) {
        my $test = { $observed->%{qw(name duration)} };
        $test->{neutral} = 1 if $observed->{neutral};
        push @tests, $test;
    }
    for my $path ( sort keys $document->{files}->%* ) {
        my $file = $document->{files}{$path};
        $sources{$path} = $file->{source};
        my $source = Test::Mutation::Source->new( path => $path, text => $file->{source}, encoding => 'UTF-8' );
        push @entries, map { _entry( $source, $_ ) } $file->{mutants}->@*;
    }
    return Test::Mutation::Result->new(
        root               => $document->{projectRoot},
        sources            => \%sources,
        tests              => \@tests,
        entries            => \@entries,
        problems           => $facts->{problems},
        warnings           => $facts->{warnings},
        baseline_failures  => [ map { { test => $_, output => q{}, errors => q{} } } $facts->{baselineFailures}->@* ],
        jobs               => $facts->{jobs},
        parallel_safe      => $facts->{parallelSafe} ? 1 : 0,
        interrupted        => $facts->{interrupted},
        cache_mismatch     => $facts->{cacheMismatch} ? 1 : 0,
        reused             => $facts->{reused},
        shard              => $facts->{shard},
        selection          => $facts->{selection} || {},
        measured_scope     => $facts->{measuredScope},
        min_score          => $facts->{assessment} ? $facts->{assessment}{minimum} : undef,
        catalog_digest     => $facts->{catalogDigest},
        measurement_digest => $facts->{measurementDigest},
        dependency_digest  => $facts->{dependencyDigest},
        compiler_inputs    => $facts->{compilerInputs} || {},
        inventory          => $facts->{inventory},
        started            => $facts->{started},
        finished           => $facts->{finished},
        stats              => { map { $_ => $facts->{stats}{ $WORK_KEY{$_} } } keys %WORK_KEY },

        compiler_input_protocol => $facts->{compilerInputProtocol},
    );
}

sub _offset ( $source, $position ) {
    return $source->offset_within_source( $position->@{qw(line column)} )
      // Test::Mutation::Error::raise( 'report-location-outside', path => $source->path );
}

sub _entry ( $source, $mutant ) {
    my ( $start, $end ) = map { _offset( $source, $mutant->{location}{$_} ) } qw(start end);
    Test::Mutation::Error::raise( 'report-location-reversed', path => $source->path ) if $end < $start;
    my ( $extra, $duration ) = $mutant->@{qw(testMutation duration)};
    return {
        mutant => Test::Mutation::Mutant->new(
            id          => $mutant->{id},
            path        => $source->path,
            mutator     => $mutant->{mutatorName},
            start       => $start,
            end         => $end,
            original    => substr( $source->text, $start, $end - $start ),
            replacement => $mutant->{replacement},
            description => $mutant->{description},
            from        => [ $mutant->{location}{start}->@{qw(line column)} ],
            to          => [ $mutant->{location}{end}->@{qw(line column)} ],
            scope       => $extra->{scope},
            suppressed  => $extra->{suppressed} ? 1 : 0,
            comparable  => $extra->{comparable} ? 1 : 0,
        ),
        status     => $extra->{status},
        reason     => $extra->{reason},
        detail     => $mutant->{statusReason},
        by         => $mutant->{killedBy} ? $mutant->{killedBy}[0] : $extra->{decidingTest},
        covered_by => $mutant->{coveredBy},
        tests_run  => $mutant->{testsCompleted},
        duration   => $duration / $MILLISECONDS,
        defined $extra->{compiledDigest} ? ( compiled_digest => $extra->{compiledDigest} ) : (),
        exists $extra->{observations}    ? ( observations    => $extra->{observations} )   : (),
    };
}

1;

__END__

=head1 NAME

Test::Mutation::Report::Json - render a result in the mutation testing report schema

=head1 SYNOPSIS

    my $text = Test::Mutation::Report::Json::render( $result, high => 80, low => 60 );

=head1 DESCRIPTION

The report follows version 2 of the C<mutation-testing-report-schema> that the Stryker projects publish.
Tools that read that schema, such as the C<mutation-testing-elements> viewer, can display it.

=head1 FUNCTIONS

=head2 document

Returns the report as a data structure.
Each test file appears as one test, because a run treats a test file as one unit.
The C<testMutation> key of the document and of each mutant holds the facts that the schema has no place for.
The schema allows such keys, and C<mutation merge> reads them.

The status of a mutant is the name that L<Test::Mutation::Status> gives it in the schema, so a viewer of the report computes the score of the run.
A timeout is C<Ignored>, and a mutant without a verdict is C<RuntimeError>.
The C<testMutation> key of the mutant holds its status in the run and the reason of that status, and C<statusReason> holds the sentence about the case.

=head2 render

Returns the report as JSON text with sorted keys.

=head2 stream

Writes each source file in path order through the C<write> callback.
Mutants are written as they are encoded, including when a single source has many mutants.
The callback receives character strings.

=head2 parse

    my $result = Test::Mutation::Report::Json::parse($text);

Rebuilds the L<Test::Mutation::Result> that a report describes.
The status and the reason of each mutant come from its C<testMutation> key, which has to agree with the name of the schema.
The spans and the original text of the mutants come from the sources in the report.
The rebuilt result includes every analyzed source and names the failing tests of the unmodified run.
The function dies when the text is no report that Test::Mutation wrote.

=cut
