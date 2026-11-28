use v5.36;
use Test2::V0;
use File::Temp ();
use lib 't/lib';
use Bounded;
use Raised;
use Test::Mutation::Mutant::Generator;
use Test::Mutation::Mutator::Catalog;
use Test::Mutation::Source;
use Test::Mutation::Syntax::PPI;

sub generated ( $code, %select ) {
    my $source = Test::Mutation::Source->new( path => 'lib/X.pm', text => $code, encoding => 'UTF-8' );
    my @perl   = exists $select{perl} ? ( perl => delete $select{perl} ) : ();
    my $mutators =
      Test::Mutation::Mutator::Catalog::choose( profile => 'default', enable => [], disable => [], %select );
    return Test::Mutation::Mutant::Generator::generate(
        source   => $source,
        analysis => Test::Mutation::Syntax::PPI::analyze($source),
        mutators => $mutators,
        @perl,
    );
}

sub mutants ( $code, %select ) {
    return generated( $code, %select )->{mutants};
}

sub changes ( $code, $name, %select ) {
    return [ map { [ $_->original, $_->replacement ] } grep { $_->mutator eq $name } mutants( $code, %select )->@* ];
}

sub refused ( $code, %select ) {
    return [ map { [ $_->@{qw(mutator line rule)} ] } generated( $code, %select )->{rejected}->@* ];
}

subtest 'the generator refuses a change that breaks the file' => sub {
    is refused("sub f {\n    return 1 + 2;\n}\n"), [], 'a file whose changes all stand';

    my $returned = "sub f {\n    return <<\"T\";\ntext\nT\n}\n";
    is refused($returned), [ [ 'return-value', 2, 'here-document' ] ],
      'a removed return value would leave the text of its here-document behind';
    is changes( $returned, 'sub-body' ), [ [ "\n    return <<\"T\";\ntext\nT\n", "\n\n\n\n" ] ],
      'and the removed body takes the here-document as a whole';
    is refused("f(<<A);\nx\nA\ng();\n"), [ [ 'statement-removal', 1, 'here-document' ] ],
      'a removed statement likewise';

    my $declaring = "sub f {\n    chomp( my \$line = g() );\n    return \$line;\n}\n";
    is refused($declaring), [ [ 'statement-removal', 2, 'declaration' ] ],
      'a removed statement would take a declaration that later code names';
    my $callback = 'configure(default => sub { my $bytes = read_bytes(); return $bytes });';
    is changes( "$callback\nsub other { my \$bytes = 4; return \$bytes }\n1;\n", 'statement-removal' ),
      [ [ $callback, q{} ] ], 'a lexical declaration in a callback ends inside the removable statement';
    my $read   = 'fetch(my $key);';
    my $unused = <<'PERL';
# $key appears here as documentation.
my @key = ('value');
my $quoted = '$key';
my $escaped = "\$key";
1;
PERL
    is changes( "$read\n$unused", 'statement-removal' ), [ [ $read, q{} ] ],
      'a comment, a literal, an escaped dollar sign, and another sigil leave the scalar unused';
    is refused( "$read\n" . 'return "key: $key";' ), [ [ 'statement-removal', 1, 'declaration' ] ],
      'an interpolated scalar keeps its declaration';

    for my $case (
        [ '@items', '$items[0]',   1 ],
        [ '@items', '$#items',     1 ],
        [ '%items', '$items{key}', 1 ],
        [ '$items', '${items}[0]', 1 ],
        [ '@items', '${items}[0]', 0 ],
        [ '$items', '$items[0]',   0 ],
        [ '$items', '\\$items',    0 ],
        [ '$items', '\\\\$items',  1 ],
      )
    {
        my ( $symbol, $interpolation, $needed ) = $case->@*;
        my $statement = "fetch(my $symbol);";
        my $source    = qq{sub example { $statement return "$interpolation"; }\n1;\n};
        is [ grep { $_->[0] eq $statement } changes( $source, 'statement-removal' )->@* ],
          $needed ? [] : [ [ $statement, q{} ] ], "$interpolation resolves the declared $symbol";
    }
    for my $case ( [ q{'END_TEXT'}, 0 ], [ 'END_TEXT', 1 ] ) {
        my ( $terminator, $needed ) = $case->@*;
        my $code = "$read\nmy \$message = <<$terminator;\n\$key\nEND_TEXT\n1;\n";
        is [ grep { $_->[0] eq $read } changes( $code, 'statement-removal' )->@* ],
          $needed ? [] : [ [ $read, q{} ] ], "a here-document introduced by $terminator";
    }
    my $shadow = 'my $other = sub { my $key = 1; return $key };';
    is [ grep { $_->[0] eq $read } changes( "$read\n$shadow\n1;", 'statement-removal' )->@* ], [ [ $read, q{} ] ],
      'a use bound to another lexical in a nested block does not need the outer declaration';
    is [ grep { $_->[0] eq $read } changes( "$read\n$shadow\n" . 'warn $key;', 'statement-removal' )->@* ], [],
      'a later use outside the shadow still needs the declaration';
    is changes( $read, 'statement-removal' ), [ [ $read, q{} ] ],
      'a declaration at the end of the file has no later reference';
    is [ grep { $_->[0] eq $read }
          changes( "$read\n" . 'if (my $key = $key) { warn $key }', 'statement-removal' )->@* ],
      [], 'the initializer of a shadowing condition still reads the outer lexical';
    is [ grep { $_->[0] eq $read }
          changes( "$read\n" . 'if (my $key = read_key()) { warn "$key" }', 'statement-removal' )->@* ],
      [ [ $read, q{} ] ], 'a reference in a conditional block uses the lexical from the condition';
    for my $loop (
        'for my $key (@items) { inspect($key) } continue { count($key) }',
        'for (my $key = first_key(); $key; --$key) { inspect($key) }'
      )
    {
        is [ grep { $_->[0] eq $read } changes( "$read\n$loop\n1;", 'statement-removal' )->@* ], [ [ $read, q{} ] ],
          'the loop variable shadows the outer lexical in the loop';
        is [ grep { $_->[0] eq $read } changes( "$read\n$loop\n" . 'warn $key;', 'statement-removal' )->@* ], [],
          'the same name after the loop refers to the outer lexical again';
    }
    is [ grep { $_->[0] eq $read }
          changes( "$read\n" . 'for my $key ($key) { inspect($key) }', 'statement-removal' )->@* ],
      [], 'the list supplying a foreach loop still sees the outer lexical';
    my $pair = 'consume(my $key) and record($key);';
    is [ grep { $_->[0] eq $pair } changes( "our \$key;\n$pair\n1;", 'statement-removal' )->@* ], [ [ $pair, q{} ] ],
      'a reference inside the removed expression cannot require its declaration later';
    is [ grep { $_->[0] eq $read } changes( 'our $key; { ' . $read . ' } warn $key;', 'statement-removal' )->@* ],
      [ [ $read, q{} ] ], 'the later package variable lies outside the block that declared a lexical';
    my $with_input = 'fetch($input, my $key);';
    is [ grep { $_->[0] eq $with_input } changes( "$with_input\n" . 'warn $key;', 'statement-removal' )->@* ], [],
      'a declaration after an ordinary argument still binds the later use';
    is [ grep { $_->[0] eq $read } changes( "$read\n" . 'my $key = other(); warn $key;', 'statement-removal' )->@* ],
      [ [ $read, q{} ] ], 'a later top-level declaration shadows the previous lexical through the end of the file';
    is refused( "if ( open my \$log, '<', \$p ) { print {\$log} 1 }\n", enable => ['condition-fixed'] ),
      [ [ 'condition-fixed', 1, 'declaration' ], [ 'condition-fixed', 1, 'declaration' ] ],
      'and so would either fixed condition';

    my $module = "package A;\nsub f { 2 }\n1;\n";
    is refused( $module, enable => ['number-literal'] ), [ [ 'number-literal', 3, 'final-value' ] ],
      'the true value that ends a module stays';
    is changes( $module, 'number-literal', enable => ['number-literal'] ), [ [ '2', '3' ] ],
      'and another number changes';

    is refused( "my \$s = \"a\nb\";\n", enable => ['string-literal'] ), [ [ 'string-literal', 1, 'line-count' ] ],
      'an emptied string of two lines would move every later line';
    my $wrapped = "if (\$a) { f() }\nelsif ( my \$m = g() ) { h(\$m) }\n";
    is changes( $wrapped, 'condition-negation' ), [ [ 'if', 'unless' ], [ ' my $m = g() ', '!( my $m = g() )' ] ],
      'a negated condition keeps the declaration that it wraps';
    is changes( "my \$t = \$c ? <<A : \$d;\ntext\nA\n", 'condition-negation' ), [ [ '<<A : $d', '$d : <<A' ] ],
      'and a swap of branches keeps an introducer on its line';
    is refused("my \$t = \$c\n  ? <<A\ntext\nA\n  : \$d;\n"), [ [ 'condition-negation', 2, 'here-document' ] ],
      'a swap that moves an introducer to another line would read the next line as its text';
    is refused('f() if !!$x;'), [ [ 'negation', 1, 'same-result' ] ],
      'the second of two changes with one resulting text';
    is changes( 'f() if !!$x;', 'negation' ), [ [ q{!}, q{} ] ], 'and the first one stands';
};

subtest 'a change that calls a function names one that the file resolves' => sub {
    my %with_swap = ( enable => ['call-swap'] );
    my $swap      = sub ($code) { return changes( $code, 'call-swap', %with_swap ) };
    is $swap->("use List::Util qw(any);\nmy \$ok = any { \$_ } \@c;\n"), [ [ 'any', 'List::Util::all' ] ],
      'the module of the original provides the other name';
    is $swap->("use List::Util qw(any all);\nmy \$ok = any { \$_ } \@c;\n"), [ [ 'any', 'all' ] ],
      'the file imports the other name';
    is $swap->("my \$m = List::Util::max(\@b);\n"), [ [ 'List::Util::max', 'List::Util::min' ] ],
      'a qualified call keeps its package';
    is $swap->("push \@a, 1;\nmy \$s = lc \$t;\n"), [ [ 'push', 'unshift' ], [ 'lc', 'uc' ] ], 'core functions';
    is $swap->("my \$m = max(\@b);\n"),             [], 'a name of unknown origin has no swap';
    is refused( "my \$m = max(\@b);\n", %with_swap ), [ [ 'call-swap', 1, 'unresolved-call' ] ],
      'and the refusal names the rule';
    is $swap->("sub max { 1 }\nmy \$m = max(\@b);\n"), [],                      'a subroutine of the file has no swap';
    is $swap->("use POSIX;\nmy \$n = ceil(\$x);\n"),   [ [ 'ceil', 'floor' ] ], 'a default export';
    is $swap->("use List::Util qw(any);\nuse List::Util qw(all);\nmy \$ok = any { \$_ } \@c;\n"),
      [ [ 'any', 'List::Util::all' ] ], 'two statements may import into two scopes, so the module is named';
    is $swap->("CORE::push \@a, 1;\n"), [ [ 'CORE::push', 'CORE::unshift' ] ],
      'a core function under its qualified name';
    is $swap->("sub unshift { 1 }\npush \@a, 1;\n"), [ [ 'push', 'CORE::unshift' ] ],
      'a subroutine of the file with the other name, which the bare word would make ambiguous';
    is changes( "sub pop { 1 }\nmy \$s = shift \@a;\nmy \$t = CORE::pop \@a;\n", 'shift-pop', enable => ['shift-pop'] ),
      [ [ 'shift', 'CORE::pop' ], [ 'CORE::pop', 'CORE::shift' ] ], 'the other family of core functions likewise';

    my $boolean = sub ($code) { return changes( $code, 'boolean-literal' ) };
    for my $module (qw(JSON JSON::PP Types::Serialiser)) {
        is $boolean->("use $module ();\nsub flag { \$_[0] ? ${module}::true : ${module}::false }\n1;\n"),
          [ [ "${module}::true", "${module}::false" ], [ "${module}::false", "${module}::true" ] ],
          "a qualified boolean keeps its provider $module";
    }
    is $boolean->("use v5.40;\nmy \$f = true;\n"), [ [ 'true', 'false' ] ], 'a boolean of the bundle';
    is $boolean->("use builtin qw(true);\nmy \$f = true;\n"), [ [ 'true', 'builtin::false' ] ],
      'a boolean that the file imports alone';
    is $boolean->("my \$f = true;\n"), [], 'a word that only looks like a boolean';
    my $local = <<'PERL';
package Flags;
sub true () { 1 }
sub enabled { return true() }
sub false () { 0 }
sub disabled { return false }
package Other { sub check { return true() } }
sub again { return true() }
1;
PERL
    is $boolean->($local), [ [ 'true', 'false' ], [ 'false', 'true' ], [ 'true', 'false' ] ],
      'the replacement resolves in the package of the call, including a later definition called with parentheses';
    is $boolean->('package Flags; sub true () { 1 } sub enabled { return true } sub false () { 0 } 1;'),
      [], 'a bare name needs its declaration before the call';
    is $boolean->('sub false (); sub true () { 1 } sub enabled { return true } sub false () { 0 } 1;'),
      [ [ 'true', 'false' ] ], 'a forward declaration makes a later definition visible';
    is $boolean->('sub false (); sub true () { 1 } sub enabled { return true() } 1;'),
      [], 'a forward declaration alone cannot supply a replacement';
    is $boolean->('sub Flags::true () { 1 } sub Flags::false () { 0 } package Flags { sub check { true() } } 1;'),
      [ [ 'true', 'false' ] ], 'qualified definitions belong to the named package';
    is $boolean->('package Flags { sub true () { 1 } sub check { true() } } package Other { sub false () { 0 } } 1;'),
      [], 'a peer in a separate package block cannot resolve the call';
    is $boolean->('package Other { sub false () { 0 } } sub true () { 1 } sub check { return true() } 1;'),
      [], 'the main package resumes after a package block';
    is $boolean->('my sub false () { 0 } sub true () { 1 } package Later; sub check { return true() } 1;'),
      [], 'a lexical subroutine cannot provide a replacement in a different package';
    is $boolean->('my sub spare () { 2 } sub main::false () { 0 } sub true () { 1 } sub check { return true() } 1;'),
      [ [ 'true', 'false' ] ], 'a main-package definition after a lexical declaration still resolves';
    is $boolean->('sub Flags::false () { 0 } package Flags { sub true () { 1 } sub check { return true() } } 1;'),
      [ [ 'true', 'false' ] ], 'a qualified definition is visible inside its matching package block';
    is $boolean->('sub Flags::false () { 0 } package Flags; sub true () { 1 } sub check { return true() } 1;'),
      [ [ 'true', 'false' ] ], 'a qualified definition is visible after a semicolon package declaration';
    is $boolean->('sub true () { 1 } { my sub false () { 0 } } sub check { return true() } 1;'),
      [], 'a lexical definition in another block cannot supply a package subroutine';

    my ($described) =
      grep { $_->mutator eq 'call-swap' }
      mutants( "use List::Util qw(any);\nmy \$ok = any { \$_ } \@c;\n", %with_swap )->@*;
    is $described->description, 'replaced any with List::Util::all', 'the description names what the mutant holds';
};

subtest 'a swapped call compiles' => sub {
    my $code =
        "use strict;\nuse warnings;\nuse List::Util qw(any max);\nmy \@c = ( 1, 2 );\n"
      . "sub unshift { return 1 }\n"
      . "print 'some' if any { \$_ > 1 } \@c;\nprint max(\@c), List::Util::max(\@c);\npush \@c, 3;\n";
    my $source = Test::Mutation::Source->new( path => 'lib/X.pm', text => $code, encoding => 'UTF-8' );
    my @swaps  = grep { $_->mutator eq 'call-swap' } mutants( $code, enable => ['call-swap'] )->@*;
    is [ map { $_->replacement } @swaps ], [ 'List::Util::all', 'List::Util::min', 'List::Util::min', 'CORE::unshift' ],
      'four swaps';
    for my $mutant (@swaps) {
        my $file = File::Temp->new( SUFFIX => '.pl' );
        print {$file} $source->replace_span( $mutant->start, $mutant->end, $mutant->replacement ) or die "write: $!";
        close $file                                                                               or die "close: $!";
        my $path   = $file->filename;
        my $answer = qx{'$^X' -c '$path' 2>&1};
        is [ $?, $answer ], [ 0, "$path syntax OK\n" ], 'perl compiles the file with ' . $mutant->replacement;
    }
};

subtest 'operator families' => sub {
    my $in_module = sub ( $code, @options ) { return changes( "$code\n1;\n", @options ) };
    is $in_module->( '$a + $b - $c * $d / $e % $f ** $g;', 'arithmetic' ),
      [ [ '+', '-' ], [ '-', '+' ], [ '*', '/' ], [ '/', '*' ], [ '%', '*' ], [ '**', '*' ] ], 'arithmetic';
    is $in_module->( 'f(-$a, +$b);', 'arithmetic' ), [], 'unary signs are left alone';
    my $comparisons = '$a < $b; $a >= $b; $a == $b; $a lt $b; $a eq $b; 1;';
    is $in_module->( $comparisons, 'comparison-boundary', enable => ['comparison-boundary'] ),
      [ [ '<', '<=' ], [ '>=', '>' ], [ 'lt', 'le' ] ],
      'numeric and string comparisons change their boundary';
    is $in_module->( $comparisons, 'comparison-negation' ),
      [ [ '<', '>=' ], [ '>=', '<' ], [ '==', '!=' ], [ 'lt', 'ge' ], [ 'eq', 'ne' ] ],
      'numeric and string comparisons reverse their answer';
    my $slurp = "my \$data = do {\n    local \$/;\n    open my (\$fh), '<:raw', \$path\n"
      . "      or die \"could not read file <\$path>\\n\";\n    <\$fh>;\n};\n";
    is $in_module->( $slurp, 'comparison-negation' ), [], 'a readline at the start of a statement is no comparison';
    is $in_module->( '$a && $b || $c // $d; f() or g() and h(); $e xor $f; $g ^^ $h;', 'logical' ),
      [
        [ '&&',  '||' ],
        [ '||',  '&&' ],
        [ '//',  '||' ],
        [ 'or',  'and' ],
        [ 'and', 'or' ],
        [ 'xor', 'or' ],
        [ '^^',  '||' ]
      ],
      'logical, with the exclusive or of both precedences';
    my $bitwise = sub ($code) { return $in_module->( $code, 'bitwise', enable => ['bitwise'] ) };
    is $bitwise->('my $m = $a & $b | $c ^ $d << 1 >> 2; $e &= 1; $f |= 2; $g ^= 3; $h <<= 1; my $n = ~$i;'),
      [
        [ q{&},  q{|} ],
        [ q{|},  q{&} ],
        [ q{^},  q{&} ],
        [ '<<',  '>>' ],
        [ '>>',  '<<' ],
        [ '&=',  '|=' ],
        [ '|=',  '&=' ],
        [ '^=',  '&=' ],
        [ '<<=', '>>=' ],
        [ q{~},  q{} ],
      ],
      'bitwise operators, their assignments, and the complement';
    is $bitwise->('use feature q(bitwise); my $s = $a &. $b |. $c ^. $d; $e &.= $f; my $t = ~.$g;'),
      [ [ '&.', '|.' ], [ '|.', '&.' ], [ '^.', '&.' ], [ '&.=', '|.=' ], [ '~.', q{} ] ],
      'and their string forms';
    is $bitwise->('my @bits = ( 1 << 0, 0x20 >> 0, 1 << 2, $mask >> 0, 2 << 0 + $n );'),
      [ [ '<<', '>>' ], [ '>>', '<<' ], [ '<<', '>>' ] ],
      'only shifts of a literal by a literal zero have the same result in either direction';
    is $in_module->( 'my @n = ( -$x, - $y, -1, 2 - 1, -bare => 1, $z ** -0.5 );', 'unary-minus' ),
      [ [ q{-}, q{} ], [ q{-}, q{} ], [ '-1', '1' ], [ '-0.5', '0.5' ] ],
      'a unary minus and a negative number lose their sign, and a subtraction and a dashed word stay';
    my $postfix = 'sub last_pair { return 0 .. $array->$#*-1 } sub size { $array->@* -2 }';
    is $in_module->( $postfix, 'unary-minus' ), [], 'a subtraction after a postfix dereference keeps its minus';
    is $in_module->( $postfix, 'arithmetic' ), [ [ '-', '+' ], [ '-', '+' ] ],
      'both subtractions expose their operator alone';
    is $in_module->( $postfix, 'number-literal', enable => ['number-literal'] ),
      [ [ '0', '1' ], [ '1', '2' ], [ '2', '3' ] ], 'each subtrahend is an unsigned literal';
    my $subtractions = 'sub f { return $_[0]-1, g($x)-2, ($x)-3, [$x]-4, $x++-5, $x---6, 0 .. -7 }';
    is $in_module->( $subtractions, 'unary-minus' ), [ [ '-7', '7' ] ],
      'a negative range endpoint is distinct from a subtrahend after a completed operand';
    is $in_module->( $subtractions, 'arithmetic' ), [ ( [ '-', '+' ] ) x 6 ],
      'subscripts, parenthesized calls, constructors, and postfix updates end before the subtraction sign';
    is $in_module->( '$i++; --$j;', 'increment' ), [ [ '++', '--' ], [ '--', '++' ] ], 'increment';
    is $in_module->( '$a += 1; $b .= "x"; $c //= 2; $d = 3;', 'assignment' ),
      [ [ '+=', '-=' ], [ '.=', '=' ], [ '//=', '||=' ] ],
      'assignment';
    is $in_module->( 'f() if !$a; g() unless not $b;', 'negation' ), [ [ '!', q{} ], [ 'not', q{} ] ], 'negation';
    is $in_module->( '$a =~ /x/; $b !~ /y/; $c =~ s/x/y/; $d =~ tr/a/b/;', 'match' ),
      [ [ '=~', '!~' ], [ '!~', '=~' ] ],
      'match negation skips substitution and transliteration';
};

subtest 'word families' => sub {
    is changes( 'if ($a) { f() } g() unless $b; while ($c) { h() } i() until $d;', 'condition-negation' ),
      [ [ 'if', 'unless' ], [ 'unless', 'if' ], [ 'while', 'until' ], [ 'until', 'while' ] ], 'conditional keywords';
    is changes(
        "if (\$a) { f() }\nelsif ( \$b > 1 ) { g() }\nmy \$v = \$c ? \$d + 1 : h(\$e), 2;\n",
        'condition-negation'
      ),
      [ [ 'if', 'unless' ], [ ' $b > 1 ', '!( $b > 1 )' ], [ '$d + 1 : h($e)', 'h($e) : $d + 1' ] ],
      'an elsif condition is negated, and the branches of a conditional swap';
    is changes( 'sub read_one { return $use_left ? <$left> : <$right> }', 'condition-negation' ),
      [ [ '<$left> : <$right>', '<$right> : <$left>' ] ], 'a branch swap moves both delimiters of each readline';
    is changes( 'for (@a) { next if $_; last; redo }', 'loop-control' ),
      [ [ 'next', 'last' ], [ 'last', 'next' ], [ 'redo', 'next' ] ], 'loop control, where a redo becomes a next';
    is changes( 'my @t = ( defined $x, exists $h{a}, wantarray, -e $p, -s $q > 1, ref $r, - $s );', 'predicate' ),
      [
        [ 'defined',   '!defined' ],
        [ 'exists',    '!exists' ],
        [ 'wantarray', '!wantarray' ],
        [ '-e',        '!-e' ],
        [ '-s',        '!-s' ]
      ],
      'a test of definedness, existence, context, or a file is negated';
    my $imports = "use v5.40;\nuse List::Util qw(max min any all);\n";
    is changes( $imports . 'push @a, max(@b); my %h = ( min => 1 ); $o->uc; any { $_ } @c;',
        'call-swap', enable => ['call-swap'] ),
      [ [ 'push', 'unshift' ], [ 'max', 'min' ], [ 'any', 'all' ] ], 'call swaps skip hash keys and methods';
    is changes( $imports . 'return true; my $f = false;', 'boolean-literal' ),
      [ [ 'true', 'false' ], [ 'false', 'true' ] ], 'booleans';
    is changes( 'my $s = shift;', 'shift-pop' ), [], 'shift-pop is off by default';
    is changes( 'my $s = shift;', 'shift-pop', enable => ['shift-pop'] ), [ [ 'shift', 'pop' ] ],
      'shift-pop when enabled';
};

subtest 'structural mutators' => sub {
    is changes( "sub f {\n    return 1 if \$x;\n    return 0;\n    return \$y + 1;\n    return;\n}\n", 'return-value' ),
      [ [ '1', '0' ], [ '0', '1' ], [ '$y + 1', q{} ] ], 'return values';
    is changes( "sub f {\n    log_it(\n        1,\n    );\n    return 1;\n}\n", 'statement-removal' ),
      [ [ "log_it(\n        1,\n    );", "\n\n" ] ], 'a removed statement leaves its line breaks';
    my $closing = "sub f {\n    log_it(1);\n    close \$out or die 'x';\n    closedir \$dir;\n    return 1;\n}\n";
    is changes( $closing, 'statement-removal' ), [ [ 'log_it(1);', q{} ] ],
      'the default profile leaves a close statement in place';
    is changes( $closing, 'close-removal', profile => 'extended' ),
      [ [ q{close $out or die 'x';}, q{} ], [ 'closedir $dir;', q{} ] ],
      'the extended profile removes a close and a closedir statement';
    is changes( $closing, 'close-removal' ), [], 'and the default profile has no such mutator';
    my $qualified = "sub f {\n    CORE::close(\$out);\n    CORE::closedir \$dir;\n    close_all();\n    return 1;\n}\n";
    is changes( $qualified, 'statement-removal' ), [ [ 'close_all();', q{} ] ],
      'a close under its qualified name stays in place, and a sub with a similar name is removed';
    is changes( $qualified, 'close-removal', profile => 'extended' ),
      [ [ 'CORE::close($out);', q{} ], [ 'CORE::closedir $dir;', q{} ] ],
      'the extended profile removes the qualified forms';
    is changes( "sub f {\n    g();\n}\nsub h { 1 }\nsub empty { }\n", 'sub-body' ),
      [ [ "\n    g();\n", "\n\n" ], [ ' 1 ', q{} ] ],
      'sub bodies';
};

subtest 'the computed return value of a module survives every proposed change' => sub {
    my $header = "package Truth;\nour (\$left, \$right);\nBEGIN { (\$left,\$right) = (3, 4) }\n";
    for my $tail ( q{}, 'sub later { 2 }', 'use strict;', 'package Other;', 'END { 1 }', '__DATA__' ) {
        my $code = $header . "\$left != \$right;\n$tail\n";
        is changes( $code, 'comparison-negation' ), [], "the comparison returns the module value before '$tail'";
        is [ grep { $_->[0] eq 'comparison-negation' } refused($code)->@* ],
          [ [ 'comparison-negation', 4, 'final-value' ] ],
          'the generator records the reason for the refusal';
    }
    is changes( $header . "\$left != \$right;\n1;\n", 'comparison-negation' ), [ [ '!=', '==' ] ],
      'an explicit later value leaves the comparison eligible';
    is changes( $header . "print \$left != \$right;\n", 'comparison-negation' ), [ [ '!=', '==' ] ],
      'an operand of the last output operation remains eligible';
    for my $expression ( '(( $left != $right ))', '($left + 1) != $right', '$left + 1 != $right' ) {
        is changes( "$header$expression", 'comparison-negation' ), [], 'a computed value may be grouped or end at EOF';
    }
    for my $after ( 'require strict;', 'package Last { 1 }' ) {
        is changes( $header . "\$left != \$right;\n$after\n", 'comparison-negation' ), [ [ '!=', '==' ] ],
          "the runtime value of $after follows the comparison";
    }
};

subtest 'mutants preserve the grammar of an open, a typeglob, a comparison, and a pattern' => sub {
    my $code = <<'PERL';
sub alias {
    no strict 'refs';
    if ($ready) { prepare() }
    *{'Alias::f'} = \&original;
    return $left * $right;
}
sub longer { return length > $limit || length($name) > $limit }
sub output {
    open STDERR, '>&', STDOUT;
    CORE::open(my $file, '>', 'path');
    $object->open($key, '>&', 'other');
}
1;
PERL
    is changes( $code, 'arithmetic' ), [ [ '*', '/' ] ], 'only multiplication changes into division';
    is changes( $code, 'comparison-negation' ), [ [ '>', '() <=' ], [ '>', '<=' ] ],
      'the introduced less-than sign follows an explicit empty call when the operand used the default';
    is changes( $code, 'string-literal', enable => ['string-literal'] ),
      [ [ q{'Alias::f'}, q{''} ], [ q{'path'}, q{''} ], [ q{'>&'}, q{''} ], [ q{'other'}, q{''} ] ],
      'open modes keep their meaning and a method of the same name takes ordinary string arguments';
    is changes( 'sub matches { $_[0] =~ /(^?a)\z+?|\A{1}b$/ }', 'regex-anchor', enable => ['regex-anchor'] ),
      [ [ '^', '(?:)' ], [ q{\z}, '(?:)' ], [ q{\A}, '(?:)' ], [ '$', q{} ] ],
      'quantifiers keep their own atom when its anchoring requirement is removed';
};

subtest 'changes to control flow and operands respect Perl precedence' => sub {
    is changes( 'sub cmp_args { foo($x + $y <=> g($z), "$x" cmp $hash{key}); }', 'three-way' ),
      [ [ '$x + $y <=> g($z)', 'g($z) <=> $x + $y' ], [ '"$x" cmp $hash{key}', '$hash{key} cmp "$x"' ] ],
      'each three-way comparison swaps both complete operands';
    is changes(
        'sub f { g() or return 3; g() && die "error"; g() // last LOOP; g() || log_it(); }',
        'early-exit', enable => ['early-exit']
      ),
      [ [ 'or return 3', q{} ], [ '&& die "error"', q{} ], [ '// last LOOP', q{} ] ],
      'only a guarded transfer of control loses its tail';
    is changes( 'sub f { return abs($x) + int -2; } sub g { return abs; }', 'call-removal' ),
      [ [ 'abs', q{} ], [ 'int', q{} ] ], 'absolute value and truncation keep their explicit arguments';
    is changes( 'sub f { my @s = reverse @x; my @t = sort @x; $obj->reverse; }', 'list-order', profile => 'extended' ),
      [ [ 'reverse', q{} ], [ 'sort', 'reverse sort' ] ], 'list order changes at a sort or an explicit reverse';
    is changes( 'sub f { my @a = CORE::reverse @x; my @b = CORE::sort(@x); }', 'list-order', profile => 'extended' ),
      [ [ 'CORE::reverse', q{} ], [ 'CORE::sort', 'CORE::reverse CORE::sort' ] ],
      'qualified builtins keep their namespace even when the project defines another reverse';
    my $filter = 'sub f { my @a = grep { my $x = $_; $x } @x; my @b = grep($_ > 2, @x); '
      . 'my @c = grep /abc/, @x; my $f = first { $_ } @x; $obj->grep(@x); }';
    is changes( $filter, 'filter-negation' ),
      [
        [ '{ my $x = $_; $x }', '{ !do { my $x = $_; $x } }' ],
        [ '$_ > 2',             '!($_ > 2)' ],
        [ '/abc/',              '!(/abc/)' ],
        [ '{ $_ }',             '{ !do { $_ } }' ],
      ],
      'grep and first negate their predicates while keeping their input lists';
};

sub flip_flop_cases () {
    my $ranges_in = sub ($text) {
        return grep { $_->mutator eq 'range-boundary' } mutants( $text, profile => 'extended' )->@*;
    };
    my $source = <<'CODE';
sub select_lines {
    for (@_) {
        next unless /^=head1 AUTHORS/ ... /^=/;
        return if ( $_ eq 'stop' ... $_ eq 'end' );
    }
}
sub ranges {
    my @copy = 1 ... $_[0];
    return [1 ... $_[0]] if check(1 ... $_[0]);
}
sub values {
    my $active = /begin/ ... /end/;
    my @result = scalar(/begin/ ... /end/);
    my $selected = (($active ... $result[0])) ? 1 : 0;
    return $selected;
}
sub arguments {
    my ($first) = /begin/ ... /end/;
    my $object = shift;
    return $object->scalar(/begin/ ... /end/);
}
sub unfinished { ... }
CODE
    my @ranges = $ranges_in->($source);
    is [ map { [ $_->from->[0], $_->original, $_->replacement ] } @ranges ],
      [ map { [ $_, '...', '..' ] } 3, 4, 12, 13, 14 ],
      'scalar assignments, explicit scalar context, and conditions evaluate the range endpoint earlier';
    my $blocks = <<'CODE';
my @selected = grep { /begin/ ... /end/ } @input;
my @sorted = sort { $a ... $b } @input;
my @mapped = map { /begin/ ... /end/ } @input;
my @all = grep { /begin/ ... /end/; 1 } @input;
CODE
    is [ map { $_->from->[0] } $ranges_in->($blocks) ], [ 1, 2 ],
      'a filter predicate and a sort comparator consume the final block value in scalar context';
    my $logical = <<'CODE';
sub through_list {
    my @items;
    @items = 1 ... 3 and return @items;
    push @items, 1 ... 3 or die;
    print 1 ... 3 or die;
}
sub through_condition {
    /begin/ ... /end/ and return 1;
    (/left/ ... /right/) or die;
}
sub through_callback {
    my $send = shift;
    &$send(1 ... 3) or die 'nothing sent';
}
CODE
    my @logical_ranges = $ranges_in->($logical);
    is [ map { $_->from->[0] } @logical_ranges ], [ 8, 9 ],
      'a logical operator tests its entire left operand after a list assignment or call finishes';
    my $stream = <<'CODE';
sub read_range {
    my ($first, $last, $input) = @_;
    my $right = $first ... <$input>;
    my @list = $first ... <$input>;
    my $left = <$input> ... $last;
    return $right if $first < $last;
}
CODE
    is [ map { $_->from->[0] } $ranges_in->($stream) ], [ 3, 5 ],
      'a scalar range can read either endpoint from a filehandle';
    is changes( $stream, 'comparison-negation' ), [ [ '<', '>=' ] ],
      'only the comparison outside the filehandle reads can be negated';
    return;
}

subtest 'a flip-flop can end on the same line as it starts' => sub {
    my ($ended) = Bounded::ended( 2, \&flip_flop_cases );
    ok $ended, 'range analysis terminates while following the enclosing syntax';
};

subtest 'guarded exits can be selected for a target with version-dependent startup code' => sub {
    my $code = <<'PERL';
use constant NEEDS_COMPAT => "$]" < 5.013_006;
BEGIN { NEEDS_COMPAT and (eval { die "missing configuration" if $ENV{NO_CONFIG}; 1 } or die $@) }
sub read_value { $_[0] or return 'missing'; return 'ready' }
PERL
    my $guards = [ [ 'or die $@', q{} ], [ "or return 'missing'", q{} ] ];
    is changes( $code, 'early-exit' ), [], 'the default profile leaves the guarded exits unchanged';
    is changes( $code, 'early-exit', profile => 'extended' ), $guards, 'the extended profile removes both exits';
    is changes( $code, 'early-exit', enable  => ['early-exit'], perl => 5.010001 ), $guards,
      'selecting the mutator keeps the startup guard on an older target';
    is changes( $code, 'early-exit', enable => ['@removal'] ), $guards, 'the removal group includes guarded exits';
};

subtest 'extended mutators' => sub {
    my %extended = ( profile => 'extended' );
    my @numbers  = (
        [ '0',                  '1' ],
        [ '1',                  '2' ],
        [ '-41',                '-40' ],
        [ '1_099',              '1100' ],
        [ '1.5',                '2.5' ],
        [ '1e2',                '101' ],
        [ '1e-3',               '1.001' ],
        [ '0644',               '0645' ],
        [ '0777',               '01000' ],
        [ '0o17',               '0o20' ],
        [ '0B1111',             '0B10000' ],
        [ '0x10',               '0x11' ],
        [ '-0x10',              '-0xf' ],
        [ '0xffffffffffffffff', '0x10000000000000000' ],
        [ 'v65',                'v66' ],
        [ 'v1.2.3',             'v1.2.4' ],
        [ '65.66.67',           '65.66.68' ],
    );
    my $literals = 'my @a = (' . join( q{, }, map { $_->[0] } @numbers ) . ');';
    is changes( $literals, 'number-literal', %extended ), \@numbers, 'each numeric class advances in its own base';
    my $fraction = '0.12345678901234567';
    my $changed  = changes( "my \$n = $fraction;", 'number-literal', %extended );
    is sprintf( '%a', $changed->[0][1] ), sprintf( '%a', $fraction + 1 ),
      'reading the replacement in Perl preserves the full increment';
    is changes( 'use v5.36; package Sample v1.2.3; our $VERSION = v1.2.3; 1;', 'number-literal', %extended ), [],
      'version declarations keep their numbers';
    is changes( q{my @s = ( 'abc', "", q{def}, qq<g$h> );}, 'string-literal', %extended ),
      [ [ q{'abc'}, q{''} ], [ q{""}, q{"mutant"} ], [ 'q{def}', 'q{}' ], [ 'qq<g$h>', 'qq<>' ] ],
      'string literals in quotes and under a quote operator';
    is changes( 'if ($a) { f() } while ($b) { g() } until ($c) { h() }', 'condition-fixed', %extended ),
      [ [ '$a', '1' ], [ '$a', '0' ], [ '$b', '0' ], [ '$c', '1' ] ], 'fixed conditions avoid endless loops';
    is changes( 'my @s = sort { $a <=> $b } @n; my %h = ( sort => 1 ); $o->sort;', 'list-order', %extended ),
      [ [ 'sort', 'reverse sort' ] ], 'a sort call is reversed, and a key or a method is left alone';
    is changes( 'for my $i ( 1 .. $n ) { f($i) } my $s = $a . $b;', 'range-boundary', %extended ),
      [ [ '..', '.. -1 +' ] ], 'the upper bound of a range moves down by one';
    my $patterns = 'f() if $x =~ /^ab+c*d?$/i; $y =~ s/\Afoo\z/b+r/g; my $r = qr/a{2,3}[+*^]\$(?i)z+?/msix;';
    is changes( $patterns, 'regex-anchor', %extended ), [ [ '^', q{} ], [ '$', q{} ], [ '\A', q{} ], [ '\z', q{} ] ],
      'anchors are removed, and an escaped or bracketed character is left alone';
    is changes( $patterns, 'regex-quantifier', %extended ), [ [ '+', '*' ], [ '*', '+' ], [ '?', q{} ], [ '+', '*' ] ],
      'quantifiers change, and a replacement or a repetition count is left alone';
    is changes( $patterns, 'regex-flag', %extended ),
      [ [ 'i', q{} ], [ 'g', q{} ], [ '(?i)', '(?:)' ], map { [ $_, q{} ] } qw(m s i) ],
      'each matching flag can be removed and substitution can also lose g';
    is changes( 'sub grouped { qr/(?im:x)(?-i:y)/ }', 'regex-flag', %extended ),
      [ [ '?im:', '?m:' ], [ '?im:', '?i:' ], [ '?-i:', '?:' ] ],
      'a scoped modifier keeps its group and drops an empty negative flag list';
    is changes( 'sub f { return /[\w][^^][^0]\d\W\s\S/g }', 'regex-class', %extended ),
      [
        [ '[\w]', '[^\w]' ],
        [ '\w',   '\W' ],
        [ '[^^]', '[\^]' ],
        [ '[^0]', '[0]' ],
        [ '\d',   '\D' ],
        [ '\W',   '\w' ],
        [ '\s',   '\S' ],
        [ '\S',   '\s' ],
      ],
      'bracket expressions and Perl character classes switch to their complements';
    my $indices = 'use constant INDEX => 1; sub f { my ($self, $word) = @_; '
      . 'return (qr/^$self->[ INDEX ][a-z]/, qr/a->[xy]/, qr/${word}->[ab]/) }';
    is changes( $indices, 'regex-class', %extended ),
      [ [ '[a-z]', '[^a-z]' ], [ '[xy]', '[^xy]' ], [ '[ab]', '[^ab]' ] ],
      'a subscript interpolated by Perl stays intact and adjacent character classes remain mutable';
    is changes( 'sub f { my $a = [1,2]; my $h = { x => 3 }; my @q = qw<one two>; $h->{x}; [ ]; }',
        'literal-collection', %extended ),
      [ [ '[1,2]', '[]' ], [ '{ x => 3 }', '{}' ], [ 'qw<one two>', 'qw<>' ] ],
      'nonempty anonymous arrays, hashes, and lists of words become empty';
    is changes(
        'sub f { my $v = (stat $_)[9]; my @t = (localtime)[5,4,3]; '
          . 'return ([7]->[0], f([8]), (split /:/, $_)[1]) }',
        'literal-collection',
        %extended
      ),
      [ [ '[7]', '[]' ], [ '[8]', '[]' ] ], 'indices of a list slice and dereference keep their expressions';
    is changes( 'sub f { return 0 if (stat("a"))[9] < (stat("b"))[9]; return [1] }', 'literal-collection', %extended ),
      [ [ '[1]', '[]' ] ], 'the list before a modifier-condition subscript produces values';
    is changes( 'sub f { my ($ref) = @_; my $item = ${$ref}[0][1]; ' . 'return map { $_ + 1 } [2, 3] }',
        'literal-collection', %extended ),
      [ [ '[2, 3]', '[]' ] ], 'a symbolic dereference keeps each index and a map block accepts an array literal';
    is changes( 'my $n = 41;', 'number-literal' ), [], 'extended mutators are off in the default profile';
};

subtest 'mutants carry positions, identities, and suppression' => sub {
    my $code = join "\n", 'my $a = 1 + 2;', 'my $b = 3 + 4;    ## no mutate',
      'my $c = 5 - 6;    ## no mutate (comparison-boundary)',
      'my $d = 7 * 8;    ## no mutate (comparison-boundary, arithmetic)', q{};
    my @mutants = mutants($code)->@*;
    is [ map { [ $_->from, $_->to, $_->suppressed ] } @mutants ],
      [
        [ [ 1, 11 ], [ 1, 12 ], 0 ],
        [ [ 2, 11 ], [ 2, 12 ], 1 ],
        [ [ 3, 11 ], [ 3, 12 ], 0 ],
        [ [ 4, 11 ], [ 4, 12 ], 1 ]
      ],
      'positions, and the comments of the second and the fourth line';
    my %ids = map { $_->id => 1 } @mutants;
    is scalar( keys %ids ),                   4,                           'identifiers are distinct';
    is [ map { $_->id } mutants($code)->@* ], [ map { $_->id } @mutants ], 'identifiers are stable across runs';

    my $reasons = join "\n", 'my $e = 1 - 2 > 0;    ## no mutate (comparison-boundary): the bound is fixed',
      '## no mutate: a block', 'my $f = 3 + 4;    ## no mutate (arithmetic)', 'my $g = 5 * 6;', '## use mutate', q{};
    is [ map { [ $_->from->[0], $_->mutator, $_->suppressed, $_->suppression_reason ] }
          mutants( $reasons, enable => ['comparison-boundary'] )->@* ],
      [
        [ 1, 'arithmetic',          0, undef ],
        [ 1, 'comparison-boundary', 1, 'the bound is fixed' ],
        [ 1, 'comparison-negation', 0, undef ],
        [ 3, 'arithmetic',          1, undef ],
        [ 4, 'arithmetic',          1, 'a block' ],
      ],
      'a mutant keeps the reason of the last comment that covers it';
};

subtest 'a mutant knows whether the compiled code shows it' => sub {
    my $code = "class Counter {\n    field \$step = 1 + 1;\n    method bump { \$step - 1 }\n}\n";
    is [ map { [ $_->original, $_->comparable ] } grep { $_->mutator eq 'arithmetic' } mutants($code)->@* ],
      [ [ '+', 0 ], [ '-', 1 ] ], 'a mutant of a field is not comparable';
};

subtest 'an arithmetic change without effect yields no mutant' => sub {
    is changes( '$a + 0; $b - 0; $c * 1; $d / 1; $e ** 1; $f + 0.0;', 'arithmetic' ), [],
      'zero added or subtracted, and one as a factor, a divisor, or an exponent';
    is changes( '$a + 1; $b * 0; 0 + $c; 1 * $d; $e % 1; $f + 0 * $g; $h - 0 if $i;', 'arithmetic' ),
      [ [ '+', '-' ], [ '*', '/' ], [ '+', '-' ], [ '*', '/' ], [ '%', '*' ], [ '+', '-' ], [ '*', '/' ] ],
      'another number, another side, another operator, and a number that belongs to a tighter operator';
};

subtest 'a comparison with the version of Perl keeps its boundary on another version' => sub {
    my $code          = 'f() if $] < 5.010; g() if "$]" >= 5.036; h() if 5.008 > $]; i() if $] <= 5.012001;';
    my %with_boundary = ( enable => ['comparison-boundary'] );
    is changes( $code, 'comparison-negation', perl => 5.044 ),
      [ [ '<', '>=' ], [ '>=', '<' ], [ '>', '<=' ], [ '<=', '>' ] ],
      'the tests run on another version, so the boundary changes nothing and the negation stays';
    is changes( $code, 'comparison-boundary', %with_boundary, perl => 5.036 ), [ [ '>=', '>' ] ],
      'the tests run on the named version, so the boundary of that comparison decides';
    is scalar( changes( $code, 'comparison-boundary', %with_boundary )->@* ), 4,
      'without the version of the tests every boundary stays';
    is changes( 'f() if $n < 5.010; g() if $] < $least;', 'comparison-boundary', %with_boundary, perl => 5.044 ),
      [ [ '<', '<=' ], [ '<', '<=' ] ],
      'another variable or no literal leaves the comparison as it is';
};

subtest 'two mutators with the same replacement yield one mutant' => sub {
    my @mutants = mutants( 'sub f { return 0 }', profile => 'extended' )->@*;
    is [ map { [ $_->mutator, $_->original, $_->replacement ] } grep { $_->original eq '0' } @mutants ],
      [ [ 'return-value', '0', '1' ] ], 'the first mutator is credited';

    my $source = Test::Mutation::Source->new( path => 'lib/X.pm', text => '$a + $b; 1;', encoding => 'UTF-8' );
    my @proposed =
      ( [ first => [q{-}] ], [ second => [ q{-}, q{*} ] ], [ third => [ q{*}, q{/} ] ], [ fourth => [ q{+}, q{%} ] ] );
    my $proposing = sub ( $name, $replacements ) {
        return Test::Mutation::Mutator->new(
            name        => $name,
            profile     => 'default',
            description => 'a test mutator',
            generate    => sub ($site) {
                return if $site->text ne q{+};
                return map { { replacement => $_, description => "to $_" } } $replacements->@*;
            },
        );
    };
    my $generated = Test::Mutation::Mutant::Generator::generate(
        source   => $source,
        analysis => Test::Mutation::Syntax::PPI::analyze($source),
        mutators => [ map { $proposing->( $_->@* ) } @proposed ],
    );
    is [ map { [ $_->mutator, $_->replacement ] } $generated->{mutants}->@* ],
      [ [ 'first', q{-} ], [ 'second', q{*} ], [ 'third', q{/} ], [ 'fourth', q{%} ] ],
      'a mutator keeps its later replacements after one that an earlier mutator proposed';
    is [ map { [ $_->@{qw(mutator line rule)} ] } $generated->{rejected}->@* ],
      [ [ 'second', 1, 'same-result' ], [ 'third', 1, 'same-result' ], [ 'fourth', 1, 'same-text' ] ],
      'the generator lists what it refused in the order of the proposals, and no mutator drops a proposal itself';
};

subtest 'selection' => sub {
    my $groups = Test::Mutation::Mutator::Catalog::choose(
        profile => 'default',
        enable  => [ '@regex',   '@literal' ],
        disable => [ '@removal', 'regex-flag' ]
    );
    my %selected = map { $_->name => 1 } $groups->@*;
    ok $selected{$_}, "$_ belongs to an enabled group"
      for qw(regex-anchor regex-class literal-collection number-literal string-literal);
    ok !$selected{$_}, "$_ was disabled"
      for qw(early-exit call-removal close-removal statement-removal sub-body regex-flag);
    my @default =
      map { $_->name }
      Test::Mutation::Mutator::Catalog::choose( profile => 'default', enable => [], disable => [] )->@*;
    my @extended =
      map { $_->name }
      Test::Mutation::Mutator::Catalog::choose( profile => 'extended', enable => [], disable => [] )->@*;
    is scalar(@extended), scalar( Test::Mutation::Mutator::Catalog::mutators()->@* ),
      'the extended profile holds every mutator';
    ok scalar(@default) < scalar(@extended), 'the default profile is a subset';
    is [ grep { $_ eq 'comparison-boundary' || $_ eq 'call-swap' || $_ eq 'bitwise' } @default ], [],
      'mutators above the measured structural equivalence limit require an explicit selection';
    is [
        grep { $_ eq 'arithmetic' }
        map  { $_->name }
          Test::Mutation::Mutator::Catalog::choose( profile => 'default', enable => [], disable => ['arithmetic'] )->@*
      ],
      [], 'a disabled mutator is removed';
    is Raised::error(
        sub {
            Test::Mutation::Mutator::Catalog::choose( profile => 'default', enable => [qw(nope none)], disable => [] );
        }
      ),
      [ 'usage', 'mutator-unknown', 'unknown mutator: nope, none' ], 'unknown names are refused together';
};

subtest 'every mutant of the corpus changes its span alone' => sub {
    my @broken;
    my $count = 0;
    for my $path ( sort glob 't/corpus/modern/*.pm' ) {
        open my $handle, '<:raw', $path or die "open $path: $!";
        my $bytes   = do { local $/ = undef; readline $handle };
        my $source  = Test::Mutation::Source->from_bytes( path => $path, bytes => $bytes );
        my $text    = $source->text;
        my $mutants = Test::Mutation::Mutant::Generator::generate(
            source   => $source,
            analysis => Test::Mutation::Syntax::PPI::analyze($source),
            mutators => Test::Mutation::Mutator::Catalog::mutators(),
        );
        for my $mutant ( $mutants->{mutants}->@* ) {
            $count++;
            my $mutated  = $source->replace_span( $mutant->start, $mutant->end, $mutant->replacement );
            my $expected = substr( $text, 0, $mutant->start ) . $mutant->replacement . substr( $text, $mutant->end );
            push @broken, $mutant->id
              if $mutated ne $expected
              || substr( $text, $mutant->start, $mutant->end - $mutant->start ) ne $mutant->original
              || $mutated eq $text;
        }
    }
    is \@broken, [], 'no mutant touches text outside its span';
    ok $count > 100, "the corpus yields mutants ($count)";
};

done_testing;
