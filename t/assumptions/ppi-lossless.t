use v5.36;
use Test2::V0;
use Encode ();
use PPI;
use PPI::Dumper;
use lib 't/lib';
use Library;

# PPI must reproduce every corpus file character for character, and a token's location must address its own text.
# PPI rejects raw bytes above 0x7F in identifiers, so the source is decoded first.

sub slurp_text ($path) {
    open my $handle, '<:raw', $path or die "open $path: $!";
    local $/ = undef;
    my $bytes = readline $handle;
    return Encode::decode( 'UTF-8', $bytes, Encode::FB_CROAK );
}

sub line_starts ($text) {
    my @starts = (0);
    push @starts, pos($text) while $text =~ /\n/g;
    return \@starts;
}

my @files = Library::modules('t/corpus')->@*;
is \@files,
  [
    't/corpus/findings/AuthorSection.pm',
    't/corpus/findings/CompileDuringLoad.pm',
    't/corpus/findings/ParentProcess.pm',
    map { "t/corpus/modern/$_.pm" } qw(Class Heredoc PodData Postfix Regex Signatures TryCatch Unicode)
  ],
  'the source corpus includes every regression fixture and every supported syntax fixture';

for my $path (@files) {
    my $text     = slurp_text($path);
    my $document = PPI::Document->new( \$text );
    ok $document, "$path parses" or do { diag PPI::Document->errstr; next };
    is $document->serialize, $text, "$path serializes to the same text";

    $document->index_locations;
    my $starts     = line_starts($text);
    my @mismatches = ();
    for my $token ( $document->tokens ) {
        my $location = $token->location;
        my $offset   = $starts->[ $location->[0] - 1 ] + $location->[1] - 1;
        my $content  = $token->content;
        next if substr( $text, $offset, length $content ) eq $content;
        push @mismatches, sprintf '%s at line %d', ref $token, $location->[0];
    }
    is \@mismatches, [], "$path token locations address their own text";

    note PPI::Dumper->new( $document, whitespace => 0, comments => 0 )->string
      if $ENV{TEST_MUTATION_DUMP_PPI};
}

done_testing;
