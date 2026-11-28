use v5.36;
use Test2::V0;
use Test::Mutation::Source;
use Test::Mutation::Syntax::PPI;

sub reads ($source) {
    return scalar Test::Mutation::Syntax::PPI::compile_reads($source);
}

my $quoted = q{"value ${ \do { BEGIN { main::observe() } 42 } }"};
my $regex  = q{qr/(?{ BEGIN { main::observe() } 1 })/};
is reads("sub description { return $quoted }"), undef, 'a phase inside string interpolation runs during compilation';
is reads("sub matches { return $regex }"),      undef, 'a regex code assertion compiles before a subroutine runs';
is reads(q{sub replace { s/BEGIN/ do { BEGIN { main::observe() } 42 } /e }}), undef,
  'a substitution compiles its Perl replacement';
is reads(q{sub uses { return "@{[ do { use Settings; 42 } ]}" }}), undef,
  'an import inside interpolation runs at compile time';
is reads(<<'SOURCE'), undef, 'an interpolating here-document can compile a phase block';
sub note { return <<TEXT;
${\do { BEGIN { main::observe() } 42 }}
TEXT
}
SOURCE
is reads(q{sub text { return q{BEGIN { main::observe() }}, qr/BEGIN\s+\w+/, "BEGIN $name" }}), [],
  'literal phase names in strings and regexes do not run';
is reads(q{sub text { return "value ${ \do { 'BEGIN' } }" }}), [],
  'a string literal inside an interpolated expression remains text';
is reads(q{sub text { return "$labels{BEGIN}" }}),   [],    'a bare hash key in an interpolated lookup is a string';
is reads(q{sub text { return "$labels{ CHECK }" }}), [],    'whitespace around a literal hash key keeps its meaning';
is reads(q{sub text { return "$labels[BEGIN]" }}),   undef, 'an array index still needs input verification';
is reads(q{sub text { return "$labels{do { BEGIN { main::observe() } 'BEGIN' }}" }}), undef,
  'a phase in a computed hash key runs before the lookup';
is reads(q{sub nested { return "@{[ qr/(?{ CHECK { main::observe() } 1 })/ ]}" }}), undef,
  'embedded Perl can compile another regex with a phase block';
my $class = "use experimental 'class'; class Model { method describe { return $quoted } } 1;";
is scalar Test::Mutation::Syntax::PPI::compile_reads( $class, 1 ), undef,
  'a native method can compile an interpolated phase before object construction';

is reads(q{sub answer { return 42 }}), [], 'a subroutine with no compiler directives needs no input';

subtest 'valid Perl whitespace can make embedded code unreadable to PPI' => sub {
    my $pattern       = $regex  =~ s/\bBEGIN\b/\x0bBEGIN/r;
    my $interpolation = $quoted =~ s/\bBEGIN\b/\x0bBEGIN/r;
    for my $expression ( $pattern, $interpolation ) {
        ok
          lives { is reads("sub describe { return $expression }"), undef, 'an unreadable phase cannot certify inputs' },
          'the parser can decline the input without terminating the run';
    }
    my $source = Test::Mutation::Source->new(
        path     => 'lib/Query.pm',
        encoding => 'UTF-8',
        text     => "sub matches { return $pattern }\nsub below { return 1 < 2 }\n"
    );
    ok lives {
        my $analysis = Test::Mutation::Syntax::PPI::analyze($source);
        is $analysis->{dropped}, [ { line => 1, kind => 'regex', reason => 'the pattern does not parse' } ],
          'the unsupported pattern is reported';
        ok + ( grep { $_->text eq '<' } $analysis->{sites}->@* ), 'an independent comparison is still available';
    }, 'source analysis continues after the regular expression parser declines the pattern';
};

done_testing;
