use v5.36;
use Test2::V0;
use List::Util qw(min sum0);
use lib 't/lib';
use Gate;
use Matrix;
use Oracle;
use Snippets;
use Test::Mutation::Host;

# Generated snippets put every operator of PPI between operands of every shape, in every context that runs code.
# The list has no random part, and perl decides which snippets are code at all.
# Each snippet goes through the oracles, and its expression must have the mutants that its context permits.

subtest 'the pairs reject a tuple list that leaves a pair out' => sub {
    my @sizes  = ( 5, 3, 4, 2 );
    my @tuples = Snippets::pairwise(@sizes);
    my %pair;
    for my $tuple (@tuples) {
        for my $one ( 0 .. $#sizes ) {
            $pair{"$one=$tuple->[$one] $_=$tuple->[$_]"} = 1 for $one + 1 .. $#sizes;
        }
    }
    my $wanted = 5 * 3 + 5 * 4 + 5 * 2 + 3 * 4 + 3 * 2 + 4 * 2;
    is scalar( keys %pair ), $wanted, 'every value of an axis meets every value of every other axis';
    ok @tuples >= 20 && @tuples <= 30, 'in about as many tuples as the two largest axes need (' . @tuples . ')';
    is [ Snippets::pairwise(@sizes) ], \@tuples, 'the list is the same in every run';
    is scalar(
        grep {
            $_->@* != 4
              || grep { !defined }
              $_->@*
        } @tuples
      ),
      0, 'every tuple names a value of every axis';
    is scalar( Snippets::product(@sizes) ), 5 * 3 * 4 * 2, 'the product holds every tuple';
};

subtest 'the generator takes its operators from the table of PPI' => sub {
    my %operator = map { $_ => 1 } Snippets::operators();
    ok $operator{$_},    "the binary operator $_" for qw(+ ** <=> cmp x .. && // and xor |. **= //= ^.=);
    ok !$operator{$_},   "no binary operator $_"  for qw(-> ++ ! ~ ? : => <> not), q{,};
    ok !$operator{'~~'}, 'no smartmatch, which perl 5.42 removed';
    is [ grep { !$PPI::Singletons::OPERATOR{$_} } keys %operator ], [], 'and no operator from elsewhere';
};

subtest 'a snippet file places each expression and the text of its here-document' => sub {
    my %context = map { $_->{name} => $_ } Snippets::contexts();
    my %operand = map { $_->{name} => $_ } Snippets::operands();
    my $plain   = Snippets::expression( q{+}, @operand{ 'variable',      'literal' } );
    my $heredoc = Snippets::expression( q{.}, @operand{ 'here-document', 'call' } );
    is $plain->{text},   '$x + 2',           'an operator between two operands';
    is $heredoc->{text}, q{<<'EOT' . f($y)}, 'an operand that is a here-document';

    my $file = Snippets::file( $context{'return'}, $plain, $heredoc );
    is $file->{text}, <<'CODE', 'one package for each expression, and the text of a here-document after its line';
use v5.36;
no warnings;
package Snippet::N0;
our ( $x, $y, $r );
BEGIN { ( $x, $y, $r ) = ( 3, 4, { k => 5, list => [ 1, 2 ] } ) }
sub f { return $_[0] }
sub c { return $x + 2 }
package Snippet::N1;
our ( $x, $y, $r );
BEGIN { ( $x, $y, $r ) = ( 3, 4, { k => 5, list => [ 1, 2 ] } ) }
sub f { return $_[0] }
sub c { return <<'EOT' . f($y) }
7
EOT
1;
CODE
    is [ map { substr $file->{text}, $_->[0], $_->[1] - $_->[0] } $file->{spans}->@* ],
      [ '$x + 2', q{<<'EOT' . f($y)} ], 'each span addresses its expression';

    my $source  = Oracle::text_source( 'lib/Snippet.pm', $file->{text} );
    my $changes = Oracle::candidates( $source, Oracle::generated($source) );
    is [ Snippets::inside( $changes, $file->{spans}[0] ) ], [ '3 + -> - arithmetic', '5 2 -> 3 number-literal' ],
      'the changes inside an expression, by their place in it';
    is [ Snippets::inside( $changes, [ 0, 5 ] ) ], [], 'and none outside it';
};

subtest 'the context check rejects a context that changes the mutants of an expression' => sub {
    my %context = map { $_->{name} => $_ } Snippets::contexts();
    my %operand = map { $_->{name} => $_ } Snippets::operands();
    my $sum     = Snippets::expression( q{+}, @operand{ 'variable', 'literal' } );
    is Snippets::lost( $context{'assignment'},      $sum ), [], 'the reference context loses nothing';
    is Snippets::lost( $context{'return'},          $sum ), [], 'and neither does a return value';
    is Snippets::lost( $context{'final statement'}, $sum ), [],
      'a context whose changes the generator refuses with a rule accounts for each of them';

    # The lists of a context that loses and adds a change are written by hand, as no context of the tool has to do it.
    my @reference = ( '3 + -> - arithmetic', '5 2 -> 3 number-literal' );
    is Snippets::difference( ['3 + -> - arithmetic'], \@reference ), ['- 5 2 -> 3 number-literal'],
      'a context without one change of the reference loses it';
    is Snippets::difference( [ @reference, '1  $x  -> 1 condition-fixed' ], \@reference ),
      ['+ 1  $x  -> 1 condition-fixed'], 'and a context with a change of its own adds it';
    is Snippets::difference( [], \@reference ), [ '- 3 + -> - arithmetic', '- 5 2 -> 3 number-literal' ],
      'a context that the analysis never reads loses every change';
};

subtest 'the context check expects an endpoint change only in a known scalar context' => sub {
    my %context = map { $_->{name} => $_ } Snippets::contexts();
    my %operand = map { $_->{name} => $_ } Snippets::operands();
    my $range   = Snippets::expression( '...', @operand{qw(variable literal)} );
    for my $name ( qw(assignment modifier argument return), 'compound condition' ) {
        is Snippets::lost( $context{$name}, $range ), [], "the $name context produces the specified changes";
    }
    my $endpoint = '3 ... -> .. range-boundary';
    my $literal  = '7 2 -> 3 number-literal';
    is Snippets::lost( $context{modifier}, $range, [$literal] ), ["- $endpoint"],
      'losing the flip-flop in a scalar condition fails';
    is Snippets::lost( $context{argument}, $range, [ $literal, $endpoint ] ), ["+ $endpoint"],
      'changing a range between equivalent list operators fails';
    is Snippets::lost( $context{assignment}, $range, [$endpoint] ), ["- $literal"],
      'the scalar exception cannot hide another mutator losing the end operand';
};

subtest 'the matrix rejects a context that cuts the expression' => sub {
    my ($return) = grep { $_->{name} eq 'return' } Snippets::contexts();
    is Matrix::context()->{code}, 'sub c { return ( EXPR ) }', 'the expression stands inside parentheses';
    ok Matrix::keeps_whole( Matrix::context() ), 'and the value of the subroutine holds both operands of `or`';
    is Gate::outcomes( sub { ok Matrix::keeps_whole($return), 'the context keeps the whole expression' } ), ['fail'],
      'a bare return takes the left operand of `or` alone, and the check fails';
};

subtest 'the matrix rejects a mutant that no input tells from the original' => sub {
    my $return  = Matrix::context();
    my $file    = Snippets::file( $return, { text => '$x + 0 > $y', body => q{} } );
    my $source  = Oracle::text_source( 'lib/Snippet.pm', $file->{text} );
    my @mutants = (
        Oracle::by_hand( $source, '+ 0',  '- 0' ),
        Oracle::by_hand( $source, '> $y', '>= $y' ),
        Oracle::by_hand( $source, '+ 0',  '+' ),
    );
    my $replaced = sub ($rows) {
        my $result = Matrix::inseparable( $source, \@mutants, $rows );
        return [
            map {
                [ map { $_->replacement } $_->@* ]
            } $result->@{qw(executed equal)}
        ];
    };
    is $replaced->( [ Matrix::rows() ] ), [ [ '- 0', '>= $y' ], ['- 0'] ],
      'a change that keeps every value is refused, the boundary of a comparison is accepted, and code that perl refuses never runs';
    is $replaced->( [ grep { $_->[0] != $_->[1] } Matrix::rows( -2, 1, 3 ) ] ),
      [ [ '- 0', '>= $y' ], [ '- 0', '>= $y' ] ],
      'a matrix without an equal pair has no input that tells the boundary apart';
    is Matrix::observed( [ $file->{text} =~ s/return/retrun/r ], [ Matrix::rows() ] ), [undef],
      'a text that perl refuses has nothing to observe';

    # Each change differs from its original only where a variable holds the value of a literal operand, or its text.
    my @boundaries = (
        [ { text => '$r->{k} < 2',          body => q{} },        '< 2',   '<= 2' ],
        [ { text => q{$x ge <<'EOT'},       body => "7\nEOT\n" }, 'ge <<', 'gt <<' ],
        [ { text => '7 .. $y',              body => q{} },        '.. $y', '.. -1 + $y' ],
        [ { text => '7 <= $r->{list}->$#*', body => q{} },        '<= $r', '< $r' ],
        [ { text => '$r->{k} <= 2',         body => q{} },        '<= 2',  '<= 3' ],
        [ { text => '$x // 2',              body => q{} },        '// 2',  '// 3' ],
    );
    for my $case (@boundaries) {
        my ( $expression, $original, $replacement ) = $case->@*;
        my $unit   = Oracle::text_source( 'lib/Snippet.pm', Snippets::file( $return, $expression )->{text} );
        my $rows   = Matrix::rows_for( $expression->{text}, [ Matrix::rows() ] );
        my $result = Matrix::inseparable( $unit, [ Oracle::by_hand( $unit, $original, $replacement ) ], $rows );
        is [ scalar $result->{executed}->@*, scalar $result->{equal}->@* ], [ 1, 0 ],
          "a row tells $expression->{text} from the change of $original to $replacement";
    }
    my @all = Matrix::rows();
    is [ map { scalar Matrix::rows_for( $_, \@all )->@* } '7 + 2', '$x + 2', '$r->{k} - ( $y )' ], [ 1, 11, 99 ],
      'an expression runs once for each difference in the variables that it names';

    my @records = Matrix::judged_records( $source, \@mutants, [ Matrix::rows() ], 'by hand' );
    is [ grep { $_->[0] eq 'expression' } @records ], [ [ 'expression', 'run' ] ], 'perl runs the original';
    my $summary = Oracle::summary( [ map { [ 'lib/Snippet.pm', $_->@* ] } grep { $_->[0] ne 'expression' } @records ] );
    is [ map { /\Ac2: (.*?), in / ? $1 : () } Oracle::lines($summary) ],
      ['by-hand has no input of the matrix that tells it from the original'],
      'the output names each change that no row separates';

    # The rate of a mutator decides a finding, and the varied columns count the mutants that the rows reach.
    my $tally = Oracle::tally();
    Oracle::count( $tally, 'comparison-negation', 'varied',      50 );
    Oracle::count( $tally, 'comparison-negation', 'unseparated', 2 );
    Oracle::count( $tally, 'arithmetic',          'varied',      50 );
    Oracle::count( $tally, 'arithmetic',          'unseparated', 1 );
    Oracle::count( $tally, 'number-literal',      'varied',      50 );
    Oracle::count( $tally, 'number-literal',      'unseparated', 25 );
    is Matrix::over_bound($tally),
      ['comparison-negation has no input of the matrix that tells it from the original (2 of 50, limit 2%)'],
      'a mutator of the default profile above 2 percent is a finding, and one of the extended profile has no bound';
    is Gate::outcomes( sub { Gate::findings( 'mutants-c2-rejected', Matrix::over_bound($tally) ) } ),
      ['fail'], 'and a finding fails the gate';
    my ($varied) = Matrix::expressions( [ 0, 0, 2 ] );
    my ($fixed)  = Matrix::expressions( [ 0, 0, 1 ] );
    is [ $varied->{varied}, $fixed->{varied} ], [ 1, 0 ], 'a literal operand takes an expression out of the rate';
};

# Perl compiles each snippet alone first, so a combination that is no code leaves the list.
my @snippets = Snippets::chosen( Snippets::pairwise( Snippets::sizes() ) );
my $workers  = min( 8, Test::Mutation::Host::processors()->{count} );
my $summary  = Snippets::surveyed( \@snippets, $workers );

note $_ for Oracle::table( $summary->{tally}, Oracle::columns() ), Oracle::lines($summary), Oracle::rules($summary);
note "$_: $summary->{snippets}{$_}" for sort keys $summary->{snippets}->%*;
is $summary->{problems}, {}, 'the tool analyzes every snippet that perl compiles';
Gate::findings( "mutants-$_-generated", Oracle::found( $summary, $_ ) ) for qw(a b b2 b3 d e context refusal);
my $total = Oracle::total( $summary->{tally} );
Gate::checked( 'snippets',                            scalar @snippets,               at_least => 800 );
Gate::checked( 'snippets that perl compiles',         $summary->{snippets}{compiled}, at_least => 600 );
Gate::checked( 'mutants',                             $total->{mutants},              at_least => 3000 );
Gate::checked( 'mutants that perl judged',            $total->{judged},               at_least => 2000 );
Gate::checked( 'verdicts that a cold perl confirmed', $summary->{crossed},            at_least => 140 );
Gate::checked(
    'changes that the tool refused',
    sum0( map { values $_->%* } values $summary->{refusals}->%* ),
    at_least => 1400
);
Gate::checked( 'refused changes that perl judged', $total->{asked}, at_least => 15 );

# Each expression runs as the value of a subroutine over the matrix, with every operator beside every operand shape.
my @expressions = Matrix::expressions( Snippets::pairwise( ( Snippets::sizes() )[ 0 .. 2 ] ) );
my $matrix      = Matrix::surveyed( \@expressions, $workers, [ Matrix::rows() ] );
note $_
  for Oracle::table( $matrix->{tally}, 'executed', 'inseparable:executed', 'varied', 'unseparated:varied' ),
  Oracle::lines($matrix);
note "$_: $matrix->{expressions}{$_}" for sort keys $matrix->{expressions}->%*;
is $matrix->{problems}, {}, 'the tool analyzes every expression';
Gate::findings( 'mutants-c2-generated', Matrix::over_bound( $matrix->{tally} ) );
my $ran = Oracle::total( $matrix->{tally} );
Gate::checked( 'expressions',                                       scalar @expressions,           at_least => 400 );
Gate::checked( 'expressions that perl runs',                        $matrix->{expressions}{run},   at_least => 300 );
Gate::checked( 'mutants that ran over the matrix',                  $ran->{executed},              at_least => 400 );
Gate::checked( 'mutants of expressions with two variable operands', $ran->{varied},                at_least => 200 );
Gate::checked( 'rows of the matrix',                                scalar( () = Matrix::rows() ), at_least => 100 );

done_testing;
