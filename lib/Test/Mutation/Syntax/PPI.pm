package Test::Mutation::Syntax::PPI;
use v5.36;
use PPI;
use PPIx::QuoteLike;
use PPIx::Regexp;
use Scalar::Util    qw(refaddr);
use Types::Standard qw(ArrayRef Bool InstanceOf Int Maybe Optional Str Tuple);
use Type::Params    qw(signature_for);
use version         ();
use Test::Mutation::Mutator::Providers;
use Test::Mutation::Site;
use Test::Mutation::Suppression;
use Test::Mutation::Syntax::Precedence;
use Test::Mutation::Try;
use Test::Mutation::Types qw(Analysis);

our $VERSION = '0.001';

my $TOKEN  = InstanceOf ['PPI::Token'];
my $BLOCK  = InstanceOf ['PPI::Structure::Block'];
my $NUMBER = InstanceOf ['PPI::Token::Number'];

my %CONDITIONAL  = map { $_ => 1 } qw(if unless while until);
my %MODIFIER     = map { $_ => 1 } qw(if unless while until for foreach);
my %LOOP_CONTROL = map { $_ => 1 } qw(last next redo);
my %DECLARATOR   = map { $_ => 1 } qw(sub method class role package field);
my %CODE_BLOCK_WORD =
  map { $_ => 1 }
  qw(do eval sub map grep first any all none notall try catch finally defer method ADJUST class role else continue
  BEGIN END INIT CHECK UNITCHECK);
my %UNDELETABLE_FIRST_WORD =
  map { $_ => 1 } qw(package class role field method use no my our local state return last next redo goto);
my %BOUNDED_COMPARISON = map { $_ => 1 } qw(< <= > >=);
my %THREE_WAY          = map { $_ => 1 } qw(<=> cmp);
my %EXIT_GUARD         = map { $_ => 1 } qw(or || // and &&);
my %TRANSFER =
  map { $_ => 1 } qw(return next last redo die croak confess exit CORE::die CORE::exit Carp::croak Carp::confess);
my %REMOVABLE_CALL   = map { $_ => 1 } qw(abs int reverse CORE::abs CORE::int CORE::reverse);
my %FILTER           = map { $_ => 1 } qw(grep CORE::grep first List::Util::first List::AllUtils::first);
my %LIST_BLOCK_WORD  = map { $_ => 1 } qw(map grep);
my %DECLARATION      = map { $_ => 1 } qw(my our state);
my %OPEN_BLOCK_HEAD  = map { $_ => 1 } qw(ADJUST if unless while until for foreach);
my %BLOCK_FIRST_HEAD = map { $_ => 1 } qw(finally defer try);
my %NAMED_BLOCK_HEAD = map { $_ => 1 } qw(class role method sub);
my %CONTINUATION     = map { $_ => 1 } qw(elsif else continue catch finally);
my %BODY_HEAD        = map { $_ => 1 } qw(method sub ADJUST);
my %EXCLUDED_HEAD    = map { $_ => 1 } qw(use no package);
my %HIDDEN_HEAD      = map { $_ => 1 } qw(field ADJUST);
my %COMPILE_KEYWORD  = map { $_ => 1 } qw(use no BEGIN UNITCHECK CHECK INIT END);
my %ROUTINE_HEAD     = map { $_ => 1 } qw(sub method);
my %NEVER_A_CALL =
  map { $_ => 1 }
  qw(my our local state sub package class role field method use no return do eval else elsif for foreach
  continue given when default try catch finally defer BEGIN END INIT CHECK UNITCHECK ADJUST
  __PACKAGE__ __FILE__ __LINE__ __SUB__ __CLASS__);

# The operators whose whole right operand the analysis names when it is a number, for the operands that leave a value alone.
my %ARITHMETIC = map { $_ => 1 } qw(+ - * / % **);
my %SHIFT      = map { $_ => 1 } qw(<< >>);

# An operator that has no other use than before its operand, so the parse of its siblings may leave it without a place.
my %ALWAYS_PREFIX = map { $_ => 1 } qw(! ~ ~. not);

# The kinds of the siblings that the table of precedence reads, and every other significant element is a term.
my @ITEM_KIND = (
    [ 'PPI::Token::Operator'      => 'operator' ],
    [ 'PPI::Token::Word'          => 'word' ],
    [ 'PPI::Token::Cast'          => 'cast' ],
    [ 'PPI::Token::Structure'     => 'stop' ],
    [ 'PPI::Token::Label'         => 'stop' ],
    [ 'PPI::Token::Separator'     => 'stop' ],
    [ 'PPI::Structure::Subscript' => 'subscript' ],
    [ 'PPI::Structure::Block'     => 'block' ],
    [ 'PPI::Structure::List'      => 'list' ],
    [ 'PPI::Structure::Condition' => 'list' ],
    [ 'PPI::Structure::For'       => 'list' ],
    [ 'PPI::Structure::Signature' => 'list' ],
);

my @BEFORE_A_SUB_BODY = qw(PPI::Structure::List PPI::Structure::Signature PPI::Token::Prototype PPI::Token::Attribute);
my @REGEX_TOKEN       = qw(PPI::Token::Regexp::Match PPI::Token::Regexp::Substitute PPI::Token::QuoteLike::Regexp);
my %REGEX_ROLE        = (
    'PPIx::Regexp::Token::Assertion'  => 'anchor',
    'PPIx::Regexp::Token::Quantifier' => 'quantifier',
    'PPIx::Regexp::Token::Modifier'   => 'flag',
);
my %ANCHOR = map { $_ => 1 } ( q{^}, q{$}, '\\A', '\\z', '\\Z' );
my %OPEN   = map { $_ => 1 } qw(open CORE::open);

# The bundle of Perl 5.40, in development from 5.39, imports the booleans and the rounding functions of the core.
my $BUNDLE_WITH_BUILTINS = version->parse('v5.39.0');
my %LITERAL_WORD         = map { $_ => 1 } qw(__PACKAGE__ __FILE__ __LINE__ __CLASS__ true false);
my @LITERAL              = qw(PPI::Token::Number PPI::Token::Quote PPI::Token::Operator);

signature_for analyze => ( positional => [ InstanceOf ['Test::Mutation::Source'] ], returns => Analysis );

sub analyze ($source) {
    my $text = $source->text;

    # Perl skips a byte order mark and PPI rejects it, so the parser reads the text after the mark.
    my $mark = $text =~ /\A\x{feff}/ ? 1 : 0;

    # PPI ends a line at its line feed, and a line keeps its columns without the carriage return before the feed.
    my $copy = substr( $text, $mark ) =~ s/\r\n/\n/gr;
    return _problem('the file has a carriage return without a line feed') if $copy =~ /\r/;
    my $document = _document($copy);
    if ( !$document ) {
        my $reason = PPI::Document->errstr;
        return _problem( 'PPI cannot parse the file: ' . ( defined $reason ? $reason : 'unknown error' ) );
    }
    _split_subtractions($document);
    return _problem('PPI does not reproduce the file') if $document->serialize ne $copy;

    my $context = {
        source  => $source,
        text    => $text,
        mark    => $mark,
        lines   => 1 + ( $text =~ tr/\n// ),
        scopes  => {},
        sites   => [],
        dropped => []
    };
    $context->{misread} = _misread_readlines($document);
    $context->{values}  = _value_spans( $context, $document );
    my $names = _names( $document, $context );
    _visit( $context, $document, 0 );
    my @sites    = sort { $a->start <=> $b->start || $a->end <=> $b->end } $context->{sites}->@*;
    my $heredocs = _heredocs( $context, $document );
    return {
        sites        => \@sites,
        suppressions => _suppressions( $context, $document ),
        dropped      => $context->{dropped},
        heredocs     => $heredocs,
        names        => $names,
        problem      => undef
    };
}

signature_for inside_begin => ( positional => [ InstanceOf ['Test::Mutation::Source'], Int ], returns => Bool );

sub inside_begin ( $source, $offset ) {
    my $text     = $source->text;
    my $mark     = $text =~ s/\A\x{feff}// ? 1 : 0;
    my $document = _document($text) or return 0;
    my $context  = { source => $source, text => $source->text, mark => $mark };
    for my $block ( @{ $document->find('PPI::Statement::Scheduled') || [] } ) {
        next unless $block->type eq 'BEGIN';
        my $first = _offset( $context, $block->first_token );
        my $last  = _offset( $context, $block->last_token );
        return 1 if defined $first && defined $last && $first <= $offset && $offset <= $last;
    }
    return 0;
}

my $COMPILE_DIRECTIVE = qr/\b(?:BEGIN|UNITCHECK|CHECK|use|no)\b/;

signature_for compile_reads =>
  ( positional => [ Str, Bool, { default => 0 } ], returns => Maybe [ ArrayRef [ Tuple [ Str, Str ] ] ] );

sub compile_reads ( $source, $loaded ) {
    return [] unless $loaded || $source =~ $COMPILE_DIRECTIVE;
    my $document = _document($source) or return;
    return if $loaded && !_fixed_module_load($document);
    return if _embedded_phase($document);
    my @reads;
    for my $phase ( @{ $document->find('PPI::Statement::Scheduled') || [] } ) {
        next unless $phase->type =~ /\A(?:BEGIN|UNITCHECK|CHECK)\z/;
        my $body = $phase->block or return;
        my %handles;
        for my $statement ( $body->schildren ) {
            my $text = join q{ }, map { $_->content } grep { $_->significant } $statement->tokens;
            $text =~ s/(?: \s+ | \A ) ; \z//x;
            next if _known_phase_statement( $text, \%handles, \@reads );
            return;
        }
    }
    if ( $loaded || @reads ) {
        return
          if grep { $_->type ne 'require' && !_fixed_import($_) } @{ $document->find('PPI::Statement::Include') || [] };
    }
    return \@reads;
}

sub _embedded_phase ($document) {
    for my $token ( $document->tokens ) {
        my $text = $token->isa('PPI::Token::HereDoc') ? join( q{}, $token->heredoc ) : $token->content;
        next unless $text =~ $COMPILE_DIRECTIVE;
        my $quoted = PPIx::QuoteLike->handles($token);
        next unless $quoted || grep { $token->isa($_) } @REGEX_TOKEN;
        my $parsed = _parsed_quote( $quoted ? 'PPIx::QuoteLike' : 'PPIx::Regexp', $token ) or return 1;
        for my $part ( $quoted ? $parsed->children : $parsed->tokens ) {
            next unless $part->can('ppi') && $part->content =~ $COMPILE_DIRECTIVE;
            my $inner = $part->ppi or return 1;
            return 1 if $inner->find_first( \&_embedded_keyword );
            return 1 if _embedded_phase($inner);
        }
    }
    return 0;
}

sub _embedded_keyword ( $document, $element ) {
    return 0 unless _is_word( $element, \%COMPILE_KEYWORD );
    my $subscript = $element->parent->parent;
    return 1 unless ref $subscript eq 'PPI::Structure::Subscript';
    my $key = join q{}, map { $_->content } grep { $_->significant } $subscript->tokens;
    return $key ne '{' . $element->content . '}';
}

sub _fixed_module_load ($document) {
    my $native_class = 0;
    for my $statement ( $document->schildren ) {
        if ( $statement->isa('PPI::Statement::Sub') ) {
            my $name = $statement->name || q{};
            return 0 if $name =~ /(?:\A|::) (?:import|unimport|AUTOLOAD|DESTROY) \z/x;
        }
        if ( $statement->isa('PPI::Statement::Include') && _fixed_import($statement) ) {
            $native_class = _class_feature( $statement, $native_class );
            next;
        }
        next unless _runs_at_load($statement);
        next if $native_class && _fixed_class_load($statement);
        my @value = grep { !_is_semicolon($_) } $statement->schildren;
        return 0 unless @value == 1 && $value[0]->isa('PPI::Token::Number');
    }
    return 1;
}

sub _class_feature ( $statement, $enabled ) {
    my $module = $statement->module || q{};
    my $type   = $statement->type;
    return 0 if !$module && $type eq 'use';
    return $enabled unless $module eq 'feature' || $module eq 'experimental';
    my @arguments = $statement->arguments;
    my @features  = map { $_->literal }
      grep { $_->isa('PPI::Token::Quote::Single') || $_->isa('PPI::Token::QuoteLike::Words') } @arguments;
    return $type eq 'use' if grep { $_ eq 'class' } @features;
    return 0 if $module eq 'feature' && $type eq 'no' && ( !@arguments || grep { $_ eq ':all' } @features );
    return $enabled;
}

sub _fixed_class_load ($statement) {
    for my $segment ( _segments( {}, $statement )->@* ) {
        my @parts = grep { !_is_semicolon($_) } $segment->{children}->@*;
        return 0 unless _fixed_class_segment(@parts);
    }
    return 1;
}

sub _fixed_class_segment ( $keyword = undef, $name = undef, @rest ) {
    return 1 unless defined $keyword;
    return 1 if $NUMBER->check($keyword) && !defined $name;
    return 0 unless _is_word( $keyword, { class => 1 } ) && _is_name($name);
    shift @rest if $NUMBER->check( $rest[0] );
    my ($block) = @rest;
    return 0 unless @rest == 1 && $BLOCK->check($block);

    # PPI can group a compile-time directive with the method declared immediately before it.
    return 0 if $block->find_first( sub ( $document, $element ) { _is_word( $element, \%COMPILE_KEYWORD ) } );
    for my $member ( $block->schildren ) {
        return 0 unless ref $member eq 'PPI::Statement';
        for my $segment ( _segments( {}, $member )->@* ) {
            my @parts = grep { !_is_semicolon($_) } $segment->{children}->@*;
            return 0 if @parts && !_deferred_class_member(@parts);
        }
    }
    return 1;
}

sub _deferred_class_member ( $keyword, $next = undef, @rest ) {
    return 0 unless $next;
    return 1 if _is_word( $keyword, { field => 1 } ) && $next->isa('PPI::Token::Symbol');
    return 1 if _is_word( $keyword, { ADJUST => 1 } ) && $next->isa('PPI::Structure::Block') && !@rest;
    return 0 unless _is_word( $keyword, { method => 1 } ) && _is_name($next);
    return 0 if $next->content =~ /\A(?:import|unimport|AUTOLOAD|DESTROY)\z/;
    return 1 unless @rest;
    shift @rest if $rest[0]->isa('PPI::Structure::List');
    return @rest == 1 && $rest[0]->isa('PPI::Structure::Block');
}

sub _fixed_import ($include) {
    my $module = $include->module   || q{};
    return 0 unless length($module) || $include->version;
    my @arguments = $include->arguments;
    return 1 unless @arguments;
    return 1 if @arguments == 1 && $arguments[0]->isa('PPI::Structure::List') && !$arguments[0]->schild(0);
    return 1 if $module eq 'constant' && ( join q{ }, map { $_->content } @arguments ) =~ /\A[a-zA-Z_]\w* => [0-9]+\z/;
    my $text        = join q{}, map { $_->content } @arguments;
    my $environment = qr{\$ENV\{\s*[a-zA-Z_]\w*\s*\}};
    return 1 if $module eq 'lib' && $text =~ /\A$environment(?:,$environment)*\z/;
    return !grep {
             !_is_operator( $_, q{,} )
          && !$_->isa('PPI::Token::Quote::Single')
          && !$_->isa('PPI::Token::QuoteLike::Words')
          && !$_->isa('PPI::Token::Number')
    } @arguments;
}

sub _known_phase_statement ( $text, $handles, $reads ) {
    my $variable = qr{\$[a-zA-Z_]\w*};
    my $literal  = qr{(?: '[^'\\]*' | "[^"\$\@\\]*" )}x;
    my $operand  = qr{(?: $literal | \$ENV \s \{ \s [a-zA-Z_]\w* \s \} )}x;
    return 1 if $text =~ /\A (?:unshift|push) \s \@INC \s , \s $operand (?:\s , \s $operand)* \z/x;
    my $ends       = qr{(?: \s (?:or|\|\|) \s (?:CORE::)?die \s \$! )?}x;
    my $filehandle = qr{(?: \( \s )? (?:my \s)? ($variable) \s , \s}x;
    my $read_mode  = qr{(?: '<(?::raw)?' | "<(?::raw)?" ) \s , \s}x;
    if ( $text =~ m{\A (?:CORE::)?open \s $filehandle $read_mode ($operand) (?: \s \) )? $ends \z}x ) {
        my ( $handle, $path ) = ( $1, $2 );
        $handles->{$handle} = 1;
        push @$reads, $path =~ /\A\$ENV \{ (\w+) \}\z/ ? [ env => $1 ] : [ file => substr( $path, 1, -1 ) ];
        return 1;
    }
    return 1 if $text eq q{} || $text eq 'require constant';
    my $message   = qr{(?: '[^'\\]*' | "(?: [^"\$\@\\] | \\[nrt"\\] )*" )}x;
    my $number    = qr{[0-9]+(?:[.][0-9]+)?};
    my $operation = qr{(?: [+*/%<>-] | [!=<>]= )}x;
    my $guard     = qr{$number (?: \s $operation \s $number )*}x;
    return 1 if $text =~ /\A (?:CORE::)?die \s $message \s (?:if|unless) \s $guard \z/x;
    return 1 if $text =~ /\A constant \s -> \s import \s \( \s $literal \s , \s $variable \s \) \z/x;

    if ( $text =~ /\A(?:CORE::)?close ($variable)$ends\z/ ) {
        return $handles->{$1};
    }
    my $expression = $text;
    $expression =~ s{\A(?:my )?$variable = }{} or return;
    my $atom = qr{(?:$variable|\d+(?:[.]\d+)?|$literal)};
    return 1 if $expression =~ /\A$atom(?: [+\/*%-] $atom)*\z/;
    if ( $expression =~ /\A (?:$atom \s [+\/*%-] \s)? < \s* ($variable) \s* > \z/x ) {
        return $handles->{$1};
    }
    return;
}

signature_for witness_offsets =>
  ( positional => [ InstanceOf ['Test::Mutation::Source'] ], returns => Maybe [ Tuple [ Int, Int, Optional [Int] ] ] );

sub witness_offsets ($source) {
    my $text     = $source->text;
    my $mark     = $text =~ s/\A\x{feff}// ? 1 : 0;
    my $document = _document($text) or return;
    my @tokens   = map { $_->first_token || () }
      grep { $_->isa('PPI::Statement') && !$_->isa('PPI::Statement::Data') && !$_->isa('PPI::Statement::End') }
      $document->schildren;
    return unless @tokens;
    my $at = sub ($token) {
        my ( $line, $column ) = $token->location->@[ 0, 1 ];
        return $source->offset_of( $line, $column ) + ( $line == 1 ? $mark : 0 );
    };
    my @edges = map { $at->($_) } @tokens[ 0, -1 ];
    if ( $text =~ /\n[#]![^\n]*\bperl\b/ ) {
        my $extract;
        for my $token ( $document->tokens ) {
            if ( $extract && $token->significant ) {
                my $offset = $at->($token);
                push @edges, $offset if $edges[0] < $offset && $offset <= $edges[1];
                last;
            }
            $extract = 1 if $token->isa('PPI::Token::Comment') && $token->content =~ /\A[#]![^\n]*\bperl\b/;
        }
    }
    return \@edges;
}

sub _problem ($message) {
    return {
        sites        => [],
        suppressions => { directives => [], refusals => [] },
        dropped      => [],
        heredocs     => [],
        names        => { imports => [], declared => [] },
        problem      => $message
    };
}

# A module can return a calculated value before trailing declarations or a data section.
sub _value_spans ( $context, $document ) {
    my @statements = $document->schildren;
    my ($last)     = grep { _runs_at_load($_) } reverse @statements;
    my @values     = grep {
        ref $_ eq 'PPI::Statement'
          && ( _is_value($_) || $last && refaddr($_) == refaddr($last) && _computed_value( $_, $context->{misread} ) )
    } @statements;

    # A statement whose place holds another text has no span, and it is among the places left out.
    return [ grep { $_->@* } map { [ _whole_span( $context, $_->schildren ) ] } @values ];
}

sub _runs_at_load ($statement) {
    return 0
      if grep { $statement->isa($_) }
      qw(PPI::Statement::Sub PPI::Statement::End PPI::Statement::Data PPI::Statement::Null);
    return $statement->type eq 'require' if $statement->isa('PPI::Statement::Include');
    return scalar grep { $_->isa('PPI::Structure::Block') } $statement->schildren
      if $statement->isa('PPI::Statement::Package');
    return $statement->isa('PPI::Statement');
}

sub _computed_value ( $statement, $readlines ) {
    my @parts = grep { !_is_semicolon($_) } $statement->schildren;
    if ( @parts == 1 && $parts[0]->isa('PPI::Structure::List') ) {
        return scalar grep { _computed_value( $_, $readlines ) } $parts[0]->schildren;
    }
    my $parsed = _parsed( $statement, $readlines );
    my $end    = grep { $_->{kind} ne 'stop' } $parsed->{units}->@*;
    for my $at ( keys $parsed->{records}->@* ) {
        my $op = $parsed->{records}[$at] or next;
        next unless $op->{position} eq 'infix' && $op->{before}[0] == 0 && $op->{after} && $op->{after}[1] == $end;
        return $parsed->{units}[$at]{text} ne '->';
    }
    return 0;
}

sub _whole_span ( $context, @children ) {
    return _span( $context, _edge_tokens( @children[ 0, -1 ] ) );
}

sub _is_value ($statement) {
    return !grep { !_is_semicolon($_) && !_is_literal($_) } $statement->schildren;
}

sub _is_literal ($element) {
    return 1 if grep { $element->isa($_) } @LITERAL;
    return $element->isa('PPI::Token::Word') && $LITERAL_WORD{ $element->content } ? 1 : 0;
}

# PPI reads <$handle> in some places as two comparisons around a name.
# No comparison lacks its right operand, so a ">" without one ends a readline, and the nearest "<" before it starts it.
# The opening token counts the following siblings that form one operand.
sub _misread_readlines ($document) {
    my %inside;
    my @ends = grep { $_->content eq '>' && _lacks_operand( scalar $_->snext_sibling ) }
      @{ $document->find('PPI::Token::Operator') || [] };
    for my $end (@ends) {
        my @siblings = $end->parent->schildren;
        my ($last)   = grep { refaddr $siblings[$_] == refaddr $end } 0 .. $#siblings;
        my ($first)  = grep { _starts_readline( $siblings[$_] ) } reverse 0 .. $last;
        next if !defined $first;
        $inside{ refaddr $_ } = 0 for map { $_->isa('PPI::Token') ? $_ : $_->tokens } @siblings[ $first .. $last ];
        $inside{ refaddr $siblings[$first] } = $last - $first;
    }
    return \%inside;
}

sub _starts_readline ($element) {
    return $element->isa('PPI::Token::Operator') && $element->content eq '<' ? 1 : 0;
}

# An operand starts with a name, a value, a bracket, or an operator that the table of precedence places before its operand.
sub _lacks_operand ($next) {
    return 1 if !$next || _is_semicolon($next) || _is_word( $next, \%MODIFIER );
    return $next->isa('PPI::Token::Operator')
      && !Test::Mutation::Syntax::Precedence::starts_operand( $next->content )
      ? 1
      : 0;
}

sub _line_offset ( $context, $line ) {
    return $line > $context->{lines} ? length $context->{text} : $context->{source}->offset_of( $line, 1 );
}

# The text of a here-document starts on the line after its introducer, behind the text of an earlier one of that line.
# The lines of the file give its extent, because PPI strips the indentation of an indented here-document.
sub _heredocs ( $context, $document ) {
    my ( %taken, @heredocs );
    for my $token ( @{ $document->find('PPI::Token::HereDoc') || [] } ) {
        my $from = _offset( $context, $token );
        next if !defined $from;
        my $line  = $token->location->[0];
        my $first = $line + 1 + ( $taken{$line} || 0 );
        my @text  = $token->heredoc;
        my $after = $first + @text;
        my $start = _line_offset( $context, $after );
        my $last  = substr $context->{text}, $start, _line_offset( $context, $after + 1 ) - $start;
        $last =~ s/\A\s+|\s+\z//g;
        $after++ if $last eq $token->terminator;
        $taken{$line} += $after - $first;
        push @heredocs,
          [ $from, $from + length $token->content, _line_offset( $context, $first ), _line_offset( $context, $after ) ];
    }
    return \@heredocs;
}

sub _listed_items ($token) {
    return $token->literal if $token->isa('PPI::Token::QuoteLike::Words');
    return $token->string  if $token->isa('PPI::Token::Quote');
    return;
}

# The module of a use statement and the names it imports, as far as the text of the statement tells.
sub _imported ($include) {
    my $version = $include->version;
    if ( length $version ) {
        return if !version::is_lax($version) || version->parse($version) < $BUNDLE_WITH_BUILTINS;
        return ( 'builtin', Test::Mutation::Mutator::Providers::listed( 'builtin', ':5.40' )->@* );
    }
    my $module    = $include->module or return;
    my @arguments = $include->arguments;
    return ( $module, Test::Mutation::Mutator::Providers::default_exports($module)->@* ) if !@arguments;
    return ( $module, map { Test::Mutation::Mutator::Providers::listed( $module, $_ )->@* }
          map { _listed_items($_) } @arguments );
}

# The names of subroutines that the file resolves: what each of its use statements imports, and what it declares.
sub _names ( $document, $context ) {
    my @imports;
    for my $include ( grep { $_->type eq 'use' } @{ $document->find('PPI::Statement::Include') || [] } ) {
        my ( $module, @names ) = _imported($include);
        push @imports, { module => $module, names => \@names } if @names;
    }
    my @subs     = grep { !$_->isa('PPI::Statement::Scheduled') } @{ $document->find('PPI::Statement::Sub') || [] };
    my %declared = map  { ( $_ => 1 ) } grep { defined } map { $_->name } @subs;
    my %by_package;
    for my $sub (@subs) {
        my $name = $sub->name;
        next if !defined $name || defined $sub->type;
        my @parts    = split /::/, $name;
        my $short    = pop @parts;
        my $scope    = @parts ? join( '::', @parts ) : _package_of($sub);
        my $function = $by_package{$scope}{$short} ||= {};
        $function->{defined}                     = 1 if $sub->block;
        $context->{declarations}{ refaddr $sub } = $function;
        $context->{local_subs}{$short}{$scope}   = $by_package{$scope};
    }
    return { imports => \@imports, declared => [ sort keys %declared ] };
}

sub _package_of ($node) {
    for ( my $part = $node ; $part ; $part = $part->parent ) {
        return $part->namespace if $part->isa('PPI::Statement::Package');
        for ( my $prior = $part->sprevious_sibling ; $prior ; $prior = $prior->sprevious_sibling ) {
            return $prior->namespace
              if $prior->isa('PPI::Statement::Package')
              && !grep { $_->isa('PPI::Structure::Block') } $prior->schildren;
        }
    }
    return 'main';
}

# PPI learns from a few pragmas that a file uses signatures, and it reads the signature of another file as a prototype.
# A prototype holds no letter, so a letter there means a signature, and PPI reads the file again with signatures on.
sub _document ($copy) {
    my $document = PPI::Document->new( \$copy ) or return;
    my $letters  = grep { $_->content =~ /[[:alpha:]]/ } @{ $document->find('PPI::Token::Prototype') || [] };
    return $letters ? PPI::Document->new( \$copy, feature_mods => { signatures => 1 } ) : $document;
}

# PPI can attach a subtraction sign after a completed operand to the following number.
sub _split_subtractions ($document) {
    for my $number ( @{ $document->find('PPI::Token::Number') || [] } ) {
        my $text = $number->content;
        next if substr( $text, 0, 1 ) ne q{-};
        next unless _ends_operand( scalar $number->sprevious_sibling );
        $number->insert_before( PPI::Token::Operator->new(q{-}) );
        $number->set_content( substr $text, 1 );
    }
    return;
}

sub _ends_operand ($element) {
    return 0 if !$element;
    return 1
      if grep { $element->isa($_) }
      qw(PPI::Structure::Subscript PPI::Structure::List PPI::Structure::Condition PPI::Structure::Constructor);
    return 1 if _is_operator( $element, '++', '--' );
    return $element->isa('PPI::Token::Cast') && _is_operator( scalar $element->sprevious_sibling, '->' );
}

# A place that yields no site is a place without mutants, so each one is kept for the report of the run.
# The analysis may ask for the place of one token more than once, and the token counts once, where it first came up.
sub _drop ( $context, $token, $kind, $reason ) {
    return if $context->{is_dropped}{ refaddr $token };
    $context->{is_dropped}{ refaddr $token } = 1;
    my $location = $token->location;
    push $context->{dropped}->@*, { line => $location ? $location->[0] : 0, kind => $kind, reason => $reason };
    return;
}

sub _visit ( $context, $element, $excluded ) {
    if ( $element->isa('PPI::Token') ) {
        _token_site( $context, $element ) if !$excluded && $element->significant;
        return;
    }

    # An anonymous subroutine can run after the enclosing import has finished.
    $excluded = 0 if $excluded && _is_anonymous_body($element);
    if ( my $function = $context->{declarations}{ refaddr $element } ) {
        $function->{visible} = 1;
    }
    return _visit_segments( $context, $element, $excluded ) if ref $element eq 'PPI::Statement';
    return
      if !$excluded && $element->isa('PPI::Statement::Include') && _visit_constants( $context, $element->schildren );
    my $skip = $excluded || _excluded($element);
    _structure_sites( $context, $element ) if !$skip;

    # The name and the version of a package hold no behavior, and its block holds ordinary code.
    my $package = $element->isa('PPI::Statement::Package');
    for my $child ( $element->children ) {
        my $apart = $skip || ( $package && !$child->isa('PPI::Structure::Block') );
        _visit( $context, $child, $apart );
    }
    return;
}

sub _is_anonymous_body ($element) {
    return 0 if !$element->isa('PPI::Structure::Block');
    my $before = $element->sprevious_sibling;
    $before = $before->sprevious_sibling while $before && grep { $before->isa($_) } @BEFORE_A_SUB_BODY;
    return 0 if !_is_word( $before, { sub => 1 } );

    # A named subroutine is a statement of its own, and its name stands between the word and the block.
    return $element->parent->isa('PPI::Statement::Sub') ? 0 : 1;
}

sub _visit_segments ( $context, $statement, $excluded ) {
    my $parent = $statement->parent;
    my $runs =
      $parent->isa('PPI::Document') || ( $parent->isa('PPI::Structure::Block') && _is_code_block( $context, $parent ) );
    for my $segment ( _segments( $context, $statement )->@* ) {
        my @children = $segment->{children}->@*;
        return if !$excluded && _visit_constants( $context, @children );
        my $skip = $excluded || _is_word( $children[0], \%EXCLUDED_HEAD ) || _holds_version(@children);

        # B::Deparse prints neither a field nor an ADJUST block.
        local $context->{hidden} = 1 if _is_word( $children[0], \%HIDDEN_HEAD );
        if ( !$skip ) {
            _body_site( $context, $segment );
            _return_site( $context, _segment_scope($segment), @children );
            _statement_site( $context, $segment ) if $runs;
        }
        my %header = map { refaddr($_) => 1 } _header($segment);
        _visit( $context, $_, $skip || $header{ refaddr $_ } ) for @children;
    }
    return;
}

sub _visit_constants ( $context, $keyword, $module = undef, @arguments ) {
    return 0 unless _is_word( $keyword, { 'use' => 1 } ) && _is_word( $module, { constant => 1 } );
    shift @arguments if @arguments && $arguments[0]->isa('PPI::Token::Number');
    @arguments = grep { !_is_semicolon($_) } @arguments;
    while ( @arguments == 1 && $arguments[0]->isa('PPI::Structure::List') ) {
        @arguments = map { $_->schildren } $arguments[0]->schildren;
    }
    my ( $name, $separator, @values ) = @arguments;
    if ( _is_operator( $separator, q{,}, '=>' ) ) {
        _visit( $context, $_, 0 ) for @values;
        return 1;
    }
    return 0 if !$name || !$name->isa('PPI::Structure::Constructor');
    for my $pairs ( $name->schildren ) {
        my $value = 0;
        for my $element ( $pairs->schildren ) {
            if ( _is_operator( $element, q{,} ) ) {
                $value = !$value;
            }
            elsif ( !$value && _is_operator( $element, '=>' ) ) {
                $value = 1;
            }
            elsif ($value) {
                _visit( $context, $element, 0 );
            }
        }
    }
    return 1;
}

# The name, the version, and the attributes of a declaration hold no behavior to change.
sub _header ($segment) {
    my ( $head, @rest ) = $segment->{children}->@*;
    if ( $segment->{closes} && _is_word( $head, \%NAMED_BLOCK_HEAD ) ) {
        my $kept = _is_word( $head, { class => 1, role => 1 } ) ? 'PPI::Structure::Block' : 'PPI::Structure';
        return grep { !$_->isa($kept) } @rest;
    }
    return if !_is_word( $head, { field => 1 } );
    my ($stop) = grep { _is_semicolon( $rest[$_] ) || _is_operator( $rest[$_], q{=}, '//=', '||=' ) } 1 .. $#rest;
    return @rest[ 1 .. ( defined $stop ? $stop : scalar @rest ) - 1 ];
}

sub _is_word ( $element, $words ) {
    return $element && $element->isa('PPI::Token::Word') && $words->{ $element->content } ? 1 : 0;
}

sub _is_semicolon ($element) {
    return $element->isa('PPI::Token::Structure') ? 1 : 0;
}

sub _ends_at_block ( $head, $next, $after ) {
    return 1                                                    if _is_word( $head,  \%OPEN_BLOCK_HEAD );
    return $next && $next->isa('PPI::Structure::Block') ? 1 : 0 if _is_word( $head,  \%BLOCK_FIRST_HEAD );
    return 0                                                    if !_is_word( $head, \%NAMED_BLOCK_HEAD );

    # PPI reads a name before an attribute, as in "method name :lvalue", as a label.
    return 1 if $next && $next->isa('PPI::Token::Label');
    return _is_name($next) && !_is_operator( $after, '=>', q{,} ) ? 1 : 0;
}

# PPI ends a statement it does not know, such as a method or a defer block, at the next semicolon.
sub _segments ( $context, $statement ) {
    my @children = $statement->schildren;
    my @segments;
    while (@children) {
        my @part = shift @children;
        my ( $next, $after ) = @children;
        my $closes = _ends_at_block( $part[0], $next, $after );
        while (@children) {
            push @part, shift @children;
            last if $closes && $part[-1]->isa('PPI::Structure::Block') && !_is_word( $children[0], \%CONTINUATION );
        }
        my $segment = { children => \@part, closes => $closes };
        $context->{segment_of}{ refaddr $_ } = $segment for @part;
        push @segments, $segment;
    }
    return \@segments;
}

sub _segment_of ( $context, $statement, $element ) {
    my $child = $element;
    while ( my $parent = $child->parent ) {
        return $context->{segment_of}{ refaddr $child } if refaddr($parent) == refaddr $statement;
        $child = $parent;
    }
    return;
}

sub _segment_scope ($segment) {
    return $segment->{scope} ||= _scope_lines( _edge_tokens( $segment->{children}->@[ 0, -1 ] ) );
}

sub _scope_lines ( $first, $last ) {
    my $from = $first->location or return;
    my $to   = $last->location  or return;
    return [ $from->[0], $to->[0] ];
}

sub _edge_tokens ( $first, $last ) {
    return (
        $first->isa('PPI::Token') ? $first : $first->first_token,
        $last->isa('PPI::Token')  ? $last  : $last->last_token
    );
}

sub _excluded ($node) {
    return 1 if $node->isa('PPI::Statement::Include');
    return 0 if !$node->isa('PPI::Statement');
    return _holds_version( $node->schildren );
}

sub _holds_version (@children) {
    return scalar grep { $_->isa('PPI::Token::Symbol') && $_->content eq '$VERSION' } @children;
}

sub _offset ( $context, $token ) {
    my $location = $token->location or return;
    my $offset   = $context->{source}->offset_of( $location->[0], $location->[1] );
    $offset += $context->{mark} if $location->[0] == 1;
    my $content = $token->content;
    return $offset if substr( $context->{text}, $offset, length $content ) eq $content;
    _drop( $context, $token, 'span', 'the text at the place differs from the token' );
    return;
}

sub _span ( $context, $first, $last ) {
    my $start = _offset( $context, $first );
    my $end   = _offset( $context, $last );
    return if !defined $start || !defined $end;
    return ( $start, $end + length $last->content );
}

sub _add ( $context, %site ) {
    $site{text}       = substr $context->{text}, $site{start}, $site{end} - $site{start};
    $site{comparable} = $context->{hidden} ? 0 : 1;
    $site{facts}      = { ( $site{facts} || {} )->%*, final_value => 1 }
      if grep { $site{start} >= $_->[0] && $site{end} <= $_->[1] } $context->{values}->@*;
    push $context->{sites}->@*, Test::Mutation::Site->new(%site);
    return;
}

sub _parsed_quote ( $parser, $content ) {
    my $parsed =
      Test::Mutation::Try::attempt( sub { return $parser->new( $content, index_locations => 0 ) || 0 } )->{value};
    return if !$parsed || $parsed->failures;
    return $parsed;
}

sub _regex_sites ( $context, $token ) {
    my ( $start, $end ) = _span( $context, $token, $token ) or return;
    my $scope   = _scope( $context, $token ) or return;
    my $content = $token->content;
    my $regex   = _parsed_quote( 'PPIx::Regexp', $content );
    my @parts   = $regex ? $regex->tokens : ();
    return _drop( $context, $token, 'regex', 'the pattern does not parse' )
      if join( q{}, map { $_->content } @parts ) ne $content;

    my $offset = $start;
    for my $part (@parts) {
        my $text = $part->content;
        my $from = $offset;
        $offset += length $text;
        if ( my $width = _regex_class_width($part) ) {
            _add( $context, kind => 'regex', role => 'class', start => $from, end => $from + $width, scope => $scope );
            next;
        }
        if (   $part->isa('PPIx::Regexp::Token::GroupType::Modifier')
            || $part->isa('PPIx::Regexp::Token::Modifier') && $text =~ /\A\(\?/ )
        {
            _add( $context, kind => 'regex', role => 'modifier', start => $from, end => $offset, scope => $scope )
              if $text =~ /[ims]/;
            next;
        }
        my $role = $REGEX_ROLE{ ref $part } or next;
        if ( $role eq 'flag' ) {
            _regex_flags( $context, $token, $scope, $text, $from );
        }
        else {
            next if $role eq 'anchor' && !$ANCHOR{$text};
            my $next = $role eq 'anchor' ? $part->snext_sibling : undef;
            _add(
                $context,
                kind  => 'regex',
                start => $from,
                end   => $from + length $text,
                role  => $role,
                scope => $scope,
                $next && $next->is_quantifier ? ( facts => { quantified => 1 } ) : ()
            );
        }
    }
    return;
}

sub _regex_class_width ($part) {
    my $text = $part->content;
    return length $text if $part->isa('PPIx::Regexp::Token::CharClass::Simple') && $text =~ /\A\\[dDsSwW]\z/;
    return unless $text eq '[' && $part->isa('PPIx::Regexp::Token::Structure');
    my $class = $part->parent;
    return if !$class->isa('PPIx::Regexp::Structure::CharClass') || _interpolated_index($class);
    return length $class->content;
}

sub _regex_flags ( $context, $token, $scope, $text, $from ) {
    while ( $text =~ /([imsg])/g ) {
        next if $1 eq 'g' && !$token->isa('PPI::Token::Regexp::Substitute');
        my $at = $from + $-[0];
        _add( $context, kind => 'regex', role => 'flag', start => $at, end => $at + 1, scope => $scope );
    }
    return;
}

sub _interpolated_index ($class) {
    my $tip = $class->previous_sibling;
    return 0 unless $tip && $tip->content eq '>';
    my $dash = $tip->previous_sibling;
    return 0 unless $dash && $dash->content eq '-';
    my $value = $dash->previous_sibling;
    return $value && $value->isa('PPIx::Regexp::Token::Interpolation') && $value->content !~ /\A[\$\@]\{/;
}

sub _token_site ( $context, $token ) {
    return                                      if exists $context->{misread}{ refaddr $token };
    return _collection_site( $context, $token ) if $token->isa('PPI::Token::QuoteLike::Words') && $token->literal;
    return _regex_sites( $context, $token )     if grep { $token->isa($_) } @REGEX_TOKEN;
    return _operator_site( $context, $token )   if $token->isa('PPI::Token::Operator');
    my $kind = _literal_kind($token);
    return if !defined $kind;

    my ( $start, $end ) = _span( $context, $token, $token ) or return;
    my $scope = _scope( $context, $token ) or return;
    my $role  = $kind eq 'word' ? _word_role( $context, $token ) : q{};
    return                                   if $kind eq 'word' && $role eq q{};
    _modifier_condition( $context, $token )  if $role eq 'modifier';
    $role = 'open-mode'                      if $kind eq 'string' && _open_mode($token);
    _filter_site( $context, $token, $scope ) if $role eq 'call' && $FILTER{ $token->content };
    my $facts = $role eq 'call' ? _local_calls( $context, $token ) : {};
    $facts->{has_argument} = _has_argument( $context, $token ) if $role eq 'call' && $REMOVABLE_CALL{ $token->content };
    _add( $context, kind => $kind, start => $start, end => $end, role => $role, scope => $scope, facts => $facts );
    return;
}

sub _literal_kind ($token) {
    return 'word'   if $token->isa('PPI::Token::Word');
    return          if $token->isa('PPI::Token::Prototype');
    return 'number' if $token->isa('PPI::Token::Number');
    return 'string' if $token->isa('PPI::Token::Quote');
    return;
}

sub _modifier_condition ( $context, $token ) {
    my @condition;
    for ( my $part = $token->snext_sibling ; $part && !_is_semicolon($part) ; $part = $part->snext_sibling ) {
        push @condition, $part;
    }
    _condition_site( $context, $token, @condition ) if @condition;
    return;
}

sub _local_calls ( $context, $token ) {
    my $facts = {};
    for ( my $node = $token ; $node ; $node = $node->parent ) {
        next unless $node->isa('PPI::Statement');
        my $parent = $node->parent;
        next unless $parent && ( $parent->isa('PPI::Document') || $parent->isa('PPI::Structure::Block') );
        my $offset = _offset( $context, $node->first_token );
        $facts->{call_offset} = $offset if defined $offset;
        last;
    }
    my $packages = $context->{local_subs}{ $token->content } or return $facts;
    my $peers    = $packages->{ _package_of($token) }        or return $facts;
    my $args     = $token->snext_sibling;
    my $explicit = $args && $args->isa('PPI::Structure::List');
    return { %$facts,
        local_calls =>
          [ sort grep { $peers->{$_}{defined} && ( $explicit || $peers->{$_}{visible} ) } keys $peers->%* ] };
}

sub _open_mode ($string) {
    my $comma = $string->sprevious_sibling;
    return 0 unless _is_operator( $comma, q{,} ) && _is_operator( scalar $string->snext_sibling, q{,} );
    my $open;
    for ( $open = $comma->sprevious_sibling ; $open ; $open = $open->sprevious_sibling ) {
        last     if _is_word( $open, \%OPEN );
        return 0 if _is_operator( $open, q{,} );
    }
    if ( !$open ) {
        my $list = $string->parent->parent;
        $open = $list->sprevious_sibling if $list->isa('PPI::Structure::List');
    }
    return _is_word( $open, \%OPEN ) && !_is_operator( scalar $open->sprevious_sibling, '->' );
}

sub _filter_site ( $context, $word, $scope ) {
    my $first = $word->snext_sibling or return;
    my $last  = $first;
    my $block = $first->isa('PPI::Structure::Block');
    unless ($block) {
        return unless $word->content =~ /(?:\A|::)grep\z/;
        if ( $first->isa('PPI::Structure::List') ) {
            ($first) = map { $_->schildren } $first->schildren;
            return unless $first;
        }
        $last = $first;
        while ( my $after = $last->snext_sibling ) {
            last   if _is_operator( $after, q{,} );
            return if _is_semicolon($after);
            $last = $after;
        }
        return unless _is_operator( scalar $last->snext_sibling, q{,} );
    }
    my ( $from, $end ) = _span( $context, _edge_tokens( $first, $last ) ) or return;
    _add(
        $context,
        kind  => 'filter',
        role  => $block ? 'block' : 'expression',
        start => $from,
        end   => $end,
        scope => $scope,
        facts => { _anchors( $context, $word ) }
    );
    return;
}

sub _has_argument ( $context, $token ) {
    my $next = $token->snext_sibling;
    return scalar( $next->schildren ) ? 1 : 0 if $next && $next->isa('PPI::Structure::List');
    my $range = _place( $context, $token )->{record}{after} || [ 0, 0 ];
    return $range->[1] > $range->[0] ? 1 : 0;
}

sub _operator_site ( $context, $token ) {

    # The second caret of a logical exclusive or belongs to the site of the first one.
    my $place = _place( $context, $token );
    return if refaddr( $place->{unit}{elements}[0] ) != refaddr $token;
    my ( $start, $end ) = _span( $context, $token, $place->{unit}{elements}[-1] ) or return;
    my $scope = _scope( $context, $token ) or return;
    my ( $role, $facts ) = _operator_role( $context, $place );
    if ( $BOUNDED_COMPARISON{ $token->content } ) {
        my $before = $token->sprevious_sibling;
        $facts->{implicit_call} = 1
          if $before
          && $before->isa('PPI::Token::Word')
          && Test::Mutation::Syntax::Precedence::starts_operand( $before->content =~ s/\ACORE:://r )
          && !_is_operator( scalar $before->sprevious_sibling, '->' );
    }
    _add(
        $context,
        kind  => 'operator',
        start => $start,
        end   => $end,
        role  => $role,
        scope => $scope,
        facts => $facts,
    );
    _branches_site( $context, $token, $place, $scope )     if $token->content eq q{?};
    _comparison_site( $context, $token, $place, $scope )   if $THREE_WAY{ $token->content };
    _guarded_exit_site( $context, $token, $place, $scope ) if $EXIT_GUARD{ $token->content };
    return;
}

sub _comparison_site ( $context, $token, $place, $scope ) {
    my $record = $place->{record};
    return unless $record && $record->{before} && $record->{after};
    my $units = $place->{units};
    my ( $from,          $operand_end ) = _span( $context, _unit_edges( $units, $record->{before} ) ) or return;
    my ( $operand_start, $end )         = _span( $context, _unit_edges( $units, $record->{after} ) )  or return;
    _add(
        $context,
        kind  => 'comparison',
        role  => $token->content,
        start => $from,
        end   => $end,
        scope => $scope,
        facts => { operands => [ $operand_end - $from, $operand_start - $from ], _anchors( $context, $token ) }
    );
    return;
}

sub _guarded_exit_site ( $context, $token, $place, $scope ) {
    my $range = $place->{record}{after} or return;
    my ( $head, $last ) = _unit_edges( $place->{units}, $range );
    return unless _is_word( $head, \%TRANSFER );
    my ( $from, $end ) = _span( $context, $token, $last ) or return;
    _add(
        $context,
        kind  => 'guarded_exit',
        start => $from,
        end   => $end,
        scope => $scope,
        facts => { _anchors( $context, $token ) }
    );
    return;
}

# The siblings of an element as the table of precedence reads them, each unit with its elements and its record.
sub _place ( $context, $element ) {
    my $parent = $element->parent;
    my $parsed = $context->{parsed}{ refaddr $parent } ||= _parsed( $parent, $context->{misread} );
    my $at     = $parsed->{index}{ refaddr $element };
    return { $parsed->%*, unit => $parsed->{units}[$at], record => $parsed->{records}[$at] };
}

sub _parsed ( $parent, $readlines ) {
    my @units;
    my @children = $parent->schildren;
    while (@children) {
        my $child = shift @children;
        if ( my $following = $readlines->{ refaddr $child } ) {
            push @units, { kind => 'term', text => q{}, elements => [ $child, splice @children, 0, $following ] };
            next;
        }
        my @elements = ($child);
        if (   _is_operator( $child, q{^} )
            && _is_operator( $children[0], q{^} )
            && refaddr( $child->next_token ) == refaddr $children[0] )
        {
            push @elements, shift @children;
        }
        my ($kind) = map { $_->[1] } grep { $child->isa( $_->[0] ) } @ITEM_KIND;
        push @units,
          {
            kind     => defined $kind             ? $kind                                      : 'term',
            text     => $child->isa('PPI::Token') ? join( q{}, map { $_->content } @elements ) : q{},
            elements => \@elements
          };
    }
    my %index;
    for my $at ( 0 .. $#units ) {
        $index{ refaddr $_ } = $at for $units[$at]{elements}->@*;
    }
    my $records = Test::Mutation::Syntax::Precedence::parse( [ map { [ $_->@{qw(kind text)} ] } @units ] );
    return { units => \@units, records => $records, index => \%index };
}

sub _operator_role ( $context, $place ) {
    my $content = $place->{unit}{text};
    return ( 'update', {} ) if $content eq '++' || $content eq '--';

    if ( $content eq '=~' || $content eq '!~' ) {
        my $next = $place->{unit}{elements}[0]->snext_sibling;
        my $operand =
           !$next                                           ? 'dynamic'
          : $next->isa('PPI::Token::Regexp::Substitute')    ? 'substitute'
          : $next->isa('PPI::Token::Regexp::Transliterate') ? 'transliterate'
          :                                                   'match';
        return ( 'binary', { operand => $operand } );
    }

    my $record = $place->{record};
    if ( !$record && $content eq q{*} ) {
        return ( 'unary', {} ) if $BLOCK->check( scalar $place->{unit}{elements}[0]->snext_sibling );
    }
    return ( 'binary', { flip_flop => 1 } ) if $content eq '...' && _scalar_range( $context, $place );
    my $prefix = $record ? $record->{position} eq 'prefix' : $ALWAYS_PREFIX{$content};
    return ( 'unary',  {} ) if $prefix;
    return ( 'binary', { _right_number($place)->%*, _version_literal($place) } );
}

sub _scalar_range ( $context, $place ) {
    my $record = $place->{record};
    return 0 unless $record && $record->{before} && $record->{after};
    my $first = $place->{units}[ $record->{before}[0] ]{elements}[0];
    my $last  = $place->{units}[ $record->{after}[1] - 1 ]{elements}[-1];
    while (1) {
        my ( $previous, $next ) = ( $first->sprevious_sibling, $last->snext_sibling );
        return 1 if _tested_range( $context, $first, $next ) || _scalar_assignment($previous);
        last     if $next && !_is_semicolon($next);
        return 1 if _is_word( $previous, \%CONDITIONAL );
        last     if $previous;
        my $parent = $first->parent->parent;
        return !_is_operator( scalar $parent->sprevious_sibling->sprevious_sibling, '->' )
          if $parent->isa('PPI::Structure::Condition');
        return _scalar_block_result( $first->parent, $parent ) if $parent->isa('PPI::Structure::Block');
        last unless $parent->isa('PPI::Structure::List');
        my $prefix = $parent->sprevious_sibling;
        return !_is_operator( scalar $prefix->sprevious_sibling, '->' )
          if _is_word( $prefix, { scalar => 1, 'CORE::scalar' => 1 } );
        last if $prefix && ( !$prefix->isa('PPI::Token::Operator') || _is_operator( $prefix, '->' ) );
        $first = $last = $parent;
    }
    return 0;
}

sub _tested_range ( $context, $first, $following ) {
    return 0 unless _is_operator( $following, q{?}, qw(or and xor) );
    my $consumer = _place( $context, $following );
    my $operand  = $consumer->{record}{before};
    return $operand && $operand->[0] == $consumer->{index}{ refaddr $first };
}

sub _scalar_assignment ($operator) {
    return 0 unless _is_operator( $operator, '=' );
    my $target = $operator->sprevious_sibling;
    return $target && $target->isa('PPI::Token::Symbol') && $target->raw_type eq '$';
}

sub _scalar_block_result ( $statement, $block ) {
    return 0 if $statement->snext_sibling;
    my $word = $block->sprevious_sibling;
    return _is_word( $word, { grep => 1, sort => 1, 'CORE::grep' => 1, 'CORE::sort' => 1 } )
      && !_is_operator( scalar $word->sprevious_sibling, '->' );
}

# The element of an operand that is one element alone.
sub _alone ( $place, $side ) {
    my $span = $place->{record} ? $place->{record}{$side} : undef;
    return $span && $span->[1] - $span->[0] == 1 ? $place->{units}[ $span->[0] ]{elements}[0] : undef;
}

sub _is_number ($element) {
    return $element && $element->isa('PPI::Token::Number') && !$element->isa('PPI::Token::Number::Version') ? 1 : 0;
}

# A comparison of the version of Perl with a literal has one result on each interpreter.
sub _version_literal ($place) {
    return if !$BOUNDED_COMPARISON{ $place->{unit}{text} };
    my @sides    = grep { defined } map { _alone( $place, $_ ) } qw(before after);
    my ($number) = grep { _is_number($_) } @sides;
    my ($perl)   = grep { $_->content eq '$]' || $_->content eq '"$]"' } @sides;
    my $value    = $number && $perl ? $number->literal : undef;
    return defined $value ? ( version => 0 + $value ) : ();
}

# A shift can dispatch to an overloaded operator unless its left operand is a literal number.
sub _right_number ($place) {
    my $operator = $place->{unit}{text};
    return {} unless $ARITHMETIC{$operator} || $SHIFT{$operator} && _is_number( _alone( $place, 'before' ) );
    my $number = _alone( $place, 'after' );
    return {} if !_is_number($number);
    my $value = $number->literal;
    return defined $value ? { right => 0 + $value } : {};
}

# The two branches of a conditional, with the places of its question mark and its colon.
sub _branches_site ( $context, $mark, $place, $scope ) {
    my $record = $place->{record};
    return _drop( $context, $mark, 'conditional', 'the conditional operator has no colon or no second branch' )
      if !$record || !$record->{after};
    my $units = $place->{units};
    my ( $start, $first_end ) = _span( $context, _unit_edges( $units, $record->{middle} ) ) or return;
    my ( $later, $end )       = _span( $context, _unit_edges( $units, $record->{after} ) )  or return;
    my $colon   = $units->[ $record->{middle}[1] ]{elements}[0];
    my @anchors = map { [ _span( $context, $_, $_ ) ] } $mark, $colon;
    return if grep { !$_->@* } @anchors;
    _add(
        $context,
        kind  => 'branches',
        start => $start,
        end   => $end,
        scope => $scope,
        facts => {
            branches => [ $first_end - $start, $later - $start ],
            anchors  => \@anchors,
            _looser( $place, $record ) ? ( loose => 1 ) : ()
        },
    );
    return;
}

# The colon closes the first branch, so it may hold an assignment, which binds looser than the conditional itself.
# The operator whose operands span the whole branch is the one that binds loosest in it.
sub _looser ( $place, $record ) {
    my ( $from, $to ) = $record->{middle}->@*;
    my ($root) = grep { $_ && $_->{position} eq 'infix' && $_->{before}[0] == $from && $_->{after}[1] == $to }
      $place->{records}->@*;
    return $root && $root->{level} < $record->{level} ? 1 : 0;
}

sub _unit_edges ( $units, $span ) {
    return _edge_tokens( $units->[ $span->[0] ]{elements}[0], $units->[ $span->[1] - 1 ]{elements}[-1] );
}

# The place of the token that names the construct of a site wider than a token.
sub _anchors ( $context, $token ) {
    my @span = $TOKEN->check($token) ? _span( $context, $token, $token ) : ();
    return @span ? ( anchors => [ \@span ] ) : ();
}

sub _word_role ( $context, $token ) {
    my $content  = $token->content;
    my $previous = $token->sprevious_sibling;
    my $next     = $token->snext_sibling;
    my $parent   = $token->parent;

    return q{} if _is_data_word( $previous, $next, $parent );

    my $segment = ref $parent eq 'PPI::Statement' ? $context->{segment_of}{ refaddr $token } : undef;
    my $heads   = $segment && refaddr( $segment->{children}[0] ) == refaddr $token;
    my $leads   = !$previous || $previous->isa('PPI::Token::Label') || $heads;
    if ( $CONDITIONAL{$content} ) {
        return $leads ? 'compound' : 'modifier';
    }
    return 'control' if $LOOP_CONTROL{$content} && $leads && ( $heads || $parent->isa('PPI::Statement::Break') );
    return q{}       if $NEVER_A_CALL{$content} || $LOOP_CONTROL{$content};
    return 'call';
}

sub _is_operator ( $element, @contents ) {
    return 0 if !$element || !$element->isa('PPI::Token::Operator');
    return scalar grep { $element->content eq $_ } @contents;
}

sub _is_data_word ( $previous, $next, $parent ) {
    return 1 if _is_operator( $next, '=>', '->' ) || _is_operator( $previous, '->' );
    return 1 if $previous && $previous->isa('PPI::Token::Word') && $DECLARATOR{ $previous->content };
    return 0 if $previous || $next;
    return $parent->isa('PPI::Statement::Expression') && $parent->parent->isa('PPI::Structure::Subscript') ? 1 : 0;
}

sub _is_name ($element) {
    return $element && ( $element->isa('PPI::Token::Word') || $element->content eq 'x' ) ? 1 : 0;
}

sub _is_code_block ( $context, $block ) {
    my $parent = $block->parent;

    # PPI reads the braces of a file handle inside the parentheses of print as a bare block.
    return 0 if $parent->isa('PPI::Statement::Compound') && $parent->parent->isa('PPI::Structure::List');
    return 1 if $parent->isa('PPI::Statement::Compound') || $parent->isa('PPI::Statement::Package');
    return 1 if ref $parent eq 'PPI::Statement' && _segment_of( $context, $parent, $block )->{closes};
    my $previous = $block->sprevious_sibling;
    return 1 if $previous && grep { $previous->isa($_) } @BEFORE_A_SUB_BODY;
    return 0 if !_is_name($previous);
    return 1 if $CODE_BLOCK_WORD{ $previous->content };
    return _is_word( scalar $previous->sprevious_sibling, \%DECLARATOR );
}

sub _running_statement ( $context, $element ) {
    my $statement = $element->isa('PPI::Statement') ? $element : $element->statement;
    while ($statement) {
        my $parent = $statement->parent or return $statement;
        return $statement if $parent->isa('PPI::Document');
        return $statement
          if ref $statement ne 'PPI::Statement::Expression'
          && $parent->isa('PPI::Structure::Block')
          && _is_code_block( $context, $parent );
        $statement = $parent->statement;
    }
    return;
}

sub _scope ( $context, $element ) {
    my $statement = _running_statement( $context, $element ) or return;
    my $segment   = ref $statement eq 'PPI::Statement' ? _segment_of( $context, $statement, $element ) : undef;
    return _segment_scope($segment) if $segment;
    my $key = refaddr $statement;
    return $context->{scopes}{$key} ||= _scope_lines( $statement->first_token, $statement->last_token );
}

sub _structure_sites ( $context, $node ) {
    _collection_site( $context, $node )
      if $node->isa('PPI::Structure::Constructor') && $node->schildren && $node->finish;
    if ( $node->isa('PPI::Structure::Condition') ) {
        my $keyword = $node->sprevious_sibling;
        _condition_site( $context, $keyword, $node )
          unless _is_word( $keyword, \%CONDITIONAL ) && _word_role( $context, $keyword ) eq 'modifier';
    }
    return if !$node->isa('PPI::Statement');
    if ( $node->isa('PPI::Statement::Sub') && !$node->isa('PPI::Statement::Scheduled') ) {
        my $block = $node->block;
        my $name  = $node->name;
        _add_body( $context, $block, defined $name ? $name : q{}, $node->first_token ) if $block;
    }
    _return_site( $context, scalar _scope( $context, $node ), $node->schildren ) if $node->isa('PPI::Statement::Break');
    return;
}

sub _collection_site ( $context, $element ) {
    if ( $element->isa('PPI::Structure::Constructor') && $element->start->content eq '[' ) {
        my $previous = $element->sprevious_sibling;
        return if _ends_operand($previous);
        if ( $previous && $previous->isa('PPI::Structure::Block') ) {
            my $before = $previous->sprevious_sibling;
            return if $before && $before->isa('PPI::Token::Cast');
        }
    }
    my ( $from, $end ) = _span( $context, _edge_tokens( $element, $element ) ) or return;
    my $scope = _scope( $context, $element ) or return;
    _add(
        $context,
        kind  => 'collection',
        start => $from,
        end   => $end,
        scope => $scope,
        facts => { $element->isa('PPI::Token::QuoteLike::Words') ? _anchors( $context, $element ) : () }
    );
    return;
}

sub _inner_span ( $context, $structure ) {
    my $open  = $structure->start  or return;
    my $close = $structure->finish or return;
    return if !$structure->schildren;
    my $start = _offset( $context, $open );
    my $end   = _offset( $context, $close );
    return if !defined $start || !defined $end;
    return ( $start + 1, $end );
}

sub _condition_site ( $context, $keyword, @expression ) {
    my ( $first, $last ) = @expression[ 0, -1 ];
    my ( $start, $end ) =
      @expression == 1 && $first->isa('PPI::Structure::Condition')
      ? _inner_span( $context, $first )
      : _span( $context, _edge_tokens( $first, $last ) );
    return if !defined $start;
    my $scope    = _scope( $context, $first ) or return;
    my $declares = _declares_for_later( $first->parent, [ map { $_->tokens } @expression ] );
    _add(
        $context,
        kind  => 'condition',
        start => $start,
        end   => $end,
        scope => $scope,
        facts => {
            keyword => $keyword ? $keyword->content : q{},
            _anchors( $context, $keyword ),
            $declares ? ( declares => 1 ) : ()
        },
    );
    return;
}

sub _body_site ( $context, $segment ) {
    my ( $head, $name ) = $segment->{children}->@*;
    my $block = $segment->{children}[-1];
    return if !$segment->{closes} || !_is_word( $head, \%BODY_HEAD ) || !$block->isa('PPI::Structure::Block');
    _add_body( $context, $block, $head->content eq 'ADJUST' ? 'ADJUST' : $name->content =~ s/\s*:\z//r, $head );
    return;
}

sub _add_body ( $context, $block, $name, $head ) {
    my ( $start, $end ) = _inner_span( $context, $block ) or return;
    my $scope = _scope_lines( $head, $block->finish ) or return;
    _add(
        $context,
        kind  => 'sub_body',
        start => $start,
        end   => $end,
        scope => $scope,
        facts => { name => $name, _anchors( $context, $head ) },
    );
    return;
}

sub _return_site ( $context, $scope, $keyword, @rest ) {
    return if !$scope || !_is_word( $keyword, { return => 1 } );

    my @expression;
    for my $child (@rest) {
        last if _is_semicolon($child) || _is_word( $child, \%MODIFIER );
        push @expression, $child;
    }
    return if !@expression;

    my ( $start, $end ) = _span( $context, _edge_tokens( @expression[ 0, -1 ] ) ) or return;
    my $literal =
      @expression == 1 && $expression[0]->isa('PPI::Token::Number') ? $expression[0]->content : undef;
    _add(
        $context,
        kind  => 'return',
        start => $start,
        end   => $end,
        scope => $scope,
        facts => { defined $literal ? ( literal => $literal ) : (), _anchors( $context, $keyword ) },
    );
    return;
}

sub _statement_site ( $context, $segment ) {
    my @children = $segment->{children}->@*;
    return if grep { $_->isa('PPI::Structure::Block') } @children;
    return if _is_word( $children[0], \%UNDELETABLE_FIRST_WORD );

    my @content = grep { !_is_semicolon($_) } @children;
    return if !@content;
    return if @content == 1 && ( $content[0]->isa('PPI::Token::Number') || $content[0]->isa('PPI::Token::Quote') );

    return if _is_whole_list_block( $children[0]->parent );

    my ( $start, $end ) = _span( $context, _edge_tokens( @children[ 0, -1 ] ) ) or return;
    my $scope    = _segment_scope($segment);
    my @tokens   = map { $_->isa('PPI::Token') ? $_ : $_->tokens } @children;
    my $declares = _declares_for_later( $children[0]->parent, \@tokens );
    my $anchored = $children[0]->isa('PPI::Token::Word') || _is_operator( $children[0], '...' );
    _add(
        $context,
        kind  => 'statement',
        start => $start,
        end   => $end,
        scope => $scope,
        facts => {
            head => $children[0]->isa('PPI::Token::Word') ? $children[0]->content : q{},
            $anchored ? _anchors( $context, $children[0] ) : (),
            $declares ? ( declares => 1 )                  : ()
        },
    );
    return;
}

# Perl reads the empty braces after map or grep as a hash, so the one statement of such a block must stay.
sub _is_whole_list_block ($statement) {
    my $block = $statement->parent;
    return 0 if !$block->isa('PPI::Structure::Block') || $block->schildren != 1;
    return _is_word( scalar $block->sprevious_sibling, \%LIST_BLOCK_WORD );
}

# A variable that the statement declares and later code of the block names needs its declaration under strict.
sub _declares_for_later ( $statement, $tokens ) {
    my %declared;
    for my $token ( grep { $_->isa('PPI::Token::Symbol') } $tokens->@* ) {
        next unless _declaration_of($token);
        my $parent = $token->parent;
        $parent = $parent->parent
          while refaddr($parent) != refaddr($statement) && !$parent->isa('PPI::Structure::Block');
        $declared{ $token->symbol } = 1 if refaddr($parent) == refaddr($statement);
    }
    return 0 if !%declared;
    my $scope = $statement->isa('PPI::Statement::Compound') ? $statement : $statement->parent;
    return _uses_lexical( scalar $tokens->[-1]->next_token, scalar $scope->next_token, \%declared );
}

sub _uses_lexical ( $first, $after, $declared ) {
    my %changes;
    my %depth = map { $_ => 0 } keys $declared->%*;
    for (
        my $token = $first ;
        $token && ( !$after || refaddr($token) != refaddr($after) ) ;
        $token = $token->next_token
      )
    {
        my $events = delete $changes{ refaddr $token } || {};
        $depth{$_} += $events->{$_} for keys $events->%*;
        if ( $token->isa('PPI::Token::Symbol') ) {
            my $symbol = $token->symbol;
            next unless $declared->{$symbol};
            if ( _declaration_of($token) ) {
                my ( $start, $end ) = _shadow_scope($token);
                $changes{ refaddr $start }{$symbol}++ if $start;
                $changes{ refaddr $end }{$symbol}--   if $end;
            }
            elsif ( $depth{$symbol} < 1 ) {
                return 1;
            }
        }
        else {
            return 1 if grep { $declared->{$_} && $depth{$_} < 1 } _interpolated_symbols($token);
        }
    }
    return 0;
}

# An initializer can still refer to the previous lexical until the declaration takes effect.
sub _shadow_scope ($token) {
    for ( my $node = $token ; my $parent = $node->parent ; $node = $parent ) {
        if ( $parent->isa('PPI::Structure::For') ) {
            return ( scalar $node->next_token, scalar $parent->parent->next_token );
        }
        return ( scalar $node->next_token, scalar $parent->next_token )
          if $parent->isa('PPI::Structure::Block')
          || $parent->isa('PPI::Document')
          || $node->isa('PPI::Structure::Condition');
        if ( $parent->isa('PPI::Statement::Compound') ) {
            my ($body) = grep { $_->isa('PPI::Structure::Block') } $parent->schildren;
            return ( scalar $body->first_token, scalar $parent->next_token ) if $body;
        }
    }
    return;
}

sub _declaration_of ($token) {
    return 1 if _is_word( scalar $token->sprevious_sibling, \%DECLARATION );
    my $list = $token->parent->parent;
    return $list->isa('PPI::Structure::List') && _is_word( scalar $list->sprevious_sibling, \%DECLARATION );
}

sub _interpolated_symbols ($token) {
    my $text;
    if ( $token->isa('PPI::Token::HereDoc') ) {
        return if $token->content =~ /<<[~]?\s*['\\]/;
        $text = join q{}, $token->heredoc;
    }
    else {
        return
          unless grep { $token->isa("PPI::Token::$_") }
          qw(Quote::Double Quote::Interpolate QuoteLike::Backtick QuoteLike::Command QuoteLike::Readline QuoteLike::Regexp Regexp);
        $text = $token->content;
    }
    my @references = $text =~ /(?<!\\) (?:\\\\)* ([\$\@] \#? (?: \{\w+\} | \w+ [\[\{]? )) /gx;
    for my $reference (@references) {
        $reference =~ s/\A\$\#/\@/;
        $reference =~ s/\A[\$\@](\w+)\[\z/\@$1/;
        $reference =~ s/\A[\$\@](\w+)\{\z/%$1/;
        $reference =~ tr/{}//d;
    }
    return @references;
}

# The grammar of the comments reads facts alone: the place and the text of each comment, and the routine after it.
# A walk from the end of the file meets the token after each comment before the comment.
sub _suppressions ( $context, $document ) {
    my ( @comments, $next );
    for my $token ( reverse $document->tokens ) {
        unshift @comments, { token => $token, next => $next } if $token->isa('PPI::Token::Comment');
        $next = $token                                        if $token->significant;
    }

    # PPI puts the indent of a comment on a line of its own into the comment, and it tells such a comment by its line feed.
    # The last line of a file may lack the line feed, so the first column tells the place.
    return Test::Mutation::Suppression::parse(
        path     => $context->{source}->path,
        comments => [
            map {
                {
                    line    => $_->{token}->location->[0],
                    own     => $_->{token}->location->[1] == 1 ? 1 : 0,
                    text    => $_->{token}->content =~ s/\A\s+//r =~ s/\s+\z//r,
                    routine => scalar _routine( $context, $_->{next} ),
                }
            } @comments
        ],
    );
}

# The first and the last line of the named subroutine or method that a word starts.
# PPI joins the code after a method to the method, so a plain statement holds the routine as one of its segments.
sub _routine ( $context, $word ) {
    return if !_is_word( $word, \%ROUTINE_HEAD );
    my $statement = $word->parent;
    return [ $word->location->[0], $statement->last_token->location->[0] ] if $statement->isa('PPI::Statement::Sub');
    my $segment = $context->{segment_of}{ refaddr $word };
    return if !$segment->{closes};
    return [ $word->location->[0], $segment->{children}[-1]->last_token->location->[0] ];
}

1;

__END__

=head1 NAME

Test::Mutation::Syntax::PPI - find mutation sites with PPI

=head1 SYNOPSIS

    my $analysis = Test::Mutation::Syntax::PPI::analyze($source);
    die $analysis->{problem} if defined $analysis->{problem};
    my @sites = $analysis->{sites}->@*;

=head1 DESCRIPTION

The module parses a source with PPI and reports the places a mutator can change.
It verifies that every reported span holds the text PPI attributes to it.
A span that fails the check and a pattern that L<PPIx::Regexp> fails to parse yield no site, and the result lists each of them.
C<use> and C<no> statements, the name and the version of a C<package>, C<$VERSION> assignments, and text after C<__END__> produce no sites.
The block of a C<package> holds sites like any other code, and so does the body of an anonymous subroutine inside a C<use> statement.

PPI learns from C<use v5.36> and a few other pragmas that a file uses signatures.
In another file it reads a signature as a prototype, and the module then reads the file again with signatures on.
A file with a carriage return before each line feed is analyzed, and its sites address the text with the carriage returns.
There a token that spans two lines has another text than the file, so it is among the places left out.

PPI reads a readline such as C<< <$handle> >> at the start of a statement and after some words as two comparisons around a name.
No comparison lacks its right operand, so the module takes a C<< > >> without one for the end of a readline, and the tokens back to its C<< < >> yield no site.

L<Test::Mutation::Syntax::Precedence> reads the siblings of each operator and finds its operands.
A sign before its operand is unary, and an arithmetic operator names a number that is its whole right operand.
Two carets without a space between are the logical exclusive or of Perl 5.40, which PPI reads as two tokens.
A conditional operator yields a C<branches> site over its two branches, and one without its colon or its second branch is a place left out.
A condition, a return value, the body of a subroutine, the branches of a conditional, and a statement that starts with a word name the places of the tokens of their construct.
A first branch with an assignment at its top binds looser than the conditional, and its site carries the fact C<loose>.

PPI joins the code after a method, a C<defer> block, or a C<finally> block to the block.
The module splits such a statement at the closing brace, so each part has its own scope and its own sites.
The name, the version, and the attributes of a class, a field, or a method produce no sites.
A site in a field or in an C<ADJUST> block is marked as not comparable.

The one statement of a C<map> or C<grep> block is no statement site, and the braces around a file handle hold no statement.

The module reports what a change must keep and leaves the decision to the generator.
A site that declares a variable which later code names carries the fact C<declares>.
Sites in a standalone literal value or in the expression that computes a module's return value carry the fact C<final_value>.
The result lists each here-document with the place of its introducer and of its text.
It lists each C<use> statement with the names it imports, as far as the text of the statement tells, and the subroutines that the file declares.
C<use v5.40> and a later version import the booleans and the rounding functions of the core.

=head1 FUNCTIONS

=head2 inside_begin

Returns true when the original source offset lies inside a C<BEGIN> block.

=head2 compile_reads

Returns the literal paths and environment-variable names read by a standalone compilation.
An unrecognized scheduled statement leaves the input set unknown.
The optional true argument also checks the file-scope statements and import hooks that can execute when Perl loads a module.

=head2 witness_offsets

Returns the character offsets of the first and last top-level Perl statements before a data section.
An optional third offset marks the first Perl token after an extraction header for C<perl -x>.
Returns an undefined value when the file has no statement.

=head2 analyze

Returns a hash reference in the shape of L<Test::Mutation::Types/Analysis>.
C<sites> holds L<Test::Mutation::Site> objects in source order.
C<suppressions> holds what L<Test::Mutation::Suppression> reads from the comments: the directives and the refusals of the grammar.
The analysis gives each comment the lines of the named subroutine or method that starts at its next token.
C<dropped> holds the places that yield no site, each with its line, its kind, and the reason.
C<heredocs> holds the offsets of each here-document.
C<names> holds the imports of each C<use> statement and the subroutines of the file.
C<problem> names the reason when the file cannot be analyzed.

=cut
