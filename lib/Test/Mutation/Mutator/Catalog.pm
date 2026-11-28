package Test::Mutation::Mutator::Catalog;
use v5.36;
use Math::BigInt    ();
use Types::Standard qw(ArrayRef Enum InstanceOf Str);
use Type::Params    qw(signature_for);
use Test::Mutation::Error;
use Test::Mutation::Mutator;

our $VERSION = '0.001';

my @OPERATOR_FAMILIES = (
    {
        name        => 'arithmetic',
        profile     => 'default',
        description => 'Replaces an arithmetic operator with its counterpart',
        role        => 'binary',
        table       => { '+' => ['-'], '-' => ['+'], '*' => ['/'], '/' => ['*'], '%'  => ['*'], '**' => ['*'] },
        idle        => { '+' => 0,     '-' => 0,     '*' => 1,     '/' => 1,     '**' => 1 },
    },
    {
        name        => 'comparison-boundary',
        profile     => 'extended',
        description => 'Moves the boundary of a numeric or string comparison',
        role        => 'binary',
        table       => {
            '<'  => ['<='],
            '<=' => ['<'],
            '>'  => ['>='],
            '>=' => ['>'],
            lt   => ['le'],
            le   => ['lt'],
            gt   => ['ge'],
            ge   => ['gt'],
        },
        boundary => { '<' => '<=', '<=' => '<', '>' => '>=', '>=' => '>' },
    },
    {
        name        => 'comparison-negation',
        profile     => 'default',
        description => 'Negates a numeric or string comparison',
        role        => 'binary',
        table       => {
            '<'  => ['>='],
            '<=' => ['>'],
            '>'  => ['<='],
            '>=' => ['<'],
            '==' => ['!='],
            '!=' => ['=='],
            lt   => ['ge'],
            le   => ['gt'],
            gt   => ['le'],
            ge   => ['lt'],
            eq   => ['ne'],
            ne   => ['eq'],
        },
    },
    {
        name        => 'logical',
        profile     => 'default',
        description => 'Replaces a logical operator with its counterpart',
        role        => 'binary',
        table       => {
            '&&'  => ['||'],
            '||'  => ['&&'],
            'and' => ['or'],
            'or'  => ['and'],
            '//'  => ['||'],
            'xor' => ['or'],
            '^^'  => ['||'],
        },
    },
    {
        name        => 'bitwise',
        profile     => 'extended',
        description => 'Replaces a bitwise operator with its counterpart or removes a complement',
        role        => 'binary',
        table       => {
            q{&}  => [q{|}],
            q{|}  => [q{&}],
            q{^}  => [q{&}],
            '<<'  => ['>>'],
            '>>'  => ['<<'],
            '&.'  => ['|.'],
            '|.'  => ['&.'],
            '^.'  => ['&.'],
            '&='  => ['|='],
            '|='  => ['&='],
            '^='  => ['&='],
            '<<=' => ['>>='],
            '>>=' => ['<<='],
            '&.=' => ['|.='],
            '|.=' => ['&.='],
            '^.=' => ['&.='],
        },
        unary => { q{~} => [q{}], '~.' => [q{}] },
        idle  => { '<<' => 0,     '>>' => 0 },
    },
    {
        name        => 'increment',
        profile     => 'default',
        description => 'Swaps increment and decrement',
        role        => 'update',
        table       => { '++' => ['--'], '--' => ['++'] },
    },
    {
        name        => 'assignment',
        profile     => 'default',
        description => 'Replaces a compound assignment with its counterpart',
        role        => 'binary',
        table       => {
            '+='  => ['-='],
            '-='  => ['+='],
            '*='  => ['/='],
            '/='  => ['*='],
            '%='  => ['*='],
            '**=' => ['*='],
            '.='  => ['='],
            '||=' => ['&&='],
            '&&=' => ['||='],
            '//=' => ['||='],
        },
    },
);

my @WORD_FAMILIES = (
    {
        name        => 'loop-control',
        profile     => 'default',
        description => 'Swaps last and next, and turns redo into next',
        roles       => ['control'],
        table       => { last => 'next', next => 'last', redo => 'next' },
    },
    {
        name        => 'call-swap',
        profile     => 'extended',
        description => 'Replaces a function with its counterpart',
        roles       => ['call'],
        calls       => 1,
        table       => {
            min     => 'max',
            max     => 'min',
            minstr  => 'maxstr',
            maxstr  => 'minstr',
            any     => 'all',
            all     => 'any',
            none    => 'any',
            notall  => 'all',
            push    => 'unshift',
            unshift => 'push',
            lc      => 'uc',
            uc      => 'lc',
            lcfirst => 'ucfirst',
            ucfirst => 'lcfirst',
            index   => 'rindex',
            rindex  => 'index',
            ceil    => 'floor',
            floor   => 'ceil',
        },
    },
    {
        name        => 'boolean-literal',
        profile     => 'default',
        description => 'Swaps true and false',
        roles       => ['call'],
        calls       => 1,
        table       => { true => 'false', false => 'true' },
    },
    {
        name        => 'shift-pop',
        profile     => 'extended',
        description => 'Swaps shift and pop',
        roles       => ['call'],
        calls       => 1,
        table       => { shift => 'pop', pop => 'shift' },
    },
    {
        name        => 'list-order',
        profile     => 'extended',
        description => 'Reverses a sort or removes an explicit reverse',
        roles       => ['call'],
        table       => {
            sort            => 'reverse sort',
            reverse         => q{},
            'CORE::sort'    => 'CORE::reverse CORE::sort',
            'CORE::reverse' => q{}
        },
    },
    {
        name        => 'call-removal',
        profile     => 'default',
        description => 'Removes abs or int while keeping its argument',
        roles       => ['call'],
        table       => { abs => q{}, int => q{}, 'CORE::abs' => q{}, 'CORE::int' => q{} },
    },
);

sub _blank ($text) {
    return join q{}, $text =~ /\n/g;
}

# An operand in the idle table leaves the value as it is under the operator and under its replacement.
# Zero added or subtracted never differs, and neither does one as an exponent.
# One as a factor differs from one as a divisor for negative zero alone.
sub _operator_mutator ($family) {
    my %tables   = ( $family->{role} => $family->{table}, unary => $family->{unary} || {} );
    my $idle     = $family->{idle}     || {};
    my $boundary = $family->{boundary} || {};
    return Test::Mutation::Mutator->new(
        name        => $family->{name},
        profile     => $family->{profile},
        description => $family->{description},
        generate    => sub ($site) {
            return if $site->kind ne 'operator';
            my $table        = $tables{ $site->role } or return;
            my $text         = $site->text;
            my $replacements = $table->{$text} or return;
            my $operand      = $site->facts->{right};
            return if defined $operand && defined $idle->{$text} && $operand == $idle->{$text};

            # A settled comparison gives the same result on both sides of its boundary.
            my $settled = $site->facts->{settled} ? $boundary->{$text} : undef;
            return map {
                {
                    replacement => $site->facts->{implicit_call} && /\A</ ? "() $_"                  : $_,
                    description => $_ ne q{}                              ? "replaced $text with $_" : "removed $text",
                }
              }
              grep { !defined $settled || $_ ne $settled } $replacements->@*;
        },
    );
}

sub _word_mutator ($family) {
    my %role  = map { $_ => 1 } $family->{roles}->@*;
    my $table = $family->{table};
    return Test::Mutation::Mutator->new(
        name        => $family->{name},
        profile     => $family->{profile},
        description => $family->{description},
        generate    => sub ($site) {
            return if $site->kind ne 'word' || !$role{ $site->role };
            my $text = $site->text;

            # A function may stand under its qualified name, and the table knows it by its own name.
            # The generator writes the name of the counterpart as the file resolves it.
            my $word        = $family->{calls} ? $text =~ s/\A.*:://r : $text;
            my $replacement = $table->{$word};
            return if !defined $replacement;
            return if !length($replacement) && !$site->facts->{has_argument};
            return { replacement => q{}, description => "removed $text" } if !length $replacement;
            return { replacement => $replacement, description => "replaced $text with %s", calls => $replacement }
              if $family->{calls};
            return { replacement => $replacement, description => "replaced $text with $replacement" };
        },
    );
}

sub _negation ($site) {
    return if $site->kind ne 'operator' || $site->role ne 'unary';
    my $text = $site->text;
    return if $text ne q{!} && $text ne 'not';
    return { replacement => q{}, description => "removed $text" };
}

sub _unary_minus ($site) {
    my $text = $site->text;
    return { replacement => q{}, description => 'removed the unary minus' }
      if $site->kind eq 'operator' && $site->role eq 'unary' && $text eq q{-};
    return if $site->kind ne 'number';
    my ($unsigned) = $text =~ /\A-(.+)\z/s or return;
    return { replacement => $unsigned, description => "replaced $text with $unsigned" };
}

my %NEGATED_KEYWORD = ( if => 'unless', unless => 'if', while => 'until', until => 'while' );

sub _three_way ($site) {
    return if $site->kind ne 'comparison';
    my ( $operand_end, $operand_start ) = $site->facts->{operands}->@*;
    my $text = $site->text;
    my $swapped =
        substr( $text, $operand_start )
      . substr( $text, $operand_end, $operand_start - $operand_end )
      . substr( $text, 0,            $operand_end );
    return { replacement => $swapped, description => 'swapped the operands of ' . $site->role };
}

sub _early_exit ($site) {
    return if $site->kind ne 'guarded_exit';
    return { replacement => _blank( $site->text ), description => 'removed a guarded exit' };
}

sub _filter_negation ($site) {
    return if $site->kind ne 'filter';
    my $text        = $site->text;
    my $replacement = $site->role eq 'block' ? "{ !do $text }" : "!($text)";
    return { replacement => $replacement, description => 'negated the filter predicate' };
}

# A keyword turns into its negation, and an elsif has none, so its condition is negated.
# The condition of a conditional operator has no left edge that the analysis can name, so its branches swap.
sub _condition_negation ($site) {
    my ( $kind, $text, $facts ) = ( $site->kind, $site->text, $site->facts );
    if ( $kind eq 'word' && ( $site->role eq 'compound' || $site->role eq 'modifier' ) ) {
        my $negation = $NEGATED_KEYWORD{$text} or return;
        return { replacement => $negation, description => "replaced $text with $negation" };
    }
    if ( $kind eq 'condition' && defined $facts->{keyword} && $facts->{keyword} eq 'elsif' ) {
        return { replacement => "!($text)", description => 'negated the elsif condition' };
    }
    return if $kind ne 'branches' || !$facts->{branches};
    my ( $first, $later ) = $facts->{branches}->@*;
    my $moved   = $facts->{loose} ? '(' . substr( $text, 0, $first ) . ')' : substr $text, 0, $first;
    my $swapped = substr( $text, $later ) . substr( $text, $first, $later - $first ) . $moved;
    return { replacement => $swapped, description => 'swapped the branches of the conditional' };
}

# A test of definedness, of existence, of the context of a call, or of a file turns into its negation.
my %PREDICATE = map { $_ => 1 } qw(defined exists wantarray);

sub _predicate ($site) {
    my $text = $site->text;
    my $word = $site->kind eq 'word'     && $site->role eq 'call'  && $PREDICATE{ $text =~ s/\ACORE:://r };
    my $file = $site->kind eq 'operator' && $site->role eq 'unary' && $text =~ /\A-[[:alpha:]]\z/;
    return if !$word && !$file;
    return { replacement => "!$text", description => "negated $text" };
}

sub _match ($site) {
    return if $site->kind ne 'operator' || $site->role ne 'binary';
    my $text = $site->text;
    return if $text ne '=~' && $text ne '!~';
    my $operand = $site->facts->{operand};
    return if !defined $operand || $operand ne 'match';
    my $replacement = $text eq '=~' ? '!~' : '=~';
    return { replacement => $replacement, description => "replaced $text with $replacement" };
}

sub _return_value ($site) {
    return if $site->kind ne 'return';
    my $literal = $site->facts->{literal};
    return { replacement => '0', description => 'replaced return 1 with return 0' }
      if defined $literal && $literal eq '1';
    return { replacement => '1', description => 'replaced return 0 with return 1' }
      if defined $literal && $literal eq '0';
    return { replacement => _blank( $site->text ), description => 'removed the return value' };
}

# A lexical handle closes at the end of its scope, so few test suites detect a missing close.
my %CLOSES = map { $_ => 1 } qw(close closedir CORE::close CORE::closedir);

sub _closes ($site) {
    my $head = $site->facts->{head};
    return defined $head && $CLOSES{$head} ? 1 : 0;
}

sub _statement_removal ($site) {
    return if $site->kind ne 'statement' || _closes($site);
    return { replacement => _blank( $site->text ), description => 'removed the statement' };
}

sub _close_removal ($site) {
    return if $site->kind ne 'statement' || !_closes($site);
    return { replacement => _blank( $site->text ), description => 'removed the statement' };
}

sub _sub_body ($site) {
    return if $site->kind ne 'sub_body';
    my $name = $site->facts->{name};
    return { replacement => _blank( $site->text ), description => "removed the body of $name" };
}

my %RADIX = ( b => 'as_bin', o => 'as_oct', x => 'as_hex' );

sub _successor ($number) {
    $number =~ tr/_//d;
    if ( $number =~ /\Av|\d[.]\d+[.]\d/ ) {
        return $number =~ s/(\d+)\z/Math::BigInt->new($1)->binc/er;
    }
    if ( my ( $sign, $prefix, $digits ) = $number =~ /\A (-?) (0[box]|0(?=[0-7])) ([[:xdigit:]]+) \z/ix ) {
        my $base  = length($prefix) == 1 ? 'o' : lc substr( $prefix, 1 );
        my $value = Math::BigInt->new( $sign . '0' . $base . $digits )->binc;
        return if $value->is_nan;
        my $format = $RADIX{$base};
        return $value->$format() =~ s/\A(-?)0[box]?/$1$prefix/ir;
    }
    return Math::BigInt->new($number)->binc->bstr if $number =~ /\A-?\d+\z/;
    return unless $number =~ /\A -? (?:\d+(?:[.]\d*)?|[.]\d+) (?:e[+-]?\d+)? \z/ix;
    my $next = $number + 1;
    return if $next == $number;
    my $short = "$next";
    return $short == $next ? $short : sprintf( '%.17g', $next );
}

sub _number_literal ($site) {
    return if $site->kind ne 'number';
    my $text        = $site->text;
    my $replacement = _successor($text);
    return unless defined $replacement;
    return { replacement => "$replacement", description => "replaced $text with $replacement" };
}

# A string in quotes or under q or qq keeps its delimiters, and the text between them goes or, when empty, gets a word.
sub _string_literal ($site) {
    return if $site->kind ne 'string' || $site->role eq 'open-mode';
    my $text = $site->text;
    my ( $open, $inside, $close ) = $text =~ /\A((?:qq?\s*)?[^\w\s])(.*)([^\w\s])\z/s or return;
    return if $open =~ /\A['"]\z/ && $close ne $open;
    return { replacement => $open . 'mutant' . $close, description => 'replaced the empty string' } if $inside eq q{};
    return { replacement => $open . $close, description => 'emptied the string' };
}

sub _condition_fixed ($site) {
    return if $site->kind ne 'condition';
    my $keyword = $site->facts->{keyword};
    my @values  = $keyword eq 'while' ? ('0') : $keyword eq 'until' ? ('1') : ( '1', '0' );
    return map { { replacement => $_, description => "replaced the $keyword condition with $_" } } @values;
}

sub _range_boundary ($site) {
    return if $site->kind ne 'operator' || $site->role ne 'binary';
    return { replacement => '..', description => 'tested the range endpoint on its first evaluation' }
      if $site->text eq '...' && $site->facts->{flip_flop};
    return if $site->text ne '..';
    return { replacement => '.. -1 +', description => 'lowered the upper bound of the range by one' };
}

sub _regex_anchor ($site) {
    return if $site->kind ne 'regex' || $site->role ne 'anchor';
    return {
        replacement => $site->facts->{quantified} ? '(?:)' : q{},
        description => 'removed the anchor ' . $site->text
    };
}

sub _regex_quantifier ($site) {
    return if $site->kind ne 'regex' || $site->role ne 'quantifier';
    my $text = $site->text;
    return { replacement => q{}, description => 'removed the quantifier ?' } if $text eq q{?};
    my $replacement = $text eq q{+} ? q{*} : q{+};
    return { replacement => $replacement, description => "replaced the quantifier $text with $replacement" };
}

sub _regex_flag ($site) {
    return if $site->kind ne 'regex';
    my $text = $site->text;
    return { replacement => q{}, description => "removed the flag $text" } if $site->role eq 'flag';
    return                                                                 if $site->role ne 'modifier';
    my ( $open, $flags, $close ) = $text =~ /\A(\(?\?)([\^a-z-]+)([):])\z/ or return;
    my @changes;
    while ( $flags =~ /[ims]/g ) {
        my $offset = $-[0];
        my $other  = $flags;
        my $flag   = substr( $other, $offset, 1, q{} );
        $other =~ s/-\z//;
        my $replacement = length($other) || $close eq ':' ? "$open$other$close" : '(?:)';
        push @changes, { replacement => $replacement, description => "removed the flag $flag" };
    }
    return @changes;
}

sub _regex_class ($site) {
    return if $site->kind ne 'regex' || $site->role ne 'class';
    my $text = $site->text;
    my $changed =
        $text =~ /\A\\/     ? $text =~ tr/dDsSwW/DdSsWw/r
      : $text =~ /\A\[\^\^/ ? $text =~ s/\A\[\^/[\\/r
      : $text =~ /\A\[\^/   ? $text =~ s/\A\[\^/\[/r
      :                       $text =~ s/\A\[/[^/r;
    return { replacement => $changed, description => 'complemented the character class' };
}

sub _literal_collection ($site) {
    return if $site->kind ne 'collection';
    my ( $open, $inside, $close ) = $site->text =~ /\A((?:qw\s*)?.)(.*)(.)\z/s or return;
    return { replacement => $open . _blank($inside) . $close, description => 'emptied the collection literal' };
}

my @CODED = (
    [ 'three-way',          'default',  'Swaps the operands of a three-way comparison',  \&_three_way ],
    [ 'early-exit',         'extended', 'Removes a guarded transfer of control',         \&_early_exit ],
    [ 'filter-negation',    'default',  'Negates the predicate of grep or first',        \&_filter_negation ],
    [ 'regex-class',        'extended', 'Complements a character class in a pattern',    \&_regex_class ],
    [ 'literal-collection', 'extended', 'Empties an array, hash, or word-list literal',  \&_literal_collection ],
    [ 'unary-minus',        'default',  'Removes a unary minus or the sign of a number', \&_unary_minus ],
    [
        'condition-negation',                                         'default',
        'Negates a condition or swaps the branches of a conditional', \&_condition_negation
    ],
    [ 'predicate',         'default', 'Negates a test of definedness, existence, context, or a file', \&_predicate ],
    [ 'negation',          'default', 'Removes a logical negation',                                   \&_negation ],
    [ 'match',             'default', 'Negates a pattern match',                                      \&_match ],
    [ 'return-value',      'default', 'Removes a return value or flips a literal 0 or 1',             \&_return_value ],
    [ 'statement-removal', 'default',  'Removes an expression statement',                 \&_statement_removal ],
    [ 'sub-body',          'default',  'Removes the body of a subroutine',                \&_sub_body ],
    [ 'close-removal',     'extended', 'Removes a close or closedir statement',           \&_close_removal ],
    [ 'number-literal',    'extended', 'Advances a numeric literal in its original base', \&_number_literal ],
    [ 'string-literal',    'extended', 'Empties a string literal',                        \&_string_literal ],
    [ 'condition-fixed',   'extended', 'Replaces a condition with a constant',            \&_condition_fixed ],
    [ 'range-boundary',    'extended', 'Moves the endpoint of a range or flip-flop',      \&_range_boundary ],
    [ 'regex-anchor',      'extended', 'Removes an anchor from a pattern',                \&_regex_anchor ],
    [ 'regex-quantifier',  'extended', 'Changes a quantifier in a pattern',               \&_regex_quantifier ],
    [ 'regex-flag',        'extended', 'Removes a matching or substitution flag',         \&_regex_flag ],
);

my @ALL = (
    ( map { _operator_mutator($_) } @OPERATOR_FAMILIES ),
    ( map { _word_mutator($_) } @WORD_FAMILIES ),
    (
        map {
            Test::Mutation::Mutator->new(
                name        => $_->[0],
                profile     => $_->[1],
                description => $_->[2],
                generate    => $_->[3]
            )
        } @CODED
    ),
);

signature_for mutators => ( positional => [], returns => ArrayRef [ InstanceOf ['Test::Mutation::Mutator'] ] );

sub mutators () {
    return [@ALL];
}

my %GROUP = (
    '@regex'   => [ map { $_->name } grep { $_->name =~ /\Aregex-/ } @ALL ],
    '@literal' => [ map { $_->name } grep { $_->name =~ /(?:-literal\z|\Aliteral-)/ } @ALL ],
    '@removal' => [qw(early-exit call-removal close-removal statement-removal sub-body return-value)],
);

sub _expanded (@names) {
    return map { $GROUP{$_} ? $GROUP{$_}->@* : $_ } @names;
}

signature_for choose => (
    named   => [ profile => Enum [qw(default extended)], enable => ArrayRef [Str], disable => ArrayRef [Str] ],
    returns => ArrayRef [ InstanceOf ['Test::Mutation::Mutator'] ],
);

sub choose ($arg) {
    my @enable  = _expanded( $arg->enable->@* );
    my @disable = _expanded( $arg->disable->@* );
    my %known   = map  { $_->name => 1 } @ALL;
    my @unknown = grep { !$known{$_} } @enable, @disable;
    Test::Mutation::Error::raise( 'mutator-unknown', names => join q{, }, @unknown ) if @unknown;

    my %enabled  = map { $_ => 1 } @enable;
    my %disabled = map { $_ => 1 } @disable;
    return [
        grep {
            !$disabled{ $_->name }
              && ( $enabled{ $_->name } || $_->profile eq 'default' || $arg->profile eq 'extended' )
        } @ALL
    ];
}

1;

__END__

=head1 NAME

Test::Mutation::Mutator::Catalog - the built-in mutators

=head1 SYNOPSIS

    my $mutators = Test::Mutation::Mutator::Catalog::choose(
        profile => 'default',
        enable  => ['number-literal'],
        disable => ['sub-body'],
    );

=head1 DESCRIPTION

C<mutation mutators> prints the name, the profile, and the description of every mutator.

C<comparison-boundary> moves the boundary of an ordered comparison and C<comparison-negation> complements its result.
C<three-way> exchanges both operands of C<cmp> or C<< <=> >>.
C<early-exit> removes a guarded transfer of control and C<filter-negation> negates the predicate of C<grep> or C<first>.
C<call-removal> removes C<abs> or C<int> from its explicit argument.
C<list-order> reverses a sort or removes C<reverse> from its argument.

C<number-literal> increments the literal in its original base.
C<literal-collection> empties an array reference, hash reference, or C<qw> list.
C<regex-class> complements a character class and C<regex-flag> removes one matching flag or the C<g> of a substitution.

The C<arithmetic> mutator leaves C<+ 0>, C<- 0>, C<* 1>, C</ 1>, and C<** 1> alone.
The operator and its replacement give the same value there, apart from the sign of a negative zero under C<* 1> and C</ 1>.

The C<comparison-boundary> mutator keeps the boundary of a comparison between C<$]> and a number, as in C<< $] < 5.010 >>.
The boundary matters on the one interpreter whose version equals the number, and the tests of other interpreters cannot detect its change.
The negation of such a comparison stays a mutant.

The C<logical> mutator turns the exclusive C<xor> and C<^^> into the C<or> and the C<||> of their precedence.
The C<bitwise> mutator swaps C<&> and C<|>, turns C<^> into C<&>, swaps C<<< << >>> and C<<< >> >>>, does the same to the string forms and to the assignments, and removes a complement.
The C<unary-minus> mutator removes a unary minus and the sign of a negative number.
The C<loop-control> mutator swaps C<last> and C<next> and turns C<redo> into C<next>.
A C<next> never turns into a C<redo>, which would repeat the same pass of the loop without end.

The C<condition-negation> mutator swaps C<if> and C<unless>, and C<while> and C<until>.
An C<elsif> has no such counterpart, so its condition C<C> becomes C<!(C)>.
The left edge of the condition of a conditional operator depends on every operator before it, so the mutator swaps the branches, and C<C ? A : B> becomes C<C ? B : A>.
The C<predicate> mutator negates C<defined>, C<exists>, C<wantarray>, and a file test with a C<!> before it.

The C<statement-removal> mutator leaves a C<close> or C<closedir> statement in place.
A lexical handle closes at the end of its scope, so few test suites detect the removal.
The C<close-removal> mutator of the extended profile removes those statements for a project that checks its closes.

=head1 FUNCTIONS

=head2 mutators

Returns every built-in mutator.

=head2 choose

Returns the mutators of a profile, plus the enabled names and minus the disabled names.
The C<extended> profile includes the C<default> mutators.
Use C<@regex>, C<@literal>, and C<@removal> with C<enable> or C<disable> to select related mutators together.
A disabled name or group takes precedence over an enabled one.
An unknown name is a fatal error.

=cut
