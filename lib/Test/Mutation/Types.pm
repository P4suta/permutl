package Test::Mutation::Types;
use v5.36;
use Type::Library -base,
  -declare =>
  qw(Analysis Assessment Directive Dropped Entry Facts Heredoc Names Observations PathSelection ReportSelection Reason Refusal Rejected StatusName Suppression TaskRecord TestObservation);
use Type::Utils     qw(as declare where);
use Types::Standard qw(ArrayRef Bool Dict Enum HashRef InstanceOf Int Maybe Num Optional Str StrMatch Tuple);
use Test::Mutation::Status;

our $VERSION = '0.001';

declare PathSelection, as HashRef [ ArrayRef [ Tuple [ Int, Int ] ] ];

declare ReportSelection,
  as Dict [
    paths      => Optional [PathSelection],
    since      => Optional [Str],
    mutants    => Optional [ ArrayRef [Str] ],
    undetected => Optional [Bool]
  ];

declare Assessment,
  as Dict [
    counts   => HashRef [Int],
    total    => Int,
    valid    => Int,
    score    => Maybe [Num],
    minimum  => Maybe [Num],
    outcome  => Str,
    gate     => Maybe [Str],
    exitCode => Int
  ];

declare StatusName, as Enum [ Test::Mutation::Status::names()->@* ];

declare Reason, as Enum [ map { $_->reasons->@* } Test::Mutation::Status::rows()->@* ];
declare TaskRecord,
  as Dict [
    begun       => Int,
    ended       => Int,
    served      => HashRef [ Dict [ traced => Bool, hits => HashRef [Bool] ] ],
    compiled    => HashRef [Bool],
    load_failed => HashRef [Bool],
    unresolved  => Optional [ HashRef [Bool] ],
    includes    => Optional [ ArrayRef [Str] ],
    bypassed    => HashRef [Bool],
    outside     => HashRef [Bool],
    breakable   => HashRef [ HashRef [Bool] ],
    errors      => ArrayRef [Str],
  ];

declare TestObservation,
  as Dict [
    test         => Str,
    result       => Enum [qw(pass fail timeout overflow)],
    served       => Bool,
    load_failed  => Bool,
    bypassed     => Bool,
    anomaly      => Optional [ Maybe [ Dict [ reason => Reason, detail => Str ] ] ],
    invalid_call => Optional [ Maybe [Str] ],
    read_check   => Optional [ Enum [qw(pass fail timeout overflow compile-error)] ],
    syntax       => Maybe [ Enum [ 'ok', Test::Mutation::Status::of('CompileError')->reasons->@* ] ],
  ];

declare Observations, as ArrayRef [ ArrayRef [TestObservation], 0, 2 ];

declare Entry,
  as Dict [
    mutant          => InstanceOf ['Test::Mutation::Mutant'],
    status          => StatusName,
    reason          => Maybe [Reason],
    detail          => Maybe [Str],
    by              => Maybe [Str],
    covered_by      => ArrayRef [Str],
    tests_run       => Int,
    duration        => Num,
    compiled_digest => Optional [ StrMatch [qr/\A[0-9a-f]{64}\z/] ],
    observations    => Optional [Observations],
  ],
  where { Test::Mutation::Status::fits( $_->{status}, $_->{reason} ) };

declare Facts,
  as Dict [
    right         => Optional [Num],
    version       => Optional [Num],
    settled       => Optional [Bool],
    flip_flop     => Optional [Bool],
    implicit_call => Optional [Bool],
    quantified    => Optional [Bool],
    local_calls   => Optional [ ArrayRef [Str] ],
    call_offset   => Optional [Int],
    operand       => Optional [ Enum [qw(match substitute transliterate dynamic)] ],
    keyword       => Optional [Str],
    head          => Optional [Str],
    name          => Optional [Str],
    literal       => Optional [Str],
    declares      => Optional [Bool],
    final_value   => Optional [Bool],
    branches      => Optional [ Tuple [ Int, Int ] ],
    operands      => Optional [ Tuple [ Int, Int ] ],
    has_argument  => Optional [Bool],
    loose         => Optional [Bool],
    anchors       => Optional [ ArrayRef [ Tuple [ Int, Int ] ] ],
  ];

declare Dropped, as Dict [ line => Int, kind => Enum [qw(span regex conditional)], reason => Str ];

declare Directive,
  as Dict [
    line   => Int,
    text   => Str,
    first  => Int,
    last   => Maybe [Int],
    names  => Maybe [ ArrayRef [Str] ],
    reason => Maybe [Str],
  ];

declare Refusal, as Dict [ line => Int, id => StrMatch [qr/\Asuppression-[a-z-]+\z/], text => Str ];

declare Suppression, as Dict [ directives => ArrayRef [Directive], refusals => ArrayRef [Refusal] ];

declare Heredoc, as Tuple [ Int, Int, Int, Int ];

declare Names,
  as Dict [
    imports  => ArrayRef [ Dict [ module => Str, names => ArrayRef [Str] ] ],
    declared => ArrayRef [Str],
  ];

declare Rejected,
  as Dict [
    mutator => Str,
    line    => Int,
    rule    => Enum [qw(same-text line-count here-document declaration final-value unresolved-call same-result)],
  ];

declare Analysis,
  as Dict [
    sites        => ArrayRef [ InstanceOf ['Test::Mutation::Site'] ],
    suppressions => Suppression,
    dropped      => ArrayRef [Dropped],
    heredocs     => ArrayRef [Heredoc],
    names        => Names,
    problem      => Maybe [Str],
  ];

1;

__END__

=head1 NAME

Test::Mutation::Types - the types that the analysis and its readers share

=head1 SYNOPSIS

    use Type::Params          qw(signature_for);
    use Test::Mutation::Types qw(Analysis);

    signature_for count => ( positional => [Analysis] );

    sub count ($analysis) { return scalar $analysis->{sites}->@* }

=head1 DESCRIPTION

The analysis of a source file and the generator of mutants agree on one shape of the result.
A type that two modules name lives here, so a change of the shape reaches both.

C<TaskRecord> holds process starts and endings, target observations, and diagnostics for one test invocation.

C<Facts> holds what the analysis learned about a site beyond its text: the number on the right of an operator,
the version in a comparison with C<$]>, the kind of the operand of a match, the keyword of a condition,
the first word of a statement, the name of a subroutine, and the literal of a return.

C<declares> marks a span with a declaration that later code names.
C<final_value> marks a standalone literal value or the expression that computes a module's return value.
C<implicit_call> marks a comparison after a function that uses its default argument.
C<has_argument> identifies a call whose argument can stand alone after the function name is removed.
C<operands> holds the offsets of the end of the left operand and the start of the right operand in a three-way comparison.
C<call_offset> is the insertion point for checking a replacement function in the lexical scope of its call.
C<local_calls> lists the subroutines that the package of a local call defines and that the call can name.
C<quantified> indicates that a regular expression quantifier applies to the anchor.
C<branches> holds the length of the first branch of a conditional and the place where its second branch starts, both counted from the start of the span.
C<loose> marks a first branch that holds an operator looser than the conditional, as an assignment, which needs parentheses in the place of the second branch.
C<anchors> holds the places of the tokens that name the construct of a span wider than a token, such as the question mark and the colon of a conditional or the keyword of a condition.

C<Dropped> names a place that the analysis left out, with its line, its kind, and the reason.
A conditional operator without its colon or its second branch is such a place.

C<Directive> is a C<## no mutate> comment that the grammar accepts: its line and its text, the range of lines that it covers, the mutators it names, and its reason.
A block that the file leaves open has no last line.
C<Refusal> is a comment that the run refuses, with its line, the identifier of its message, and the text.
C<Suppression> holds what L<Test::Mutation::Suppression> reads from the comments of a file: the directives and the refusals of the grammar.

C<Heredoc> holds four offsets of a here-document: the start and the end of its introducer, and the start and the end of its text with the line that ends it.

C<Names> holds the subroutine names that the file resolves: each C<use> statement with its module and the names it imports, and the names the file declares.
The statements stay apart because each one imports into the scope where it stands.

C<Rejected> names a change that the generator refused, with the mutator, the line, and the rule.

C<Analysis> is the result for one file: the sites, the suppressions, the places left out, the here-documents, the names, and the problem that kept the whole file from the analysis.

C<StatusName> is the name of a status of L<Test::Mutation::Status>, and C<Reason> is a reason that some status may carry.
C<TestObservation> describes one test outcome and the evidence that the test loaded its target.
C<Observations> keeps the outcomes in execution order and groups them by the first attempt and its confirmation.
C<Entry> is the result of one mutant: the mutant, its status, the reason that its status calls for, a sentence about the case, the deciding test, the selected tests, the number of tests that ran, and the time they took.
The verdict, the result, the reports, and the cache share these types, so a status outside the catalog or a reason of another status fails at the first of them.

C<PathSelection> maps each selected source path to its inclusive line ranges.
An empty list of ranges selects the whole file.
C<ReportSelection> records the path ranges, Git revision and mutant identifiers requested for a measurement.

=cut
