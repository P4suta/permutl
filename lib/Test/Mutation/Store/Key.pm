package Test::Mutation::Store::Key;
use v5.36;
use Config          qw(%Config);
use Cwd             ();
use Digest::SHA     ();
use Encode          ();
use Fcntl           qw(LOCK_SH O_RDONLY);
use File::Basename  ();
use File::Spec      ();
use Time::HiRes     ();
use Types::Standard qw(ArrayRef Bool Dict HashRef Maybe Optional Slurpy Str);
use Type::Params    qw(signature_for);
use Test::Mutation::Error;

our $VERSION = '0.001';

my %last_file;
my %volatile = map { $_ => 1 } qw(
  PWD OLDPWD SHLVL _ TMPDIR HARNESS_ACTIVE HARNESS_VERSION
  GITHUB_RUN_ID GITHUB_RUN_NUMBER GITHUB_RUN_ATTEMPT GITHUB_STEP_SUMMARY GITHUB_ENV GITHUB_OUTPUT GITHUB_PATH GITHUB_STATE
  RUNNER_TEMP RUNNER_TRACKING_ID CI_JOB_ID CI_PIPELINE_ID
  TEST_MUTATION_ROOT TEST_MUTATION_GENERATION TEST_MUTATION_SPEC TEST_MUTATION_RECORD TEST_MUTATION_COMPILER_INPUTS
  TEST_MUTATION_COMPILER_READS
);

signature_for digest => ( positional => [ Slurpy [ ArrayRef [Str] ] ], returns => Str );

sub digest ($parts) {
    my $sha = Digest::SHA->new(256);
    for my $part (@$parts) {
        my $bytes = utf8::is_utf8($part) ? Encode::encode_utf8($part) : $part;
        $sha->add( length($bytes) . q{:} . $bytes );
    }
    return $sha->hexdigest;
}

signature_for environment => ( positional => [ HashRef [ Maybe [Str] ], Optional [ Maybe [Str] ] ], returns => Str );

sub environment ( $env, $project = undef ) {
    my @names = sort grep { defined $env->{$_} && !$volatile{$_} && $_ !~ /\ATEST_MUTATION_(?:SPEC|RECORD)_G[0-9]+\z/x }
      keys %$env;
    my %values = %$env;
    if ( defined $project ) {
        my $separator = $Config{path_sep};
        my $root      = Cwd::abs_path($project) || $project;
        for my $name ( grep { defined $values{$_} } qw(PATH PERL5LIB PERLLIB) ) {
            $values{$name} =
              digest( map { _search_path( $project, $root, $_ ) } split /\Q$separator\E/, $values{$name}, -1 );
        }
    }
    return digest( map { ( $_, $values{$_} ) } @names );
}

sub _location ( $root, $path ) {
    return ( 'project', q{} ) if $path eq $root;
    my $prefix = $root eq '/' ? '/' : "$root/";
    return ( 'project', '/' . substr( $path, length($prefix) ) ) if index( $path, $prefix ) == 0;
    return ( 'path',    $path );
}

sub _search_path ( $project, $root, $entry ) {
    my ( $kind, $spelling ) = _location( $project, $entry );
    my $path = File::Spec->rel2abs( $entry, $project );
    my ( $directory, @missing ) = $path;
    my $resolved;
    while ( !defined( $resolved = Cwd::abs_path($directory) ) ) {
        my $parent = File::Basename::dirname($directory);
        return ( 'unresolved', digest( $kind, $spelling, $path ) )
          if $parent eq $directory || -l $directory || $directory =~ m{(?:\A|/)\.\.(?:/|\z)};
        unshift @missing, File::Basename::basename($directory);
        $directory = $parent;
    }
    $resolved = File::Spec->catdir( $resolved, @missing ) if @missing;
    my ( $location, $target ) = _location( $root, $resolved );
    return ( $kind,    $spelling ) if $kind eq $location && $spelling eq $target;
    return ( 'mapped', digest( $kind, $spelling, $location, $target ) );
}

signature_for file => ( positional => [Str], returns => Str );

sub file ($path) {
    my @stat     = Time::HiRes::stat($path);
    my $identity = @stat ? join( q{/}, @stat[ 0, 1, 2, 7, 9, 10 ] ) : undef;
    my $previous = $last_file{$path};
    return $previous->[1]
      if $previous && defined $identity && $previous->[0] eq $identity && $stat[10] < Time::HiRes::time() - 2;
    open my $input, '<:raw', $path
      or Test::Mutation::Error::raise( 'file-unreadable', path => $path, reason => "$!" );
    my $value = Digest::SHA->new(256)->addfile($input)->hexdigest;
    close $input or Test::Mutation::Error::raise( 'file-unclosable', path => $path, reason => "$!" );
    $last_file{$path} = [ $identity, $value ] if defined $identity;
    return $value;
}

signature_for tree => ( positional => [ Str, ArrayRef [Str], Bool, { default => 0 } ], returns => Str );

sub tree ( $root, $skip, $omit_reports ) {
    return project( $root, $skip, [] )->{digest} if $omit_reports;
    return _tree( $root, $skip, undef );
}

signature_for project => (
    positional => [ Str, ArrayRef [Str], ArrayRef [Str] ],
    returns    => Dict [ digest => Str, outputs => ArrayRef [Str] ],
);

sub project ( $root, $skip, $links ) {
    return _project( $root, $skip, $links, 0 );
}

signature_for published_outputs => ( positional => [ Str, ArrayRef [Str], ArrayRef [Str] ], returns => ArrayRef [Str] );

sub published_outputs ( $root, $skip, $links ) {
    return _project( $root, $skip, $links, 1 )->{outputs};
}

sub _project ( $root, $skip, $links, $outputs_only ) {
    require Test::Mutation::Report::Publication;
    my $reports = { names => [], targets => {}, outputs_only => $outputs_only };
    $reports->{candidates} = { map { $_ => 1 } Test::Mutation::Report::Publication::names()->@* };
    my $digest  = _tree( $root, $skip, $reports, $links );
    my @targets = keys $reports->{targets}->%*;
    my @outputs = grep {
        my $path = "$_/";
        !grep { index( "$_/", $path ) == 0 || index( $path, "$_/" ) == 0 } @targets;
    } $reports->{names}->@*;
    $digest = _tree( $root, [ @$skip, @outputs ], undef, $links )
      if !$outputs_only && @outputs != $reports->{names}->@*;
    return { digest => $digest, outputs => \@outputs };
}

signature_for workspace =>
  ( positional => [ Str, ArrayRef [Str], ArrayRef [Str], Maybe [Str], { default => undef } ], returns => Str );

sub workspace ( $root, $skip, $links, $original ) {
    return _tree( $root, $skip, undef, $links, $original );
}

sub _tree ( $root, $skip, $reports, $links = [], $original = undef ) {
    return digest('absent') unless -d $root;
    my $state = { root => $root, files => [], skip => { map { $_ => 1 } @$skip }, parents => {} };
    $state->{links}    = { map { $_ => 1 } @$links };
    $state->{original} = $original;
    _walk( $state, q{}, $reports );
    return digest( $state->{files}->@* );
}

sub _walk ( $state, $relative, $reports ) {
    my $root      = $state->{root};
    my $directory = length $relative ? "$root/$relative" : $root;
    my @inode     = ( stat $directory )[ 0, 1 ];
    my $identity  = join q{/}, @inode;
    return if $state->{parents}{$identity};
    local $state->{parents}{$identity} = 1;
    my ( $names, $observed ) = _directory_files( $directory, $relative, $reports, $state->{skip} );
    my $only_reports = @$names > 0;

    for my $name (@$names) {
        my $path   = length $relative ? "$relative/$name" : $name;
        my $output = !$state->{skip}{$path} && _node( $state, $path, $observed->{$name}, $reports );
        $only_reports = 0 unless $output;
    }
    return $only_reports;
}

sub _directory_files ( $directory, $relative, $reports, $skip ) {
    my $lock;
    if ($reports) {
        sysopen $lock, $directory, O_RDONLY
          or Test::Mutation::Error::raise( 'directory-unopenable', path => $directory, reason => "$!" );
        flock $lock, LOCK_SH or Test::Mutation::Error::raise( 'file-unreadable', path => $directory, reason => "$!" );
    }
    opendir my $dir, $directory
      or Test::Mutation::Error::raise( 'directory-unopenable', path => $directory, reason => "$!" );
    my @names = sort grep { $_ ne q{.} && $_ ne q{..} } readdir $dir;
    closedir $dir or Test::Mutation::Error::raise( 'file-unclosable', path => $directory, reason => "$!" );
    return ( \@names, {} ) unless $reports;
    my %observed;
    my $prefix     = length $relative ? "$relative/" : q{};
    my @candidates = grep { $reports->{candidates}{$_} && !$skip->{"$prefix$_"} } @names;

    if (@candidates) {
        my $expected = Test::Mutation::Report::Publication::outputs( $directory, $relative );
        for my $name (@candidates) {
            $observed{$name} = _report_file( "$directory/$name", $name, $expected, $reports->{outputs_only} );
        }
    }
    close $lock or Test::Mutation::Error::raise( 'file-unclosable', path => $directory, reason => "$!" );
    return ( \@names, \%observed );
}

sub _report_file ( $path, $name, $expected, $outputs_only ) {
    return if -l $path || !-f $path;
    my $mode     = ( stat $path )[2] & oct '111';
    my $recorded = !$mode && exists $expected->{$name};
    return if $outputs_only && ( !$recorded || !-r $path );
    my $digest = file($path);
    my $output = $recorded && ( !defined $expected->{$name} || $digest eq $expected->{$name} );
    return [ $output, $mode, $digest ];
}

sub _node ( $state, $path, $observed, $reports ) {
    my $root     = $state->{root};
    my $absolute = "$root/$path";
    my $files    = $state->{files};
    my $linked   = $state->{links}{$path};
    if ( $linked && defined $state->{original} ) {
        my $expected = "$state->{original}/$path";
        Test::Mutation::Error::raise( 'measurement-inputs-changed', path => $path )
          unless -l $absolute && readlink($absolute) eq $expected;
        $absolute = $expected;
    }
    if ($observed) {
        if ( $observed->[0] && !$linked ) {
            push $reports->{names}->@*, $path;
            return 1;
        }
        push @$files, 'file', $path, $observed->@[ 1, 2 ];
        return 0;
    }
    if ( -l $absolute ) {
        push @$files, 'link', $path, readlink $absolute;
        _link_target( $state, $reports, $absolute ) if $reports;
        $linked = 1;
    }
    return 0         if $reports && $reports->{outputs_only} && ( $linked || !-x -r -d $absolute );
    $reports = undef if $linked;
    if ( !-d $absolute ) {
        push @$files, 'file', $path, ( ( stat $absolute )[2] & oct '111' ), file($absolute) if -f $absolute;
        return 0;
    }
    my $offset = @$files;
    push @$files, 'directory', $path;
    local $state->{skip} = $linked ? {} : $state->{skip};
    return 0 unless _walk( $state, $path, $reports );
    splice @$files, $offset;
    push $reports->{names}->@*, $path;
    return 1;
}

sub _link_target ( $state, $reports, $absolute ) {
    my $target = Cwd::abs_path($absolute);
    my $root   = $state->{root};
    return if !defined $target || index( $target, "$root/" ) != 0;
    my $identity = join q{/}, ( stat $absolute )[ 0, 1 ];
    $reports->{targets}{ substr $target, 1 + length $root } = 1 unless $state->{parents}{$identity};
    return;
}

signature_for interpreter => ( positional => [Str], returns => Str );

sub interpreter ($program) {
    my ( $path, $actual, $configuration ) = _interpreter($program);
    return digest( $path, file($path), $actual, file($actual), $configuration );
}

signature_for interpreter_build => ( positional => [Str], returns => Str );

sub interpreter_build ($program) {
    my ( $path, $actual, $configuration ) = _interpreter($program);
    return digest( file($path), file($actual), $configuration );
}

sub _interpreter ($program) {
    my $path = Cwd::abs_path($program);
    my ( $actual, $configuration );
    if ( $path eq Cwd::abs_path($^X) ) {
        ( $actual, $configuration ) = ( $path, Config::config_sh() );
    }
    else {
        delete local $ENV{PERL5OPT};
        open my $child, q{-|}, $path, '-MConfig', '-e', 'print $^X, "\0", Config::config_sh()'
          or Test::Mutation::Error::raise( 'interpreter-invalid', program => $program );
        my $data = do { local $/ = undef; readline $child };
        close $child or Test::Mutation::Error::raise( 'interpreter-invalid', program => $program );
        ( $actual, $configuration ) = split /\0/, $data, 2 if defined $data;
        Test::Mutation::Error::raise( 'interpreter-invalid', program => $program )
          unless length($configuration) && -f $actual;
    }
    return ( $path, $actual, $configuration );
}

1;

__END__

=head1 NAME

Test::Mutation::Store::Key - fingerprint the inputs to a mutation measurement

=head1 FUNCTIONS

=head2 digest

Hashes each input with its byte length so different input boundaries stay distinct.

=head2 environment

Hashes the environment that a test inherits after removing driver assignments and volatile run identifiers.
With a project root, library and executable search paths within the project compare by their relative names.

=head2 file

Hashes the bytes of a regular file.

=head2 tree

Hashes relative names, executable bits, symlinks and contents below a directory.
The caller can exclude inputs that have separate keys.
An optional true third argument omits generated mutation reports and directories containing only those reports.

=head2 project

Returns the input digest and the published output paths to omit from an isolated copy.
Linked project inputs retain their visible contents.

=head2 published_outputs

Identifies the published paths to omit from an isolated copy even when a project input is unreadable.
The copy keeps linked inputs and files that lack a matching publication record.

=head2 workspace

Hashes the visible project inputs using the configured links.
When given the original root, verifies that each link in the copy leads back to its project path.

=head2 interpreter

Hashes both the selected executable and the Perl binary and configuration it runs.

=head2 interpreter_build

Identifies the selected executable, the Perl binary, and the compiled configuration across checkout locations.

=cut
