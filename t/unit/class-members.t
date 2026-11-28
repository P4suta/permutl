use v5.36;
use Test2::V0;
use Test::Mutation::Syntax::PPI;

sub reads ($member) {
    my $source = "use experimental 'class'; class Settings { $member } 1;";
    return scalar Test::Mutation::Syntax::PPI::compile_reads( $source, 1 );
}

is reads(q{main::observe;}),                    undef, 'a bare call runs when the class loads';
is reads(q{readline $main::settings;}),         undef, 'a filehandle operand does not declare a field';
is reads(q{do { main::observe() };}),           undef, 'an ordinary block can run during module loading';
is reads(q{sort compare { main::observe() };}), undef, 'a bareword and block after an ordinary operator can run';
is reads(q{method future ($value);}), undef, 'a signature without a method body does not establish deferred code';
is reads(q{method future ($value) { main::observe($value) }}), [], 'a named method and its signature defer their code';
is reads(q{method x ($value = main::observe()) { return $value }}), [], 'a method named x defers its default argument';
is reads(q{method future; method future { main::observe() }}), [],
  'a forward declaration can precede the deferred body';

done_testing;
