package Test::Mutation::Report::Results;
use v5.36;
use List::Util      qw(sum0);
use Types::Standard qw(ArrayRef Dict InstanceOf Maybe Num Str);
use Type::Params    qw(signature_for);
use Test::Mutation::Outcome;
use Test::Mutation::Score;
use Test::Mutation::Status;
use Test::Mutation::Types qw(Entry);

our $VERSION = '0.001';

my @scored = grep { $_->role ne 'outside' } Test::Mutation::Status::rows()->@*;
my $RESULT = InstanceOf ['Test::Mutation::Result'];
my $FILE   = Dict [ path => Str, entries => ArrayRef [Entry], cells => ArrayRef [Str] ];

signature_for heading => ( positional => [ InstanceOf ['Test::Mutation::Mutant'] ], returns => Str );

sub heading ($mutant) {
    my $place = join q{:}, $mutant->path, $mutant->from->@*;
    return join q{  }, $mutant->id, $place, $mutant->mutator, $mutant->description;
}

signature_for files => ( positional => [$RESULT], returns => ArrayRef [$FILE] );

sub files ($result) {
    my %groups = map { $_ => [] } ( keys $result->sources->%*, map { $_->{path} } $result->problems->@* );
    push $groups{ $_->{mutant}->path }->@*, $_ for $result->entries->@*;
    my @files;
    for my $path ( sort keys %groups ) {
        my $entries = $groups{$path};
        my $tally   = Test::Mutation::Score::tally( [ map { $_->{status} } @$entries ] );
        my $counts  = $tally->{counts};
        my $score   = defined $tally->{score} ? sprintf( '%.1f%%', $tally->{score} ) : 'none';
        my @other   = map { "$counts->{ $_->name } " . $_->word }
          grep { $_->role eq 'outside' && $counts->{ $_->name } } Test::Mutation::Status::rows()->@*;
        push @files,
          {
            path    => $path,
            entries => $entries,
            cells   =>
              [ $path, $score, ( map { $counts->{ $_->name } } @scored ), ( @other ? join( ', ', @other ) : q{-} ) ]
          };
    }
    return \@files;
}

signature_for columns => ( positional => [], returns => ArrayRef [Str] );

sub columns () {
    return [ 'File', 'Score', ( map { ucfirst $_->word } @scored ), 'Other' ];
}

signature_for overview => ( positional => [$RESULT], returns => ArrayRef [Str] );

sub overview ($result) {
    my $selection = $result->score_scope;
    my @scope;
    push @scope, 'previously undetected mutants' if $selection->{undetected};
    if ( !$selection->{undetected} && $selection->{mutants} ) {
        my @names = $selection->{mutants}->@*;
        push @scope, @names == 1 ? "mutant $names[0]" : scalar(@names) . ' selected mutants';
    }
    push @scope, "changes since $selection->{since}" if defined $selection->{since};
    for my $path ( sort keys %{ $selection->{paths} || {} } ) {
        my @lines = map { $_->[0] == $_->[1] ? $_->[0] : join q{-}, @$_ } $selection->{paths}{$path}->@*;
        push @scope, @lines ? $path . q{:} . join( q{,}, @lines ) : $path;
    }
    my $scope = @scope ? join( ', ', @scope ) : 'configured sources';
    $scope = 'shard ' . $result->shard . " of $scope" if defined $result->shard;
    my $counts = $result->tally->{counts};
    my $gaps   = sum0 map { $counts->{ $_->name } } grep { $_->role eq 'undetected' } @scored;
    my $observed =
        $result->baseline_failures->@* ? 'unknown (original tests failed)'
      : defined $result->interrupted   ? "$gaps observed before interruption"
      :                                  $gaps;
    return [ "Scope: $scope", "Undetected: $observed" ];
}

signature_for decision => ( positional => [ $RESULT, Maybe [Num] ], returns => ArrayRef [Str] );

sub decision ( $result, $floor ) {
    my $assessment = Test::Mutation::Outcome::assessment( $result, $floor );
    my @lines      = ("Result: $assessment->{outcome}");
    push @lines, "Gate: $assessment->{gate} (minimum $floor%)" if defined $floor;
    return \@lines;
}

signature_for next_step => ( positional => [ $RESULT, Maybe [Num], { default => undef } ], returns => Str );

sub next_step ( $result, $floor ) {
    return 'Next: rerun the interrupted measurement' if defined $result->interrupted;
    return 'Next: mutation baseline'                 if $result->baseline_failures->@*;
    for my $row ( grep { defined $_->heading } Test::Mutation::Status::rows()->@* ) {
        my ($entry) = grep { $_->{status} eq $row->name } $result->entries->@*;
        return 'Next: mutation show ' . $entry->{mutant}->id if $entry;
    }
    return 'Next: resolve the reported source problems and rerun mutation' if $result->problems->@*;
    return 'Next: merge the shard reports with mutation merge FILE...'     if defined $result->shard;
    return 'Next: mutation list'                                           if !defined $result->tally->{score};
    return 'Next: rerun mutation when the source or tests change'          if defined $floor;
    return 'Next: mutation run --min-score 100';
}

1;

__END__

=head1 NAME

Test::Mutation::Report::Results - present measured changes by source file

=head1 FUNCTIONS

=head2 heading

Returns the identifier, location, mutator name and description of a change.

=head2 files

Returns the file paths in order, their entries and the cells of the score table.

=head2 columns

Returns the column headings of the file table.

=head2 overview

Returns the selected sources, lines, or identifiers and the number of observed gaps.

=head2 decision

Returns the measured outcome and the requested threshold decision.

=head2 next_step

Returns a next step based on the result, including an identifier when the developer can inspect a change.

=cut
