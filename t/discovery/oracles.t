use v5.36;
use Test2::V0;
use File::Temp ();
use lib 't/lib';
use Gate;
use Oracle;
use Test::Mutation::Mutant;
use Test::Mutation::Mutator;

# Every oracle of the mutant quality harness must refuse the defect it exists for.
# Each case below feeds one oracle a mutant or a mutator that is broken in one known way.

my $CODE = <<'CODE';
package Sample;
use strict;
use warnings;
use List::Util qw(max);

sub largest {
    my @numbers = @_;
    return max(@numbers) + 1;
}

sub twice {
    my ($n) = @_;
    return !!$n * 2;
}

1;
CODE
my $source  = Oracle::text_source( 'lib/Sample.pm', $CODE );
my $checked = 0;

sub mutator ( $name, $generate ) {
    return Test::Mutation::Mutator->new(
        name        => $name,
        profile     => 'default',
        description => 'a mutator that is broken on purpose',
        generate    => $generate,
    );
}

# A mutant that replaces the first occurrence of a text, built by hand as no mutator of the tool would build it.
sub mutant ( $original, $replacement, %override ) {
    my $start = index $CODE, $original;
    my %span  = ( start => $start, end => $start + length $original, %override );
    return Test::Mutation::Mutant->new(
        id          => sprintf( '%012x', ++$checked ),
        path        => 'lib/Sample.pm',
        mutator     => 'by-hand',
        original    => $original,
        replacement => $replacement,
        description => "replaced $original with $replacement",
        from        => $source->position_of( $span{start} ),
        to          => $source->position_of( $span{end} ),
        scope       => [ 1, 1 ],
        %span,
    );
}

sub classes (@violations) {
    return [ map { $_->[0]->mutator . q{ } . $_->[1] } @violations ];
}

subtest 'the identity oracle rejects a mutant that returns the original text' => sub {
    is classes( Oracle::unchanged( $source, [ mutant( '+', '-' ) ] ) ), [], 'a change is accepted';
    is classes( Oracle::unchanged( $source, [ mutant( '+', '+' ) ] ) ), ['by-hand leaves the text as it was'],
      'the same text is refused';
};

subtest 'the span oracle rejects a site with a shifted span' => sub {
    is classes( Oracle::misplaced( $source, [ mutant( 'max', 'min' ) ] ) ), [], 'a span on its own text is accepted';
    my $at      = index $CODE, 'max(@numbers)';
    my $shifted = mutant( 'max', 'min', start => $at + 1, end => $at + 4 );
    is classes( Oracle::misplaced( $source, [$shifted] ) ), ['by-hand names a span that holds another text'],
      'a span one character to the right is refused';
    my $beyond = mutant( 'max', 'min', start => length($CODE) - 1, end => length($CODE) + 2 );
    is classes( Oracle::misplaced( $source, [$beyond] ) ), ['by-hand names a span that holds another text'],
      'a span beyond the end of the file is refused';
    my $elsewhere = mutant( 'max', 'min', from => [ 1, 1 ] );
    is classes( Oracle::misplaced( $source, [$elsewhere] ) ), ['by-hand names a position apart from its span'],
      'a line and column apart from the offset are refused';
};

subtest 'the patch oracle rejects a patch that does not give the mutant' => sub {
    my $patch = "--- a\n+++ a\n\@\@ -2,3 +2,3 \@\@\n b\n-c\n+C\n d\n";
    is Oracle::patched( "a\nb\nc\nd\ne\n", $patch ), "a\nb\nC\nd\ne\n",      'a hunk replaces its lines';
    is Oracle::patched( "a\nb\nx\nd\ne\n", $patch ), undef,                  'a removed line that the text lacks';
    is Oracle::patched( "a\nB\nc\nd\ne\n", $patch ), undef,                  'a context line that the text lacks';
    is Oracle::patched( "a\nb\nc\n",       $patch ), undef,                  'a hunk beyond the end of the text';
    is Oracle::patched( "a\nb\nc\nd\ne\n", $patch =~ s/-2,3/-2,4/r ), undef, 'a count that the hunk does not hold';
    is Oracle::patched( "a\nb\nc\nd\ne\n", "--- a\n+++ a\n" ),        undef, 'a patch without a hunk';
    is Oracle::patched( "a\nb\nc\nd",      "--- a\n+++ a\n\@\@ -3,2 +3,2 \@\@\n c\n-d\n+D\n" ), "a\nb\nc\nD\n",
      'a patch has no way to leave the last line without its line break';

    is classes( Oracle::unpatchable( $source, [ mutant( 'max(@numbers)', 'min(@numbers)' ) ] ) ), [],
      'the patch of a mutant gives the text of the mutant';
    is classes( Oracle::unpatchable( $source, [ mutant( "return max(\@numbers) + 1;\n}\n", "\n\n" ) ] ) ), [],
      'so does the patch of a mutant over three lines';
    my $open = Oracle::text_source( 'lib/Open.pm', "my \$n = 1 + 2;\nmy \$m = \$n - 1" );
    my ($last) = grep { $_->original eq q{-} } Oracle::generated($open)->{mutants}->@*;
    is classes( Oracle::unpatchable( $open, [$last] ) ), ['arithmetic renders a patch that gives another text'],
      'the patch of a last line without a line break is refused';
};

subtest 'the uniqueness oracle rejects two mutants with one id' => sub {
    my @pair = ( mutant( '+', '-' ), mutant( '*', '/' ) );
    is classes( Oracle::repeated( $source, \@pair ) ), [], 'two changes with two ids are accepted';
    my $twin = Test::Mutation::Mutant->new(
        ( map { $_ => $pair[1]->$_ } qw(path mutator start end original) ),
        ( map { $_ => $pair[1]->$_ } qw(replacement description from to scope) ),
        id => $pair[0]->id
    );
    is classes( Oracle::repeated( $source, [ $pair[0], $twin ] ) ), ['by-hand repeats an id'],
      'one id twice is refused';

    my $first = index $CODE, '!!';
    my @bangs = map { mutant( q{!}, q{}, start => $first + $_, end => $first + $_ + 1 ) } 0, 1;
    is classes( Oracle::repeated( $source, \@bangs ) ), ['by-hand gives the same text as a mutant of by-hand'],
      'two spans that give one text are refused';
    my $wider = mutant( '!!$n', '!$n' );
    is classes( Oracle::repeated( $source, [ $bangs[1], $wider ] ) ),
      ['by-hand gives the same text as a mutant of by-hand'], 'and so is a wider span with the same result';
    is classes( Oracle::repeated( $source, [ $bangs[0], mutant( '*', '/' ) ] ) ), [], 'another result is accepted';
};

subtest 'the key of a change rejects no pair that the whole texts tell apart' => sub {
    my $text  = "aab aab\nabab\n\nxx";
    my $small = Oracle::text_source( 'lib/Small.pm', $text );
    my @edits;
    for my $start ( 0 .. length $text ) {
        for my $end ( $start .. length $text ) {
            push @edits, map { [ $start, $end, $_ ] } q{}, 'a', 'b', 'ab', 'ba', "\n", 'xa';
        }
    }
    my ( %by_key, %by_text );
    for my $edit (@edits) {
        my ( $start, $end, $replacement ) = $edit->@*;
        push $by_key{ Oracle::change_key( $text, $start, $end, $replacement ) }->@*, "$start $end $replacement";
        push $by_text{ $small->replace_span( $start, $end, $replacement ) }->@*,     "$start $end $replacement";
    }
    my $classes = sub ($groups) {
        return [ sort map { join q{|}, $_->@* } values $groups->%* ];
    };
    is $classes->( \%by_key ), $classes->( \%by_text ), 'the key groups the changes exactly as their results do';
    $checked += @edits;
};

subtest 'the compile oracle rejects a mutator that emits a closing brace' => sub {
    my $brace = mutator(
        'brace',
        sub ($site) {
            return if $site->kind ne 'operator' || $site->text ne q{+};
            return { replacement => '}', description => 'replaced + with }' };
        }
    );
    my $unit      = Oracle::text_source( 'lib/Sample.pm', "package Sample;\nuse strict;\nsub total { 2 + 1 }\n1;\n" );
    my $judgement = Oracle::judgement( $unit, Oracle::generated( $unit, [$brace] )->{mutants}, wants => ['calls'] );
    is $judgement->{problem}, undef, 'perl accepts the original';
    is classes( Oracle::refused( $unit, $judgement ) ), ['brace yields code that perl refuses'],
      'the mutant with one brace too many is refused';
    is classes( Oracle::unresolved( $unit, $judgement ) ), [], 'and a refused mutant calls nothing';
    $checked += $judgement->{verdicts}->@*;
};

subtest 'the call oracle rejects a mutator that swaps to an unimported name' => sub {
    my $swap = mutator(
        'swap',
        sub ($site) {
            return if $site->kind ne 'word' || $site->text ne 'max';
            return { replacement => 'min', description => 'replaced max with min' };
        }
    );
    my $mutants   = Oracle::generated( $source, [$swap] )->{mutants};
    my $judgement = Oracle::judgement( $source, $mutants, wants => ['calls'] );
    is [ map { $_->original } $mutants->@* ], ['max'],        'the import list holds no site, and the call holds one';
    is classes( Oracle::refused( $source, $judgement ) ), [], 'perl compiles the call of the unknown name';
    is classes( Oracle::unresolved( $source, $judgement ) ), ['swap introduces an unresolved call'],
      'and the walker finds no subroutine behind it';
    is $judgement->{verdicts}[0]{introduced}, ['Sample::min'], 'the verdict names the call';
    $checked += $judgement->{verdicts}->@*;
};

subtest 'the compile oracle rejects a file that perl refuses as it stands' => sub {
    my $broken    = Oracle::text_source( 'lib/Broken.pm', "use strict;\nsub f { return \$missing + 1 }\n1;\n" );
    my $judgement = Oracle::judgement( $broken, Oracle::generated($broken)->{mutants}, wants => ['calls'] );
    is $judgement->{problem},  'perl refuses the original', 'the file has no verdict';
    is $judgement->{verdicts}, [],                          'and neither has a mutant';
};

subtest 'the causes reject a here-document without its introducer and a variable without its declaration' => sub {
    my $text = <<'CODE';
use strict;
sub banner {
    return <<'EOT';
hello (
EOT
}
sub size {
    if ( my $n = shift ) { return $n }
    return 0;
}
1;
CODE
    my $unit = Oracle::text_source( 'lib/Banner.pm', $text );

    # The test builds each broken mutant itself, as the tool refuses to make them.
    my @broken = (
        Oracle::by_hand( $unit, q{<<'EOT'},      q{} ),
        Oracle::by_hand( $unit, 'my $n = shift', '1' ),
        Oracle::by_hand( $unit, 'return $n',     'return' ),
        Oracle::by_hand( $unit, 'return 0',      'return 1' ),
    );
    my $judgement = Oracle::judgement( $unit, \@broken, wants => ['calls'] );
    is classes( Oracle::refused( $unit, $judgement ) ),
      [ 'by-hand removes a here-document introducer', 'by-hand leaves a variable without its declaration' ],
      'each refused mutant names its cause, and the sound ones name nothing';
    is classes( Oracle::apart( $unit, $judgement ) ), [], 'and no mutant of the unit counts apart';

    my $made = Oracle::generated($unit);
    my $real = Oracle::judgement( $unit, $made->{mutants}, wants => ['calls'] );
    is classes( Oracle::refused( $unit, $real ) ), [], 'perl compiles every mutant that the tool makes of the unit';
    my %rule = map { $_->{rule} => 1 } $made->{rejected}->@*;
    is [ grep { !$rule{$_} } qw(declaration final-value here-document) ], [],
      'and the tool refuses the changes of the same places itself, each under its rule';
    $checked += @broken + $made->{mutants}->@*;
};

subtest 'the oracles reject no mutant that behaves as one: code of the compilation, and a branch that perl left out' =>
  sub {
    my $text = <<'CODE';
use strict;
use constant DEBUG => 0;
BEGIN { defined &TRACE or eval 'sub TRACE () { 0 }' }
BEGIN { die "no trace\n" if TRACE == 1 }
sub level { return TRACE ? 1 : 2 }
sub tool { if (DEBUG) { return missing_tool() } return 3 }
1;
CODE
    my $unit    = Oracle::text_source( 'lib/Phase.pm', $text );
    my $changes = mutator(
        'change',
        sub ($site) {
            return { replacement => q{},   description => 'removed the statement' }  if $site->kind eq 'statement';
            return { replacement => '1',   description => 'fixed the condition' }    if $site->kind eq 'condition';
            return { replacement => q{!=}, description => 'negated the comparison' } if $site->text eq q{==};
            return;
        }
    );
    my $mutants   = Oracle::generated( $unit, [$changes] )->{mutants};
    my $judgement = Oracle::judgement( $unit, $mutants, wants => ['calls'] );
    is [ map { $_->original } $mutants->@* ],
      [
        q{defined &TRACE or eval 'sub TRACE () { 0 }'},
        qq{die "no trace\\n" if TRACE == 1},
        'TRACE == 1', q{==}, 'DEBUG'
      ],
      'the statements, the full modifier condition, its comparison, and the constant condition';
    is classes( Oracle::refused( $unit, $judgement ) ),    [], 'no mutant counts as text that perl cannot parse';
    is classes( Oracle::unresolved( $unit, $judgement ) ), [], 'and none counts as a call that the mutant introduced';
    is classes( Oracle::apart( $unit, $judgement ) ),
      [
        'change changes code that the compilation runs',
        'change dies while a block of the compilation runs',
        'change dies while a block of the compilation runs',
        'change reaches a call that the original leaves out',
      ],
      'each one counts apart, under its reason';
    $checked += $mutants->@*;
  };

subtest 'the load oracle rejects a mutant that leaves the file without a true value' => sub {
    my $code    = "package Loads;\nmy \$five = 5;\nmy \$limit = 10 / \$five;\nsub f { return 1 }\n1;\n";
    my $unit    = Oracle::text_source( 'lib/Loads.pm', $code );
    my @changed = (
        Oracle::by_hand( $unit, '= 5',      '= 0' ),
        Oracle::by_hand( $unit, 'return 1', 'return 0' ),
        Oracle::by_hand( $unit, "}\n1;",    "}\n0;" ),
    );
    my $judgement = Oracle::judgement( $unit, \@changed, wants => [ 'calls', 'load' ] );
    is [ map { $_->from->[0] } @changed ], [ 2, 4, 4 ], 'a divisor, a return value, and the final value of the file';
    is [ map { $_->{loaded} } $judgement->{verdicts}->@* ], [ 0, 1, 0 ], 'two of the three mutants fail to load';
    is classes( Oracle::unloaded( $unit, $judgement ) ), ['by-hand leaves the file without a true value'],
      'the final value is a finding';
    is classes( Oracle::apart( $unit, $judgement ) ), ['by-hand dies while the file loads'],
      'and the division by zero is a mutant that behaves as one';
    is classes( Oracle::refused( $unit, $judgement ) ), [], 'perl compiles all three';

    my $made = Oracle::generated($unit);
    my $real = Oracle::judgement( $unit, $made->{mutants}, wants => [ 'calls', 'load' ] );
    is classes( Oracle::unloaded( $unit, $real ) ), [],
      'every mutant that the tool makes of the unit keeps a true value';
    ok scalar( grep { $_->{rule} eq 'final-value' } $made->{rejected}->@* ), 'the tool refuses a change of that value';
    $checked += @changed + $made->{mutants}->@*;

    my $false = Oracle::text_source( 'lib/False.pm', "package False;\nsub f { return 1 }\n0;\n" );
    is Oracle::judgement( $false, Oracle::generated($false)->{mutants}, wants => ['load'] )->{problem},
      'the original fails to load', 'a file that fails to load as it stands has no verdict of this oracle';
};

subtest 'the refusal oracle rejects a change that the generator refuses without a cause' => sub {
    my $text =
      "use strict;\nsub sum { return \$_[0] + \$_[1] }\nsub text {\n    return <<'EOT';\nhello (\nEOT\n}\n1;\n";
    my $unit = Oracle::text_source( 'lib/Refuses.pm', $text );
    my $made = Oracle::generated($unit);
    my @real = Oracle::candidates( $unit, $made )->@*;
    is scalar(@real), $made->{mutants}->@* + $made->{rejected}->@*, 'the replay gives every mutant and every refusal';
    is classes( Oracle::unjustified( $unit, \@real ) ), [], 'a check of the text finds the cause of each refusal';
    my @asked = Oracle::refusals_for_perl( $unit, \@real );
    ok scalar(@asked), 'perl has refusals of the tool to judge (' . @asked . ')';
    my $judged = Oracle::judgement( $unit, \@asked, wants => ['calls'] );
    is classes( Oracle::accepted_refusals( $unit, $judged ) ), [],
      'and perl refuses each change that the tool refuses for perl';

    # Without `use strict` perl compiles a removed declaration and the text of a here-document that parses as code.
    my $loose = Oracle::text_source( 'lib/Loose.pm',
        "sub size {\n    if ( my \$n = shift ) { return \$n }\n    return 0;\n}\nsub one {\n    return <<'EOT';\n1;\nEOT\n}\n1;\n"
    );
    my $loosely = Oracle::generated($loose);
    my @shown   = Oracle::refusals_for_perl( $loose, Oracle::candidates( $loose, $loosely ) );
    my $lenient = Oracle::judgement( $loose, \@shown, wants => ['calls'] );
    is [ sort map { $_->{mutant}->description } grep { $_->{compiled} } $lenient->{verdicts}->@* ],
      [ 'declaration', 'declaration', 'here-document' ],
      'perl compiles both refused conditions of a declaration and the refused removal of a here-document';
    is classes( Oracle::accepted_refusals( $loose, $lenient ) ), [],
      'and the text shows the cause of both: a later name of the variable, and a text of the here-document left behind';

    # A refusal without a cause: the test names a rule for a change of the plus sign that no rule refuses.
    my ($plus) = grep { $_->text eq q{+} } $made->{sites}->@*;
    my @false = map { { site => $plus, mutator => 'by-hand', proposal => { replacement => q{-} }, rule => $_ } }
      qw(same-text line-count same-result final-value here-document declaration unresolved-call);
    is classes( Oracle::unjustified( $unit, \@false ) ),
      [ map { "by-hand has a change refused under $_ without a cause" }
          qw(same-text line-count same-result final-value) ],
      'a rule that the text decides is refused where the text shows no cause';
    my $accepted = Oracle::judgement( $unit, [ Oracle::refusals_for_perl( $unit, \@false ) ], wants => ['calls'] );
    is classes( Oracle::accepted_refusals( $unit, $accepted ) ),
      [ map { "by-hand has a change refused under $_ that perl accepts" }
          qw(here-document declaration unresolved-call) ],
      'and a rule that perl decides is refused where perl accepts the change';
    $checked += @real + @false;
};

subtest 'the refusal oracle rejects a declaration that never reaches the code after the change' => sub {
    my $text =
        "sub run {\n    my \$n = 1;\n    each_item( sub { my \$n = shift; return \$n } );\n    return \$n;\n}\n"
      . "sub pair {\n    my ( \$first, \$second ) = \@_;\n    return \$second;\n}\n"
      . "sub each_item { return \$_[0]->(2) }\n__PACKAGE__;\n";
    my $unit    = Oracle::text_source( 'lib/Scope.pm', $text );
    my @refused = (
        Oracle::by_hand( $unit, 'each_item( sub { my $n = shift; return $n } );', q{}, description => 'declaration' ),
        Oracle::by_hand( $unit, 'my $n = 1;',                                     q{}, description => 'declaration' ),
        Oracle::by_hand( $unit, 'my ( $first, $second ) = @_;',                   q{}, description => 'declaration' ),
        Oracle::by_hand( $unit, 'return $second;',                                q{}, description => 'declaration' ),
    );
    my $judged = Oracle::judgement( $unit, \@refused, wants => ['calls'] );
    is [ map { $_->{compiled} } $judged->{verdicts}->@* ], [ 1, 1, 1, 1 ],
      'perl compiles every change in a file without strict';
    my %excused = map { $_->original => 1 } Oracle::excused_refusals( $unit, $judged );
    is [ map { $_->[0]->original } Oracle::accepted_refusals( $unit, $judged ) ],
      [ 'each_item( sub { my $n = shift; return $n } );', 'return $second;' ],
      'a declaration inside a block of the change and a change without a declaration show no cause';
    is [ sort keys %excused ], [ 'my $n = 1;', 'my ( $first, $second ) = @_;' ],
      'a declaration that later code names shows its cause, the second name of a list too';

    my @final =
      grep { ( $_->{rule} || q{} ) eq 'final-value' } Oracle::candidates( $unit, Oracle::generated($unit) )->@*;
    is [ map { $_->{site}->text } @final ], ['__PACKAGE__;'],
      'the tool refuses to remove the name of the package that ends the file';
    is classes( Oracle::unjustified( $unit, \@final ) ), [],
      'and the text shows the cause: a constant word ends the code';
    $checked += @refused + @final;
};

subtest 'the refusal oracle rejects a final value that neither stands alone nor ends the code' => sub {
    my $middle = Oracle::text_source( 'lib/Middle.pm', "package Middle;\n__PACKAGE__;\nsub f { return 1 }\n1;\n" );
    my @inner  = grep { ( $_->{rule} || q{} ) eq 'final-value' && $_->{site}->text =~ /__PACKAGE__/ }
      Oracle::candidates( $middle, Oracle::generated($middle) )->@*;
    ok scalar(@inner), 'the tool refuses a change of a constant word that stands alone in the middle of a file';
    is classes( Oracle::unjustified( $middle, \@inner ) ), [], 'and the constant word alone shows the cause';

    # The parser reads the signature as a prototype and the text of its here-document as code, up to the last line.
    my $misread = Oracle::text_source( 'lib/Misread.pm',
            "use v5.20;\nBEGIN { require feature; feature->import('signatures') }\nno warnings;\n"
          . "sub c ( \$v = <<'EOT' ) { return \$v }\n7\nEOT\n1;\n" );
    my @last =
      grep { ( $_->{rule} || q{} ) eq 'final-value' } Oracle::candidates( $misread, Oracle::generated($misread) )->@*;
    is [ map { $_->{site}->text } @last ], ['1'], 'the tool refuses a change of the value that ends the file';
    is classes( Oracle::unjustified( $misread, \@last ) ), [], 'and the end of the code shows the cause';

    my ($sub) = grep { $_->kind eq 'sub_body' } Oracle::generated($middle)->{sites}->@*;
    my $false = { site => $sub, mutator => 'by-hand', proposal => { replacement => '{ }' }, rule => 'final-value' };
    is classes( Oracle::unjustified( $middle, [$false] ) ),
      ['by-hand has a change refused under final-value without a cause'],
      'a body of a subroutine in the middle of the file shows no cause';
    $checked += @inner + @last + 1;
};

subtest 'the cross-check rejects a verdict of the server that perl -c does not give' => sub {
    my $changes = mutator(
        'change',
        sub ($site) {
            return { replacement => '}',   description => 'replaced + with }' }     if $site->text eq q{+};
            return { replacement => 'min', description => 'replaced max with min' } if $site->text eq 'max';
            return { replacement => q{/},  description => 'replaced * with /' }     if $site->text eq q{*};
            return;
        }
    );
    my $mutants   = Oracle::generated( $source, [$changes] )->{mutants};
    my $judgement = Oracle::judgement( $source, $mutants, wants => ['calls'] );
    is [ map { $_->{compiled} . q{ } . scalar $_->{introduced}->@* } $judgement->{verdicts}->@* ],
      [ '1 1', '0 0', '1 0' ], 'a mutant with a new call, a refused mutant, and a sound one';
    is Oracle::cross_checked( $source, $judgement ), { compared => 3, differences => [] },
      'perl -c gives the verdict of the server for each of the three';

    $judgement->{verdicts}[2]{compiled} = 0;
    $judgement->{verdicts}[0]{calls}    = [];
    is Oracle::cross_checked( $source, $judgement ),
      {
        compared    => 3,
        differences => [
            'lib/Sample.pm line 8: max -> min: the server names the calls [] and perl -c names [Sample::min]',
            'lib/Sample.pm line 13: * -> /: the server refuses the mutant and perl -c compiles it',
        ],
      },
      'a verdict that perl -c does not give is named with both answers';
    is Oracle::cross_checked( $source, $judgement, accepted => 0 )->{compared}, 3,
      'a refused mutant and a mutant with a call are compared in every case';
    $checked += 3;
};

subtest 'a changed compile-time dependency leaves the same calls as a fresh perl' => sub {
    my $directory = File::Temp->newdir;
    written( $directory, 'ToggleDep.pm', "package ToggleDep; sub id { 1 } 1;\n" );
    my $unit = Oracle::text_source( 'lib/Switch.pm', <<'CODE' );
package Switch;
use constant DISABLED => 0;
BEGIN { require ToggleDep unless DISABLED }
sub deferred { require ToggleDep; ToggleDep::id() }
1;
CODE
    my @changes = grep { $_->from->[0] == 2 && $_->replacement eq '1' } Oracle::generated($unit)->{mutants}->@*;
    is scalar @changes, 1, 'one mutant disables the dependency during compilation';
    my @reach  = ( include => ["$directory"] );
    my $result = Oracle::judgement( $unit, \@changes, wants => ['calls'], @reach );
    is $result->{verdicts}[0]{introduced}, ['ToggleDep::id'], 'the deferred call has no definition at compile time';
    is Oracle::cross_checked( $unit, $result, @reach ), { compared => 1, differences => [] }, 'fresh perl agrees';
};

subtest 'the literal oracle rejects a number that changes its base' => sub {
    my $unit    = Oracle::text_source( 'lib/Modes.pm', "chmod 0644, \$file;\nmy \$n = 41;\nmy \$z = 0;\n1;\n" );
    my @numbers = (
        Oracle::by_hand( $unit, '0644', '645' ),
        Oracle::by_hand( $unit, '0644', '0645' ),
        Oracle::by_hand( $unit, '41',   '42' ),
        Oracle::by_hand( $unit, '= 0',  '= 1' ),
    );
    is [ map { $_->replacement } map { $_->[0] } Oracle::rebased( $unit, \@numbers ) ], ['645'],
      'the octal literal that turns decimal is refused, and an octal result, a decimal number, or a zero is accepted';
    is classes( Oracle::rebased( $unit, \@numbers ) ), ['by-hand reads an octal literal as a decimal number'],
      'under the name of its class';
    my @records = Oracle::text_records( $unit, Oracle::made_of(@numbers) );
    is [ map { $_->[2] } grep { $_->[0] eq 'finding' && $_->[1] eq 'literal' } @records ],
      ['by-hand reads an octal literal as a decimal number'], 'the records of a file hold the finding';
    $checked += @numbers;
};

subtest 'the code oracle rejects a mutant that compiles to the code of the original' => sub {
    my $unit = Oracle::text_source( 'lib/Folds.pm',
        "use strict;\nsub size { return 10 > 5 ? 'big' : 'small' }\nsub more { return \$_[0] > 5 }\n1;\n" );
    my @comparisons =
      grep { $_->mutator =~ /\Acomparison-(?:boundary|negation)\z/ } Oracle::generated($unit)->{mutants}->@*;
    my $judgement = Oracle::judgement( $unit, \@comparisons, wants => [ 'calls', 'deparse' ] );
    is [ map { $_->{mutant}->replacement . q{ } . $_->{same_code} } $judgement->{verdicts}->@* ],
      [ '>= 1', '<= 0', '>= 0', '<= 0' ],
      'perl folds the first comparison, and one of its mutants folds to the same value';
    is classes( Oracle::equivalent($judgement) ), ['comparison-boundary compiles to the code of the original'],
      'that mutant is a finding';
    my %count;
    $count{ $_->[2] } += $_->[3] for grep { $_->[0] eq 'count' } Oracle::judged_records( $unit, $judgement, 'deparse' );
    is \%count, { judged => 4, compared => 4, equivalent => 1 }, 'and the records count what perl compared';
    $checked += @comparisons;

    # B::Deparse dies on the code of some mutants, and such a mutant has no code to compare.
    my $verdict = $judgement->{verdicts}[1];
    $verdict->@{qw(undeparsed same_code)} = ( 'Unexpected statement modifier', 0 );
    is classes( Oracle::apart( $unit, $judgement ) ), ['comparison-negation has code that B::Deparse cannot print'],
      'a mutant that B::Deparse cannot print counts apart';
    %count = ();
    $count{ $_->[2] } += $_->[3] for grep { $_->[0] eq 'count' } Oracle::judged_records( $unit, $judgement, 'deparse' );
    is \%count, { judged => 4, compared => 3, equivalent => 1, apart => 1 }, 'and it leaves the compared mutants';
};

subtest 'the tally rejects a table that hides a column' => sub {
    my $tally = Oracle::tally();
    Oracle::count( $tally, 'arithmetic', 'mutants', 4 );
    Oracle::count( $tally, 'arithmetic', 'refused', 1 );
    Oracle::count( $tally, 'call-swap',  'mutants', 2 );
    Oracle::count( $tally, 'call-swap',  'mutants', 1 );
    is [ Oracle::table( $tally, 'mutants', 'refused:mutants' ) ],
      [
        'mutator     mutants  refused',
        'arithmetic        4  1 (25.0%)',
        'call-swap         3  0 (0.0%)',
        'all               7  1 (14.3%)',
      ],
      'one row for each mutator, a rate beside each count, and the sums';
    is Oracle::total($tally), { mutants => 7, refused => 1 }, 'the sums of the columns';
    my %column = map { s/:.*//r => 1 } Oracle::columns();
    is [ grep { !$column{$_} }
          qw(mutants unchanged misplaced unpatchable repeated refused unresolved apart equivalent) ],
      [], 'the table of a run shows every oracle';
};

subtest 'the rate rejects a mutator of the default profile above its bound, and no single mutant' => sub {
    my $tally = Oracle::tally();
    Oracle::count( $tally, 'comparison-negation', 'compared',   100 );
    Oracle::count( $tally, 'comparison-negation', 'equivalent', 3 );
    Oracle::count( $tally, 'arithmetic',          'compared',   100 );
    Oracle::count( $tally, 'arithmetic',          'equivalent', 2 );
    Oracle::count( $tally, 'number-literal',      'compared',   10 );
    Oracle::count( $tally, 'number-literal',      'equivalent', 5 );
    Oracle::count( $tally, 'negation',            'equivalent', 1 );
    is Oracle::rated( $tally, 'equivalent', 'compared', 0.02, 'is equivalent too often' ),
      ['comparison-negation is equivalent too often (3 of 100, limit 2%)'],
      'a share above the bound fails, a share at the bound passes, and a mutator of the extended profile has no bound';
    is Oracle::rated( $tally, 'equivalent', 'compared', 0.5, 'is equivalent too often' ), [],
      'a mutator without a base has no rate';
    is [ Oracle::rates( $tally, 'equivalent', 'compared' ) ],
      [ [ 'arithmetic', 2, 100, 0.02 ], [ 'comparison-negation', 3, 100, 0.03 ], [ 'number-literal', 5, 10, 0.5 ] ],
      'each mutator with a base has its count, its base, and its rate';
    my $summary = Oracle::summary(
        [
            [ 'lib/Guard.pm', 'count', 'arithmetic', 'compared',   70 ],
            [ 'lib/Guard.pm', 'count', 'arithmetic', 'equivalent', 2 ],
            [
                'lib/Guard.pm', 'finding', 'c',
                'arithmetic compiles to the code of the original',
                'lib/Guard.pm line 4: + -> -'
            ],
        ]
    );
    is Oracle::equivalence_findings( $summary, 0.02 ),
      ['arithmetic compiles to the code of the original (2 of 70, limit 2%), for example lib/Guard.pm line 4: + -> -'],
      'a failing release sample identifies the file and change that produced the same code';
    is Oracle::equivalence_findings( $summary, 0.03 ), [], 'a sample within the limit produces no finding';
};

sub written ( $directory, $name, $text ) {
    open my $handle, '>:raw', "$directory/$name" or die "write $name: $!";
    print {$handle} $text or die "write $name: $!";
    close $handle         or die "close $name: $!";
    return "$directory/$name";
}

sub of_kind ( $kind, @records ) {
    return [ map { [ $_->@[ 1 .. $_->$#* ] ] } grep { $_->[0] eq $kind } @records ];
}

subtest 'the survey of a file rejects each defect once for a mutator and a class' => sub {

    # The path alone exceeds the space for an example, so the finding must keep the location and the change intact.
    my $directory = File::Temp->newdir( 'directory-' x 18 . 'XXXXXX', TMPDIR => 1 );
    my $swap      = written( $directory, 'Swap.pm', <<'CODE' );
package Swap;
use strict;
use warnings;
use List::Util qw(max);

sub largest {
    return max(@_) + max( 1, 2 );
}

sub banner {
    return <<'EOT';
hello (
EOT
}

1;
CODE

    # The broken mutants are built by hand: the tool refuses to make any of the three.
    my $swapped = Oracle::file_source($swap);
    my @broken  = (
        Oracle::by_hand( $swapped, 'max(@_)',     'min(@_)' ),
        Oracle::by_hand( $swapped, 'max( 1, 2 )', 'min( 1, 2 )' ),
        Oracle::by_hand( $swapped, q{<<'EOT'},    q{} ),
        Oracle::by_hand( $swapped, 'max(@_) +',   'max(@_) -' ),
    );
    my @records = Oracle::survey_made( $swapped, Oracle::made_of(@broken), accepted => 1 );
    is of_kind( 'problem', @records ), [], 'the file has no problem';
    is [ map { [ $_->@[ 0, 1 ] ] } of_kind( 'finding', @records )->@* ],
      [ [ 'b', 'by-hand removes a here-document introducer' ], [ 'b2', 'by-hand introduces an unresolved call' ], ],
      'the two defects of the file, the second one once for its two mutants';
    like of_kind( 'finding', @records )->[0][2], qr/Swap[.]pm line 11: <<'EOT' -> \| /, 'a finding shows an example';
    my %count;
    $count{ $_->[1] }{ $_->[0] } += $_->[2] for of_kind( 'count', @records )->@*;
    is $count{unresolved}, { 'by-hand' => 2 }, 'the count holds every mutant of the class';
    is $count{refused},    { 'by-hand' => 1 }, 'in the column of its oracle';
    is $count{judged},  $count{mutants}, 'perl judges every mutant unless the caller sets a limit';
    is $count{patched}, $count{mutants}, 'and every mutant has its patch applied';
    is of_kind( 'crossed', @records ), [ [4] ],
      'a cold perl confirms the refused mutant, both mutants with a call, and one sound mutant';
    $checked += @broken;

    my @real = Oracle::survey($swap);
    is of_kind( 'problem', @real ), [], 'the file as the tool reads it has no problem';
    is of_kind( 'finding', @real ), [], 'and perl accepts every mutant that the tool makes of it';
    my ( %made, %limited );
    $made{ $_->[1] }{ $_->[0] }    += $_->[2] for of_kind( 'count', @real )->@*;
    $limited{ $_->[1] }{ $_->[0] } += $_->[2] for of_kind( 'count', Oracle::survey( $swap, judged => 1 ) )->@*;
    is $made{judged}, $made{mutants}, 'perl judges every mutant of the tool';
    is $limited{judged}, { map { $_ => 1 } keys $made{mutants}->%* }, 'a limit keeps that many mutants of each mutator';
    $checked += $made{mutants}{$_} for keys $made{mutants}->%*;

    my $returns = written( $directory, 'Returns.pm', "package Returns;\nsub one { return 1 }\r1;\n" );
    is [ Oracle::survey($returns) ],
      [ [ 'problem', 'analysis', 'the file has a carriage return without a line feed' ] ],
      'a file that the tool leaves alone names the reason';
    my $refused  = written( $directory, 'Refused.pm', "use strict;\nsub f { return \$missing + 1 }\n1;\n" );
    my @unjudged = Oracle::survey($refused);
    is of_kind( 'problem', @unjudged ), [ [ 'judge', 'perl refuses the original' ] ], 'a file that perl refuses';
    ok scalar( grep { $_->[0] eq 'count' && $_->[2] eq 'mutants' } @unjudged ), 'still has its mutants counted';

    # The server holds the modules of its walker, and a unit may compile with them alone.
    my $leans = written( $directory, 'Leans.pm',
        "use strict;\nBEGIN { defined &Exporter::import or die qq{no exporter\\n} }\nsub f { return 1 + 2 }\n1;\n" );
    is of_kind( 'problem', Oracle::survey($leans) ), [ [ 'judge', 'plain perl -c refuses the original' ] ],
      'a file that compiles in the server alone has no verdict';
};

subtest 'the walk over files rejects a worker that ends badly' => sub {
    my $directory = File::Temp->newdir;
    my @paths     = map { written( $directory, "$_.txt", $_ x 3 ) } qw(a b c d e);
    my $records   = Oracle::each_file( \@paths, 3, sub ($path) { return [ 'size', -s $path ], [ 'name', "a\tb\n" ] } );
    is $records, [ map { ( [ $_, 'name', 'a b ' ], [ $_, 'size', 3 ] ) } @paths ],
      'every record comes back under its path, in a fixed order and on one line';
    my @parts = map { [ $paths[0], $_, 3 ] } 0 .. 2;
    is Oracle::each_file( \@parts, 2, sub ( $path, $part, $of ) { return [ 'part', "$part of $of" ] } ),
      [ map { [ $paths[0], 'part', "$_ of 3" ] } 0 .. 2 ], 'a task carries its own arguments after the path';
    like dies {
        Oracle::each_file( \@paths, 2, sub ($path) { die "no $path\n" if $path =~ /c[.]txt/; return } )
    }, qr/\Aa worker of the walk ended badly/, 'a death in a worker fails the walk';

    my $swap = written( $directory, 'Parts.pm',
        "use strict;\nsub f { my (\$n) = \@_; return \$n + 1 if \$n > 2; return \$n * 2 - 1 }\n1;\n" );
    my %whole;
    $whole{ $_->[2] } += $_->[3] for grep { $_->[0] eq 'count' } Oracle::survey($swap);
    my %split;
    for my $part ( 0 .. 2 ) {
        $split{ $_->[2] } += $_->[3] for grep { $_->[0] eq 'count' } Oracle::survey( $swap, part => [ $part, 3 ] );
    }
    is \%split, \%whole, 'the parts of a file hold each mutant once, and the first part holds what needs no judge';
    ok $whole{judged} > 9, "the file has enough mutants for three parts ($whole{judged})";
};

subtest 'the summary of a walk rejects a finding without its oracle and a problem without its file' => sub {
    my $summary = Oracle::summary(
        [
            [ 'lib/A.pm', 'sites',   9 ],
            [ 'lib/B.pm', 'sites',   4 ],
            [ 'lib/A.pm', 'crossed', 3 ],
            [ 'lib/B.pm', 'crossed', 2 ],
            [ 'lib/A.pm', 'count',   'arithmetic', 'mutants',                         3 ],
            [ 'lib/A.pm', 'count',   'call-swap',  'mutants',                         2 ],
            [ 'lib/A.pm', 'count',   'call-swap',  'unresolved',                      1 ],
            [ 'lib/A.pm', 'finding', 'b2', 'call-swap introduces an unresolved call', 'lib/A.pm line 3: max -> min' ],
            [ 'lib/B.pm', 'count',   'call-swap', 'mutants',                          1 ],
            [ 'lib/B.pm', 'count',   'call-swap', 'unresolved',                       1 ],
            [ 'lib/B.pm', 'finding', 'b2', 'call-swap introduces an unresolved call', 'lib/B.pm line 9: any -> all' ],
            [ 'lib/C.pm', 'problem', 'analysis', 'the file has carriage returns' ],
            [ 'lib/D.pm', 'problem', 'judge',    'the judge broke', 'no B' ],
        ]
    );
    is [ Oracle::table( $summary->{tally}, 'mutants', 'unresolved:mutants' ) ],
      [
        'mutator     mutants  unresolved',
        'arithmetic        3  0 (0.0%)',
        'call-swap         3  2 (66.7%)',
        'all               6  2 (33.3%)',
      ],
      'the counts of every file in one table';
    is $summary->{sites},               13, 'the sites of every file';
    is $summary->{files},               2,  'and the files that have them';
    is $summary->{crossed},             5,  'the verdicts that a cold perl confirmed';
    is Oracle::found( $summary, 'b2' ), ['call-swap introduces an unresolved call'], 'the findings of one oracle';
    is Oracle::found( $summary, 'b' ),  [],                                          'and none of another one';
    is $summary->{problems},
      { 'analysis: the file has carriage returns' => ['lib/C.pm'], 'judge: the judge broke' => ['lib/D.pm'] },
      'the files of each problem';
    is [ Oracle::lines($summary) ],
      [
        'b2: call-swap introduces an unresolved call, in 2 files, as in lib/A.pm line 3: max -> min',
        'analysis: the file has carriage returns, in 1 file, as in lib/C.pm',
        'judge: the judge broke, in 1 file, as in lib/D.pm (no B)',
      ],
      'one line for each finding and each problem, with the number of its files and one example';
};

Gate::checked( 'mutants and changes', $checked, at_least => 400 );

done_testing;
