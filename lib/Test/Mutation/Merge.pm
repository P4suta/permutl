package Test::Mutation::Merge;
use v5.36;
use Digest::SHA     ();
use List::Util      qw(all any first max mesh_longest min sum0 uniq);
use Types::Standard qw(ArrayRef Dict InstanceOf Maybe Num Str);
use Type::Params    qw(signature_for);
use Test::Mutation::Error;
use Test::Mutation::Result;
use Test::Mutation::Verdict;

our $VERSION = '0.001';

signature_for merge => (
    positional => [
        ArrayRef [ Dict [ name => Str, result => InstanceOf ['Test::Mutation::Result'] ] ],
        Maybe [Num],
        { default => undef }
    ],
    returns => InstanceOf ['Test::Mutation::Result'],
);

sub merge ( $reports, $floor = undef ) {
    Test::Mutation::Error::raise('merge-empty') if !$reports->@*;
    my @parts   = _parts($reports);
    my @results = map { $_->{result} } @parts;
    my $count   = $results[0]->inventory->{mutants};
    my $parts   = scalar @parts;

    my %seen;
    for my $entry ( map { $_->entries->@* } @results ) {
        my $id = $entry->{mutant}->id;
        Test::Mutation::Error::raise( 'merge-repeated-mutant', id => $id ) if $seen{$id};
        $seen{$id} = 1;
    }
    for my $index ( 0 .. $#parts ) {
        my $rounded  = $count - $index + $parts - 1;
        my $expected = int $rounded / $parts;
        my $held     = scalar $results[$index]->entries->@*;
        Test::Mutation::Error::raise(
            'merge-part-size',
            name     => $parts[$index]{name},
            held     => $held,
            part     => $index + 1,
            parts    => $parts,
            expected => $expected
        ) if $held != $expected;
    }

    my @entries = grep { defined } mesh_longest map { $_->entries } @results;
    my $digest  = Digest::SHA::sha256_hex( join "\n", map { $_->{mutant}->id } @entries );
    Test::Mutation::Error::raise(
        'input-malformed',
        path   => join( ', ', map { $_->{name} } @parts ),
        reason => 'the merged mutant identifiers do not match the inventory order'
    ) unless $digest eq $results[0]->inventory->{digest};

    my ( %duration, %active );
    for my $test ( map { $_->tests->@* } @results ) {
        my $name = $test->{name};
        $active{$name}   = 1 unless $test->{neutral};
        $duration{$name} = max( $test->{duration}, exists $duration{$name} ? $duration{$name} : () );
    }
    my %problem     = map { $_->{path} => $_ } reverse map { $_->problems->@* } @results;
    my $first_floor = $results[0]->min_score;
    $floor //= $first_floor
      if defined $first_floor && all { defined $_->min_score && $_->min_score == $first_floor } @results;
    return Test::Mutation::Result->new(
        min_score => $floor,
        root      => $results[0]->root,
        sources   => { map { $_->sources->%* } @results },
        tests     => [
            map { { name => $_, duration => $duration{$_}, $active{$_} ? () : ( neutral => 1 ) } } sort keys %duration
        ],
        entries            => Test::Mutation::Verdict::conclude_inventory( \@entries ),
        problems           => [ map { $problem{$_} } sort keys %problem ],
        warnings           => [ uniq map { $_->warnings->@* } @results ],
        baseline_failures  => [],
        jobs               => max( map { $_->jobs } @results ),
        parallel_safe      => ( all { $_->parallel_safe } @results )  ? 1 : 0,
        cache_mismatch     => ( any { $_->cache_mismatch } @results ) ? 1 : 0,
        reused             => sum0( map { $_->reused } @results ),
        inventory          => $results[0]->inventory,
        selection          => $results[0]->selection,
        catalog_digest     => $results[0]->catalog_digest,
        measurement_digest => $results[0]->measurement_digest,
        dependency_digest  => ( first { defined } map { $_->dependency_digest } @results ),
        compiler_inputs    => { map { $_->compiler_inputs->%* } @results },
        started            => min( map { $_->started } @results ),
        finished           => max( map { $_->finished } @results ),
        stats              => _work(@results),
    );
}

signature_for refresh =>
  ( positional => [ ( InstanceOf ['Test::Mutation::Result'] ) x 2 ], returns => InstanceOf ['Test::Mutation::Result'] );

sub refresh ( $prior, $current ) {
    return $current if defined $prior->shard || defined $current->shard || $prior->root ne $current->root;
    return $current
      unless defined $prior->catalog_digest
      && defined $current->catalog_digest
      && $prior->catalog_digest eq $current->catalog_digest;
    return $current unless exists $current->selection->{paths} || exists $current->selection->{mutants};
    return $current unless _confirms_inputs( $prior, $current );
    my %replacement = map { $_->{mutant}->id => $_ } $current->entries->@*;
    my @entries     = map { delete $replacement{ $_->{mutant}->id } || $_ } $prior->entries->@*;
    push @entries, grep { exists $replacement{ $_->{mutant}->id } } $current->entries->@*;
    my %tests = map { $_->{name} => $_ } $prior->tests->@*, $current->tests->@*;
    my @ids   = map { $_->{mutant}->id } @entries;
    my $scope = $current->measured_scope;

    if ( @ids > $current->entries->@* ) {
        $scope = $prior->score_scope;
        $scope = { mutants => \@ids } if %replacement && keys %$scope;
    }
    return Test::Mutation::Result->new(
        $current->%*,
        measured_scope => $scope,
        entries        => Test::Mutation::Verdict::conclude_inventory( \@entries ),
        tests          => [ map { $tests{$_} } sort keys %tests ],
        sources        => { $prior->sources->%*, $current->sources->%* },
        inventory      => {
            mutants => scalar @entries,
            digest  => Digest::SHA::sha256_hex( join "\n", @ids )
        },
    );
}

sub _confirms_inputs ( $prior, $current ) {
    for my $report ( $prior, $current ) {
        return 0 if defined $report->interrupted || $report->baseline_failures->@* || $report->cache_mismatch;
        return 0 unless defined $report->verified_measurement_digest;
        return 0 if $report->tests->@* && !defined $report->dependency_digest;
    }
    return 0 if $prior->measurement_digest ne $current->measurement_digest;
    my $dependencies = $prior->dependency_digest;
    return 0
      if defined $dependencies
      && ( !defined $current->dependency_digest || $dependencies ne $current->dependency_digest );
    my $before = $prior->compiler_inputs;
    my $after  = $current->compiler_inputs;
    return all { exists $after->{$_} && $after->{$_} eq $before->{$_} } keys %$before;
}

sub _work (@results) {
    my %work;
    for my $stats ( map { $_->stats } @results ) {
        $work{$_} += $stats->{$_} for keys $stats->%*;
    }
    return \%work;
}

sub _parts ($reports) {
    my ( @parts, $whole );
    for my $report ( $reports->@* ) {
        my ( $name, $result ) = $report->@{qw(name result)};
        Test::Mutation::Error::raise( 'merge-whole-run', name => $name ) if !defined $result->shard;
        Test::Mutation::Error::raise( 'merge-interrupted', name => $name, signal => $result->interrupted )
          if defined $result->interrupted;
        Test::Mutation::Error::raise( 'merge-without-inventory', name => $name ) if !$result->inventory;
        Test::Mutation::Error::raise( 'merge-failed-baseline',   name => $name ) if $result->baseline_failures->@*;
        my ( $part, $of ) = split m{/}, $result->shard;
        Test::Mutation::Error::raise( 'input-malformed', path => $name, reason => "invalid shard $part/$of" )
          if $part > $of;
        $whole ||=
          { name => $name, part => $part, of => $of, inputs => $result->measurement_digest, $result->inventory->%* };
        Test::Mutation::Error::raise(
            'merge-other-split',
            first       => $whole->{name},
            first_part  => $whole->{part},
            first_parts => $whole->{of},
            name        => $name,
            part        => $part,
            parts       => $of
        ) if $of != $whole->{of};
        Test::Mutation::Error::raise( 'merge-other-mutants', name => $name, first => $whole->{name} )
          if $result->inventory->{digest} ne $whole->{digest} || $result->inventory->{mutants} != $whole->{mutants};
        _check_inputs( $whole, $name, $result );
        Test::Mutation::Error::raise(
            'merge-repeated-part',
            first => $parts[ $part - 1 ]{name},
            name  => $name,
            part  => $part,
            parts => $of
        ) if $parts[ $part - 1 ];
        $parts[ $part - 1 ] = $report;
    }
    my @missing = grep { !$parts[ $_ - 1 ] } 1 .. $whole->{of};
    return @parts if !@missing;
    my $last = pop @missing;
    Test::Mutation::Error::raise( 'merge-missing-part', part => $last, parts => $whole->{of} ) if !@missing;
    my $list = join @missing > 1 ? ', ' : q{ }, @missing, "and $last";
    return Test::Mutation::Error::raise( 'merge-missing-parts', list => $list, parts => $whole->{of} );
}

sub _check_inputs ( $whole, $name, $result ) {
    my $dependencies = $result->dependency_digest;
    my $compiler     = $result->compiler_inputs;
    my $changed = grep { exists $whole->{compiler}{$_} && $whole->{compiler}{$_} ne $compiler->{$_} } keys %$compiler;
    Test::Mutation::Error::raise(
        'input-malformed',
        path   => $name,
        reason => 'measurement inputs are missing, rerun every shard before merging'
    ) if !defined $result->verified_measurement_digest || ( $result->tests->@* && !defined $dependencies );
    Test::Mutation::Error::raise(
        'input-malformed',
        path   => $name,
        reason => "measurement inputs differ from $whole->{name}, rerun every shard with the same inputs"
      )
      if $changed
      || $result->measurement_digest ne $whole->{inputs}
      || ( defined $dependencies && defined $whole->{dependencies} && $dependencies ne $whole->{dependencies} );
    $whole->{dependencies} = $dependencies if defined $dependencies;
    $whole->{compiler}{$_} = $compiler->{$_} for keys %$compiler;
    return;
}

1;

__END__

=head1 NAME

Test::Mutation::Merge - join the results of the parts of one run

=head1 SYNOPSIS

    my $whole = Test::Mutation::Merge::merge(
        [
            { name => 'first/mutation.json',  result => $first },
            { name => 'second/mutation.json', result => $second },
        ]
    );

=head1 DESCRIPTION

C<mutation run --shard K/N> measures one of C<N> parts of the mutants.
This module joins the results of all parts into the result that one run without C<--shard> returns.

=head1 FUNCTIONS

=head2 refresh

Updates the selected verdicts in a report from the same project and source catalog.
Earlier verdicts require completed measurements with verified project, test, and compiler inputs.
When the current measurement cannot confirm an earlier input, the function returns the current selection and its verdicts.
The current test durations and entries take precedence.
The requested selection stays available when the measured scope includes earlier verdicts.
Shard reports remain independent until C<merge> joins them.

=head2 merge

Takes the results with the names that error messages use, and returns one L<Test::Mutation::Result>.
The function dies with a L<Test::Mutation::Error> of the kind C<usage> unless the results are the parts 1 to C<N> of one run, each exactly once.
Every shard must finish, name the same C<N> and inventory, and hold the mutants of its part.

The merged result lists the mutants in the order of a whole run.
It keeps each test with its longest duration, each warning and problem once, the largest job count, and the whole time span.
It adds up the reused results and each count of the work of the parts.

=cut
