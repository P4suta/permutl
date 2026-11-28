use v5.36;
use Test2::V0;
use File::Temp ();
use List::Util qw(sum0);
use lib 't/lib';
use Gate;
use Library;
use Oracle;
use Test::Mutation::Host;

# The installed dependencies are a corpus of real code that nobody wrote with this tool in mind.
# Every mutant of every module has its text, its span, and its identity checked, and every refusal has its rule counted.
# Perl judges a sample: the same number of mutants of each mutator in each file, spread evenly over the file.
# Perl judges every mutant of the corpus, of the fixtures, and of the tool itself, and B::Deparse prints each one.

my $JUDGED  = 4;
my $PATCHED = 4;
my $PART    = 12_000;
my $workers = Test::Mutation::Host::processors()->{count};

# A problem of the analysis is a defect of the tool, and a file that perl refuses as it stands is a fact of the corpus.
my %UNJUDGED = map { $_ => 1 } 'judge: perl refuses the original', 'judge: plain perl -c refuses the original',
  'judge: the modules that the judge holds change the original', 'judge: B::Deparse cannot print the original';

# A finding with one witness in the corpus leaves the list when the sample moves off its line.
# Perl judges the mutants of these lines in every run, so such a finding stays until the tool changes.
my %WITNESS = (
    'local/lib/perl5/Parse/PMFile.pm'                    => [319],
    'local/lib/perl5/PPIx/Regexp/Token/Interpolation.pm' => [109],
    'local/lib/perl5/Mojo/Server.pm'                     => [42],
    'local/lib/perl5/Pod/PlainText.pm'                   => [520],
);

sub surveyed (@paths) {
    my $survey = sub ( $path, %task ) {
        return Oracle::survey( $path, %task, judged => $JUDGED, patched => $PATCHED, lines => $WITNESS{$path} );
    };
    return Oracle::summary( Oracle::each_file( \@paths, $workers, $survey ) );
}

sub unanalyzed ($summary) {
    return [
        map { s/\Aanalysis: /the tool makes no mutant of a file: /r } grep { /\Aanalysis: / }
        sort keys $summary->{problems}->%*
    ];
}

sub judged_ok ( $scope, $summary, @oracles ) {
    note $_ for Oracle::table( $summary->{tally}, Oracle::columns() ), Oracle::lines($summary), Oracle::rules($summary);
    is [ grep { !/\Aanalysis: / && !$UNJUDGED{$_} } sort keys $summary->{problems}->%* ], [],
      "$scope: the judge answers for every file that perl compiles as it stands";
    Gate::findings( "mutants-files-$scope", unanalyzed($summary) );
    Gate::findings( "mutants-$_-$scope",    Oracle::found( $summary, $_ ) ) for @oracles;
    return {
        Oracle::total( $summary->{tally} )->%*,
        crossed  => $summary->{crossed},
        refusals => sum0( map { values $_->%* } values $summary->{refusals}->%* ),
    };
}

# A mutant with the code of its original measures its mutator, as the run marks it Ignored and no change of the boundary removes it.
# Appendix J of the plan keeps a mutator in the default profile while its share of such mutants stays at 2 percent or below.
my $EQUIVALENT = 0.02;

sub equivalence_ok ( $scope, $summary ) {
    my $tally = $summary->{tally};
    note sprintf '%s: %s keeps the code of the original in %d of %d compared mutants (%.1f%%)', $scope, $_->@[ 0 .. 2 ],
      100 * $_->[3]
      for Oracle::rates( $tally, 'equivalent', 'compared' );
    Gate::findings( "mutants-c-$scope", Oracle::equivalence_findings( $summary, $EQUIVALENT ) );
    return;
}

subtest 'the walk rejects a module with a mutant that perl refuses and one that calls nothing' => sub {
    my $directory = File::Temp->newdir;
    my %module    = (
        'Swap.pm'  => "use strict;\nuse List::Util qw(max);\nsub f { return max(\@_) }\nsub g { return max \@_ }\n1;\n",
        'Lines.pm' => "sub f { return 1 }\r1;\n",
    );
    for my $name ( sort keys %module ) {
        open my $handle, '>:raw', "$directory/$name" or die "write $name: $!";
        print {$handle} $module{$name} or die "write $name: $!";
        close $handle                  or die "close $name: $!";
    }

    # The broken mutants are built here by hand, as the tool resolves a swapped call or refuses the swap.
    my $swap   = Oracle::file_source("$directory/Swap.pm");
    my @broken = (
        Oracle::by_hand( $swap, 'max(@_)', 'min(@_)', mutator => 'call-swap' ),
        Oracle::by_hand( $swap, 'max @_',  'min @_',  mutator => 'call-swap' ),
    );
    my @records = (
        ( map { [ $swap->path, $_->@* ] } Oracle::survey_made( $swap, Oracle::made_of(@broken), accepted => 1 ) ),
        ( map { [ "$directory/Lines.pm", $_->@* ] } Oracle::survey("$directory/Lines.pm") ),
    );
    my $summary = Oracle::summary( \@records );
    is Oracle::found( $summary, 'b' ),  ['call-swap yields code that perl refuses'], 'the swap without parentheses';
    is Oracle::found( $summary, 'b2' ), ['call-swap introduces an unresolved call'], 'the swap with parentheses';
    is unanalyzed($summary), ['the tool makes no mutant of a file: the file has a carriage return without a line feed'],
      'the file that the tool leaves alone';
    is Gate::outcomes( sub { judged_ok( 'rejected', $summary, qw(a b b2 d e) ) } ),
      [qw(pass fail pass fail fail pass pass)],
      'the three findings fail their gates, and every other gate passes';

    my $real = surveyed("$directory/Swap.pm");
    is [ map { Oracle::found( $real, $_ )->@* } qw(a b b2 d e literal refusal) ], [],
      'the mutants that the tool makes of the same module pass every oracle';
};

my @ORACLES = qw(a b b2 d e literal refusal);
my @files   = Library::modules('local/lib/perl5')->@*;
my $summary = surveyed(@files);
my $total   = judged_ok( 'installed', $summary, @ORACLES );
my $refused = scalar( ( $summary->{problems}{'judge: perl refuses the original'} || [] )->@* );
note sprintf '%d files, %d with sites, %d sites, %d that perl refuses as they stand', scalar @files,
  $summary->{files}, $summary->{sites}, $refused;

Gate::checked( 'installed modules',                   scalar @files,                at_least => 1200 );
Gate::checked( 'modules that the tool analyzed',      $summary->{files},            at_least => 1200 );
Gate::checked( 'modules that perl judged',            $summary->{files} - $refused, at_least => 1000 );
Gate::checked( 'mutants',                             $total->{mutants},            at_least => 600_000 );
Gate::checked( 'mutants that perl judged',            $total->{judged},             at_least => 35_000 );
Gate::checked( 'patches that were applied',           $total->{patched},            at_least => 35_000 );
Gate::checked( 'verdicts that a cold perl confirmed', $total->{crossed},            at_least => 1000 );
Gate::checked( 'changes that the tool refused',       $total->{refusals},           at_least => 6000 );
Gate::checked( 'refused changes that perl judged',    $total->{asked},              at_least => 1000 );

# Perl judges every mutant of the corpus, of the fixtures, and of the tool itself, and B::Deparse prints its code.
# A mutant with the code of its original is equivalent by construction, and the fast gate has no time for this print.
my @own   = map { Library::modules($_)->@* } 't/corpus', 't/fixtures', 'lib';
my $owned = Oracle::summary(
    Oracle::each_file(
        [ Oracle::in_parts( $PART, @own ) ],
        $workers,
        sub ( $path, %task ) {
            my ($root) = $path =~ m{\A(t/fixtures/[^/]+/lib|lib)/};
            return Oracle::survey( $path, %task, include => [ $root || () ], wants => [ 'calls', 'deparse' ] );
        }
    )
);
my $own = judged_ok( 'own', $owned, qw(b b2 refusal) );
equivalence_ok( 'own', $owned );
is $owned->{problems}, {}, 'perl compiles every file of the corpus, of the fixtures, and of the tool as it stands';
Gate::checked( 'mutants of the project that perl judged',        $own->{judged},   at_least => 5000 );
Gate::checked( 'mutants whose compiled code B::Deparse printed', $own->{compared}, at_least => 5000 );

# B::Deparse prints a sample of the installed modules: one mutant of each mutator in every fourth file of modest size.
# The print of a whole module costs more than its compilation, so the sample leaves the largest files out.
my $LARGEST = 20_000;
my @modest  = grep { -s $_ <= $LARGEST } @files;
my @sampled = @modest[ grep { $_ % 4 == 0 } 0 .. $#modest ];
my $printed = Oracle::summary(
    Oracle::each_file(
        \@sampled, $workers,
        sub ($path) { return Oracle::survey( $path, judged => 1, patched => 0, wants => [ 'calls', 'deparse' ] ) }
    )
);
my $sample = judged_ok( 'sample', $printed );
equivalence_ok( 'sample', $printed );
Gate::checked( 'installed modules in the sample',                 scalar @sampled,     at_least => 200 );
Gate::checked( 'installed mutants whose code B::Deparse printed', $sample->{compared}, at_least => 1500 );

done_testing;
