package SelfMeasurement;
use v5.36;
use List::Util qw(first max min uniq);
use Test::Mutation::Report::Json;

my %UNFINISHED = map { $_ => 1 } qw(Survived NoCoverage Timeout NoVerdict Pending);

sub read_report ($path) {
    open my $file, '<:encoding(UTF-8)', $path or die "read $path: $!\n";
    my $json = do { local $/ = undef; readline $file };
    close $file or die "close $path: $!\n";
    return Test::Mutation::Report::Json::parse($json);
}

sub detector_hints ( $selection, @paths ) {
    my %tests = map { $_ => 1 } $selection->tests->@*;
    my ( %ids, %sites, %exact, %moved );
    for my $mutant ( $selection->mutants->@* ) {
        $ids{ $mutant->id } = 1;
        push $sites{ $mutant->path }{ $mutant->start }->@*, $mutant;
    }
    for my $path (@paths) {
        my $report = read_report($path);
        my %locate;
        for my $entry ( $report->entries->@* ) {
            my ( $mutant, $test ) = $entry->@{qw(mutant by)};
            next unless $entry->{status} eq 'Killed' && defined $test && $tests{$test};
            if ( $ids{ $mutant->id } ) {
                $exact{ $mutant->id } = $test;
                next;
            }
            my $file = $mutant->path;
            next unless $sites{$file};
            $locate{$file} ||=
              _locate_moved( $report->sources->{$file}, $selection->sources->{$file}->text, $sites{$file} );
            my $found = $locate{$file}->($mutant);
            $moved{ $found->id } = $test if $found;
        }
    }
    return { %moved, %exact };
}

sub _unique_offset ( $source, $text ) {
    my $offset = index( $source, $text );
    return if $offset < 0 || index( $source, $text, $offset + 1 ) >= 0;
    return $offset;
}

sub _locate_moved ( $original, $current, $sites ) {
    my @lines  = split /\n/, $original, -1;
    my $before = "\n$original\n";
    my $after  = "\n$current\n";
    return sub ($mutant) {
        my ( $start_line, $end_line ) = $mutant->line_span->@*;
        my $first   = max( 0, $start_line - 3 );
        my $last    = min( $#lines, $end_line + 1 );
        my $context = "\n" . join( "\n", @lines[ $first .. $last ] ) . "\n";
        my $from    = _unique_offset( $before, $context );
        my $to      = _unique_offset( $after,  $context );
        return unless defined $from && defined $to;
        my $offset = $to - $from;
        return first {
                 $_->end == $mutant->end + $offset
              && $_->mutator eq $mutant->mutator
              && $_->replacement eq $mutant->replacement
        } @{ $sites->{ $mutant->start + $offset } || [] };
    };
}

sub _inventory_findings ( $result, $selection, $expected ) {
    my @found;
    my $sources = $selection->sources;
    my $saved   = $result->sources;
    for my $path ( sort ( uniq( keys %$sources, keys %$saved ) ) ) {
        push @found, "$path: source missing or changed since the measurement"
          unless exists $sources->{$path} && exists $saved->{$path} && $sources->{$path}->text eq $saved->{$path};
    }
    my @reported  = sort map { $_->{mutant}->id } $result->entries->@*;
    my $inventory = $result->inventory;
    my $current   = $selection->inventory;
    push @found, 'the saved inventory count or digest differs from the analyzed project'
      unless defined $inventory
      && $inventory->{mutants} == $current->{mutants}
      && $inventory->{digest} eq $current->{digest};
    push @found, 'the mutant inventory differs from the analyzed project'
      if join( "\n", sort keys %$expected ) ne join( "\n", @reported );
    push @found, 'the catalog differs from the analyzed project'
      unless defined $result->catalog_digest && $result->catalog_digest eq $selection->catalog_digest;

    return @found;
}

sub _verdict_findings ( $entries, $expected ) {
    my @found;
    for my $entry (@$entries) {
        my ( $mutant, $status, $reason ) = $entry->@{qw(mutant status reason)};
        my $id = $mutant->id;
        push @found, "$id: $status" if $UNFINISHED{$status} || $status eq 'CompileError' && $reason eq 'parse';
        my $source   = $expected->{$id};
        my $reported = $status eq 'Ignored' && $reason eq 'suppressed';
        if ( $reported || $source && $source->suppressed ) {
            push @found, "$id: the suppression needs a matching source directive and a reason"
              unless $reported && $source && $source->suppressed && length( $source->suppression_reason || q{} );
        }
    }
    return @found;
}

sub findings ( $result, $selection ) {
    my @found;
    push @found, 'the release requires a whole measurement'   if defined $result->shard || keys $result->selection->%*;
    push @found, 'the run stopped on ' . $result->interrupted if defined $result->interrupted;
    push @found, 'the release requires a measurement without cached verdicts' if $result->reused;
    push @found, 'a cached verdict differed from the measurement'             if $result->cache_mismatch;
    push @found, "baseline failed: $_->{test}" for $result->baseline_failures->@*;
    push @found, "$_->{path}: $_->{problem}"   for $selection->unanalyzed->@*, $result->problems->@*;

    my %expected = map { $_->id => $_ } $selection->mutants->@*;
    push @found, _inventory_findings( $result, $selection, \%expected );

    push @found, _verdict_findings( $result->entries, \%expected );
    my $score = $result->tally->{score};
    push @found, 'the full mutation score must reach 100%' unless defined $score && $score == 100;
    return \@found;
}

1;
