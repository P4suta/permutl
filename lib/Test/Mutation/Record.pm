package Test::Mutation::Record;
use v5.36;
use Types::Standard qw(ArrayRef Str);
use Type::Params    qw(signature_for);
use Test::Mutation::Error;
use Test::Mutation::Types qw(TaskRecord);

our $VERSION = '0.001';

my %APPLY = (
    begin => sub ( $record, $trace, $path, $value ) {
        ${$trace} = $path ? 1 : 0;
        $record->{begun}++;
        return;
    },
    end => sub ( $record, $trace, $path, $value ) {
        $record->{ended}++;
        return;
    },
    seen => sub ( $record, $trace, $path, $value ) {
        my $file = _served( $record, $path );
        $file->{traced} = 0 if !${$trace};
        if ( !length $value ) {
            $record->{compiled}{$path} = 1;
        }
        elsif ( $value eq 'failed' ) {
            $record->{load_failed}{$path} = 1;
        }
        elsif ( $value ne 'opened' ) {
            push $record->{errors}->@*, "$path: unknown load stage $value";
        }
        return;
    },
    blind => sub ( $record, $trace, $path, $value ) {
        _served( $record, $path )->{traced} = 0;
        $record->{compiled}{$path} = 1;
        return;
    },
    hit => sub ( $record, $traced, $path, $value ) {
        if ( $value !~ /\A[1-9][0-9]*\z/ ) {
            push $record->{errors}->@*, "$path: invalid hit line";
            return;
        }
        _served( $record, $path )->{hits}{$value} = 1;
        return;
    },
    lines => sub ( $record, $traced, $path, $value ) {
        $record->{breakable}{$path}{$_} = 1 for grep { length } split /,/, $value;
        return;
    },
    outside => sub ( $record, $traced, $path, $value ) {
        $record->{outside}{$path} = 1;
        return;
    },
    around => sub ( $record, $traced, $path, $value ) {
        $record->{bypassed}{$path} = 1;
        return;
    },
    error => sub ( $record, $traced, $path, $value ) {
        push $record->{errors}->@*, "$path: $value";
        return;
    },
);

sub _interpreter_streams ($text) {
    my @parts = split /(?=^begin\t[^\t\n])/m, $text;
    return $text if @parts < 2;
    my @streams;
    my $ends = 0;

    # An exec discards the END blocks of every observer in the previous interpreter.
    # Only an outstanding ending can link an earlier observer to a later one.
    for my $part ( reverse @parts ) {
        if ($ends) {
            $streams[-1] = $part . $streams[-1];
        }
        else {
            push @streams, $part;
        }
        $ends += () = $part =~ /^end\t[^\t\n]/mg;
        --$ends if $ends;
    }
    return reverse @streams;
}

signature_for parse =>
  ( positional => [ ArrayRef [Str], ArrayRef [Str], { default => sub { [] } } ], returns => TaskRecord );

sub parse ( $texts, $targets ) {
    my %record = (
        begun       => 0,
        ended       => 0,
        served      => {},
        compiled    => {},
        load_failed => {},
        bypassed    => {},
        outside     => {},
        breakable   => {},
        errors      => []
    );
    for my $text ( map { _interpreter_streams($_) } $texts->@* ) {
        my ( %missing, %compiled );
        my $traced = 0;
        for my $line ( split /\n/, $text ) {
            my ( $kind, $path, $value ) = split /\t/, $line, 3;
            next if !defined $kind;
            my $apply = $APPLY{$kind};
            if ( !$apply ) {
                push $record{errors}->@*, "unknown record kind $kind";
                next;
            }
            if ( !defined $path || !length $path ) {
                push $record{errors}->@*, "missing field for record kind $kind";
                next;
            }
            if ( $kind eq 'blind' && $path =~ /\A[0-9]+\z/ ) {
                if ( !defined $targets->[$path] ) {
                    push $record{errors}->@*, "unknown target index $path";
                    next;
                }
                $path = $targets->[$path];
            }
            my $stage = $value // q{};
            if ( $kind eq 'seen' && $stage eq 'unresolved' ) {
                $missing{$path} = 1;
                next;
            }
            if ( $kind eq 'seen' && $stage eq 'unresolved-at-exit' ) {
                $record{unresolved}{$path} = 1 if $missing{$path};
                next;
            }
            next if $kind eq 'blind' && $stage eq 'loaded-at-exit' && $compiled{$path};
            $compiled{$path} = 1 if $kind eq 'seen' && !length $stage;
            $apply->( \%record, \$traced, $path, $stage );
        }
    }
    return \%record;
}

sub _served ( $record, $path ) {
    my $served = $record->{served};
    $served->{$path} = { traced => 1, hits => {} } if !exists $served->{$path};
    return $served->{$path};
}

signature_for read_directory =>
  ( positional => [ Str, ArrayRef [Str], { default => sub { [] } } ], returns => TaskRecord );

sub read_directory ( $directory, $targets ) {
    my ( @texts, %includes );
    opendir my $entries, $directory
      or Test::Mutation::Error::raise( 'directory-unopenable', path => $directory, reason => "$!" );
    my @names = sort grep { /[.](?:rec|inc)\z/ } readdir $entries;
    closedir $entries or Test::Mutation::Error::raise( 'file-unclosable', path => $directory, reason => "$!" );
    for my $name (@names) {
        my $path = "$directory/$name";
        open my $handle, '<:raw', $path
          or Test::Mutation::Error::raise( 'file-unreadable', path => $path, reason => "$!" );
        local $/ = undef;
        my $text = readline $handle;
        close $handle or Test::Mutation::Error::raise( 'file-unclosable', path => $path, reason => "$!" );
        if ( $name =~ /[.]inc\z/ ) {
            $includes{ pack 'H*', $_ } = 1 for grep { /\A(?:[0-9a-f]{2})+\z/ } split /\n/, $text || q{};
        }
        elsif ( defined $text ) {
            push @texts, $text;
        }
    }
    my $record = parse( \@texts, $targets );
    $record->{includes} = [ sort keys %includes ] if keys %includes;
    return $record;
}

1;

__END__

=head1 NAME

Test::Mutation::Record - read what the shim recorded about one test run

=head1 SYNOPSIS

    my $record = Test::Mutation::Record::read_directory($directory);
    my $loaded = exists $record->{served}{$path};

=head1 FUNCTIONS

=head2 parse

Folds the texts of the record files of one test run into one record.
C<served> maps each target that the hook served to its trace state and the lines that ran.
A target counts as traced when every interpreter that loaded it was tracing.
C<begun> and C<ended> count observer starts and endings across the record files.
C<exec> keeps the process ID and discards the previous interpreter's C<END> blocks.
C<compiled>, C<load_failed>, C<bypassed>, and C<outside> name the targets with those observations.
C<unresolved> names introduced functions by target when the same process found the binding missing at compilation and exit.
C<errors> preserves diagnostics from the shim and the record decoder.
C<breakable> maps a target to the lines that hold a runtime statement.

=head2 read_directory

Reads the files whose names end in C<.rec> in the given directory in filename order.

=cut
