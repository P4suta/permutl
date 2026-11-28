package Oracle;
use v5.36;
use IO::Select   ();
use List::Util   qw(max sum0);
use POSIX        ();
use Scalar::Util qw(refaddr);
use PPI;
use Bounded;
use Judge;
use Test::Mutation::Mutant;
use Test::Mutation::Mutant::Generator;
use Test::Mutation::Mutator::Catalog;
use Test::Mutation::Report::Patch;
use Test::Mutation::Source;
use Test::Mutation::Syntax::PPI;

# The oracles of the mutant quality harness.
# Each one takes mutants as the tool made them and returns the ones that break its invariant, each with a class.
# A class is fixed text, so a finding reads the same on every interpreter and in every run.

sub text_source ( $path, $text ) {
    return Test::Mutation::Source->new( path => $path, text => $text, encoding => 'UTF-8' );
}

sub file_source ($path) {
    open my $handle, '<:raw', $path or die "read $path: $!\n";
    my $bytes = do { local $/ = undef; readline $handle };
    close $handle or die "close $path: $!\n";
    return Test::Mutation::Source->from_bytes( path => $path, bytes => defined $bytes ? $bytes : q{} );
}

sub _ungenerated ( $problem, $detail ) {
    return { problem => $problem, detail => $detail, sites => [], mutants => [], rejected => [], suppressions => [] };
}

# The sites and the mutants of a source with the given mutators, or the reason for their absence.
sub generated ( $source, $mutators = Test::Mutation::Mutator::Catalog::mutators() ) {

    # A bound around the call stops the analysis with an error, and the bound reads that error itself.
    my $analysis = eval { Test::Mutation::Syntax::PPI::analyze($source) };
    die $@                                         if !$analysis && Bounded::stopped($@);
    return _ungenerated( 'the analysis died', $@ ) if !$analysis;
    my $problem = $analysis->{problem};
    return _ungenerated( $problem =~ s/:.*//sr, $problem ) if defined $problem;
    my $made = eval {
        Test::Mutation::Mutant::Generator::generate( source => $source, analysis => $analysis, mutators => $mutators );
    };
    die $@                                           if !$made && Bounded::stopped($@);
    return _ungenerated( 'the generation died', $@ ) if !$made;
    return {
        problem => undef,
        $analysis->%{qw(sites suppressions dropped heredocs names)},
        $made->%{qw(mutants rejected)}, mutators => $mutators,
    };
}

# Every change that a mutator proposes for a source, in the order of the generator, with what the generator made of it.
# The generator names a refused change by its mutator, its line, and its rule, so the replay gives the change its span.
# A candidate holds the site, the name of the mutator, the proposal, and either the mutant or the rule that refused it.
sub candidates ( $source, $made ) {
    my @mutants = $made->{mutants}->@*;
    my @refused = $made->{rejected}->@*;
    my @candidates;
    for my $site ( $made->{sites}->@* ) {
        my $line = $source->position_of( $site->start )->[0];
        for my $mutator ( $made->{mutators}->@* ) {
            for my $proposal ( $mutator->mutations($site)->@* ) {
                my %candidate = ( site => $site, mutator => $mutator->name, proposal => $proposal );
                if ( _is_made( $mutants[0], $site, $mutator->name, $proposal ) ) {
                    push @candidates, { %candidate, mutant => shift @mutants };
                    next;
                }
                my $refusal = shift @refused;
                die 'the replay of ' . $source->path . " meets no refusal for a change of line $line\n"
                  if !$refusal || $refusal->{mutator} ne $mutator->name || $refusal->{line} != $line;
                push @candidates, { %candidate, rule => $refusal->{rule} };
            }
        }
    }
    die 'the replay of ' . $source->path . " leaves mutants or refusals over\n" if @mutants || @refused;
    return \@candidates;
}

sub _is_made ( $mutant, $site, $name, $proposal ) {
    return 0 if !$mutant || $mutant->mutator ne $name || $mutant->start != $site->start || $mutant->end != $site->end;
    return defined $proposal->{calls} || $mutant->replacement eq $proposal->{replacement} ? 1 : 0;
}

my $made_by_hand = 0;

# A mutant that replaces the first occurrence of a text in a source, built as no mutator of the tool builds it.
# A gate feeds its oracle with such a mutant, so the broken input depends on no defect of the tool.
sub by_hand ( $source, $original, $replacement, %override ) {
    my $start = index $source->text, $original;
    die 'the source ' . $source->path . " holds no $original\n" if $start < 0;
    my %span = ( start => $start, end => $start + length $original, %override );
    return Test::Mutation::Mutant->new(
        id          => sprintf( '%012x', ++$made_by_hand ),
        path        => $source->path,
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

# The text of a call that the boundary found no name for: the package of the original call before the new name.
sub _call_text ( $site, $name ) {
    my ($package) = $site->text =~ /\A(.+)::\w+\z/;
    return defined $package && $name !~ /::/ ? "${package}::$name" : $name;
}

# The refused change of a candidate as a mutant, so perl and the reports read it like one.
# The description holds the rule, and a call that the boundary found no name for keeps the package of the original.
sub _refused_mutant ( $source, $candidate ) {
    my ( $site, $proposal ) = $candidate->@{qw(site proposal)};
    return Test::Mutation::Mutant->new(
        id          => sprintf( '%012x', ++$made_by_hand ),
        path        => $source->path,
        mutator     => $candidate->{mutator},
        start       => $site->start,
        end         => $site->end,
        original    => $site->text,
        replacement => defined $proposal->{calls} ? _call_text( $site, $proposal->{calls} ) : $proposal->{replacement},
        description => $candidate->{rule},
        from        => $source->position_of( $site->start ),
        to          => $source->position_of( $site->end ),
        scope       => [ 1, 1 ],
    );
}

# The words that perl reads as a constant while it compiles a file.
my %CONSTANT_WORD = map { $_ => 1 } qw(__PACKAGE__ __FILE__ __LINE__ __CLASS__);

sub _is_value_token ($token) {
    return 1 if grep { $token->isa("PPI::Token::$_") } qw(Number Quote Operator Structure);
    return $token->isa('PPI::Token::Word') && $CONSTANT_WORD{ $token->content } ? 1 : 0;
}

# The spans of the statements of a file that are a value alone: literals and operators, as the last `1;` of a module.
sub _value_statements ($source) {
    my $read        = tokens($source);
    my %place       = map { refaddr( $_->{token} ) => $_ } $read->{tokens}->@*;
    my @statements  = $read->{document} ? $read->{document}->schildren : ();
    my ($returning) = grep {
             $_->isa('PPI::Statement')
          && !$_->isa('PPI::Statement::Sub')
          && !$_->isa('PPI::Statement::End')
          && !$_->isa('PPI::Statement::Data')
          && !$_->isa('PPI::Statement::Null')
          && ( !$_->isa('PPI::Statement::Include') || $_->type eq 'require' )
          && ( !$_->isa('PPI::Statement::Package') || $_->find_first('PPI::Structure::Block') )
    } reverse @statements;
    my @spans;
    for my $statement (@statements) {
        next if ref $statement ne 'PPI::Statement';
        my @tokens = grep { $_->significant } $statement->tokens;
        if ( grep { !_is_value_token($_) } @tokens ) {
            next unless $returning && refaddr($returning) == refaddr($statement);
            next unless _computed_footer($statement);
        }
        my ( $first, $last ) = @place{ refaddr( $tokens[0] ), refaddr( $tokens[-1] ) };
        push @spans, [ $first->{start}, $last->{end} ] if $first && $last;
    }
    return @spans;
}

sub _computed_footer ($statement) {
    my @parts = grep { $_->content ne q{;} } $statement->schildren;
    return 0 if !@parts || $parts[0]->content =~ /\A(?:print|printf|say|warn|die)\z/;
    return 1 if @parts == 1 && $parts[0]->isa('PPI::Structure::List');
    return scalar grep { $_->isa('PPI::Token::Operator') && $_->content ne '->' } @parts;
}

my %BY_PERL = map { $_ => 1 } qw(here-document declaration unresolved-call);

my %DECLARES = map { $_ => 1 } qw(my our state);

# The word before a symbol, or before the list that holds it, as in `my $x` and `my ( $x, $y )`.
# A symbol after the first one of a list stands after a comma, so the word before the list declares it.
sub _declaring_word ($symbol) {
    my $before = $symbol->sprevious_sibling;
    return $before if $before && $before->isa('PPI::Token::Word');
    my $list = $symbol->parent;
    $list = $list->parent if $list && $list->isa('PPI::Statement::Expression');
    return $list && $list->isa('PPI::Structure::List') ? $list->sprevious_sibling : $before;
}

# The innermost block around a token, or nothing at the level of the file.
sub _block_of ($token) {
    my $node = $token->parent;
    $node = $node->parent while $node && !$node->isa('PPI::Structure::Block');
    return $node;
}

# The end of the code that a declaration at the level of a span reaches: the end of the block around the span.
sub _reach_of ( $source, $read, $first ) {
    my $end     = length $source->text;
    my $block   = _block_of($first) or return $end;
    my $close   = $block->finish    or return $end;
    my ($place) = grep { refaddr( $_->{token} ) == refaddr($close) } $read->{tokens}->@*;
    return $place ? $place->{start} : $end;
}

sub _same_node ( $one, $other ) {
    return !$one && !$other || $one && $other && refaddr($one) == refaddr($other) ? 1 : 0;
}

# Whether a span declares a variable that a symbol after the span names, as PPI reads the text here.
# A declaration inside a block of the span ends with that block, and a later name counts inside the block around the span.
# Perl refuses such a change under `use strict` alone, so the text decides the rule in every file.
sub _declares_a_later_name ( $source, $read, $site ) {
    my @symbols = grep { $_->{class} eq 'PPI::Token::Symbol' } $read->{tokens}->@*;
    my ($first) = grep { $_->{start} >= $site->start && $_->{end} <= $site->end } $read->{tokens}->@*;
    return 0 if !$first;
    my $outer = _block_of( $first->{token} );
    my %declared;
    for my $item ( grep { $_->{start} >= $site->start && $_->{end} <= $site->end } @symbols ) {
        my $token = $item->{token};
        my $word  = _declaring_word($token);
        next                            if !$word || !$word->isa('PPI::Token::Word') || !$DECLARES{ $word->content };
        $declared{ $token->symbol } = 1 if _same_node( _block_of($token), $outer );
    }
    my $reach = _reach_of( $source, $read, $first->{token} );
    return
      scalar grep { $_->{start} >= $site->end && $_->{end} <= $reach && $declared{ $_->{token}->symbol } } @symbols;
}

# Whether a change drops the introducer of a here-document and leaves its text, which starts on the next line.
# The text of a here-document that parses as code compiles all the same, so the text decides the rule in every file.
sub _splits_a_heredoc ( $source, $read, $site, $written ) {
    return scalar grep {
             $_->{class} eq 'PPI::Token::HereDoc'
          && $_->{start} >= $site->start
          && $_->{end} <= $site->end
          && index( $written, $_->{content} ) < 0
          && substr( $source->text, $_->{end}, $site->end - $_->{end} ) !~ /\n/
    } $read->{tokens}->@*;
}

# Whether the text shows the cause of a refused change that perl compiles, written as a mutant with its rule.
sub _shows_cause ( $source, $read, $refused ) {
    my $rule = $refused->description;
    return _declares_a_later_name( $source, $read, $refused )                   if $rule eq 'declaration';
    return _splits_a_heredoc( $source, $read, $refused, $refused->replacement ) if $rule eq 'here-document';
    return 0;
}

# Whether a span ends the code of the file: a semicolon, comments, documentation, and the data section may follow it.
# PPI reads some files in another way than perl does, and the end of the code holds the value of the file all the same.
sub _ends_the_code ( $source, $site ) {
    my $rest = substr $source->text, $site->end;
    $rest =~ s/\A(?:\s+|;|[#][^\n]*|^=[[:alpha:]].*?(?:^=cut\b[^\n]*|\z))+//ms;
    return !length $rest || $rest =~ /\A__(?:END|DATA)__\b/ ? 1 : 0;
}

# Whether the text shows the cause of a refusal whose rule speaks of the text alone.
sub _has_cause ( $source, $candidate, $earlier, $values ) {
    my ( $site, $rule ) = $candidate->@{qw(site rule)};
    my $written = $candidate->{proposal}{replacement};
    return 1                                                                 if !defined $written;
    return $written eq $site->text                                           if $rule eq 'same-text';
    return ( $written =~ tr/\n// ) != ( $site->text =~ tr/\n// )             if $rule eq 'line-count';
    return _within( $site, $values->@* ) || _ends_the_code( $source, $site ) if $rule eq 'final-value';
    return $earlier->{ change_key( $source->text, $site->start, $site->end, $written ) } ? 1 : 0;
}

# The oracle of the refusals, for the rules that the text decides.
# A change refused as the same text leaves the file as it was, and one refused for its lines changes their number.
# A change refused as the same result leaves the text of an earlier mutant, by a key that this module computes itself.
# A change refused as a final value stands in a statement of the file that is a value alone, as PPI reads it here.
sub unjustified ( $source, $candidates ) {
    my ( %earlier, @found );
    my @values = _value_statements($source);
    for my $candidate ( $candidates->@* ) {
        my $mutant = $candidate->{mutant};
        if ($mutant) {
            $earlier{ change_key( $source->text, $mutant->start, $mutant->end, $mutant->replacement ) } = 1;
            next;
        }
        next if $BY_PERL{ $candidate->{rule} } || _has_cause( $source, $candidate, \%earlier, \@values );
        push @found,
          [ _refused_mutant( $source, $candidate ), "has a change refused under $candidate->{rule} without a cause" ];
    }
    return @found;
}

# The refused changes that perl decides, each as a mutant for the judge.
# A change refused for a here-document, for a declaration, or for a call without a name has to fail before perl.
sub refusals_for_perl ( $source, $candidates ) {
    return map { _refused_mutant( $source, $_ ) } grep { defined $_->{rule} && $BY_PERL{ $_->{rule} } } $candidates->@*;
}

# The oracle of the refusals, for the rules that perl decides: perl compiles the change and finds every call.
# Perl compiles a declaration that later code names, and a text of a here-document that parses, in a file without `use strict`.
# The text shows the cause of such a refusal, so perl has to accept the change and the text has to show no cause.
sub accepted_refusals ( $source, $judgement ) {
    my ( $causeless, undef ) = _accepted_apart( $source, $judgement );
    return map { [ $_, 'has a change refused under ' . $_->description . ' that perl accepts' ] } $causeless->@*;
}

# The refused changes that perl accepts and whose text shows the cause, which the gate counts apart.
sub excused_refusals ( $source, $judgement ) {
    my ( undef, $excused ) = _accepted_apart( $source, $judgement );
    return $excused->@*;
}

# The refused changes that perl accepts, apart by whether the text shows their cause.
sub _accepted_apart ( $source, $judgement ) {
    my @accepted = map { $_->{mutant} } grep { $_->{compiled} && !$_->{introduced}->@* } $judgement->{verdicts}->@*;
    return ( [], [] ) if !@accepted;
    my $read = tokens($source);
    my ( @causeless, @excused );
    push @{ _shows_cause( $source, $read, $_ ) ? \@excused : \@causeless }, $_ for @accepted;
    return ( \@causeless, \@excused );
}

# What the generator would return for a source that holds the given mutants and nothing else.
sub made_of (@mutants) {
    return { problem => undef, sites => [], mutants => \@mutants, rejected => [], mutators => [] };
}

sub _in_range ( $source, $mutant ) {
    return $mutant->start >= 0 && $mutant->start <= $mutant->end && $mutant->end <= length $source->text;
}

# Oracle a: the text of the mutant differs from the text of the file.
sub unchanged ( $source, $mutants ) {
    my $text = $source->text;
    return map { [ $_, 'leaves the text as it was' ] } grep {
        _in_range( $source, $_ )
          ? substr( $text, $_->start, $_->end - $_->start ) eq $_->replacement
          : $source->replace_span( $_->start, $_->end, $_->replacement ) eq $text
    } $mutants->@*;
}

sub _same_position ( $one, $other ) {
    return $one->[0] == $other->[0] && $one->[1] == $other->[1];
}

# Oracle d, first half: the span holds the text that the mutant names, at the position that the mutant names.
sub misplaced ( $source, $mutants ) {
    return grep { $_->@* == 2 } map { [ $_, _misplacement( $source, $_ ) ] } $mutants->@*;
}

sub _misplacement ( $source, $mutant ) {
    my $holds = _in_range( $source, $mutant )
      && substr( $source->text, $mutant->start, $mutant->end - $mutant->start ) eq $mutant->original;
    return 'names a span that holds another text' if !$holds;
    my $placed = _same_position( $mutant->from, $source->position_of( $mutant->start ) )
      && _same_position( $mutant->to, $source->position_of( $mutant->end ) );
    return $placed ? () : 'names a position apart from its span';
}

# The text that a unified diff of one hunk makes of a text, or nothing when the diff does not apply.
# A diff line stands for a whole line, so the result ends with a line break.
sub patched ( $text, $patch ) {
    my ( $old, $new, $hunk, @body ) = split /\n/, $patch;
    return if !defined $hunk || $old !~ /\A--- / || $new !~ /\A[+]{3} / || grep { !/\A[ +-]/ } @body;
    my ( $from, $removed, $to, $added ) = $hunk =~ /\A@@ -(\d+),(\d+) [+](\d+),(\d+) @@\z/ or return;
    my @before = map { substr $_, 1 } grep { !/\A[+]/ } @body;
    my @after  = map { substr $_, 1 } grep { !/\A-/ } @body;
    my @lines  = $text =~ /\G([^\n]*\n|[^\n]+\z)/g;
    return if $from != $to || $from < 1 || @before != $removed || @after != $added || $from - 1 + $removed > @lines;
    my @there = map { s/\n\z//r } @lines[ $from - 1 .. $from + $removed - 2 ];
    return if join( "\n", @there ) ne join "\n", @before;
    return join q{}, @lines[ 0 .. $from - 2 ], ( map { "$_\n" } @after ), @lines[ $from - 1 + $removed .. $#lines ];
}

# Oracle d, second half: the patch that the show command renders turns the file into the mutant.
sub unpatchable ( $source, $mutants ) {
    my $text = $source->text;
    return map { [ $_, 'renders a patch that gives another text' ] } grep {
        my $result = patched( $text, Test::Mutation::Report::Patch::render( text => $text, mutant => $_ ) );
        !defined $result || $result ne $source->replace_span( $_->start, $_->end, $_->replacement )
    } $mutants->@*;
}

sub _shared_prefix ( $one, $other ) {
    my $limit  = length $one < length $other ? length $one : length $other;
    my $length = 0;
    $length++ while $length < $limit && substr( $one, $length, 1 ) eq substr $other, $length, 1;
    return $length;
}

# One key for every change of a text that gives the same result, without the result itself.
# A change is cut down to the characters that differ, and a removal or an insertion moves left as far as it can.
sub change_key ( $text, $start, $end, $replacement ) {
    my $old    = substr $text, $start, $end - $start;
    my $prefix = _shared_prefix( $old, $replacement );
    ( $start, $old, $replacement ) = ( $start + $prefix, substr( $old, $prefix ), substr $replacement, $prefix );
    my $suffix = _shared_prefix( scalar reverse($old), scalar reverse $replacement );
    $end = $start + length($old) - $suffix;
    $replacement = substr $replacement, 0, length($replacement) - $suffix;
    return 'none' if $start == $end && !length $replacement;

    if ( !length $replacement ) {
        while ( $start > 0 && substr( $text, $start - 1, 1 ) eq substr $text, $end - 1, 1 ) {
            $start--;
            $end--;
        }
    }
    while ( $start == $end && $start > 0 && substr( $text, $start - 1, 1 ) eq substr $replacement, -1 ) {
        $start--;
        $end--;
        $replacement = substr( $text, $start, 1 ) . substr $replacement, 0, -1;
    }
    return "$start $end $replacement";
}

# Oracle e: an id names one mutant of a file, and no two mutants give the same text.
sub repeated ( $source, $mutants ) {
    my ( %id, %result, @found );
    for my $mutant ( $mutants->@* ) {
        push @found, [ $mutant, 'repeats an id' ] if $id{ $mutant->id }++;
        next if !_in_range( $source, $mutant );
        my $key     = change_key( $source->text, $mutant->start, $mutant->end, $mutant->replacement );
        my $earlier = $result{$key};
        push @found, [ $mutant, 'gives the same text as a mutant of ' . $earlier->mutator ] if $earlier;
        $result{$key} ||= $mutant;
    }
    return @found;
}

# Perl reads a whole number with a leading zero as octal, and a replacement without that zero is a decimal number.
# The mutant then holds another value than the one that its description names.
sub rebased ( $source, $mutants ) {
    return map { [ $_, 'reads an octal literal as a decimal number' ] }
      grep { $_->original =~ /\A0[0-7]+\z/ && $_->replacement =~ /\A[1-9][0-9]*\z/ } $mutants->@*;
}

# Every significant token of a source with its offsets, read by PPI without the analysis of the tool.
# A token whose location does not address its own text has no offsets, and the caller counts it.
# The token objects live as long as the document that the caller keeps.
sub tokens ($source) {
    my $text     = $source->text;
    my $mark     = $text =~ /\A\x{feff}/ ? 1 : 0;
    my $copy     = substr $text, $mark;
    my $document = PPI::Document->new( \$copy ) or return { document => undef, tokens => [], unplaced => 0 };
    $document->index_locations;
    my ( @tokens, $unplaced );
    for my $token ( grep { $_->significant } $document->tokens ) {
        my ( $line, $column ) = $token->location->@*;
        my $start   = $source->offset_of( $line, $column ) + ( $line == 1 ? $mark : 0 );
        my $content = $token->content;
        if ( substr( $text, $start, length $content ) ne $content ) {
            $unplaced++;
            next;
        }
        push @tokens,
          {
            token   => $token,
            class   => ref $token,
            content => $content,
            start   => $start,
            end     => $start + length $content
          };
    }
    return { document => $document, tokens => \@tokens, unplaced => $unplaced || 0 };
}

sub _unjudged ( $problem, $detail = q{} ) {
    return { problem => $problem, detail => $detail, verdicts => [], original => undef };
}

sub _mutated_bytes ( $source, $mutant ) {
    return $source->to_bytes( $source->replace_span( $mutant->start, $mutant->end, $mutant->replacement ) );
}

sub _judged ( $judge, $source, $mutants, @wants ) {
    my $original = $source->to_bytes( $source->text );
    my $cold     = Judge::compiled( $judge, $original, 'calls', 'loaded' );
    return _unjudged( 'perl refuses the original', $cold->{diagnostics} ) if !$cold->{compiled};

    # A compile-time change can omit a module that the original loads.
    # Each child must then load its own dependencies to expose the calls that Perl sees.
    my $places = _places($source);
    if ( !grep { _within( $_, $places->{phase}->@* ) } $mutants->@* ) {
        my @deparser = ( grep { $_ eq 'deparse' } @wants ) ? 'B/Deparse.pm' : ();
        Judge::preload( $judge, @deparser, $cold->{loaded}->@* );
    }
    my $warm = Judge::compiled( $judge, $original, @wants, 'calls' );
    return _unjudged('the modules that the judge holds change the original')
      if !$warm->{compiled} || "@{ $warm->{calls} }" ne "@{ $cold->{calls} }";
    return _unjudged( 'B::Deparse cannot print the original', $warm->{undeparsed} ) if length $warm->{undeparsed};

    return judged_by( $judge, $source, $mutants, $warm, @wants );
}

# The verdicts of a server that the caller keeps, beside the verdict of that server on the original.
# A caller with many small sources and no module to load starts one server for all of them.
sub judged_by ( $judge, $source, $mutants, $original, @wants ) {
    my %known   = map  { $_ => 1 } $original->{calls}->@*;
    my $compare = grep { $_ eq 'deparse' } @wants;
    my $loads   = grep { $_ eq 'load' } @wants;
    return _unjudged('the original fails to load')
      if $loads && !Judge::loaded( $judge, $source->to_bytes( $source->text ) )->{loaded};
    my @verdicts;
    for my $mutant ( $mutants->@* ) {
        my $bytes   = _mutated_bytes( $source, $mutant );
        my $verdict = Judge::compiled( $judge, $bytes, grep { $_ ne 'load' } @wants );
        $verdict->{mutant}     = $mutant;
        $verdict->{introduced} = [ grep { !$known{$_} } $verdict->{calls}->@* ];
        my $printed = $verdict->{compiled} && $compare && defined $verdict->{deparse};
        $verdict->{same_code} = $printed && $verdict->{deparse} eq $original->{deparse} ? 1      : 0;
        $verdict->{load}      = $loads && $verdict->{compiled} ? Judge::loaded( $judge, $bytes ) : undef;
        $verdict->{loaded}    = $verdict->{load}               ? $verdict->{load}{loaded}        : undef;
        delete $verdict->{deparse};
        push @verdicts, $verdict;
    }
    return { problem => undef, detail => q{}, verdicts => \@verdicts, original => $original };
}

# The verdict of perl on every given mutant of a source, or the reason why perl judges none of them.
# `wants` names what a verdict holds beside the compilation: `calls` and `deparse`.
sub judgement ( $source, $mutants, %arg ) {
    my $judge  = Judge::start( include => $arg{include} || [], timeout => $arg{timeout} || 10 );
    my $result = eval { _judged( $judge, $source, $mutants, ( $arg{wants} || [] )->@* ) };
    my $error  = $@;
    my $ended  = eval { Judge::stop($judge) };
    die $error                                             if !$result;
    die 'the judge of ' . $source->path . " ended badly\n" if !$ended;
    return $result;
}

sub _difference ( $verdict, $cold ) {
    my @said = map { $_ ? 'compiles' : 'refuses' } $verdict->{compiled}, $cold->{compiled};
    return "the server $said[0] the mutant and perl -c $said[1] it" if $said[0] ne $said[1];
    my @calls = map { "[@{ $_->{calls} }]" } $verdict, $cold;
    return $calls[0] eq $calls[1] ? () : "the server names the calls $calls[0] and perl -c names $calls[1]";
}

# The verdicts of the server beside the answer of a perl that starts cold and compiles the mutant as its own program.
# Every refused mutant and every mutant with a new call is compared, and so is a sample of the mutants that perl accepts.
# A difference means that the modules of the server changed a verdict, so no finding of the walk can stand on it.
sub cross_checked ( $source, $judgement, %arg ) {
    my @verdicts = grep { !$_->{timed_out} } $judgement->{verdicts}->@*;
    my @sound    = grep { $_->{compiled} && !$_->{introduced}->@* } @verdicts;
    my %sampled  = map  { $_ => 1 } spread( \@sound, defined $arg{accepted} ? $arg{accepted} : 1 );
    my @compared = grep { !$_->{compiled} || $_->{introduced}->@* || $sampled{$_} } @verdicts;
    my @differences;
    for my $verdict (@compared) {
        my $mutant = $verdict->{mutant};
        my $bytes  = _mutated_bytes( $source, $mutant );
        my @reach  = ( include => $arg{include} || [] );

        # Plain `perl -c` answers for the compilation, and the cold walker answers for the calls of a unit that both compile.
        my $plain = Judge::reference( $bytes, @reach );
        my $calls =
          $plain && $verdict->{compiled} ? Judge::reference_calls( $bytes, @reach )->{calls} : $verdict->{calls};
        my $cold = { compiled => $plain, calls => $calls };
        push @differences, map { _example( $source, $mutant, q{} ) =~ s/ [|] \z/: $_/r } _difference( $verdict, $cold );
    }
    return { compared => scalar @compared, differences => \@differences };
}

# What PPI tells about the places of a source that a verdict depends on.
# `heredocs` holds the introducers of here-documents.
# `phase` holds the spans of the code that perl runs while it compiles: a `use` statement and a block such as BEGIN.
sub _places ($source) {
    my $read  = tokens($source);
    my %place = map { refaddr( $_->{token} ) => $_ } $read->{tokens}->@*;
    my @early =
      $read->{document}
      ? grep { $_->isa('PPI::Statement::Include') || $_->isa('PPI::Statement::Scheduled') && $_->type ne 'END' }
      @{ $read->{document}->find('PPI::Statement') || [] }
      : ();
    my @phase;
    for my $statement (@early) {
        my ( $first, $last ) = @place{ refaddr( $statement->first_token ), refaddr( $statement->last_token ) };
        push @phase, [ $first->{start}, $last->{end} ] if $first && $last;
    }
    return { heredocs => [ grep { $_->{class} eq 'PPI::Token::HereDoc' } $read->{tokens}->@* ], phase => \@phase };
}

sub _within ( $mutant, @spans ) {
    return scalar grep { $_->[0] <= $mutant->start && $mutant->end <= $_->[1] } @spans;
}

sub _removes_an_introducer ( $mutant, @heredocs ) {
    my @inside = grep { $_->{start} >= $mutant->start && $_->{end} <= $mutant->end } @heredocs;
    return scalar grep { index( $mutant->replacement, $_->{content} ) < 0 } @inside;
}

# A mutant that perl stops while a block of the compilation phase runs is a mutant that died, and perl parsed it.
sub _died_in_compilation ($verdict) {
    return $verdict->{diagnostics} =~ /^(?:BEGIN|UNITCHECK|CHECK) failed--/m ? 1 : 0;
}

# A mutant of code that the compilation runs changes what the rest of the file compiles to.
# Such a mutant behaves as a mutant should, so its refusal counts apart from a text that perl cannot parse.
sub _refusal ( $verdict, $places ) {
    my $mutant = $verdict->{mutant};
    my $said   = $verdict->{diagnostics} =~ /\A([^\n]*)/ ? $1 : q{};
    return [ 'apart', 'never ends its compilation',                 q{} ] if $verdict->{timed_out};
    return [ 'apart', 'dies while a block of the compilation runs', $verdict->{diagnostics} ]
      if _died_in_compilation($verdict);
    return [ 'apart', 'changes code that the compilation runs', $said ] if _within( $mutant, $places->{phase}->@* );
    return [ 'b',     'removes a here-document introducer',     $said ]
      if _removes_an_introducer( $mutant, $places->{heredocs}->@* );
    return [ 'b', 'leaves a variable without its declaration', $said ]
      if $verdict->{diagnostics} =~ /^Global symbol "[^"]+" requires explicit package name/m;
    return [ 'b', 'yields code that perl refuses', $said ];
}

# A constant condition lets perl leave a branch out, and a mutant of the condition brings the calls of the branch back.
# The mutant introduced a call when its replacement holds the name of the call.
sub _call ( $verdict, $places ) {
    my $mutant = $verdict->{mutant};
    my @names  = $verdict->{introduced}->@*;
    return [ 'apart', 'changes code that the compilation runs', "@names" ] if _within( $mutant, $places->{phase}->@* );
    my @own = grep { my ($name) = /(\w+)\z/; $mutant->replacement =~ /\b\Q$name\E\b/ } @names;
    return [ 'apart', 'reaches a call that the original leaves out', "@names" ] if !@own;
    return [ 'b2',    'introduces an unresolved call',               "@own" ];
}

# A file whose final value turns false fails to load, and the tool must leave that value alone.
# Any other death while the file loads is the work of a mutant that behaves as one.
sub _load_failure ( $verdict, $places ) {
    my $load = $verdict->{load};
    my $said = $load->{diagnostics} =~ /\A([^\n]*)/ ? $1 : q{};
    return [ 'apart', 'never ends its loading',                 q{} ] if $load->{timed_out};
    return [ 'apart', 'changes code that the compilation runs', $said ]
      if _within( $verdict->{mutant}, $places->{phase}->@* );
    return [ 'b3',    'leaves the file without a true value', $said ] if $said =~ /did not return a true value/;
    return [ 'apart', 'dies while the file loads',            $said ];
}

sub _outcomes_of ( $verdict, $places ) {
    return _refusal( $verdict, $places ) if !$verdict->{compiled};
    my $unprinted = $verdict->{undeparsed};
    return (
        $verdict->{introduced}->@*                        ? _call( $verdict, $places )         : (),
        defined $verdict->{loaded} && !$verdict->{loaded} ? _load_failure( $verdict, $places ) : (),
        length $unprinted ? [ 'apart', 'has code that B::Deparse cannot print', $unprinted ]   : (),
    );
}

# The outcome of every verdict that breaks an invariant: the mutant, the oracle, the class, and a detail for the reader.
# Oracle b: perl compiles the mutant, as it compiles the original.
# Oracle b2: the compiled mutant calls no subroutine that is missing, unless the original calls it too.
# Oracle b3: the mutant loads, as the original does.
# The oracle `apart` holds what the brief counts apart: a mutant that behaves as one and that perl stops all the same.
sub outcomes ( $source, $judgement ) {
    my @flagged =
      grep {
        !$_->{compiled} || $_->{introduced}->@* || length $_->{undeparsed} || ( defined $_->{loaded} && !$_->{loaded} )
      } $judgement->{verdicts}->@*;
    return if !@flagged;
    my $places = _places($source);
    my @outcomes;
    for my $verdict (@flagged) {
        push @outcomes, map { [ $verdict->{mutant}, $_->@* ] } _outcomes_of( $verdict, $places );
    }
    return @outcomes;
}

sub _of_oracle ( $oracle, @outcomes ) {
    return map { [ $_->@[ 0, 2, 3 ] ] } grep { $_->[1] eq $oracle } @outcomes;
}

sub refused ( $source, $judgement ) {
    return _of_oracle( 'b', outcomes( $source, $judgement ) );
}

sub unresolved ( $source, $judgement ) {
    return _of_oracle( 'b2', outcomes( $source, $judgement ) );
}

sub unloaded ( $source, $judgement ) {
    return _of_oracle( 'b3', outcomes( $source, $judgement ) );
}

sub apart ( $source, $judgement ) {
    return _of_oracle( 'apart', outcomes( $source, $judgement ) );
}

# Oracle c: the compiled code of the mutant differs from the compiled code of the original.
# B::Deparse prints no field and no ADJUST block, so a mutant there has nothing to compare.
my $SAME_CODE = 'compiles to the code of the original';

sub equivalent ($judgement) {
    return map { [ $_->{mutant}, $SAME_CODE ] }
      grep { $_->{compiled} && $_->{same_code} && $_->{mutant}->comparable } $judgement->{verdicts}->@*;
}

# At most a limit of the items, spread evenly over their order, so a sample is the same in every run.
sub spread ( $items, $limit ) {
    my $count = $items->@*;
    return $items->@* if !defined $limit || $count <= $limit;
    return map { $items->[ int $_ * $count / $limit ] } 0 .. $limit - 1;
}

sub _in_order (@mutants) {
    my @sorted = sort { $a->start <=> $b->start || $a->end <=> $b->end || $a->id cmp $b->id } @mutants;
    return @sorted;
}

sub _of_each_mutator ( $mutants, $limit ) {
    my %by;
    push $by{ $_->mutator }->@*, $_ for $mutants->@*;
    return [ _in_order( map { spread( $by{$_}, $limit ) } sort keys %by ) ];
}

sub _counts ( $column, @mutants ) {
    my %count;
    $count{ $_->mutator }++ for @mutants;
    return map { [ 'count', $_, $column, $count{$_} ] } sort keys %count;
}

my $EXAMPLE_LENGTH = 160;
my $QUEUE_RECORD   = 8;
my $QUEUE_TASKS    = 8000;
my $PIPE_BYTES     = 65_536;

# The change stays whole however long the path of its file is, and the detail fills the room that is left.
sub _example ( $source, $mutant, $detail ) {
    my $change = sprintf '%s line %d: %s -> %s | ', $source->path, $mutant->from->[0], $mutant->original,
      $mutant->replacement;
    $change =~ s/\s+/ /g;
    my $room = $EXAMPLE_LENGTH > length $change ? $EXAMPLE_LENGTH - length $change : 0;
    return $change . substr $detail =~ s/\s+/ /gr, 0, $room;
}

# The violations of one oracle as records: a count for each mutator, and each class of a mutator once with an example.
sub _violations ( $source, $oracle, $column, @violations ) {
    my ( %seen, @findings );
    for my $violation (@violations) {
        my ( $mutant, $class, $detail ) = $violation->@*;
        my $finding = $mutant->mutator . q{ } . $class;
        next if $seen{$finding}++;
        push @findings, [ 'finding', $oracle, $finding, _example( $source, $mutant, defined $detail ? $detail : q{} ) ];
    }
    return _counts( $column, map { $_->[0] } @violations ), @findings;
}

sub _judgement_records ( $source, $chosen, %arg ) {
    my @wants = ( $arg{wants} || ['calls'] )->@*;

    # The server holds the modules of its walker, and a file may compile with them alone.
    # Plain `perl -c` reads the original once for a file, with the share that samples the accepted mutants.
    my $plain =
      !$arg{accepted} || Judge::reference( $source->to_bytes( $source->text ), include => $arg{include} || [] );
    my @asked     = ( $arg{refused} || [] )->@*;
    my @units     = $plain ? ( $chosen->@*, @asked ) : ();
    my $judgement = eval { judgement( $source, \@units, include => $arg{include}, wants => \@wants ) };
    return [ 'problem', 'judge', 'plain perl -c refuses the original' ]
      if $judgement && !$plain && !defined $judgement->{problem};
    return [ 'problem', 'judge', 'the judge broke', $@ =~ s/\s+/ /gr ] if !$judgement;
    return [ 'problem', 'judge', $judgement->{problem} ] if defined $judgement->{problem};

    my ( $mutants, @refusals ) = asked_apart( $source, $judgement, @asked );
    return ( judged_records( $source, $mutants, @wants ), crossed_records( $source, $mutants, %arg ), @refusals );
}

# One server judges the mutants of the tool and the changes that the tool refused, and each has its own oracle.
# The answer is the judgement of the mutants alone, and after it the records of the refused changes.
sub asked_apart ( $source, $judgement, @asked ) {
    my %asked    = map  { $_->id => 1 } @asked;
    my @refusals = grep { $asked{ $_->{mutant}->id } } $judgement->{verdicts}->@*;
    my $mutants  = { $judgement->%*, verdicts => [ grep { !$asked{ $_->{mutant}->id } } $judgement->{verdicts}->@* ] };
    my $refused  = { verdicts                 => \@refusals };
    return (
        $mutants,
        _counts( 'asked',   map { $_->{mutant} } @refusals ),
        _counts( 'excused', excused_refusals( $source, $refused ) ),
        _violations( $source, 'refusal', 'accepted', accepted_refusals( $source, $refused ) ),
    );
}

# The refusals of a source as records: each rule with its mutator, and the refusals whose text shows no cause.
sub refusal_records ( $source, $made, $candidates ) {
    my %count;
    $count{ $_->{rule} }{ $_->{mutator} }++ for $made->{rejected}->@*;
    my @rules;
    for my $rule ( sort keys %count ) {
        push @rules, map { [ 'refusal', $rule, $_, $count{$rule}{$_} ] } sort keys $count{$rule}->%*;
    }
    return ( @rules, _violations( $source, 'refusal', 'causeless', unjustified( $source, $candidates ) ) );
}

# The cross-check of a judgement as records: the count of the compared verdicts, and a problem for a difference.
sub crossed_records ( $source, $judgement, %arg ) {
    my $crossed = cross_checked( $source, $judgement, include => $arg{include}, accepted => $arg{accepted} );
    my ($first) = $crossed->{differences}->@*;
    return ( [ 'crossed', $crossed->{compared} ],
        defined $first ? [ 'problem', 'cross-check', 'perl -c differs from the server', $first ] : () );
}

# The verdicts of a source as records: the count of the judged mutants and the outcome of each one that perl stops.
sub judged_records ( $source, $judgement, @wants ) {
    my @verdicts = $judgement->{verdicts}->@*;
    my @compared = grep { $_->{compiled} && $_->{mutant}->comparable && !length $_->{undeparsed} } @verdicts;
    my @outcomes = outcomes( $source, $judgement );
    return (
        _counts( 'judged', map { $_->{mutant} } @verdicts ),
        _violations( $source, 'apart', 'apart',      _of_oracle( 'apart', @outcomes ) ),
        _violations( $source, 'b',     'refused',    _of_oracle( 'b',     @outcomes ) ),
        _violations( $source, 'b2',    'unresolved', _of_oracle( 'b2',    @outcomes ) ),
        _counts( 'loaded', map { $_->{mutant} } grep { defined $_->{loaded} } @verdicts ),
        _violations( $source, 'b3', 'unloaded', _of_oracle( 'b3', @outcomes ) ),
        ( grep { $_ eq 'deparse' } @wants )
        ? (
            _counts( 'compared', map { $_->{mutant} } @compared ),
            _violations( $source, 'c', 'equivalent', equivalent($judgement) )
          )
        : (),
    );
}

my $ANALYSIS_SECONDS = 300;

# The records of the oracles that read the text alone: the identity, the span with its patch, and the uniqueness.
sub text_records ( $source, $made, %arg ) {
    my $mutants = $made->{mutants};
    my $patched = _of_each_mutator( $mutants, $arg{patched} );
    return (
        [ 'sites', scalar $made->{sites}->@* ],
        _counts( 'mutants', $mutants->@* ),
        _violations( $source, 'a',       'unchanged', unchanged( $source, $mutants ) ),
        _violations( $source, 'd',       'misplaced', misplaced( $source, $mutants ) ),
        _violations( $source, 'e',       'repeated',  repeated( $source, $mutants ) ),
        _violations( $source, 'literal', 'rebased',   rebased( $source, $mutants ) ),
        _counts( 'patched', $patched->@* ),
        _violations( $source, 'd', 'unpatchable', unpatchable( $source, $patched ) ),
    );
}

# One file through every oracle, as records for the tally and the findings of a run.
# `judged` and `patched` limit the mutants of each mutator that perl judges and that have their patch applied.
# `part` names one of several shares of the mutants that perl judges, and the first share holds every other record.
sub survey ( $path, %arg ) {
    my $source = file_source($path);
    my ( $ended, $made ) = Bounded::ended( $ANALYSIS_SECONDS, sub { return generated($source) } );
    return [ 'problem', 'analysis', 'the analysis does not end' ] if !$ended;
    return [ 'problem', 'analysis', $made->{problem} ]            if defined $made->{problem};
    return survey_made( $source, $made, %arg );
}

# The records of a source for mutants that the caller holds, as the generator made them or as a test built them.
sub survey_made ( $source, $made, %arg ) {
    my ( $part, $parts ) = ( $arg{part} || [ 0, 1 ] )->@*;
    my @chosen = _of_each_mutator( $made->{mutants}, $arg{judged} )->@*;

    # `lines` names lines whose mutants perl judges in every run, whatever the sample holds.
    my %always = map { $_     => 1 } ( $arg{lines} || [] )->@*;
    my %picked = map { $_->id => 1 } @chosen;
    push @chosen, grep { $always{ $_->from->[0] } && !$picked{ $_->id } } $made->{mutants}->@*;
    @chosen = @chosen[ grep { $_ % $parts == $part } 0 .. $#chosen ];
    my $first = $part == 0;

    # The first share replays the proposals of the mutators, so each refusal has its span and meets its own oracle.
    my $candidates = $first && ( $made->{mutators} || [] )->@* ? candidates( $source, $made ) : [];
    my @refused    = _of_each_mutator( [ refusals_for_perl( $source, $candidates ) ], $arg{judged} )->@*;
    return (
        $first ? ( text_records( $source, $made, %arg ), refusal_records( $source, $made, $candidates ) ) : (),
        @chosen || @refused
        ? _judgement_records( $source, \@chosen, %arg, refused => \@refused, accepted => $first ? 1 : 0 )
        : (),
    );
}

# The tasks of a walk that judges a large file in several shares, so its mutants spread over the workers.
sub in_parts ( $bytes_of_a_part, @paths ) {
    my @tasks;
    for my $path (@paths) {
        my $bytes = -s $path;
        my $parts = 1 + int( $bytes / $bytes_of_a_part );
        push @tasks, map { [ $path, part => [ $_, $parts ] ] } 0 .. $parts - 1;
    }
    return @tasks;
}

sub _work ( $write, $queue, $code, $tasks ) {
    while ( sysread $queue, my $index, $QUEUE_RECORD ) {
        my ( $path, @arguments ) = $tasks->[$index]->@*;
        for my $record ( $code->( $path, @arguments ) ) {
            print {$write} join( "\t", $path, map { s/[\t\n]/ /gr } $record->@* ), "\n" or die "write: $!\n";
        }
    }
    close $write or die "close: $!\n";
    return 1;
}

# The tasks wait in a pipe, and each worker takes the next one when it is free, so no worker idles beside a busy one.
# A record of the pipe has a fixed length, and the pipe holds every record before the first worker starts.
sub _queue (@tasks) {
    die 'a walk holds at most ' . $QUEUE_TASKS . " tasks\n" if @tasks > $QUEUE_TASKS;
    pipe my $queue, my $feed or die "pipe: $!\n";
    syswrite $feed, join q{}, map { sprintf "%0${QUEUE_RECORD}d", $_ } 0 .. $#tasks if @tasks;
    close $feed or die "close: $!\n";
    return $queue;
}

# The records that the code returns for every task, each under the path of its task, from worker processes.
# A task is a path, or a path with the arguments that the code takes after it.
# The parent reads every worker at once, so no worker waits with a full pipe.
sub each_file ( $tasks, $workers, $code ) {
    my %size  = map  { $_ => -s $_ || 0 } map { ref ? $_->[0] : $_ } $tasks->@*;
    my @tasks = sort { $size{ $b->[0] } <=> $size{ $a->[0] } || "@$a" cmp "@$b" } map { ref ? $_ : [$_] } $tasks->@*;
    my $queue = _queue(@tasks);
    my ( %pid, %text );
    my $readers = IO::Select->new;
    for my $worker ( 1 .. $workers ) {
        pipe my $read, my $write or die "pipe: $!\n";
        my $pid = fork;
        die "fork: $!\n" if !defined $pid;
        if ( !$pid ) {
            close $read or die "close: $!\n";
            my $done = eval { _work( $write, $queue, $code, \@tasks ) };
            warn $@ if !$done;
            POSIX::_exit( $done ? 0 : 1 );
        }
        close $write or die "close: $!\n";
        $readers->add($read);
        $pid{$read} = $pid;
    }
    my $failed = 0;
    while ( $readers->count ) {
        for my $read ( $readers->can_read ) {
            next if sysread $read, $text{$read}, $PIPE_BYTES, length( $text{$read} || q{} );
            $readers->remove($read);
            waitpid $pid{$read}, 0;
            $failed++ if $?;
        }
    }
    die "a worker of the walk ended badly\n" if $failed;
    my @records = map { [ split /\t/, $_, -1 ] } map { split /\n/ } values %text;
    return [ sort { $a->[0] cmp $b->[0] || "@$a" cmp "@$b" } @records ];
}

# The records of a walk as one tally, the findings of each oracle, and the files of each problem.
sub summary ($records) {
    my %summary = (
        tally    => tally(),
        findings => {},
        problems => {},
        detail   => {},
        refusals => {},
        sites    => 0,
        files    => 0,
        crossed  => 0,
    );
    for my $record ( $records->@* ) {
        my ( $path, $kind, @fields ) = $record->@*;
        if ( $kind eq 'count' || $kind eq 'refusal' ) {
            count( $kind eq 'count' ? $summary{tally} : $summary{refusals}, @fields );
        }
        elsif ( $kind eq 'crossed' || $kind eq 'sites' ) {
            $summary{$kind} += $fields[0];
            $summary{files}++ if $kind eq 'sites';
        }
        elsif ( $kind eq 'finding' ) {
            my ( $oracle, $finding, $example ) = @fields;
            my $seen = $summary{findings}{$oracle}{$finding} ||= { files => 0, example => $example };
            $seen->{files}++;
        }
        else {
            my ( $stage, $reason, $detail ) = @fields;
            push $summary{problems}{"$stage: $reason"}->@*, $path;
            $summary{detail}{"$stage: $reason"} ||= $detail;
        }
    }
    return \%summary;
}

# The rate of a column over a base column for each mutator with a base: the mutator, both counts, and their share.
sub rates ( $tally, $count, $base ) {
    my @rates;
    for my $mutator ( sort keys $tally->%* ) {
        my $whole = $tally->{$mutator}{$base} || 0;
        next if !$whole;
        my $part = $tally->{$mutator}{$count} || 0;
        push @rates, [ $mutator, $part, $whole, $part / $whole ];
    }
    return @rates;
}

# A mutant that compiles to the code of its original, or that no input tells apart, measures its mutator, and no change fixes it.
# The plan places a mutator in the default profile while such a rate stays at its bound, so a finding names a mutator above it.
sub rated ( $tally, $count, $base, $bound, $text, $findings = {} ) {
    my %default =
      map { $_->name => 1 } grep { $_->profile eq 'default' } Test::Mutation::Mutator::Catalog::mutators()->@*;
    my @lines;
    for my $rate ( rates( $tally, $count, $base ) ) {
        my ( $mutator, $part, $whole, $share ) = $rate->@*;
        next if !$default{$mutator} || $share <= $bound;
        my $reason  = "$mutator $text";
        my $line    = sprintf '%s (%d of %d, limit %g%%)', $reason, $part, $whole, 100 * $bound;
        my $finding = $findings->{$reason};
        push @lines, $finding ? "$line, for example $finding->{example}" : $line;
    }
    return \@lines;
}

sub equivalence_findings ( $summary, $bound ) {
    return rated( $summary->{tally}, 'equivalent', 'compared', $bound, $SAME_CODE, $summary->{findings}{c} || {} );
}

# One line for each rule of the generator: how often it refused a change, and for which mutators.
# A rule that fires more often than its defect is common shows here.
sub rules ($summary) {
    my $refusals = $summary->{refusals};
    my @lines;
    for my $rule ( sort keys $refusals->%* ) {
        my $by    = $refusals->{$rule};
        my $total = sum0 values $by->%*;
        push @lines, "refused under $rule: $total (" . join( ', ', map { "$_ $by->{$_}" } sort keys $by->%* ) . ')';
    }
    return @lines;
}

sub found ( $summary, $oracle ) {
    return [ sort keys( ( $summary->{findings}{$oracle} || {} )->%* ) ];
}

sub _in_files ($count) {
    return sprintf 'in %d %s', $count, $count == 1 ? 'file' : 'files';
}

# One line for each finding and each problem, for the reader of the test output.
sub lines ($summary) {
    my @lines;
    for my $oracle ( sort keys $summary->{findings}->%* ) {
        my $findings = $summary->{findings}{$oracle};
        push @lines, map { "$oracle: $_, " . _in_files( $findings->{$_}{files} ) . ", as in $findings->{$_}{example}" }
          sort keys $findings->%*;
    }
    for my $problem ( sort keys $summary->{problems}->%* ) {
        my @paths  = $summary->{problems}{$problem}->@*;
        my $detail = $summary->{detail}{$problem};
        push @lines, "$problem, " . _in_files( scalar @paths ) . ", as in $paths[0]" . ( $detail ? " ($detail)" : q{} );
    }
    return @lines;
}

sub tally () {
    return {};
}

# The columns of the table of a run: each oracle beside the mutants that it read.
sub columns () {
    return qw(
      mutants unchanged:mutants misplaced:mutants repeated:mutants rebased:mutants patched unpatchable:patched
      judged refused:judged unresolved:judged apart:judged loaded unloaded:loaded compared equivalent:compared
      causeless asked accepted:asked excused:asked
    );
}

sub total ($tally) {
    my %total;
    for my $counts ( values $tally->%* ) {
        $total{$_} += $counts->{$_} for keys $counts->%*;
    }
    return \%total;
}

sub count ( $tally, $mutator, $column, $number = 1 ) {
    $tally->{$mutator}{$column} += $number;
    return;
}

sub _cell ( $counts, $column ) {
    my ( $name, $base ) = split /:/, $column;
    my $count = $counts->{$name} || 0;
    return $count if !defined $base;
    my $whole = $counts->{$base} || 0;
    return sprintf '%d (%.1f%%)', $count, $whole ? 100 * $count / $whole : 0;
}

# The rows of a table of counts, one for each mutator and one for their sums.
# A column `name:base` shows its count and the share of the base column that it makes.
sub table ( $tally, @columns ) {
    my @mutators = sort keys $tally->%*;
    my %sum;
    for my $column ( map { split /:/ } @columns ) {
        $sum{$column} = sum0 map { $tally->{$_}{$column} || 0 } @mutators;
    }
    my @rows = ( [ 'mutator', map { s/:.*//r } @columns ] );
    for my $mutator (@mutators) {
        push @rows, [ $mutator, map { _cell( $tally->{$mutator}, $_ ) } @columns ];
    }
    push @rows, [ 'all', map { _cell( \%sum, $_ ) } @columns ];
    my @width;
    for my $index ( 0 .. $#columns + 1 ) {
        push @width, max map { length $_->[$index] } @rows;
    }
    return map { _row( \@width, $_->@* ) } @rows;
}

# The name stands left, the first count stands right, and every other cell stands left under its heading.
sub _row ( $width, @cells ) {
    my $row = join q{  }, sprintf( '%-*s', $width->[0], $cells[0] ), sprintf( '%*s', $width->[1], $cells[1] ),
      map { sprintf '%-*s', $width->[$_], $cells[$_] } 2 .. $#cells;
    return $row =~ s/\s+\z//r;
}

1;
