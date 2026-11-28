package Test::Mutation::Select;
use v5.36;
use Cwd             ();
use File::Spec      ();
use Types::Standard qw(ArrayRef Bool HashRef InstanceOf Maybe Optional Str Undef);
use Type::Params    qw(signature_for);
use Digest::SHA     ();
use File::Basename  ();
use POSIX           ();
use Test::Mutation::Diff;
use Test::Mutation::Git;
use Test::Mutation::Mutator::Catalog;
use Test::Mutation::Project;
use Test::Mutation::Selection;
use Test::Mutation::Signals;
use Test::Mutation::Source;
use Test::Mutation::Suppression;
use Test::Mutation::Error;
use Test::Mutation::Types qw(PathSelection);
use Test::Mutation::Store::Key;
use Test::Mutation::Store;
use Test::Mutation::Store::Analysis;

our $VERSION = '0.001';

# Revise this key when the analyzer changes the sites, candidates or refusals it records.
our $ANALYSIS_REVISION = 3;

sub _refuse ( $path, $reason ) {
    return Test::Mutation::Error::raise( 'path-selector-invalid', path => $path, reason => $reason );
}

sub _ranges ( $operand, $lines ) {
    my @ranges;
    for my $part ( split /,/, $lines, -1 ) {
        my ( $first, $last ) = $part =~ /\A([1-9][0-9]*)(?:-([1-9][0-9]*))?\z/;
        _refuse( $operand, 'expected a positive line or ascending line range' ) if !defined $first;
        $last = $first                                                          if !defined $last;
        _refuse( $operand, 'the last line precedes the first' )                 if $last < $first;
        push @ranges, [ 0 + $first, 0 + $last ];
    }
    return \@ranges;
}

signature_for paths => ( positional => [ Str, ArrayRef [Str], ArrayRef [Str] ], returns => PathSelection );

sub paths ( $root, $operands, $sources ) {
    my %selected;
    for my $operand ( $operands->@* ) {
        my ( $path, $lines ) = ($operand);
        ( $path, $lines ) = ( $1, $2 ) if !-e File::Spec->rel2abs( $path, $root ) && $operand =~ /\A(.+):([^:]*)\z/;
        my $absolute = File::Spec->rel2abs( $path, $root );
        _refuse( $operand, 'the path does not exist' ) if !length $path || !-e $absolute;
        my $relative  = File::Spec->abs2rel( Cwd::abs_path($absolute), $root );
        my $directory = -d $absolute;
        _refuse( $operand, 'a line range needs a file' ) if defined $lines && ( $directory || !length $lines );
        my $ranges = defined $lines ? _ranges( $operand, $lines ) : [];
        my @matches =
          grep { $_ eq $relative || ( $directory && ( $relative eq q{.} || index( $_, "$relative/" ) == 0 ) ) }
          $sources->@*;
        _refuse( $operand, 'no selected source matches the path' ) if !@matches;

        for my $file (@matches) {
            next                  if exists $selected{$file} && !$selected{$file}->@*;
            $selected{$file} = [] if !$ranges->@*;
            push $selected{$file}->@*, $ranges->@* if $ranges->@*;
        }
    }
    return \%selected;
}

signature_for resolve => (
    named => [
        config   => InstanceOf ['Test::Mutation::Config'],
        paths    => Optional [ Maybe [PathSelection] ],
        changed  => Optional [ Maybe [PathSelection] ],
        operands => ArrayRef [Str],
        { default => sub { [] } },
        baseline_only => Bool,
        { default => 0 },
        read_only => Bool,
        { default => 0 },
        identifiers      => Optional [ ArrayRef [Str] ],
        historical_paths => HashRef [Str],
        { default => sub { {} } },
        reports => Bool,
        { default => 0 },
        summary => Optional [ Maybe [Str] ],
    ],
    returns => InstanceOf ['Test::Mutation::Selection'],
);

signature_for operand_paths => (
    positional => [ InstanceOf ['Test::Mutation::Config'], ArrayRef [Str] ],
    returns    => PathSelection
);

sub operand_paths ( $config, $operands ) {
    return paths( $config->root, $operands, _files( $config, $config->root, 'source', {} ) );
}

sub _rules_digest ( $config, $version, $mutators ) {
    return Test::Mutation::Store::Key::digest(
        $VERSION, $ANALYSIS_REVISION, "$version", _parser_versions(),
        $config->suppress_require_names,
        $config->suppress_require_reason,
        map { $_->name } @$mutators
    );
}

sub _catalog_digest ( $rules, $digests ) {
    return Test::Mutation::Store::Key::digest( $rules, map { ( $_, $digests->{$_} ) } sort keys %$digests );
}

signature_for measurement_rules => (
    positional => [ InstanceOf ['Test::Mutation::Config'], InstanceOf ['Test::Mutation::Selection'] ],
    returns    => Str
);

sub measurement_rules ( $config, $selection ) {
    return $selection->analysis_rules_digest if $selection->has_analysis_rules_digest;
    my ( undef, $version ) = _interpreter( $selection->project, $selection->perl );
    my $rules = _rules_digest( $config, $version, $selection->mutators );
    return $rules if _catalog_digest( $rules, $selection->digests ) eq $selection->catalog_digest;
    return Test::Mutation::Store::Key::digest( $rules, $selection->catalog_digest );
}

sub resolve ($arg) {
    my $config = $arg->config;
    my $root   = $config->root;
    Test::Mutation::Error::raise(
        'directory-closed',
        directory => $root,
        reason    => 'expected an accessible directory'
    ) if !-d $root || !-x $root;
    $root = Cwd::abs_path($root);
    my $mutators = Test::Mutation::Mutator::Catalog::choose(
        profile => $config->profile,
        enable  => $config->enable,
        disable => $config->disable
    );
    my ( $program, $version ) = _interpreter( $root, $config->perl );
    my $rules = _rules_digest( $config, $version, $mutators );
    my %matches;
    my $files   = _files( $config, $root, 'source', \%matches );
    my $tests   = _files( $config, $root, 'test',   \%matches );
    my $changed = $arg->changed
      // ( defined $config->since ? Test::Mutation::Git::changed( $root, $config->since ) : undef );
    my $paths    = $arg->operands->@* ? paths( $root, $arg->operands, $files ) : $arg->paths;
    my $prefixes = $arg->identifiers || $config->mutant;
    my @pending;
    my $analysis = _analysis(
        $config, $files,
        $mutators,
        {
            root          => $root,
            pending       => \@pending,
            read_only     => $arg->read_only,
            prefixes      => $prefixes,
            rules         => $rules,
            version       => $version,
            paths         => $arg->identifiers && !@$prefixes ? {} : $paths,
            changed       => $changed,
            report_inputs => $arg->reports,
            baseline_only => $arg->baseline_only
        }
    );
    my @mutants = $analysis->{mutants}->@*;

    @mutants = _named( $arg, $prefixes, \@mutants, \%matches ) if @$prefixes;
    my $inventory =
      { mutants => scalar @mutants, digest => Digest::SHA::sha256_hex( join "\n", map { $_->id } @mutants ) };
    if ( defined $config->shard ) {
        my ( $part, $parts ) = split m{/}, $config->shard;
        @mutants = @mutants[ grep { $_ % $parts == $part - 1 } 0 .. $#mutants ];
    }
    my %filters;
    $filters{paths}   = $paths                  if defined $paths;
    $filters{since}   = $config->since          if defined $config->since;
    $filters{mutants} = [ $config->mutant->@* ] if $config->mutant->@*;
    my $catalog = _catalog_digest( $rules, $analysis->{digests} );
    outputs( $config, $arg->summary )                                                           if $arg->reports;
    Test::Mutation::Store::Analysis::publish( Test::Mutation::Store::path($config), \@pending ) if @pending;
    return Test::Mutation::Selection->new(
        $analysis->%*,
        project        => $root,
        perl           => $program,
        tests          => $tests,
        mutators       => $mutators,
        mutants        => \@mutants,
        inventory      => $inventory,
        matches        => \%matches,
        selection      => \%filters,
        catalog_digest => $catalog,
        narrowed       => (
            $paths
              || grep { exists $config->specified->{$_} }
              qw(source source-exclude test test-exclude since mutant enable disable profile shard)
        ) ? 1 : 0,
        analysis_rules_digest => $rules,
    );
}

sub _named ( $arg, $prefixes, $mutants, $matches ) {
    my %wanted;
    my $current = _matches_by_prefix( $prefixes, $mutants );
    for my $prefix (@$prefixes) {
        Test::Mutation::Error::raise( 'mutant-unknown', identifier => $prefix )
          if !$arg->identifiers && length($prefix) < 4;
        my $found = $current->{$prefix};
        unless (@$found) {
            my @stale = grep { index( $_, $prefix ) == 0 } keys $arg->historical_paths->%*;
            Test::Mutation::Error::raise( 'mutant-ambiguous', identifier => $prefix ) if @stale > 1;
            Test::Mutation::Error::raise(
                'mutant-history-stale',
                identifier => $stale[0],
                path       => $arg->historical_paths->{ $stale[0] }
            ) if @stale;
            Test::Mutation::Error::raise( 'mutant-unknown', identifier => $prefix );
        }
        Test::Mutation::Error::raise( 'mutant-ambiguous', identifier => $prefix ) if @$found > 1;
        $wanted{ $found->[0] } = 1;
        $matches->{mutant}{$prefix} = $found;
    }
    return grep { $wanted{ $_->id } } @$mutants;
}

sub _matches_by_prefix ( $prefixes, $mutants ) {
    my %found   = map { $_ => [] } @$prefixes;
    my %lengths = map { length($_) => 1 } grep { /\A[0-9a-f]{1,12}\z/ } keys %found;
    my @lengths = keys %lengths;
    for my $mutant (@$mutants) {
        my $id = $mutant->id;
        for my $length (@lengths) {
            my $matches = $found{ substr $id, 0, $length } or next;
            push @$matches, $id if @$matches < 2;
        }
    }
    return \%found;
}

sub _files ( $config, $root, $name, $matches ) {
    my $exclude = $name . '_exclude';
    my %found;
    for my $item ( [ $name, $config->$name ], [ "$name-exclude", $config->$exclude ] ) {
        my ( $setting, $patterns ) = $item->@*;
        for my $pattern ( $patterns->@* ) {
            my $paths;
            if ( $setting eq $name ) {
                $paths = Test::Mutation::Project::files( $root, [$pattern], [] );
            }
            else {
                my $exclude_pattern = Test::Mutation::Project::pattern_regex($pattern);
                $paths = [ sort grep { /$exclude_pattern/ } keys %found ];
            }
            if ( exists $config->specified->{$setting} ) {
                Test::Mutation::Error::raise(
                    'glob-unmatched',
                    setting => $config->specified->{$setting},
                    pattern => $pattern
                ) if !$paths->@*;
                $matches->{$setting}{$pattern} = $paths;
            }
            if ( $setting eq $name ) {
                @found{ $paths->@* } = (1) x $paths->@*;
            }
            else {
                delete @found{ $paths->@* };
            }
        }
    }
    my @files = sort keys %found;
    @files = grep { !m{\A(?:bin|script)/} || Test::Mutation::Project::perl_script("$root/$_") } @files
      if $name eq 'source' && !exists $config->specified->{source};
    return \@files;
}

sub _interpreter ( $root, $name ) {
    my @candidates =
      $name =~ m{/}
      ? ( File::Spec->rel2abs( $name, $root ) )
      : map { File::Spec->rel2abs( File::Spec->catfile( $_, $name ), $root ) } File::Spec->path;
    my ($program) = grep { -f $_ && -x _ } @candidates;
    Test::Mutation::Error::raise( 'interpreter-invalid', program => $name ) if !defined $program;
    return ( $program, 0 + $] )                                             if $program eq $^X;
    my $pid = open my $answer, q{-|};
    Test::Mutation::Error::raise( 'interpreter-invalid', program => $name ) if !defined $pid;
    _print_version($program)                                                if !$pid;
    my $version = join q{}, readline $answer;
    my $ok      = close $answer;
    Test::Mutation::Error::raise( 'interpreter-invalid', program => $name )
      if !$ok || $version !~ /\A[0-9]+(?:[.][0-9]+)?\z/ || $version < 5.010;
    return ( $program, 0 + $version );
}

sub _print_version ($program) {
    delete $ENV{PERL5OPT};
    open STDERR, '>', File::Spec->devnull or POSIX::_exit(126);
    no warnings 'exec';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
    exec {$program} $program, '-e', 'print $]';
    return POSIX::_exit(127);
}

signature_for by_id => (
    positional => [ ArrayRef [ InstanceOf ['Test::Mutation::Mutant'] ], Str ],
    returns    => InstanceOf ['Test::Mutation::Mutant']
);

sub by_id ( $mutants, $prefix ) {
    my @matches = length $prefix ? grep { index( $_->id, $prefix ) == 0 } $mutants->@* : ();
    Test::Mutation::Error::raise( 'mutant-unknown',   identifier => $prefix ) if !@matches;
    Test::Mutation::Error::raise( 'mutant-ambiguous', identifier => $prefix ) if @matches > 1;
    return $matches[0];
}

signature_for outputs => ( positional => [ InstanceOf ['Test::Mutation::Config'], Maybe [Str] ], returns => Undef );

sub outputs ( $config, $summary ) {
    my %wanted = map { $_ => 1 } $config->format->@*;
    if ( $wanted{json} || $wanted{html} ) {
        my $directory = File::Spec->rel2abs( $config->report_dir, $config->root );
        my $parent    = $directory;
        $parent = File::Basename::dirname($parent) while !lstat $parent;
        Test::Mutation::Error::raise(
            'directory-uncreatable',
            path   => $config->report_dir,
            reason => 'expected a writable directory'
        ) if !-d $parent || !-w _ || !-x _;
        for my $format ( grep { $wanted{$_} } qw(json html) ) {
            my $target = "$directory/mutation.$format";
            _writable_file($target) if -e $target || -l $target;
        }
    }
    if ( $config->github && defined $summary && length $summary ) {
        my $path = File::Spec->rel2abs( $summary, $config->root );
        _writable_file($path);
    }
    return;
}

sub _writable_file ($path) {
    my $parent = File::Basename::dirname($path);
    my $ok     = -e $path || -l $path ? -f $path && -w _ : -d $parent && -x _ && -w _;
    Test::Mutation::Error::raise( 'file-unwritable', path => $path, reason => 'expected a writable file' ) if !$ok;
    return;
}

sub _parser_versions () {
    return ( $PPI::VERSION, $PPIx::Regexp::VERSION ) if defined $PPI::VERSION && defined $PPIx::Regexp::VERSION;
    unless ( grep { ref } @INC ) {
        require Module::Metadata;
        my @versions;
        for my $module (qw(PPI PPIx::Regexp)) {
            my $version = $module->VERSION;
            unless ( defined $version ) {
                my $metadata = Module::Metadata->new_from_module($module);
                $version = $metadata && $metadata->version;
            }
            push @versions, "$version" if defined $version;
        }
        return @versions if @versions == 2;
    }
    require Test::Mutation::Syntax::PPI;
    return ( $PPI::VERSION, $PPIx::Regexp::VERSION );
}

sub _file_reader ( $config, $mutators, $options ) {
    my %chosen = map { $_->name => 1 } $mutators->@*;
    my $others = [ grep { !$chosen{ $_->name } } Test::Mutation::Mutator::Catalog::mutators()->@* ];
    my $store  = Test::Mutation::Store::path( $config, 0 );
    my $db     = $config->cache ? Test::Mutation::Store::read_database($store) : undef;
    return sub ( $batch, $visit ) {
        my @identities =
          map { Test::Mutation::Store::Key::digest( $options->{rules}, $_->@{qw(path digest)} ) } @$batch;
        my $saved = $db ? Test::Mutation::Store::Analysis::read_files( $db, \@identities, $options->{prefixes} ) : {};
        for my $index ( keys @$batch ) {
            my ( $path, $source ) = $batch->[$index]->@{qw(path source)};
            my $identity = $identities[$index];
            my $file     = $saved->{$identity};
            unless ($file) {
                $file = _analyze_file( $config, $source->(), $mutators, $others, $options->{version} );
                push $options->{pending}->@*, [ $identity, $file ] if $config->cache && !$options->{read_only};
            }
            $visit->( $path, $source, $file );
        }
        return;
    };
}

sub _analysis ( $config, $files, $mutators, $options ) {
    my ( $paths, $changed ) = $options->@{qw(paths changed)};
    my %wanted  = map { $_         => 1 } $options->{prefixes}->@*;
    my %lengths = map { length($_) => 1 } keys %wanted;
    my ( %sources, %left_out, @mutants, @problems, @rejected, @refusals );
    my $visit = sub ( $path, $source, $file ) {
        push @refusals, $file->{refusals}->@*;
        if ( defined $file->{problem} ) {
            push @problems, { path => $path, problem => $file->{problem} };
            return;
        }
        my $candidates = $file->{mutants};
        if (%wanted) {
            $candidates = [
                grep {
                    my $id = $_->id;
                    grep { $wanted{ substr $id, 0, $_ } } keys %lengths
                } @$candidates
            ];
        }
        $sources{$path}  = $source->()       if !%wanted || @$candidates;
        $left_out{$path} = $file->{left_out} if $file->{left_out};
        push @mutants, grep { !$paths || !$paths->{$path}->@* || _in_changed_lines( $paths->{$path}, $_ ) }
          grep { !$changed || _in_changed_lines( $changed->{$path}, $_ ) } @$candidates;
        push @rejected, map { { path => $path, $_->%* } } $file->{rejected}->@*;
        return;
    };
    my $digests = _read_sources( $config, $files, $mutators, $options, \%sources, $visit );

    # A run with a broken comment would measure other mutants than the comments ask for, so it measures none.
    Test::Mutation::Error::raise( 'suppressions-invalid', list => join q{; }, map { $_->{text} } @refusals )
      if @refusals;
    return {
        sources    => \%sources,
        mutants    => \@mutants,
        unanalyzed => \@problems,
        rejected   => \@rejected,
        left_out   => \%left_out,
        digests    => $digests
    };
}

sub _read_sources ( $config, $files, $mutators, $options, $sources, $visit ) {
    my ( $root, $paths, $changed ) = $options->@{qw(root paths changed)};
    my ( @batch, %digests, $read );
    my $bytes_held = 0;
    for my $path ( $files->@* ) {
        my $selected = ( !$changed || $changed->{$path} ) && ( !$paths || exists $paths->{$path} );
        next unless $selected || $config->cache || $options->{report_inputs};
        my $bytes = Test::Mutation::Source::read_bytes("$root/$path");
        my $decoded;
        my $source = sub { return $decoded ||= Test::Mutation::Source->from_bytes( path => $path, bytes => $bytes ) };
        $digests{$path} = Digest::SHA::sha256_hex($bytes);
        next unless $selected;
        if ( $options->{baseline_only} ) {
            $sources->{$path} = $source->();
            next;
        }
        $read ||= _file_reader( $config, $mutators, $options );
        push @batch, { path => $path, digest => $digests{$path}, source => $source };
        $bytes_held += length $bytes;
        next if @batch < 64 && $bytes_held < 1024 * 1024;
        $read->( \@batch, $visit );
        @batch      = ();
        $bytes_held = 0;
    }
    $read->( \@batch, $visit ) if @batch;
    return \%digests;
}

sub _analyze_file ( $config, $source, $mutators, $others, $version ) {
    require Test::Mutation::Syntax::PPI;
    require Test::Mutation::Mutant::Generator;
    my $analysis = Test::Mutation::Syntax::PPI::analyze($source);
    Test::Mutation::Signals::check();
    my $file = {
        problem  => $analysis->{problem},
        left_out => scalar $analysis->{dropped}->@*,
        rejected => [],
        refusals => [],
        mutants  => []
    };
    return $file if defined $analysis->{problem};
    my ( $generated, $judged ) = map {
        Test::Mutation::Mutant::Generator::generate(
            source   => $source,
            analysis => $analysis,
            mutators => $_,
            perl     => $version
        );
    } $mutators, $others;
    $file->{mutants}  = $generated->{mutants};
    $file->{rejected} = $generated->{rejected};
    $file->{refusals} = Test::Mutation::Suppression::refusals(
        path           => $source->path,
        suppression    => $analysis->{suppressions},
        mutants        => [ map { $_->{mutants}->@* } $generated, $judged ],
        require_names  => $config->suppress_require_names,
        require_reason => $config->suppress_require_reason,
    );
    return $file;
}

sub _in_changed_lines ( $ranges, $mutant ) {
    return Test::Mutation::Diff::touches( $ranges, $mutant->line_span->@* );
}

1;

__END__

=head1 NAME

Test::Mutation::Select - resolve source path and line operands against a project

=head1 SYNOPSIS

    my $paths = Test::Mutation::Select::paths( $root, ['lib/Adder.pm:7,10-12'], $sources );

=head1 FUNCTIONS

=head2 resolve

Resolves the configured globs, changed lines, path operands, suppressions, mutant prefixes, and shard in order.
Returns a L<Test::Mutation::Selection> before the runner acquires a workspace.

=head2 operand_paths

Resolves path and line operands against the configured source files.

=head2 measurement_rules

Returns the analysis rules for a resolved or caller-supplied selection.
For a selection that supplies only a catalog digest, it uses the target Perl, mutators and settings to reconstruct the catalog.
A catalog with different inputs keeps a separate measurement identity.

=head2 by_id

Returns the single mutant matching the supplied identifier prefix.

=head2 outputs

Checks the files requested by the selected report formats and the GitHub step summary.

=head2 paths

Returns the selected source paths and their inclusive line ranges.
An empty list for a selected file covers every line.
Directory operands include all matching sources below them.
An invalid operand raises a usage error before the run starts.

=cut
