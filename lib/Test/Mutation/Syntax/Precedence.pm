package Test::Mutation::Syntax::Precedence;
use v5.36;
use Types::Standard qw(ArrayRef Bool Dict Enum Int Maybe Optional Str Tuple);
use Type::Params    qw(signature_for);

our $VERSION = '0.001';

# The named unary operators of perlfunc, which perl reads with one operand that binds tighter than they do.
# t/assumptions/word-classes.t compares this list and the next ones with the reading of B::Deparse.
my @NAMED_UNARY = qw(
  abs alarm caller chdir chomp chop chr chroot close closedir cos dbmclose defined delete do each eof eval evalbytes
  exists exit exp fc fileno getc getgrgid getgrnam gethostbyname getnetbyname getpeername getpgrp getprotobyname
  getpwnam getpwuid getsockname gmtime hex int keys lc lcfirst length localtime lock log lstat oct ord pop pos
  prototype quotemeta rand readdir readline readlink readpipe ref require reset rewinddir rmdir scalar sethostent
  setnetent setprotoent setservent shift sin sleep sqrt srand stat study tell telldir tied uc ucfirst umask undef
  untie values write
);

# perlop, "Named Unary Operators": the file tests bind as the named unary operators do.
my @FILE_TESTS = map { "-$_" } qw(r w x o R W X O e z s f d l p S b c t u g k T B M A C);

# The list operators of perlfunc, which take every operand up to an operator looser than a comma.
my @LIST_OPERATORS = qw(
  accept atan2 bind binmode bless chmod chown connect crypt dbmopen die exec fcntl flock formline gethostbyaddr
  getnetbyaddr getpriority getprotobynumber getservbyname getservbyport getsockopt glob grep index ioctl join kill link
  listen map mkdir msgctl msgget msgrcv msgsnd open opendir pack pipe print printf push read recv rename return
  reverse rindex say seek seekdir select semctl semget semop send setpgrp setpriority setsockopt shmctl shmget shmread
  shmwrite shutdown socket socketpair sort splice split sprintf substr symlink syscall sysopen sysread sysseek system
  syswrite tie truncate unlink unpack unshift utime vec waitpid warn
);

# The functions that take no operand, which perl reads as a whole term.
my @TERMS = qw(
  endgrent endhostent endnetent endprotoent endpwent endservent fork getgrent gethostent getlogin getnetent
  getppid getprotoent getpwent getservent setgrent setpwent time times wait wantarray
  __CLASS__ __FILE__ __LINE__ __PACKAGE__ __SUB__
);

my @ASSIGNMENTS = (qw(= **= += -= .= *= /= %= x= &= |= ^= <<= >>= &&= ||= //= &.= |.= ^.=));

# perlop, "Operator Precedence and Associativity", from the tightest level to the loosest, below the terms.
# The conditional operator stands as its question mark, which pairs with a colon.
my @LEVELS = (
    { associativity => 'left',     infix  => ['->'] },
    { associativity => 'nonassoc', prefix => [qw(++ --)], postfix => [qw(++ --)] },
    { associativity => 'right',    infix  => ['**'] },
    { associativity => 'right',    prefix => [ qw(! ~ ~.), q{\\}, qw(+ -) ] },
    { associativity => 'left',     infix  => [qw(=~ !~)] },
    { associativity => 'left',     infix  => [qw(* / % x)] },
    { associativity => 'left',     infix  => [qw(+ - .)] },
    { associativity => 'left',     infix  => [qw(<< >>)] },
    { associativity => 'nonassoc', prefix => [ @NAMED_UNARY, @FILE_TESTS ] },
    { associativity => 'nonassoc', infix  => ['isa'] },
    { associativity => 'chained',  infix  => [qw(< > <= >= lt gt le ge)] },
    { associativity => 'chain/na', infix  => [qw(== != eq ne <=> cmp ~~)] },
    { associativity => 'left',     infix  => [qw(& &.)] },
    { associativity => 'left',     infix  => [qw(| |. ^ ^.)] },
    { associativity => 'left',     infix  => ['&&'] },
    { associativity => 'left',     infix  => [qw(|| ^^ //)] },
    { associativity => 'nonassoc', infix  => [qw(.. ...)] },
    { associativity => 'right',    infix  => [q{?}] },
    { associativity => 'right',    infix  => \@ASSIGNMENTS, prefix => [qw(goto last next redo dump)] },
    { associativity => 'left',     infix  => [ q{,}, '=>' ] },
    { associativity => 'nonassoc', prefix => \@LIST_OPERATORS },
    { associativity => 'right',    prefix => ['not'] },
    { associativity => 'left',     infix  => ['and'] },
    { associativity => 'left',     infix  => [qw(or xor)] },
);

# A level binds tighter the higher its number, and the loosest level is one.
my ( %INFIX, %PREFIX );
for my $index ( 0 .. $#LEVELS ) {
    my $level     = @LEVELS - $index;
    my $rightward = $LEVELS[$index]{associativity} eq 'right' ? 1 : 0;
    $INFIX{$_}  = [ $level, $rightward ] for @{ $LEVELS[$index]{infix}  || [] };
    $PREFIX{$_} = $level                 for @{ $LEVELS[$index]{prefix} || [] };
}
my %TERM        = map { $_ => 1 } @TERMS;
my $UNARY       = $PREFIX{'!'};
my $CONDITIONAL = $INFIX{q{?}}[0];
my $ASSIGNMENT  = $INFIX{q{=}}[0];
my $COMMA       = $INFIX{q{,}}[0];
my $LIST        = $PREFIX{print};

# A declaration takes the variable or the list after it, and these words end an expression or stand outside one.
my %DECLARATOR = map { $_ => 1 } qw(my our local state);
my %STOP       = map { $_ => 1 } qw(if unless while until for foreach else elsif continue);
my %BLOCK_TERM = map { $_ => 1 } qw(do eval);

my $SPAN   = Tuple [ Int, Int ];
my $RECORD = Dict [
    position => Enum [qw(prefix infix postfix)],
    level    => Int,
    before   => Optional [$SPAN],
    middle   => Optional [$SPAN],
    after    => Optional [$SPAN],
];

signature_for levels => (
    positional => [],
    returns    => ArrayRef [
        Dict [
            associativity => Enum [qw(left right nonassoc chained chain/na)],
            infix         => ArrayRef [Str],
            prefix        => ArrayRef [Str],
            postfix       => ArrayRef [Str],
        ]
    ],
);

sub levels () {
    return [ map { _level($_) } @LEVELS ];
}

sub _level ($level) {
    return {
        associativity => $level->{associativity},
        map { ( $_ => [ @{ $level->{$_} || [] } ] ) } qw(infix prefix postfix)
    };
}

signature_for terms => ( positional => [], returns => ArrayRef [Str] );

sub terms () {
    return [@TERMS];
}

signature_for starts_operand => ( positional => [Str], returns => Bool );

sub starts_operand ($text) {
    return defined $PREFIX{$text} ? 1 : 0;
}

signature_for parse => (
    positional => [ ArrayRef [ Tuple [ Enum [qw(operator word cast term list block subscript stop)], Str ] ] ],
    returns    => ArrayRef [ Maybe [$RECORD] ],
);

sub parse ($items) {
    my $state = { items => $items, records => [] };
    my $index = 0;
    while ( $items->[$index] ) {
        my $end = _expression( $state, $index, 1 );
        $index = $end > $index ? $end : $index + 1;
    }
    return [ map { $state->{records}[$_] } 0 .. $#$items ];
}

# Past the last token the list ends as a stop would end it.
sub _item ( $state, $index ) {
    return $state->{items}[$index] || [ 'stop', q{} ];
}

# A word that the table does not know takes its operands as a list operator does.
sub _record ( $state, $index, $position, %parts ) {
    my $text  = _item( $state, $index )->[1];
    my $level = $position eq 'infix' ? $INFIX{$text}[0] : $PREFIX{$text};
    $state->{records}[$index] = {
        position => $position,
        level    => defined $level ? $level : $LIST,
        map { ( $_ => $parts{$_} ) } grep { $parts{$_}[1] > $parts{$_}[0] } keys %parts
    };
    return;
}

sub _infix ( $state, $index ) {
    my ( $kind, $text ) = _item( $state, $index )->@*;
    return $kind eq 'operator' || $kind eq 'word' ? $INFIX{$text} : undef;
}

# Whether a token can start an operand: a term, a structure, a word that is no operator, or an operator before its operand.
sub _starts ( $state, $index ) {
    my ( $kind, $text ) = _item( $state, $index )->@*;
    return 0 if $kind eq 'stop' || $kind eq 'subscript';
    return defined $PREFIX{$text}          ? 1 : 0 if $kind eq 'operator';
    return !$STOP{$text} && !$INFIX{$text} ? 1 : 0 if $kind eq 'word';
    return 1;
}

sub _expression ( $state, $start, $least ) {
    my $index = _operand( $state, $start );
    return $start if $index == $start;
    while (1) {
        my ( $kind, $text ) = _item( $state, $index )->@*;
        if ( $kind eq 'operator' && ( $text eq '++' || $text eq '--' ) ) {
            _record( $state, $index, 'postfix', before => [ $start, $index ] );
            $index++;
            next;
        }
        my $infix = _infix( $state, $index ) or last;
        my ( $level, $rightward ) = $infix->@*;
        last if $level < $least;
        if ( $text eq q{?} ) {
            my $end = _conditional( $state, $start, $index );
            return $end if !$state->{records}[$index]{after};
            $index = $end;
            next;
        }
        my $end =
          $text eq '->'
          ? _arrow( $state, $index + 1 )
          : _expression( $state, $index + 1, $rightward ? $level : $level + 1 );
        _record( $state, $index, 'infix', before => [ $start, $index ], after => [ $index + 1, $end ] );
        $index = $end;
    }
    return $index;
}

# The first branch reaches its colon, and the second branch takes what binds tighter than the conditional itself.
sub _conditional ( $state, $start, $mark ) {
    my $colon = _expression( $state, $mark + 1, $ASSIGNMENT );
    my ( $kind, $text ) = _item( $state, $colon )->@*;
    my $end =
      $colon > $mark + 1 && $kind eq 'operator' && $text eq q{:}
      ? _expression( $state, $colon + 1, $CONDITIONAL )
      : $colon;
    my @branches = $end > $colon + 1 ? ( middle => [ $mark + 1, $colon ], after => [ $colon + 1, $end ] ) : ();
    _record( $state, $mark, 'infix', before => [ $start, $mark ], @branches );
    return $end;
}

# An arrow takes a method name, a subscript, or a list of arguments, and the subscripts after it.
sub _arrow ( $state, $index ) {
    my $kind = _item( $state, $index )->[0];
    return $index unless $kind eq 'word' || $kind eq 'subscript' || _starts( $state, $index );
    $index++;
    $index++ if _item( $state, $index )->[0] eq 'list';
    return _subscripts( $state, $index );
}

sub _subscripts ( $state, $index ) {
    $index++ while _item( $state, $index )->[0] eq 'subscript';
    return $index;
}

sub _operand ( $state, $index ) {
    return $index if !_starts( $state, $index );
    my ( $kind, $text ) = _item( $state, $index )->@*;
    return _prefixed( $state, $index, $text )                    if $kind eq 'operator';
    return _word( $state, $index, $text )                        if $kind eq 'word';
    return _expression( $state, $index + 1, $UNARY )             if $kind eq 'cast' && $text eq q{\\};
    return _subscripts( $state, _operand( $state, $index + 1 ) ) if $kind eq 'cast';
    return _subscripts( $state, $index + 1 );
}

sub _prefixed ( $state, $index, $text ) {
    my $end = _expression( $state, $index + 1, $PREFIX{$text} );
    _record( $state, $index, 'prefix', after => [ $index + 1, $end ] );
    return $end;
}

sub _word ( $state, $index, $text ) {
    my $next = $index + 1;
    my ($kind) = _item( $state, $next )->@*;
    return _subscripts( $state, _operand( $state, $next ) )           if $DECLARATOR{$text};
    return _anonymous( $state, $next )                                if $text eq 'sub';
    return _subscripts( $state, $next + 1 )                           if $BLOCK_TERM{$text} && $kind eq 'block';
    return _subscripts( $state, $kind eq 'list' ? $next + 1 : $next ) if $TERM{$text};
    my $level = $PREFIX{$text} || $LIST;

    # A parenthesis after the name makes the call a term, and a word without a known class is a term before an operator.
    return _subscripts( $state, $next + 1 ) if $kind eq 'list' && $level != $ASSIGNMENT;
    return _subscripts( $state, $next )
      if !_starts( $state, $next ) || ( !$PREFIX{$text} && $kind eq 'operator' );
    my $end = $level == $LIST ? _arguments( $state, $next ) : _expression( $state, $next, $level );
    _record( $state, $index, 'prefix', after => [ $next, $end ] );
    return $end;
}

# An anonymous subroutine holds a signature, a prototype, or attributes before its block.
sub _anonymous ( $state, $index ) {
    $index++ while grep { $_ eq _item( $state, $index )->[0] } qw(list term);
    return _item( $state, $index )->[0] eq 'block' ? _subscripts( $state, $index + 1 ) : $index;
}

# The operands of a list operator are expressions above the comma, and a block or a file handle may stand before them.
sub _arguments ( $state, $index ) {
    $index = _expression( $state, $index, $COMMA ) while _starts( $state, $index );
    return $index;
}

1;

__END__

=head1 NAME

Test::Mutation::Syntax::Precedence - the precedence and the associativity of every operator of Perl

=head1 SYNOPSIS

    my $levels = Test::Mutation::Syntax::Precedence::levels();
    my $parsed = Test::Mutation::Syntax::Precedence::parse(
        [ [ term => '$a' ], [ operator => q{+} ], [ term => '$b' ], [ operator => q{*} ], [ term => '2' ] ] );
    my $after_the_sum = $parsed->[1]{after};    # [ 2, 5 ]
    my $starts        = Test::Mutation::Syntax::Precedence::starts_operand(q{-});
    my $words         = Test::Mutation::Syntax::Precedence::terms();

=head1 DESCRIPTION

The table follows the section "Operator Precedence and Associativity" of L<perlop>, from the tightest level to the loosest.
The named unary operators and the list operators are the functions of L<perlfunc> that perl reads as such.
The file tests bind as named unary operators, as the section "Named Unary Operators" of L<perlop> says.

The parse reads one list of sibling tokens and finds the operands of each operator in it.
A structure such as a parenthesized list or a block is one token, and the analysis reads its inside as a list of its own.
A name or a parenthesized list after a list operator or a named unary operator makes a call that is a term.
A word that the table does not know is a term before an operator, as a constant is, and a list operator before a term.
The question mark of a conditional pairs with the colon at the depth of its siblings.
Its second branch takes what binds tighter than the conditional, so it ends before an assignment, a comma, a low C<not>, C<and>, C<or>, or C<xor>, a statement modifier, and a semicolon.

=head1 FUNCTIONS

=head2 levels

Returns the levels of the table, from the tightest to the loosest.
Each level holds its associativity and its infix, prefix, and postfix operators.

=head2 terms

Returns the functions that take no operand, which perl reads as a whole term.

=head2 starts_operand

Returns true for an operator or a word that can stand before its operand.

=head2 parse

Takes a list of tokens, each with its kind and its text, and returns a record for each token that is an operator, or nothing.
A kind is C<operator>, C<word>, C<cast>, C<term>, C<list>, C<block>, C<subscript>, or C<stop>.
A record holds the position of the operator, C<prefix>, C<infix>, or C<postfix>, and the spans of its operands as indexes into the list.
C<before> is the left operand, C<after> the right one, and C<middle> the first branch of a conditional.
C<level> is the level of the operator in its place, counted from one for the loosest level of the table.
A conditional without its colon or its second branch has neither C<middle> nor C<after>.
A word that takes no operand in its place has no record.

=cut
