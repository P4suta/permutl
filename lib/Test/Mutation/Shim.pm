use 5.010;

package Test::Mutation::Shim;
use strict;
use warnings;
our $VERSION = '0.001';

# The driver copies this file under a generation-specific package name and rewrites the next line.
my $GENERATION = 0;

# PERLDB_LINE compiles a dbstate op for every statement.
# PERLDB_NOOPT keeps the first statement of a block, which the compiler otherwise drops.
my $TRACE_FLAGS = 0x02 | 0x04;

my %STATE;

sub spec_variable {
    return $GENERATION ? "TEST_MUTATION_SPEC_G$GENERATION" : 'TEST_MUTATION_SPEC';
}

sub record_variable {
    return $GENERATION ? "TEST_MUTATION_RECORD_G$GENERATION" : 'TEST_MUTATION_RECORD';
}

sub import {
    my $spec_path = $ENV{ spec_variable() };
    return if !defined $spec_path || $STATE{active};
    my $record_dir = $ENV{ record_variable() };
    activate( read_spec($spec_path), $record_dir );
    return;
}

sub read_spec {
    my ($path) = @_;
    open my $handle, '<', $path or die "mutation: cannot read spec $path: $!\n";
    my @lines = <$handle>;
    close $handle or die "mutation: cannot close spec $path: $!\n";
    my %spec = ( trace => 0, targets => [] );
    for my $line (@lines) {
        chomp $line;
        next if !length $line;
        my ( $key, @fields ) = split /\t/, $line, -1;
        if ( $key eq 'target' ) {
            push @{ $spec{targets} },
              { original => $fields[0], serve => $fields[1], defined $fields[2] ? ( outside => $fields[2] ) : () };
        }
        elsif ( $key eq 'command' ) {
            push @{ $spec{commands}{ $fields[0] } }, $fields[1];
        }
        elsif ( $key eq 'extract' ) {
            $spec{extract}{ $fields[0] } = 1;
        }
        else {
            $spec{$key} = $fields[0];
        }
    }
    return \%spec;
}

sub activate {
    my ( $spec, $record_dir ) = @_;
    return if $STATE{active};

    my ( %by_base, %disk_files );
    my $index = 0;
    for my $target ( @{ $spec->{targets} } ) {
        $target->{index} = $index++;
        my @stat = stat $target->{original};
        $target->{device} = $stat[0];
        $target->{inode}  = $stat[1];
        my $base = _basename( $target->{original} );
        push @{ $disk_files{$base} }, [ $target->{original}, @stat[ 0, 1 ] ] if @stat;
        if ( defined $target->{outside} ) {
            my @outside = stat $target->{outside};
            $target->{outside_device} = $outside[0];
            $target->{outside_inode}  = $outside[1];
            push @{ $disk_files{$base} }, [ $target->{outside}, @outside[ 0, 1 ] ] if @outside;
        }
        push @{ $by_base{$base} }, $target;
    }

    %STATE = (
        active      => 1,
        includes    => $spec->{includes},
        trace       => 0,
        debug_flags => $^P,
        trace_eval  => $spec->{trace_eval},
        targets     => $spec->{targets},
        by_base     => \%by_base,
        disk_files  => \%disk_files,
        placed      => $spec->{placed},
        by_path     => {},
        record_dir  => scalar _untainted($record_dir),
    );

    my @directory = stat q{.};
    $STATE{directory} = [ @directory[ 0, 1 ] ] if @directory;
    my @program = stat $0;
    $STATE{program} = [ _basename($0), @program[ 0, 1 ] ] if @program;
    if ( $spec->{includes} ) {
        require Cwd;
        _include_directories();
    }
    unless ( $spec->{observe} ) {
        my $hook = sub { return _serve(@_) };
        unshift @INC, $hook;
        _keep_hook_first($hook);
    }
    $STATE{trace} = _install_tracer() if $spec->{trace};
    $STATE{blind} = $spec->{trace} && !$STATE{trace};
    _record_handle();
    _trace_main($spec) if $STATE{trace} && $STATE{placed};
    return;
}

sub _trace_main {
    my ($spec)     = @_;
    my $candidates = $STATE{by_base}{ _basename($0) } or return;
    my @main       = stat $0                          or return;
    my $target;
    for my $candidate ( @{$candidates} ) {
        my $path = $candidate->{original};
        next if $spec->{extract}{$path};
        for my $file ( $path, @{ $spec->{commands}{$path} || [] } ) {
            my @stat = stat $file or next;
            $target = $candidate if $main[0] == $stat[0] && $main[1] == $stat[1];
        }
        last if $target;
    }
    return unless $target;
    require Filter::Util::Call;
    $target->{main} = $0;
    $STATE{by_path}{$0} = $target;
    _source_lines($0);
    _trace_compile(1);
    Filter::Util::Call::filter_add(
        sub {
            my $more = Filter::Util::Call::filter_read();
            _trace_compile( $more > 0 && !/\A__(?:END|DATA)__\s*\z/ );
            return $more;
        }
    );
    return;
}

sub _basename {
    my ($path) = @_;
    return $path =~ m{([^/]+)\z} ? $1 : $path;
}

sub _untainted {
    my ($value) = @_;
    return if !defined $value;
    my ($clean) = $value =~ /\A(.*)\z/s;
    return $clean;
}

sub _keep_hook_first {
    my ($hook) = @_;
    require lib;
    my $original = \&lib::import;
    no warnings 'redefine';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
    *lib::import = sub {
        $original->(@_);
        @INC = ( $hook, grep { !( ref $_ && $_ == $hook ) } @INC );    ## no critic (Variables::RequireLocalizedPunctuationVars)
        return;
    };
    return;
}

sub _include_directories {
    my $dir = $STATE{record_dir};
    return unless defined $dir;
    my @new;
    for my $entry (@INC) {
        next if ref $entry;
        my $path = $entry =~ m{\A/} ? $entry : Cwd::getcwd() . "/$entry";
        next if exists $STATE{include_seen}{$path};
        $STATE{include_seen}{$path} = 1;
        push @new, unpack 'H*', $path;
    }
    return unless @new;
    open my $list, '>>:raw', "$dir/$$.inc" or do { _record( 'error', $dir, "cannot record includes: $!" ); return };
    print {$list} join( "\n", @new ) . "\n" or _record( 'error', $dir, "cannot write includes: $!" );
    close $list                             or _record( 'error', $dir, "cannot close includes: $!" );
    return;
}

sub _resolve {
    my ($file) = @_;
    for my $entry (@INC) {
        next if ref $entry;
        my $path = "$entry/$file";
        return $path if -f $path;
    }
    return;
}

# The file itself wins over a copy with the same text, such as the copy in blib.
# Among several targets with the text of a copy, the one whose path ends in the required name wins.
sub _target_at {
    my ( $path, $file, $candidates ) = @_;
    my @stat = stat $path or return;
    for my $target ( @{$candidates} ) {
        return $target if defined $target->{inode} && $stat[1] == $target->{inode} && $stat[0] == $target->{device};
    }
    my $text = _slurp($path);
    return unless defined $text;
    my @equal = grep {
        my $original = _slurp( $_->{original} );
        defined $original && $text eq $original;
    } @{$candidates};
    my ($named) = grep { substr( "/$_->{original}", -length("/$file") ) eq "/$file" } @equal;
    return $named || $equal[0];
}

sub _slurp {
    my ($path) = @_;
    open my $handle, '<:raw', $path or return;
    local $/ = undef;
    my $content = <$handle>;
    close $handle or return;
    return $content;
}

sub _serve {
    my ( undef, $file ) = @_;
    _trace_compile(0)      if $STATE{trace};
    _include_directories() if $STATE{includes};

    my $candidates = $STATE{by_base}{ _basename($file) } or return;
    my $path       = _resolve($file)                     or return;
    my @actual     = stat $path;
    for my $target ( @{$candidates} ) {
        if (   defined $target->{outside_inode}
            && @actual
            && $actual[1] == $target->{outside_inode}
            && $actual[0] == $target->{outside_device} )
        {
            _record( 'outside', $target->{original} );
            return;
        }
    }
    return if $STATE{placed} && $path =~ /["\n]/;
    my $target = _target_at( $path, $file, $candidates ) or return;

    open my $handle, '<', $target->{serve} or do {    ## no critic (InputOutput::RequireBriefOpen)
        _record( 'error', $target->{original}, "cannot open $target->{serve}: $!" );
        return;
    };
    $target->{served}       = 1;
    $target->{file}         = $file;
    $target->{logical_path} = $path;
    $STATE{by_path}{$path}  = $target;
    _record( 'seen', $target->{original}, 'opened' );

    $INC{$file} = $path;                              ## no critic (Variables::RequireLocalizedPunctuationVars)
        # Code in package DB compiles without trace points, so the block adds no hit to the first line of the file.
    my $prepend = sprintf "UNITCHECK { package DB; %s::mark_compiled(%d) }\n", __PACKAGE__, $target->{index};
    $prepend .= qq{#line 1 "$path"\n} if $path !~ /["\n]/;
    return ( \$prepend, $handle )     if !$STATE{trace};

    my $filter = sub {
        my $more = length $_ ? 1 : 0;
        _trace_compile( $more && !/\A__(?:END|DATA)__\s*\z/ ? 1 : 0 );
        return $more;
    };

    # Perl before 5.16 keeps the lines of a file only when the flags are set before it starts to read the file.
    _trace_compile(1);
    return ( \$prepend, $handle, $filter );
}

sub trace_source {
    my ( $index, $path, $file, $directory, $shift ) = @_;
    if ( !$STATE{active} ) {
        %STATE        = ( active => 1, targets => [], by_path => {}, record_dir => $directory, debug_flags => $^P );
        $STATE{trace} = _install_tracer();
        $STATE{blind} = !$STATE{trace};
        _record_handle();
    }
    my $target = $STATE{targets}[$index] ||= { index => $index, original => $path };
    return if !$STATE{trace};
    $target->{tracing_file}   = $file;
    $target->{line_shift}     = $shift;
    $STATE{by_path}{$file}    = $target;
    $STATE{compiling}{$index} = 1;
    _source_lines($file);
    _trace_compile(1);
    return;
}

sub seen {
    my ($index) = @_;
    my $target = $STATE{targets}[$index] or return;
    $target->{witnessed} = 1;
    if ( defined $target->{tracing_file} ) {
        delete $STATE{compiling}{$index};
        _trace_compile(0);
        _record( 'lines', $target->{original}, join q{,},
            map { $_ + $target->{line_shift} } _breakable_lines( $target->{tracing_file} ) );
    }
    _record(
        ( $target->{served} || defined $target->{main} || defined $target->{tracing_file} )
          && !$STATE{blind} ? 'seen' : 'blind',
        $target->{original}
    );
    return 1;
}

sub mark_compiled {
    my ($index) = @_;
    my $target = $STATE{targets}[$index] or return;
    if ( $STATE{blind} ) {
        _record( 'blind', $target->{original} );
    }
    else {
        _record( 'seen', $target->{original} );
    }
    return;
}

sub _trace_compile {
    my ($enabled) = @_;
    ## no critic (Variables::RequireLocalizedPunctuationVars)
    my $flags = $STATE{debug_flags};
    $flags |= 0x400 | 0x800 if $STATE{trace_eval};
    $flags |= $TRACE_FLAGS  if $enabled || $STATE{compiling} && keys %{ $STATE{compiling} };
    $^P = $flags;
    ## use critic
    return;
}

sub _install_tracer {
    _define_dispatcher();
    return 0 if !$Test::Mutation::Shim::DISPATCHER || \&DB::DB != $Test::Mutation::Shim::DISPATCHER;

    my $by_path = $STATE{by_path};
    my $record  = \&_record;
    {

        # The tracer runs inside the debugger, where no line is traced, so it compiles without trace points too.
        package DB;    ## no critic (Modules::ProhibitMultiplePackages)
        push @Test::Mutation::Shim::TRACERS, sub {
            my ( $file, $line ) = @_;
            my $target = $by_path->{$file} or return;
            $line += $target->{line_shift} if $target->{line_shift};
            return                         if $target->{hits}{$line};
            $target->{hits}{$line} = 1;
            $record->( 'hit', $target->{original}, $line );
            return;
        };
    }

    # Initializing the debugger creates its control variables and can reset $DB::trace on older interpreters.
    _trace_compile(1);
    _trace_compile(0);
    $DB::trace = 1;    ## no critic (Variables::ProhibitPackageVars)
    return 1;
}

sub _define_dispatcher {
    return if defined &DB::DB;

    package DB;        ## no critic (Modules::ProhibitMultiplePackages)
    $Test::Mutation::Shim::DISPATCHER = sub {

        # A trace point lies between two statements, and the second one may read the error number of the first.
        # An assignment restores the number: a localized $! with an initial value comes back as zero.
        my $number = $! + 0;
        my ( undef, $file, $line ) = caller;
        $_->( $file, $line ) for @Test::Mutation::Shim::TRACERS;
        $! = $number;    ## no critic (Variables::RequireLocalizedPunctuationVars)
        return;
    };
    no strict 'refs';    ## no critic (TestingAndDebugging::ProhibitNoStrict)
    *{'DB::DB'} = $Test::Mutation::Shim::DISPATCHER;
    return;
}

sub _record_handle {
    my $dir = $STATE{record_dir};
    return                       if !defined $dir;
    return $STATE{record_handle} if defined $STATE{pid} && $STATE{pid} == $$;
    $STATE{pid} = $$;
    delete $STATE{record_handle};
    my $name = "$dir/$$.rec";
    open my $handle, '>>:raw', $name or do {    ## no critic (InputOutput::RequireBriefOpen)
        warn "mutation: cannot open record $name: $!\n";
        return;
    };
    syswrite $handle, "begin\t$STATE{trace}\n";
    return $STATE{record_handle} = $handle;
}

sub _record {
    my (@fields) = @_;
    my $handle   = _record_handle() or return;
    my @clean    = @fields;
    tr/\t\n/  / for @clean;
    syswrite $handle, join( "\t", @clean ) . "\n";
    return;
}

sub _source_lines {
    my ($path) = @_;
    no strict 'refs';    ## no critic (TestingAndDebugging::ProhibitNoStrict)
    return \@{ $main::{"_<$path"} } if defined $main::{"_<$path"};
    return \@{"main::_<$path"};
}

sub _breakable_lines {
    my ($path) = @_;
    my $lines = _source_lines($path);
    no warnings 'numeric';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
    return grep { defined $lines->[$_] && int( $lines->[$_] ) != int "$lines->[$_]" } 1 .. $#{$lines};
}

sub _relative_disk_match {
    my ( $path, $name, $device, $inode ) = @_;
    my $initial   = $STATE{directory} or return 0;
    my @directory = stat q{.};
    return 0 if !@directory || $directory[0] != $initial->[0] || $directory[1] != $initial->[1];
    my $suffix = q{/} . join q{/}, grep { length && $_ ne q{.} } split m{/}, $path;
    my $peers  = $STATE{disk_files}{$name} || [];
    return !grep { ( q{/} . $_->[0] ) =~ /\Q$suffix\E\z/ && ( $_->[1] != $device || $_->[2] != $inode ) } @{$peers};
}

sub _loaded_from_disk {
    my ( $target, $device, $inode ) = @_;
    return 0 if !defined $inode;
    my $name    = _basename( $target->{original} );
    my $program = $STATE{program};
    return 1 if $program && $program->[0] eq $name && $program->[1] == $device && $program->[2] == $inode;
    for my $path ( grep { defined && !ref } values %INC ) {
        next if _basename($path) ne $name;
        next if $path !~ m{\A/} && !_relative_disk_match( $path, $name, $device, $inode );
        my @stat = stat $path or next;
        return 1 if $stat[1] == $inode && $stat[0] == $device;
    }
    return 0;
}

sub finish {
    return if !$STATE{active};
    for my $target ( grep { defined } @{ $STATE{targets} } ) {
        _record( 'outside', $target->{original} )
          if _loaded_from_disk( $target, $target->{outside_device}, $target->{outside_inode} );
        if ( defined $target->{main} ) {
            _record( 'lines', $target->{original}, join q{,}, _breakable_lines( $target->{main} ) );
            next;
        }
        if ( !$target->{served} ) {
            if ( $target->{witnessed} ) {
                _record( 'lines', $target->{original}, join q{,},
                    map { $_ + $target->{line_shift} } _breakable_lines( $target->{tracing_file} ) )
                  if defined $target->{tracing_file};
                next;
            }
            if ( _loaded_from_disk( $target, $target->{device}, $target->{inode} ) ) {
                if ( $STATE{placed} ) { _record( 'blind', $target->{original}, 'loaded-at-exit' ) }
                else                  { _record( 'around', $target->{original} ) }
            }
            next;
        }
        _record( 'seen', $target->{original}, 'failed' ) if !defined $INC{ $target->{file} };
        _record( 'lines', $target->{original}, join q{,}, _breakable_lines( $target->{logical_path} ) )
          if $STATE{trace};
    }
    _record( 'end', $$ );
    return;
}

END {
    local $?;    ## no critic (Variables::RequireInitializationForLocalVars)
    finish();
}

1;

__END__

=head1 NAME

Test::Mutation::Shim - serve mutated source inside a test process

=head1 DESCRIPTION

The driver of Test::Mutation loads a copy of this module into every test process.
The copy reads the spec file named by its environment variable and puts a hook at the front of C<@INC>.
When a test requires a target file, the hook serves the replacement source and records the event.
The module depends on core modules alone and runs on Perl 5.10 and later.

=head1 RECORDS

Each process writes tab-separated lines to one file in the record directory.
C<begin> carries 1 when line tracing is active.
C<seen> names a target that compiled.
The optional C<opened> and C<failed> fields record opening the source and a failed load.
C<blind> names a target that compiled without an available line tracer.
Its optional C<loaded-at-exit> field identifies a file found in C<%INC> or as the main program at process exit.
The reader uses file coverage for that observation unless the same process already recorded compilation of the target.
C<around> records loading the target around the hook and C<outside> records loading the project file outside its copy.
C<error> carries the target and the diagnostic from the shim.
C<hit> carries a target and a line that ran.
C<lines> carries a target and the lines that hold a runtime statement.
C<end> marks a process that reached its C<END> block.

=head1 FUNCTIONS

=head2 import

Activates the shim when the environment names a spec file.
Perl calls it when a C<-M> switch loads the module.

=head2 trace_source

Traces the executable lines of a diagnostic copy and maps them to lines in the measured source.

=head2 seen

Records compilation from the target itself.
A load outside the tracing hook supplies file coverage.

=head2 mark_compiled

Records that the target with the given index compiled.
The text that the hook serves calls it from a C<UNITCHECK> block.

=head2 activate

    Test::Mutation::Shim::activate( $spec, $record_dir );

Installs the hook for the targets in C<$spec>.
C<$spec> has the keys C<targets> and C<trace>.
Each target has the keys C<original> and C<serve>.

=head2 read_spec

    my $spec = Test::Mutation::Shim::read_spec($path);

Parses a tab-separated spec file.

=head2 finish

Writes the load state of every target to the record file.
The C<END> block calls it.

=head2 spec_variable

Returns the name of the environment variable that carries the spec path.

=head2 record_variable

Returns the name of the environment variable that carries the record directory.

=cut
