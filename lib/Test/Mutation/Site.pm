package Test::Mutation::Site;
use v5.36;
use Moo;
use Types::Standard       qw(Bool Enum Int Str Tuple);
use Test::Mutation::Types qw(Facts);

our $VERSION = '0.001';

with 'Test::Mutation::Value';

has kind => (
    is  => 'ro',
    isa => Enum [
        qw(operator word number string regex statement condition sub_body return branches comparison guarded_exit filter collection)
    ],
    required => 1,
);
has text       => ( is => 'ro', isa => Str, required => 1 );
has start      => ( is => 'ro', isa => Int, required => 1 );
has end        => ( is => 'ro', isa => Int, required => 1 );
has role       => ( is => 'ro', isa => Str, default  => q{} );
has scope      => ( is => 'ro', isa => Tuple [ Int, Int ], required => 1 );
has facts      => ( is => 'ro', isa => Facts, default => sub { {} } );
has comparable => ( is => 'ro', isa => Bool,  default => 1 );

1;

__END__

=head1 NAME

Test::Mutation::Site - a place in a source file that a mutator can change

=head1 DESCRIPTION

A site describes one span of source text without reference to the parser that found it.
Mutators receive sites and return replacement text.

=head1 ATTRIBUTES

=head2 kind

Token sites have kind C<operator>, C<word>, C<number>, C<string>, or C<regex>.
Larger spans have kind C<statement>, C<condition>, C<sub_body>, C<return>, C<branches>, C<comparison>, C<guarded_exit>, C<filter>, or C<collection>.
A C<branches> site spans the two branches of a conditional operator, from the start of the first to the end of the second.
A C<comparison> spans its two operands and a C<guarded_exit> spans the guarding operator and the exit.
A C<filter> spans the predicate and a C<collection> spans the delimited literal.

=head2 text

The source text of the span.

=head2 start

The character offset of the first character of the span.

=head2 end

The character offset after the last character of the span.

=head2 role

How the text is used.
An operator is C<binary>, C<unary>, or C<update>.
A word is C<compound>, C<modifier>, C<control>, or C<call>.
A part of a pattern is an C<anchor>, C<quantifier>, C<class>, trailing C<flag>, or inline C<modifier>.

=head2 scope

The first and last line of the statement that runs the span.
A test reaches the site when it runs a line in this range.

=head2 facts

What the analysis learned about the span beyond its text, in the shape of L<Test::Mutation::Types/Facts>.
C<right> holds the number that is the whole right operand of an arithmetic operator, as L<Test::Mutation::Syntax::Precedence> bounds the operand.
C<operand> names the kind of the operand after a binding operator.
C<flip_flop> marks a three-dot range in a known scalar context.
C<branches> holds where the two branches of a conditional stand inside the span, and C<anchors> the places of the tokens that name a wider construct.
C<operands> gives the end of the left operand and the start of the right operand in a three-way comparison.
C<has_argument> marks a call with an explicit operand.
A key outside that shape is a fatal error, so a mutator reads no fact that the analysis never writes.

=head2 comparable

False when L<B::Deparse> leaves the code of the span out, as it does for a field and an C<ADJUST> block.
A change there never shows in the compiled code that the run compares.

=cut
