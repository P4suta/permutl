package Test::Mutation::Mutator::Declined;
use v5.36;
use Types::Standard qw(HashRef Str);
use Type::Params    qw(signature_for);

our $VERSION = '0.001';

# The constructs that no mutator of the catalog changes, each with the reason.
# A construct is named as the census of constructs names it: the class of its token, an operator, or a keyword with its text.
my @DECLINED = (
    [ 'a brace, a bracket, a parenthesis, or a semicolon groups code and computes nothing' => 'Structure' ],
    [ 'a comma separates the items of a list'                                              => 'operator ,' ],
    [ 'a fat comma separates a key from its value'                                         => 'operator =>' ],
    [ 'an arrow names the target of a dereference or of a call'                            => 'operator ->' ],
    [ 'the name of a variable has no counterpart that fits every place'                    => qw(Symbol ArrayIndex) ],
    [ 'the name of a special variable has no counterpart that fits every place'            => 'Magic' ],
    [ 'a sigil before a block or a reference names the type of the value'                  => 'Cast' ],
    [ 'a label names a loop'                                                               => 'Label' ],
    [ 'a prototype belongs to the declaration of a subroutine'                             => 'Prototype' ],
    [ 'an attribute belongs to a declaration'                                              => 'Attribute' ],
    [ 'the end mark of the code holds no behavior'                                         => 'Separator' ],
    [ 'the text after the data mark is no code'                                            => 'Data' ],
    [ 'a version number names a requirement'                                               => 'Number::Version' ],
    [
        'the text of a here-document stands on the lines after its introducer, outside the span of its token' =>
          'HereDoc'
    ],
    [ 'a readline takes the next record of a handle, and no other record fits its place' => 'QuoteLike::Readline' ],
    [
        'a transliteration pairs two lists of characters by place, and a change of one list is a change of a literal'
          => 'Regexp::Transliterate'
    ],
    [
        'a change of a concatenation or a repetition changes the look of a text, and most such mutants survive without a defect'
          => 'operator .',
        'operator x'
    ],
    [ 'a unary plus changes how perl parses what follows and computes nothing' => 'operator + (unary)' ],
    [
        'a plain assignment stores a value, and the mutants of the value and of its statement measure it' =>
          'operator ='
    ],
    [
        'keys and values give the same count in scalar context, so a swap of the two survives there' => 'word keys',
        'word values'
    ],
    [
        'a declaration names a variable for its scope and computes no value' => map { "word $_" }
          qw(my our state local)
    ],
    [
        'the analysis leaves a pragma, an import, and the name of a package out, as they run while perl compiles' =>
          map { "word $_" } qw(use no package)
    ],
    [ 'a removed require leaves the calls into its module without their code'       => 'word require' ],
    [ 'a do or an eval block runs the statements inside it, which hold the mutants' => map { "word $_" } qw(do eval) ],
    [
        'an else block runs when every condition before it fails, and condition-negation changes those conditions' =>
          'word else'
    ],
    [
        'a loop over a list runs its block for each item, and the mutants of the list, the block, and its loop control measure it'
          => map { "word $_" } qw(for foreach)
    ],
    [
        'a continue block runs after each pass of its loop, and the mutants of its statements measure it' =>
          'word continue'
    ],
    [ 'a goto names its target, and no other target fits its place'                             => 'word goto' ],
    [ 'a map gives what its block gives for each item, and the mutants of the block measure it' => 'word map' ],
    [
        'looking up an account by name has no counterpart that takes a name and returns its user ID or account record'
          => 'word getpwnam'
    ],
    [
        'a function that acts on a handle, a file, the network, or a process has no counterpart, and statement-removal removes the statements that call it'
          => 'QuoteLike::Backtick',
        'QuoteLike::Command',
        map { "word $_" } qw(chown exec fork getc gethostbyname getpgrp ioctl print printf say seek sysread system)
    ],
    [
        'a function of a value has no counterpart that takes the same operands, and the mutants of its operands measure it'
          => map { "word $_" }
          qw(caller each fc fileno glob gmtime length localtime log lstat oct ord prototype quotemeta rand readdir
          readlink ref split sprintf sqrt stat tell telldir undef unpack)
    ],

    # The profile slice of the plan brings the mutators of these constructs, and the census then refuses each reason here.
);

signature_for reasons => ( positional => [], returns => HashRef [Str] );

sub reasons () {
    my %reason;
    for my $row (@DECLINED) {
        my ( $reason, @constructs ) = $row->@*;
        $reason{$_} = $reason for @constructs;
    }
    return \%reason;
}

1;

__END__

=head1 NAME

Test::Mutation::Mutator::Declined - the constructs that no mutator changes, each with its reason

=head1 SYNOPSIS

    my $reasons = Test::Mutation::Mutator::Declined::reasons();
    print "$reasons->{'operator ,'}\n";

=head1 DESCRIPTION

Every construct of Perl either has a mutator in L<Test::Mutation::Mutator::Catalog> or a reason here.
A construct is named by the class of its token after C<PPI::Token::>, as C<Number::Version> for C<PPI::Token::Number::Version>, by C<operator> and the text of an operator, or by C<word> and the text of a keyword.
A sign carries its arity, as in C<operator + (unary)>.

The census of the mutant harness reads every token of a corpus, and it fails on a construct that neither a mutant changes nor this table declines.
It also fails on a reason that stands beside a mutant, so the table loses a construct when a mutator takes it.

=head1 FUNCTIONS

=head2 reasons

Returns each declined construct with its reason.

=cut
