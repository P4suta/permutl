use v5.36;
use Test2::V0;
use lib 't/lib';
use Bounded;
use Test::Mutation::Source;
use Test::Mutation::Syntax::PPI;

sub analyze ($code) {
    my $source = Test::Mutation::Source->new( path => 'lib/X.pm', text => $code, encoding => 'UTF-8' );
    my ( $ended, $analysis ) = Bounded::ended( 2, sub { return Test::Mutation::Syntax::PPI::analyze($source) } );
    die "analysis did not finish for $code\n" unless $ended;
    return $analysis;
}

sub sites_of ( $code, $kind ) {
    return [ grep { $_->kind eq $kind } analyze($code)->{sites}->@* ];
}

sub summary ( $code, $kind ) {
    return [ map { [ $_->text, $_->role ] } sites_of( $code, $kind )->@* ];
}

subtest 'BEGIN membership uses the character offsets of the original source' => sub {
    my $first  = 'BEGIN { 1 }';
    my $later  = "sub BEGIN {\r\n3;\r\n}";
    my $text   = "\x{feff}$first\r\nEND { 2 }\r\n$later\r\n1;\r\n";
    my $source = Test::Mutation::Source->new( path => 'X.pm', text => $text, encoding => 'UTF-8' );
    my @inside = grep { Test::Mutation::Syntax::PPI::inside_begin( $source, $_ ) } 0 .. length $text;
    my $start  = index $text, $later;
    is \@inside, [ 1 .. length($first), $start .. $start + length($later) - 1 ],
      'the mark, CRLF, neighboring END block and bytes beyond the closing brace are outside the BEGIN blocks';
    for my $code ( "my \$a = 1;\n", "my \$a = 1;\x0bmy \$b;\n" ) {
        my $other = Test::Mutation::Source->new( path => 'Y.pm', text => $code, encoding => 'UTF-8' );
        is Test::Mutation::Syntax::PPI::inside_begin( $other, 0 ), 0,
          'a source with no observable BEGIN block supplies no attribution';
    }
    my $location = PPI::Element->can('location');
    for my $missing ( 'BEGIN', '}' ) {
        no warnings 'redefine';
        local *PPI::Element::location = sub ($token) {
            return if $token->content eq $missing;
            return $token->$location();
        };
        is Test::Mutation::Syntax::PPI::inside_begin( $source, 3 ), 0,
          'a block with an unlocated endpoint cannot establish where the replacement occurred';
    }
    isa_ok dies { Test::Mutation::Syntax::PPI::inside_begin( $source, 1, 'extra' ) }, ['Error::TypeTiny'],
      'the public lookup checks its source and offset arguments';
};

subtest 'a replacement call is observed in its nearest executable statement and package' => sub {
    my $code = <<'PERL';
package Other;
sub min { 1 }
package Local;
use List::Util qw(min sum);
sub pick { 2 }
sub total { return (sum(1, min(2, 3)) + pick()); }
PERL
    my %lookups;
    my $lookup = Test::Mutation::Syntax::PPI->can('_package_of');
    no warnings 'redefine';
    local *Test::Mutation::Syntax::PPI::_package_of = sub ($node) {    ## no critic (Variables::ProtectPrivateVars)
        $lookups{ $node->content }++ if $node->isa('PPI::Token::Word');
        return $lookup->($node);
    };
    my %calls = map { $_->text => $_->facts } grep { $_->role eq 'call' } sites_of( $code, 'word' )->@*;
    for my $name (qw(sum min pick)) {
        is $calls{$name}{call_offset}, index( $code, 'return' ),
          "the probe for $name belongs to the return statement enclosing the expression";
    }
    is $lookups{sum}, undef, 'an imported name absent from the declarations needs no namespace walk';
    ok $lookups{min},                    'a name declared in another package requires a namespace lookup';
    ok !exists $calls{sum}{local_calls}, 'an imported function has no list of local replacements';
    ok !exists $calls{min}{local_calls}, 'a function of the same name in another package provides no local replacement';
    ok exists $calls{pick}{local_calls}, 'a declared function carries the candidates from its own package';
};

subtest 'every site addresses its own text' => sub {
    my $code     = "use v5.36;\nsub f (\$x) {\n    return \$x + 1 if \$x > 0;\n    return -\$x;\n}\n";
    my $analysis = analyze($code);
    is $analysis->{problem}, undef, 'no problem';
    my @wrong = grep { substr( $code, $_->start, $_->end - $_->start ) ne $_->text } $analysis->{sites}->@*;
    is \@wrong, [], 'text equals the span';
    ok scalar( $analysis->{sites}->@* ), 'sites exist';
};

subtest 'operators carry a role' => sub {
    is summary( 'my $y = $a + $b - -$c; $y++; my $z = !$y;', 'operator' ),
      [
        [ '=',  'binary' ],
        [ '+',  'binary' ],
        [ '-',  'binary' ],
        [ '-',  'unary' ],
        [ '++', 'update' ],
        [ '=',  'binary' ],
        [ '!',  'unary' ]
      ],
      'binary, unary, and update operators';
    is summary( 'return - $x;', 'operator' ), [ [ '-', 'unary' ] ], 'minus after return is unary';
    my $aliases = q!sub bind { if ($ok) { *{'A::first'} = \&first; } *{'A::second'} = \&second; return $a * $b }!;
    is [ map { $_->role } grep { $_->text eq '*' } sites_of( $aliases, 'operator' )->@* ], [ 'unary', 'binary' ],
      'the typeglob after a conditional assignment is distinct from the multiplication that follows it';
    is [ map { $_->role } grep { $_->text eq '*' } sites_of( 'my $value = $factor * { pairs() };', 'operator' )->@* ],
      ['binary'], 'a completed left operand multiplies a hash reference even when PPI calls the braces a block';
    my $postfix = 'sub f { my $n = \\ -4; $r->@*; return $r->$#*-1 + $r->$*-2 }';
    is [ map { $_->text } sites_of( $postfix, 'number' )->@* ], [ '-4', '1', '2' ],
      'a prefix reference keeps its signed operand and each postfix dereference ends before the subtraction';
    is [ map { $_->text } grep { $_->text eq '-' } sites_of( $postfix, 'operator' )->@* ], [ '-', '-' ],
      'both subtraction signs have operator spans';
    is summary( 'sub last_index { $r->$#* }', 'operator' ), [ [ '->', 'binary' ] ],
      'a postfix dereference can end its statement';
    is [ map { $_->text } sites_of( 'sub first { -1 } sub second { $a[0]-2e-3 }', 'number' )->@* ],
      [ '-1', '0', '2e-3' ], 'a leading minus and the sign in an exponent belong to the number';
    my $shifts = 'my @n = ( 1 << 0, $mask >> 0, 2 & 0, 2 << 0 + $n );';
    is [ map { $_->facts->{right} } grep { $_->text =~ /\A(?:<<|>>|&)\z/ } sites_of( $shifts, 'operator' )->@* ],
      [ 0, undef, undef, undef ], 'a shift names a literal count when its left operand is also a literal';
    is [ map { $_->facts->{operand} } sites_of( '$a =~ /x/; $b =~ s/x/y/; $c !~ $re;', 'operator' )->@* ],
      [ 'match', 'substitute', 'match' ], 'binding operators name their operand';
    my $code = '$a + 0; $b - 0.0; $c * 1 + $d; $e + 0 * $f; $g * 1 ** $h; $i / $j; 0 + $k; $l - 1 if $m; f( $n + 0 );';
    is [ map { $_->text . ( defined $_->facts->{right} ? $_->facts->{right} : q{?} ) }
          sites_of( $code, 'operator' )->@* ],
      [qw(+0 -0 *1 +? +? *? *? **? /? +? -1 +0)],
      'an arithmetic operator names a number that is its whole right operand';
    my $versions = '$] < 5.010; "$]" >= 5.036; 5.008 > $]; $] == 5.010; $n < 5.010; $] < $least; $] >= 5.36.0;';
    is [ map { $_->text . ( defined $_->facts->{version} ? $_->facts->{version} : q{?} ) }
          sites_of( $versions, 'operator' )->@* ],
      [qw(<5.01 >=5.036 >5.008 ==? <? <? >=?)],
      'an ordering comparison of the version of Perl names its literal';
    is [ map { $_->text } sites_of( 'f( [ < $in ] );', 'operator' )->@* ], ['<'],
      'a comparison without a neighbor on one side is read without a literal';
    my $unfinished = 'my $active = $start ...; my $complete = $start ... $end;';
    is [ map { $_->facts->{flip_flop} } grep { $_->text eq '...' } sites_of( $unfinished, 'operator' )->@* ],
      [ undef, 1 ], 'a scalar assignment supplies a flip-flop only when both operands are present';
};

subtest 'condition keywords used as method names take list arguments' => sub {
    my $code = <<'PERL';
sub route {
    my ($rule, $first, $last) = @_;
    $rule->if($first ... $last);
    return 1 if (($first ... $last));
    my @values = $rule->if + $first ... $last;
    my $active = $rule->if + $first ... $last;
    my @other = $rule->if() + $first ... $last;
}
PERL
    is [ map { $_->facts->{flip_flop} } grep { $_->text eq '...' } sites_of( $code, 'operator' )->@* ],
      [ undef, 1, undef, 1, undef ], 'the assignment sets the context of a range starting with a method result';
};

subtest 'a readline that the parser takes for two comparisons yields no site' => sub {
    my $operators = sub ($code) {
        return [ map { $_->text } sites_of( $code, 'operator' )->@* ];
    };
    my @misread = (
        [ '<$fh>;',                     [] ],
        [ 'return <$fh>;',              [] ],
        [ 'print <STDIN>;',             [] ],
        [ 'f( [ [<$in>] ] );',          [] ],
        [ 'my @lines = sort <$fh>;',    ['='] ],
        [ 'print <$fh>, "\n";',         [','] ],
        [ 'my @l = sort <$fh> if $ok;', ['='] ],
        [ 'print $out <$in{ 1 + 2 }>;', [] ],
        [ '$a < $b or print <$fh>;',    [ '<', 'or' ] ],
        [ "\$x >;\nprint <\$fh>;",      ['>'] ],
    );
    is $operators->( $_->[0] ), $_->[1], "the operators of $_->[0]" for @misread;

    is $operators->('f( $a > -$b, $c < !$d, $e > ++$f, $g > -e $h, $i > length $j, $k > $l );'),
      [ '>', q{-}, q{,}, '<', q{!}, q{,}, '>', '++', q{,}, '>', '-e', q{,}, '>', q{,}, '>' ],
      'a comparison keeps its sites before each kind of right operand';
};

subtest 'words carry a role and data words are left out' => sub {
    is summary( 'if ($x) { push @a, max(1, 2) } foo() unless $y; last if $z;', 'word' ),
      [
        [ 'if',     'compound' ],
        [ 'push',   'call' ],
        [ 'max',    'call' ],
        [ 'foo',    'call' ],
        [ 'unless', 'modifier' ],
        [ 'last',   'control' ],
        [ 'if',     'modifier' ]
      ],
      'compound keyword, calls, modifiers, loop control';
    is summary( 'my %h = ( max => 1 ); $h{min}; $obj->push(1); Foo::Bar->new; sub lc { 1 }', 'word' ),
      [],
      'declarators, hash keys, subscripts, method names, class names, and sub names produce no site';
};

subtest 'excluded regions produce no sites' => sub {
    is analyze("use List::Util 1.45 qw(max);\nno warnings;\npackage Foo;\nour \$VERSION = '1.2' + 0;\n")->{sites},
      [], 'imports, pragmas, package declarations, and version assignments';
    is summary( "1;\n__END__\nmy \$x = 1 + 2;\n", 'operator' ), [], 'text after __END__';
    is summary( "=pod\n\n1 + 2\n\n=cut\n\n# 3 + 4\nmy \$s = '5 + 6';\n", 'operator' ), [ [ '=', 'binary' ] ],
      'POD, comments, and string contents';
    is summary( "my \$t = <<~EOT;\n    1 + 2\n    EOT\nmy \$u = 3 - 4;\n", 'operator' ),
      [ [ '=', 'binary' ], [ '=', 'binary' ], [ '-', 'binary' ] ], 'heredoc bodies';
};

subtest 'a package block holds sites like any other code' => sub {
    my $code = <<'PERL';
package Outer::Inner {
    sub total ($x) { return $x + 1 }
    log_it('loaded');
}
package Outer::Versioned 1.2 {
    sub twice ($x) { return $x * 2 }
    register(4);
}
package Outer::Plain;
sub minus ($x) { return $x - 3 }
PERL
    is [ map { [ $_->kind, $_->text, $_->scope ] } grep { $_->kind ne 'word' } analyze($code)->{sites}->@* ],
      [
        [ 'sub_body',  ' return $x + 1 ',    [ 2,  2 ] ],
        [ 'return',    '$x + 1',             [ 2,  2 ] ],
        [ 'operator',  q{+},                 [ 2,  2 ] ],
        [ 'number',    '1',                  [ 2,  2 ] ],
        [ 'statement', q{log_it('loaded');}, [ 3,  3 ] ],
        [ 'string',    q{'loaded'},          [ 3,  3 ] ],
        [ 'sub_body',  ' return $x * 2 ',    [ 6,  6 ] ],
        [ 'return',    '$x * 2',             [ 6,  6 ] ],
        [ 'operator',  q{*},                 [ 6,  6 ] ],
        [ 'number',    '2',                  [ 6,  6 ] ],
        [ 'statement', 'register(4);',       [ 7,  7 ] ],
        [ 'number',    '4',                  [ 7,  7 ] ],
        [ 'sub_body',  ' return $x - 3 ',    [ 10, 10 ] ],
        [ 'return',    '$x - 3',             [ 10, 10 ] ],
        [ 'operator',  q{-},                 [ 10, 10 ] ],
        [ 'number',    '3',                  [ 10, 10 ] ],
      ],
      'the bodies of two package blocks and the code after a package statement, without the names and the version';
};

subtest 'a call of a function with the name of a declaration is no declaration' => sub {
    my $code = q{class 'Name' => 1 + 2; method foo => sub { g() }; sub { f() }->();};
    is sites_of( $code, 'sub_body' ), [], 'no body site';
    is [ map { $_->text } sites_of( $code, 'statement' )->@* ], [ 'g()', 'f()' ],
      'the blocks of the anonymous subs hold statements';
    is [ map { $_->text } grep { $_->role eq 'binary' } sites_of( $code, 'operator' )->@* ], [ '=>', q{+}, '=>', '->' ],
      'the arguments keep their sites';
};

subtest 'a lone word with the name of a declaration is analyzed without an error' => sub {
    is [ map { analyze($_)->{problem} } 'class', 'method', 'sub', 'finally', 'ADJUST', 'field' ], [ (undef) x 6 ],
      'no problem and no exception';
};

subtest 'unary operators and operators after a word' => sub {
    is summary( 'my $z = ~$y; my $r = \$y; my $n = not $y; my $t = time - $x;', 'operator' ),
      [
        [ q{=},  'binary' ],
        [ q{~},  'unary' ],
        [ q{=},  'binary' ],
        [ q{=},  'binary' ],
        [ 'not', 'unary' ],
        [ q{=},  'binary' ],
        [ q{-},  'binary' ],
      ],
      'complement and not are unary, a reference is no operator, and a minus after a function name is binary';
    is summary( 'f( length -$x, join -$y, LIMIT - $z, $o->size -$w, -e $p );', 'operator' ),
      [
        [ q{-}, 'unary' ],
        [ q{,}, 'binary' ],
        [ q{-}, 'unary' ],
        [ q{,}, 'binary' ],
        [ q{-}, 'binary' ],
        [ q{,}, 'binary' ],
        [ '->', 'binary' ],
        [ q{-}, 'binary' ],
        [ q{,}, 'binary' ],
        [ '-e', 'unary' ],
      ],
      'a sign after an operator of the table starts its operand, and one after a constant or a method stands between two';
    is summary( 'my $x = $p ^^ $q;', 'operator' ), [ [ q{=}, 'binary' ], [ '^^', 'binary' ] ],
      'two carets without a space between are the logical exclusive or';
    is summary( 'my $x = $p ^ ^$q;', 'operator' ), [ [ q{=}, 'binary' ], [ q{^}, 'binary' ], [ q{^}, 'binary' ] ],
      'and with a space they are two tokens';
    is [ map { $_->text } sites_of( 'my $v = $p ^^ $q ? $left : $right;', 'branches' )->@* ], ['$left : $right'],
      'operators after a logical exclusive or still have both operands';
};

subtest 'the branches of a conditional operator' => sub {
    my $code = "my \$r = \$c ? \$a + 1 : f(\$b), 2;\nmy \$s = \$c\n  ? \$d ? 3 : 4\n  : 5 or g();\n";
    is [ map { [ $_->text, $_->facts->{branches}, $_->scope ] } sites_of( $code, 'branches' )->@* ],
      [
        [ '$a + 1 : f($b)',     [ 6,  9 ],  [ 1, 1 ] ],
        [ "\$d ? 3 : 4\n  : 5", [ 10, 15 ], [ 2, 4 ] ],
        [ '3 : 4',              [ 1,  4 ],  [ 2, 4 ] ]
      ],
      'each conditional with the length of its first branch and the place of its second one';
    is [ map { $_->facts->{loose} }
          sites_of( "my \$r = \$c ? \$a = 1 : 2;\nmy \$s = \$c ? \$d ? \$a = 1 : 2 : 3;\n", 'branches' )->@* ],
      [ 1, undef, 1 ],
      'a first branch with an assignment at its top binds looser than the conditional, and one with a conditional at its top does not';
    is [ map { $_->facts->{loose} } sites_of( 'my $r = $c ? $obj->{key} = 1 : 0;', 'branches' )->@* ], [1],
      'the assignment spans the first branch even when its target contains a tighter operator';
    my $grouped = "(\r\n3\r\n)";
    is [ map { $_->text } sites_of( "my \$v = \$ok ? $grouped : $grouped;\r\n", 'branches' )->@* ],
      ["$grouped : $grouped"], 'grouped branches keep the line endings between their boundary tokens';
    my $quoted = "\"a\r\nb\"";
    for my $branches ( "$quoted : 2", "1 : $quoted" ) {
        is sites_of( "my \$v = \$ok ? $branches;\r\n", 'branches' ), [],
          'exchanging two branches requires verified source offsets for both';
    }
    my ($first) = sites_of( $code, 'branches' )->@*;
    is [ map { substr $code, $_->[0], $_->[1] - $_->[0] } $first->facts->{anchors}->@* ], [ q{?}, q{:} ],
      'and the places of its question mark and its colon';
    my $unpaired = analyze("my \$t = \$c ? 1 : ;\nmy \$u = 2;\n");
    is $unpaired->{dropped},
      [ { line => 1, kind => 'conditional', reason => 'the conditional operator has no colon or no second branch' } ],
      'a conditional that fails to pair is a place left out';
};

subtest 'a site wider than a token names the token of its construct' => sub {
    my $code     = "sub f {\n    if (\$a) { g() } elsif (\$b) { return \$c + 1 }\n}\n";
    my $anchored = sub ($kind) {
        return [
            map {
                [ map { substr $code, $_->[0], $_->[1] - $_->[0] } $_->facts->{anchors}->@* ]
            } sites_of( $code, $kind )->@*
        ];
    };
    is $anchored->('condition'), [ ['if'], ['elsif'] ], 'a condition names its keyword';
    is $anchored->('return'),    [ ['return'] ],        'a return value its word';
    is $anchored->('sub_body'),  [ ['sub'] ],           'the body of a subroutine its declaration';
    is $anchored->('statement'), [ ['g'] ],             'and a statement the function that it calls first';
};

subtest 'a word with an argument or inside a list is a call' => sub {
    is summary( '$h{ lc $key }; f(shift); my @l = (pop);', 'word' ),
      [ [ 'lc', 'call' ], [ 'f', 'call' ], [ 'shift', 'call' ], [ 'pop', 'call' ] ],
      'a call inside a subscript, and a lone word inside parentheses';
};

subtest 'the parts of a pattern after an assertion that is no anchor' => sub {
    is summary( '$x =~ /\bfoo$/i;', 'regex' ), [ [ q{$}, 'anchor' ], [ 'i', 'flag' ] ],
      'a word boundary is no site, and the anchor and the flag after it are';
};

subtest 'blocks that hold code and blocks that hold data' => sub {
    my $code = join "\n", 'my @a = @{ list() };', 'sub attributed :lvalue { h() }', 'my $f = sub ($x) { g($x) };',
      'frobnicate { k() } 1;', 'print {*STDERR} l();', q{};
    is [ map { $_->text } sites_of( $code, 'statement' )->@* ], [ 'h()', 'g($x)' ],
      'a sub with an attribute or a signature holds statements, and a dereference, a block after an unknown word, and a file handle block do not';
};

subtest 'a token whose reported place holds other text yields no site' => sub {
    my $reported = \&PPI::Element::location;
    my $code     = "if (\$a) { f(1) }\nif (\$b) { f(1) + 3; }\nif (\$a + 2) { }\n";
    my $sites    = do {
        no warnings 'redefine';
        local *PPI::Element::location = sub ($self) {
            my $place = $reported->($self) or return;
            return [ 1, $place->@[ 1 .. $place->$#* ] ];
        };
        analyze($code)->{sites};
    };
    is [ map { [ $_->kind, $_->text ] } $sites->@* ],
      [
        ( [ 'word',      'if' ] ) x 3,
        ( [ 'condition', '$a' ] ) x 2,
        ( [ 'word',      'f' ] ) x 2,
        [ 'statement', 'f(1)' ],
        ( [ 'number', '1' ] ) x 2,
      ],
      'a span stays when both of its ends hold the reported text, and it is dropped when one end does not';
};

subtest 'structural sites' => sub {
    my $code = <<'PERL';
sub total {
    my ($list) = @_;
    my $sum = 0;
    log_call('total');
    for my $n (@$list) {
        $sum += $n;
    }
    return 0 if !@$list;
    return $sum;
}
PERL
    is [ map { [ $_->text, $_->facts->{head} ] } sites_of( $code, 'statement' )->@* ],
      [ [ q{log_call('total');}, 'log_call' ], [ '$sum += $n;', q{} ] ],
      'expression statements are deletable, declarations and returns are not, and a leading word is named';
    is [ map { [ $_->text, $_->facts->{literal} ] } sites_of( $code, 'return' )->@* ],
      [ [ '0', '0' ], [ '$sum', undef ] ],
      'return expressions stop before a modifier';
    my ($body) = sites_of( $code, 'sub_body' )->@*;
    is $body->facts->{name}, 'total',   'the sub body is named';
    is $body->scope,         [ 1, 10 ], 'the sub body scope is the whole sub';
    like $body->text, qr/\A\n    my \(\$list\).*return \$sum;\n\z/s, 'the body span is inside the braces';
    is [ map { [ $_->text, $_->facts->{keyword} ] }
          sites_of( 'if ( $a > 1 ) { f() } elsif ($b) { g() } while ($c) { h() }', 'condition' )->@* ],
      [ [ ' $a > 1 ', 'if' ], [ '$b', 'elsif' ], [ '$c', 'while' ] ], 'conditions';
};

subtest 'a statement whose removal breaks the file is not deletable' => sub {
    my $code = <<'PERL';
sub f {
    my ( $fh, @data ) = @_;
    print( {$fh} map { lc } @data );
    my @kept = grep { defined && length } @data;
    my %seen = map { my $key = lc; note($key); ( $key => 1 ) } @kept;
    open( my $in, '<', $data[0] ) or die;
    close $in;
    split_pair( my ( $left, $right ) = @data );
    note($right);
    ( my $name = $data[1] ) =~ s/x/y/;
    bless \( my $unused = 1 ), 'Flag';
    push @kept, do { my $inner = 1; note($inner) };
    my $inner = 2;
    eval <<'CODE' or die;
1;
CODE
    return $name;
}
sub g {
    bless \( my $late = 1 ), 'Flag';
    return;
}
sub h { my $late = 2; return $late }
PERL
    is [ map { [ $_->text, $_->facts->{declares} ? 'declares' : () ] } sites_of( $code, 'statement' )->@* ],
      [
        ['print( {$fh} map { lc } @data );'], ['note($key);'],
        ['( $key => 1 )'], [ q{open( my $in, '<', $data[0] ) or die;},      'declares' ],
        ['close $in;'],    [ 'split_pair( my ( $left, $right ) = @data );', 'declares' ],
        ['note($right);'], [ '( my $name = $data[1] ) =~ s/x/y/;',          'declares' ],
        [q{bless \( my $unused = 1 ), 'Flag';}], ['note($inner)'],
        [q{eval <<'CODE' or die;}],              [q{bless \( my $late = 1 ), 'Flag';}],
      ],
      'no file handle block and no only statement of map or grep, and a declaration that later code uses is marked';
};

subtest 'statements that must stay are not deletable' => sub {
    is [ map { $_->text }
          sites_of( "1;\n'done';\nmy \$x = f();\nfield \$y = 1;\nADJUST { f() } method name { g() }\n", 'statement' )
          ->@* ],
      [ 'f()', 'g()' ], 'literals, declarations, fields, and block-bearing statements stay';
};

subtest 'class syntax yields method bodies' => sub {
    my $code =
      "use v5.38;\nclass P {\n    field \$x :param = 0;\n    method move (\$dx) {\n        \$x += \$dx;\n        return \$self;\n    }\n    method x { \$x }\n}\n";
    is [ map { [ $_->facts->{name}, $_->scope ] } sites_of( $code, 'sub_body' )->@* ],
      [ [ 'move', [ 4, 7 ] ], [ 'x', [ 8, 8 ] ] ], 'method bodies with their line ranges';
};

subtest 'a class body is a code block whatever its header holds' => sub {
    my $code = <<'PERL';
class Counter 1.0 {
    field $step = 1 + 1;
    register('counter');
}
class Other :isa(Counter) {
    field $size = 2 * 2;
}
class Third 2.0 :isa(Other) {
    field $rate = 3 - 3;
}
PERL
    my %scope = map { $_->text => $_->scope } grep { $_->role eq 'binary' } sites_of( $code, 'operator' )->@*;
    is $scope{'+'}, [ 2, 2 ], 'a field of a class with a version';
    is $scope{'*'}, [ 6, 6 ], 'a field of a class with an attribute';
    is $scope{'-'}, [ 9, 9 ], 'a field of a class with both';
    is [ map { $_->text } sites_of( $code, 'statement' )->@* ], [q{register('counter');}],
      'a call in the class body is deletable';
};

subtest 'every named body of a class is a body site' => sub {
    my $code = <<'PERL';
class Counter {
    ADJUST {
        setup();
    }
    method bump :lvalue ($by = 1) { $count }
    sub helper { return 1 }
    method read { $count }
    my $anonymous = method { 2 };
}
PERL
    is [ map { [ $_->facts->{name}, $_->scope, $_->text ] } sites_of( $code, 'sub_body' )->@* ],
      [
        [ 'ADJUST', [ 2, 4 ], "\n        setup();\n    " ],
        [ 'bump',   [ 5, 5 ], ' $count ' ],
        [ 'helper', [ 6, 6 ], ' return 1 ' ],
        [ 'read',   [ 7, 7 ], ' $count ' ],
      ],
      'the adjust block, a method with an attribute, and a sub that follows a method';
};

subtest 'a joined statement keeps the rules of its own kind' => sub {
    my $code = <<'PERL';
sub f {
    defer { cleanup() }
    return compute() + 1;
}
method a { one() }
use constant LIMIT => 2 * 3;
method b { two() }
our $VERSION = '1.0' - 0;
method c { three() }
my $kept = four();
method d { five() }
package Other;
PERL
    is [ map { [ $_->text, $_->scope ] } sites_of( $code, 'return' )->@* ], [ [ 'compute() + 1', [ 3, 3 ] ] ],
      'a return after a defer block has a return site';
    is [ map { $_->text } sites_of( $code, 'statement' )->@* ], [ 'cleanup()', 'one()', 'two()', 'three()', 'five()' ],
      'a declaration after a method stays, and the method before a version keeps its sites';
    is [ map { $_->text } grep { $_->role eq 'binary' } sites_of( $code, 'operator' )->@* ], [ q{+}, q{*}, q{=} ],
      'a constant after a method keeps its value expression';
};

subtest 'a compound statement and a loop control after an open block keep their roles' => sub {
    my $code = <<'PERL';
for my $item (@list) {
    defer { done() }
    next if $item;
    last;
}
sub f {
    defer { done() }
    if ( $a > 1 ) { g() } elsif ($b) { h() } else { i() }
    while ($c) { j() }
    k();
}
PERL
    is summary( $code, 'word' ),
      [
        [ 'done',  'call' ],
        [ 'next',  'control' ],
        [ 'if',    'modifier' ],
        [ 'last',  'control' ],
        [ 'done',  'call' ],
        [ 'if',    'compound' ],
        [ 'g',     'call' ],
        [ 'h',     'call' ],
        [ 'i',     'call' ],
        [ 'while', 'compound' ],
        [ 'j',     'call' ],
        [ 'k',     'call' ],
      ],
      'the keywords lead their own statements';
    is [ map { [ $_->text, $_->facts->{keyword}, $_->scope ] } sites_of( $code, 'condition' )->@* ],
      [
        [ '$item',    'if',    [ 3, 3 ] ],
        [ ' $a > 1 ', 'if',    [ 8, 8 ] ],
        [ '$b',       'elsif', [ 8, 8 ] ],
        [ '$c',       'while', [ 9, 9 ] ]
      ],
      'the conditions are condition sites';
    is [ map { $_->text } sites_of( $code, 'statement' )->@* ],
      [ 'done()', 'done()', 'g()', 'h()', 'i()', 'j()', 'k();' ],
      'the call after the loop is its own statement';
};

subtest 'a site that the compiled code leaves out is not comparable' => sub {
    my $code = <<'PERL';
class Counter {
    field $step = 1 + 1;
    field @list = map { note($_); $_ * 2 } 1 .. 3;
    ADJUST {
        setup( 4 - 4 );
    }
    method bump ($by = 5 / 5) { $step % $by }
    register( 6 ** 6 );
}
sub plain { 7 x 7 }
PERL
    is [ map { $_->text . $_->comparable } grep { $_->role eq 'binary' } sites_of( $code, 'operator' )->@* ],
      [qw(=0 +0 =0 *0 ..0 -0 =1 /1 %1 **1 x1)], 'the operators of a field and of an ADJUST block';
    is [ map { [ $_->facts->{name}, $_->comparable ] } sites_of( $code, 'sub_body' )->@* ],
      [ [ 'ADJUST', 0 ], [ 'bump', 1 ], [ 'plain', 1 ] ], 'the body of an ADJUST block';
    is [ map { [ $_->text, $_->comparable ] } sites_of( $code, 'statement' )->@* ],
      [
        [ 'note($_);',           0 ],
        [ '$_ * 2',              0 ],
        [ 'setup( 4 - 4 );',     0 ],
        [ '$step % $by',         1 ],
        [ 'register( 6 ** 6 );', 1 ],
        [ '7 x 7',               1 ]
      ],
      'a statement of a field and of an ADJUST block';
};

subtest 'declaration headers produce no sites' => sub {
    my $code = <<'PERL';
class Counter 1.0 :isa(Base) {
    field $count :param :reader = 0;
    field $name :param(label) //= 'none';
    method bump :lvalue ($by = 1) { $count }
}
class Plain 2.0;
role Shared;
PERL
    is [ map { [ $_->kind, $_->text ] } grep { $_->kind ne 'sub_body' } analyze($code)->{sites}->@* ],
      [
        [ 'operator',  q{=} ],
        [ 'number',    '0' ],
        [ 'operator',  '//=' ],
        [ 'string',    q{'none'} ],
        [ 'operator',  q{=} ],
        [ 'number',    '1' ],
        [ 'statement', '$count' ],
      ],
      'the initializers, the signature, and the bodies remain';
};

subtest 'code after a block that PPI leaves open is its own statement' => sub {
    my $code = <<'PERL';
sub f {
    try { g() } catch ($e) { h() }
    finally {
        i();
    }
    after_finally( 1 + 2 );
    defer { j() }
    after_defer( 3 - 4 );
    last_call();
}
method name {
    k();
}
after_method( 5 * 6 );
PERL
    is [ map { [ $_->text, $_->scope ] } grep { $_->text =~ /after|last/ } sites_of( $code, 'statement' )->@* ],
      [
        [ 'after_finally( 1 + 2 );', [ 6,  6 ] ],
        [ 'after_defer( 3 - 4 );',   [ 8,  8 ] ],
        [ 'last_call();',            [ 9,  9 ] ],
        [ 'after_method( 5 * 6 );',  [ 14, 14 ] ],
      ],
      'the statement after the block is deletable';
    my %scope = map { $_->text => $_->scope } grep { $_->role eq 'binary' } sites_of( $code, 'operator' )->@*;
    is $scope{'+'}, [ 6,  6 ],  'an operator after a finally block';
    is $scope{'-'}, [ 8,  8 ],  'an operator after a defer block';
    is $scope{'*'}, [ 14, 14 ], 'an operator after a method';
};

subtest 'scope is the statement that runs the site' => sub {
    my $code = <<'PERL';
sub f {
    my $x = g(
        1 + 2,
        [ 3 * 4 ],
    );
    my @sorted = sort {
        $a <=> $b
    } @list;
    if ( $x > 1 ) {
        h( 5 - 6 );
    }
    my %h = map {
        $_ => 7 / 8
    } @list;
    return {
        total => 9 % 10,
    };
}
PERL
    my %scope = map { $_->text => $_->scope } grep { $_->role eq 'binary' } sites_of( $code, 'operator' )->@*;
    is $scope{'+'},   [ 2,  5 ],  'an argument on a later line belongs to the whole statement';
    is $scope{'*'},   [ 2,  5 ],  'a nested constructor belongs to the whole statement';
    is $scope{'<=>'}, [ 6,  8 ],  'a sort block belongs to the sort statement';
    is $scope{'>'},   [ 9,  11 ], 'a condition belongs to its compound statement';
    is $scope{'-'},   [ 10, 10 ], 'a statement in a branch has its own scope';
    is $scope{'/'},   [ 13, 13 ], 'a map block runs its own statement';
    is $scope{'%'},   [ 15, 17 ], 'an anonymous hash belongs to the return statement';
};

subtest 'the grammar of the suppression comments reads the place of each comment and the routine after it' => sub {
    my $read = sub ($code) {
        my $suppressions = analyze($code)->{suppressions};
        return {
            directives => [ map { [ $_->@{qw(line first last)} ] } $suppressions->{directives}->@* ],
            refusals   => [ map { [ $_->@{qw(line id)} ] } $suppressions->{refusals}->@* ],
        };
    };
    my $code = join "\n",
      'my $a = 1 + 2;    ## no mutate',
      '## no mutate (arithmetic, comparison-boundary)',
      'my $b = 3 + 4;',
      '## use mutate',
      '# a plain comment',
      'sub f {',
      "    ## no mutate (logical): kept   \t",
      '    return $_[0] || 1;',
      '    ## use mutate',
      '}',
      q{};
    is $read->($code), { directives => [ [ 1, 1, 1 ], [ 2, 2, 4 ], [ 7, 7, 9 ] ], refusals => [] },
      'a comment behind code, a block, and an indented block';
    is [ map { [ $_->@{qw(text names reason)} ] } analyze($code)->{suppressions}{directives}->@* ],
      [
        [ '## no mutate',                                   undef,                                   undef ],
        [ '## no mutate (arithmetic, comparison-boundary)', [ 'arithmetic', 'comparison-boundary' ], undef ],
        [ '## no mutate (logical): kept',                   ['logical'],                             'kept' ],
      ],
      'the text of each comment without its indent and its trailing blanks';

    my $routines = join "\n",
      'use v5.38;',
      q{use experimental 'class';},
      '## no mutate sub',
      'class Counter {',
      '    field $step = 1;',
      '    ## no mutate sub',
      '    method bump ($by = 1 + 1) {',
      '        return $step + $by;',
      '    }',
      '    ## no mutate sub: the second method',
      '    method reset { $step = 0 }',
      '}',
      '## no mutate sub',
      'sub total ( $x,',
      '    $y = 2 * 3 ) {',
      '    return $x + $y;',
      '}',
      '## no mutate sub',
      q{},
      '# a note between',
      'sub forward;',
      'my @list = (',
      '    ## no mutate sub',
      '    sub { 1 + 1 },',
      ');',
      '## no mutate sub',
      'sub { 2 + 2 };',
      '## no mutate sub';
    is $read->($routines),
      {
        directives => [ [ 6, 7, 9 ],                                 [ 10, 11, 11 ], [ 13, 14, 17 ], [ 18, 21, 21 ] ],
        refusals   => [ map { [ $_, 'suppression-sub-missing' ] } 3, 23,             26,             28 ],
      },
      'methods one after the other, a signature over two lines, a declaration, and no routine after the comment';
    is analyze($routines)->{suppressions}{refusals}[0]{text},
      'lib/X.pm:3: ## no mutate sub stands before no named subroutine or method', 'a refusal names the file';
};

subtest 'files that cannot be analyzed report a problem' => sub {
    my %nothing = (
        sites        => [],
        suppressions => { directives => [], refusals => [] },
        dropped      => [],
        heredocs     => [],
        names        => { imports => [], declared => [] },
    );
    is analyze("my \$x = 1;\rmy \$y = 2;\n"),
      { %nothing, problem => 'the file has a carriage return without a line feed' },
      'a carriage return that ends no line';
    is analyze("my \$x = 1;\x0bmy \$y = 2;\n"),
      { %nothing, problem => q{PPI cannot parse the file: Lexer failed: Encountered unexpected character '11'} },
      'a character that PPI rejects, with the reason of PPI';

    my $unfaithful = do {
        no warnings 'redefine';
        local *PPI::Document::serialize = sub { return 'other text' };
        analyze("my \$x = 1 + 2;\n");
    };
    is $unfaithful, { %nothing, problem => 'PPI does not reproduce the file' },
      'a document that does not serialize to the text it came from';
};

subtest 'a file with a carriage return before each line feed is analyzed' => sub {
    my $code     = "my \$a = 1 + 2;\r\nmy \$b = 3 - 4;\r\nf( 1,\r\n  2 );\r\n";
    my $analysis = analyze($code);
    is $analysis->{problem}, undef, 'the file is analyzed';
    is $analysis->{dropped}, [],    'and nothing is left out';
    is [
        map  { [ $_->text, $_->start, substr $code, $_->start, $_->end - $_->start ] }
        grep { $_->role eq 'binary' && $_->text ne q{,} } $analysis->{sites}->@*
      ],
      [ [ q{=}, 6, q{=} ], [ q{+}, 10, q{+} ], [ q{=}, 22, q{=} ], [ q{-}, 26, q{-} ] ],
      'each site addresses its own text in the file with the carriage returns';
    is [ map { [ $_->text, $_->scope ] } grep { $_->kind eq 'statement' } $analysis->{sites}->@* ],
      [ [ "f( 1,\r\n  2 );", [ 3, 4 ] ] ], 'a statement over two lines keeps the carriage return inside its text';

    my $string = analyze("my \$s = \"a\r\nb\" . f();\r\nmy \$t = 1 + 2;\r\n");
    is $string->{dropped}, [ { line => 1, kind => 'span', reason => 'the text at the place differs from the token' } ],
      'a string over two lines has another text than its token, and the analysis says so';
    is [ map { $_->text } grep { $_->role eq 'binary' && $_->text ne q{=} } $string->{sites}->@* ], [ q{.}, q{+} ],
      'the sites around it stay';

    my $patterns = analyze("my \$match = /^a\r\nb\$/i;\r\nmy \$other = /[ab]/;\r\n");
    is $patterns->{dropped},
      [ { line => 1, kind => 'span', reason => 'the text at the place differs from the token' } ],
      'a multiline pattern with different source bytes is reported once';
    is [ map { [ $_->text, $_->scope ] } grep { $_->kind eq 'regex' } $patterns->{sites}->@* ],
      [ [ '[ab]', [ 3, 3 ] ] ], 'only the pattern with verified source offsets supplies mutation sites';
};

subtest 'the analysis lists every place it leaves out' => sub {
    is analyze("my \$x = 1 + 2;\nmy \$ok = \$x =~ /^ab+c\$/i;\n")->{dropped}, [], 'a file that it reads in full';

    my $unparsed = do {
        no warnings 'redefine';
        local *PPIx::Regexp::failures = sub { return 1 };
        analyze("my \$x = 1;\n\nmy \$ok = \$x =~ /^ab+c\$/ || \$x =~ /d\$/;\nmy \$y = \$x + 2;\n");
    };
    is $unparsed->{dropped}, [ ( { line => 3, kind => 'regex', reason => 'the pattern does not parse' } ) x 2 ],
      'each pattern that PPIx::Regexp fails to parse, with its line';
    is [ map { $_->text } grep { $_->kind eq 'regex' } $unparsed->{sites}->@* ], [], 'such a pattern has no site';
    is [ map { $_->text } grep { $_->role eq 'binary' && $_->text eq q{+} } $unparsed->{sites}->@* ], [q{+}],
      'and the code around it keeps its sites';

    my $mixed = do {
        no warnings 'redefine';
        local *PPIx::Regexp::failures = sub { return 1 };
        analyze("my \$late = \$x =~ /b/;\r\nmy \$ok = \"a\r\nb\" =~ /x/;\r\n");
    };
    is $mixed->{dropped},
      [
        { line => 1, kind => 'regex', reason => 'the pattern does not parse' },
        { line => 2, kind => 'span',  reason => 'the text at the place differs from the token' },
        { line => 3, kind => 'regex', reason => 'the pattern does not parse' },
      ],
      'the places stand in the order in which the analysis met them, each token once';

    my $twisted = do {
        no warnings 'redefine';
        local *PPIx::Regexp::Token::content = sub { return q{} };
        analyze("my \$ok = \$x =~ /^ab+c\$/;\n");
    };
    is $twisted->{dropped}, [ { line => 1, kind => 'regex', reason => 'the pattern does not parse' } ],
      'a pattern whose parts do not add up to its text';
};

subtest 'a signature yields its sites however the file turns signatures on' => sub {
    my $sites = sub ($code) {
        return [
            map  { $_->text }
            grep { $_->role eq 'binary' && $_->text =~ /\A[-+*]\z/ } analyze($code)->{sites}->@*
        ];
    };
    my $body = "sub f (\$x = 1 + 2, \$y = \$x * 3) { return \$x - \$y }\n";
    is $sites->("use v5.36;\n$body"), [ q{+}, q{*}, q{-} ], 'a feature bundle that PPI knows';
    is $sites->("package A;\nuse Mojo::Base -strict, -signatures;\n$body"), [ q{+}, q{*}, q{-} ],
      'an import that PPI does not know';
    is $sites->("package A;\nuse My::Preamble;\n$body"), [ q{+}, q{*}, q{-} ], 'a module that turns them on by itself';
    is $sites->(
        "sub pair(\$\$) { return \$_[0] + \$_[1] }\nsub top(\\\@) { return \$_[0][0] - 1 }\nsub it(_) { 1 * shift }\n"),
      [ q{+}, q{-}, q{*} ], 'a prototype holds no site, and the bodies keep theirs';
    is analyze("package A;\nuse My::Preamble;\n$body")->{dropped}, [], 'nothing is left out';
};

subtest 'an anonymous subroutine inside a use statement yields its sites' => sub {
    my $code = "use overload q{+} => sub { \$_[0]{value} + \$_[1] },\n  q{\"\"} => sub { \$_[0]{text} . q{!} };\n";
    is summary( $code, 'operator' ), [ [ q{+}, 'binary' ], [ q{.}, 'binary' ] ], 'the operators of both bodies';
    is [ map { $_->scope } sites_of( $code, 'operator' )->@* ], [ [ 1, 1 ], [ 2, 2 ] ],
      'each with the line of its own statement';
    is [ map { $_->text } sites_of( $code, 'statement' )->@* ], [ '$_[0]{value} + $_[1]', '$_[0]{text} . q{!}' ],
      'and the statement of each body';
    is summary( "use constant LIMIT => 2 * 3;\nuse List::Util 1.45 qw(max);\n", 'operator' ), [ [ '*', 'binary' ] ],
      'a constant value yields its arithmetic site';
    is analyze("use Sizes map { \$_ * 2 } 1 .. 3;\nour \$VERSION = do { 1 + 1 };\n")->{sites}, [],
      'a block of another kind inside an excluded statement stays out';
    my $nested = "use constant { PICK => sub { \$_[0] - 1 } };\n";
    is summary( $nested, 'operator' ), [ [ q{-}, 'binary' ] ], 'a subroutine inside a hash of constants';
    is summary( "use v5.36;\nuse constant PICK => sub (\$n = 2 * 3) { \$n - 1 };\n", 'operator' ),
      [ [ q{=}, 'binary' ], [ q{*}, 'binary' ], [ q{-}, 'binary' ] ],
      'the default argument and the body of a constant subroutine';
};

subtest 'an overload callback returned by a block retains its executable sites' => sub {
    my $code = <<'PERL';
package Weighted;
use overload q{+} => do {
    sub sub { return $_[0] + 1 }
    my $weight = Weighted::sub(1);
    sub { $_[1] * $weight }
};
PERL
    is [ map { [ $_->text, $_->scope ] } sites_of( $code, 'operator' )->@* ], [ [ q{*}, [ 5, 5 ] ] ],
      'the runtime callback supplies the operator and the named import helper stays outside its scope';
};

subtest 'the name and version of a constant declaration stay outside the value' => sub {
    my $code = <<'PERL';
use constant 1.30 'LIMIT', 2 * 3;
use constant {
    'FIRST' => 4 + 5,
    OTHER => join(':', 6, 7),
};
use constant 'PAIR' => (8, 9);
use constant { 'TEN', 10, 'ELEVEN', 11 };
use constant (('PAIR_AGAIN', 12, 13));
use constant ({ 'LAST' => 14 });
use constant;
use constant {};
no constant 'LAST';
PERL
    is [ map { $_->text } sites_of( $code, 'number' )->@* ], [qw(2 3 4 5 6 7 8 9 10 11 12 13 14)],
      'the values of single, multiple, and list constants';
    is [ map { $_->text } sites_of( $code, 'string' )->@* ], [q{':'}],
      'only the separator in the value is a string site';
    is [ map { $_->text } sites_of( $code, 'word' )->@* ], ['join'], 'only the function in the value is a call site';
    is summary( 'use constant do { +{ COMPUTED => sub { 7 + 1 } } };', 'operator' ), [ [ q{+}, 'binary' ] ],
      'an anonymous body in a computed hash of constants still runs as ordinary code';
};

subtest 'a statement modifier tests its whole expression' => sub {
    my $code = <<'PERL';
return 1 if ($x) != ($y);
work() unless ($x);
next while $left &&
    $right;
work() until (my $done = read_value()) || $finished;
print $done;
PERL
    my @conditions = sites_of( $code, 'condition' )->@*;
    is [ map { [ $_->text, $_->facts->{keyword}, $_->scope ] } @conditions ],
      [
        [ '($x) != ($y)',                           'if',     [ 1, 1 ] ],
        [ '$x',                                     'unless', [ 2, 2 ] ],
        [ "\$left &&\n    \$right",                 'while',  [ 3, 4 ] ],
        [ '(my $done = read_value()) || $finished', 'until',  [ 5, 5 ] ]
      ],
      'a grouped operand, a grouped condition, and an ungrouped condition';
    ok $conditions[-1]->facts->{declares}, 'the condition declares a name that the following statement uses';
};

subtest 'the analysis records where each here-document stands' => sub {
    is analyze("my \$x = 1;\n")->{heredocs}, [], 'a file without one';
    is analyze("my \$t = <<\"EOT\" . f();\nline\nEOT\nmy \$u = 1;\n")->{heredocs}, [ [ 8, 15, 23, 32 ] ],
      'the introducer, and the text with the line that ends it';
    is analyze("f( <<A, <<~B );\na\nA\n  b\n  B\ng();\n")->{heredocs}, [ [ 3, 6, 16, 20 ], [ 8, 12, 20, 28 ] ],
      'two here-documents of one line, the second one indented';
    is analyze("my \$t = <<A;\r\nx\r\nA\r\n")->{heredocs}, [ [ 8, 11, 14, 20 ] ],
      'a file with carriage returns keeps them inside the text';
    is analyze("my \$t = <<A;\nx\n")->{heredocs}, [ [ 8, 11, 13, 15 ] ], 'a text without its end line runs to the end';
    is analyze("my \$t = <<A;\nx")->{heredocs}, [ [ 8, 11, 13, 14 ] ],
      'and so does one whose last line has no line feed';

    my $reported  = \&PPI::Element::location;
    my $misplaced = do {
        no warnings 'redefine';
        local *PPI::Element::location = sub ($self) {
            return $self->content eq '<<A' ? [ 1, 1, 1, 1, undef ] : $reported->($self);
        };
        analyze("f(<<A);\nx\nA\ng(<<B);\ny\nB\n");
    };
    is $misplaced->{heredocs}, [ [ 14, 17, 20, 24 ] ],
      'a here-document without a place is left out, and a later one stays';
    is $misplaced->{dropped},
      [ { line => 1, kind => 'span', reason => 'the text at the place differs from the token' } ],
      'and the analysis counts it';
};

subtest 'the analysis records the names that the file resolves' => sub {
    my $code = join "\n", 'use v5.36;', 'use List::Util qw(any max);', 'use POSIX;',
      q{use Scalar::Util 'blessed', "reftype";},
      'use Carp ();',       'use List::MoreUtils 0.4 qw(none any);', 'no warnings qw(once);', 'sub helper { 1 }',
      'sub _private { 2 }', 'my $c = sub { 3 };',                    'BEGIN { }',             q{};
    is analyze($code)->{names},
      {
        imports => [
            { module => 'List::Util',      names => [qw(any max)] },
            { module => 'POSIX',           names => [qw(ceil floor)] },
            { module => 'Scalar::Util',    names => [qw(blessed reftype)] },
            { module => 'List::MoreUtils', names => [qw(none any)] },
        ],
        declared => [qw(_private helper)],
      },
      'each statement with the names it lists, the default exports of a known module, and the subroutines of the file';

    my $imports = sub ($text) {
        return [ map { [ $_->{module}, $_->{names}->@* ] } analyze($text)->{names}{imports}->@* ];
    };
    my @bundle = ( [qw(builtin ceil false floor true)] );
    is $imports->("use v5.40;\n"), \@bundle, 'the bundle of Perl 5.40 imports the booleans and the rounding functions';
    is $imports->("use $_;\n"), \@bundle, "use $_ names that bundle or a later one"
      for qw(v5.39 5.039 5.040 5.40.0 v5.42);
    is $imports->("use $_;\n"), [], "use $_ names an older bundle" for qw(v5.38 5.038009 5.010 5.6.1);
    is $imports->("use POSIX ();\nuse Carp;\nrequire List::Util;\nno List::Util qw(any);\nuse builtin qw(true);\n"),
      [ [qw(builtin true)] ],
      'an empty list, a module of unknown exports, and a statement of another kind import nothing';
    is $imports->("use List::MoreUtils qw(:all);\nuse POSIX qw(:math_h);\nuse builtin ':5.40';\n"),
      [ [qw(List::MoreUtils all any none notall)], [qw(POSIX ceil floor)], @bundle ],
      'a tag of a known module stands for its names';
    is $imports->("use List::Util qw(:nothing max -strict 9lives);\nuse My::Tools qw(:all);\n"),
      [ [qw(List::Util max)] ], 'an unknown tag and a text that is no name are left out';
    is $imports->('use'),     [], 'a statement without a module';
    is $imports->("use ;\n"), [], 'and one that holds a semicolon alone';

    my $unreadable = do {
        no warnings 'redefine';
        local *PPI::Statement::Include::version = sub { return 'five' };
        $imports->("use v5.40;\n");
    };
    is $unreadable, [], 'a version that the version module rejects imports nothing';
};

subtest 'the analysis marks what a change must keep' => sub {
    my $module = "package A;\nsub f { 1 }\n1;\n";
    is [ map { [ $_->text, $_->facts ] } sites_of( $module, 'number' )->@* ],
      [ [ '1', {} ], [ '1', { final_value => 1 } ] ],
      'the true value that ends a module, and no other number';
    is [ map { $_->facts } sites_of( "package A;\n'a true value';\n", 'string' )->@* ], [ { final_value => 1 } ],
      'a string in that place';
    is [ map { [ $_->text, $_->facts ] } sites_of( "package A;\nsub f { 1 }\n__PACKAGE__;\n", 'statement' )->@* ],
      [ [ '__PACKAGE__;', { head => '__PACKAGE__', anchors => [ [ 23, 34 ] ], final_value => 1 } ] ],
      'a word in that place';
    is [ map { $_->facts } sites_of( "package A;\nf() + 1;\n1;\n__END__\n\n=head1 NAME\n", 'number' )->@* ],
      [ {}, { final_value => 1 } ], 'the documentation after the end mark moves nothing';
    is [ map { $_->facts->{final_value} } analyze("package A;\nA->setup( 1 + 2 );\n")->{sites}->@* ], [ (undef) x 5 ],
      'a last statement that does work is no mere value';
    is [ map { $_->facts->{final_value} } sites_of( "package A;\n(3 < 4);\n", 'operator' )->@* ], [1],
      'a grouped comparison supplies the module return value';
    is [ map { $_->facts->{final_value} } sites_of( "package A;\n(print 3 < 4);\n", 'operator' )->@* ], [undef],
      'grouping the output operation leaves its comparison eligible for mutation';
    is [ map { [ $_->text, $_->facts->{final_value} ] } analyze("package A;\n!!1;\n")->{sites}->@* ],
      [ [ q{!}, 1 ], [ '!!1;', 1 ], [ q{!}, 1 ], [ '1', 1 ] ], 'a value under operators in that place';
    is [ map { $_->facts->{final_value} } sites_of( "use v5.40;\npackage A;\ntrue;\n", 'word' )->@* ], [1],
      'a boolean in that place';
    is [ map { [ $_->text, $_->facts ] } sites_of( "package A;\nsub run { 2 }\nrun;\n", 'statement' )->@* ],
      [ [ 'run;', { head => 'run', anchors => [ [ 25, 28 ] ] } ] ], 'a word that may call a subroutine is no value';
    is [ map { $_->facts->{final_value} } sites_of( "package A;\n\$A::loaded;\n", 'statement' )->@* ], [undef],
      'and neither is a variable';

    for my $after ( 'sub late { 3 }', 'END { }', 'package B;', 'use strict;', q{;}, "__DATA__\n2",
        "__END__\n\n=head1 NAME" )
    {
        my ( $value, @others ) = sites_of( "package A;\n1;\n$after\n", 'number' )->@*;
        is $value->facts, { final_value => 1 }, 'the value of the file stands before ' . $after =~ s/\n.*//sr;
        is [ map { $_->facts } @others ], [ ( {} ) x @others ], 'and a later number is none';
    }
    is [ map { $_->facts } sites_of( "package A;\n1;\nrequire A::More;\n", 'number' )->@* ], [ { final_value => 1 } ],
      'a value alone has no behavior wherever it stands in the file';
    is [ map { $_->facts } sites_of( "\"a\r\nb\";\r\n1;\r\n", 'number' )->@* ], [ { final_value => 1 } ],
      'a value without a place hides no later one';

    my $declaring = "if ( open my \$log, '<', \$path ) { print {\$log} 1 }\nif ( my \$n = f() ) { g() }\n";
    is [ map { $_->facts } sites_of( $declaring, 'condition' )->@* ],
      [ { keyword => 'if', anchors => [ [ 0, 2 ] ], declares => 1 }, { keyword => 'if', anchors => [ [ 51, 53 ] ] } ],
      'a condition whose declaration the block names, and one whose declaration nothing names';
    is [ map { [ $_->text, $_->facts ] }
          sites_of( "sub f {\n    chomp( my \$line = g() );\n    return \$line;\n}\n", 'statement' )->@* ],
      [ [ 'chomp( my $line = g() );', { head => 'chomp', anchors => [ [ 12, 17 ] ], declares => 1 } ] ],
      'a statement whose declaration later code names is a site with that fact';
};

subtest 'a byte order mark before the first line moves no site' => sub {
    my $code     = "\x{feff}my \$a = 1 + 2;\nmy \$b = 3 - 4;\n";
    my $analysis = analyze($code);
    is $analysis->{problem}, undef, 'the file is analyzed';
    is [
        map  { [ $_->text, $_->start, substr $code, $_->start, $_->end - $_->start ] }
        grep { $_->role eq 'binary' } $analysis->{sites}->@*
      ],
      [ [ q{=}, 7, q{=} ], [ q{+}, 11, q{+} ], [ q{=}, 22, q{=} ], [ q{-}, 26, q{-} ] ],
      'each site addresses its own text in the file with the mark';
};

done_testing;
