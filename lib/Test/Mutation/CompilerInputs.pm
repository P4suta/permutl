use 5.010;

package Test::Mutation::CompilerInputs;
use strict;
use warnings;
use Config qw(%Config);
use Cwd    ();
use Fcntl  qw(O_CREAT O_EXCL O_WRONLY);

our $VERSION = '0.001';

my ($record) = ( $ENV{TEST_MUTATION_COMPILER_INPUTS} || q{} ) =~ /\A(.*)\z/s;
if ( length($record) && lstat $record ) {
    $record = q{} unless -f _ && unlink $record;
}
my %initial       = map { _absolute($_) => 1 } grep { !ref } @INC;
my $operands      = $ENV{TEST_MUTATION_COMPILER_READS} || q{};
my @core          = @Config{qw(privlibexp archlibexp)};
my $initial_reads = _opened( \%ENV );

sub _absolute {
    my ($path) = @_;
    return $path =~ m{\A/} ? $path : Cwd::getcwd() . ( $path eq q{.} ? q{} : "/$path" );
}

sub _opened {
    my ($environment) = @_;
    my %paths;
    for my $operand ( split /,/, $operands ) {
        return unless $operand =~ /\A([ef])((?:[a-f0-9]{2})+)\z/;
        my ( $kind, $name ) = ( $1, pack 'H*', $2 );
        my $path = $kind eq 'e' ? $environment->{$name} : $name;
        return unless defined $path && length $path && -f $path;
        $paths{$operand} = _absolute($path);
    }
    return \%paths;
}

sub _record {
    return unless length $record;
    my %paths         = map { $_ => 1 } grep { !$initial{$_} } map { _absolute($_) } grep { !ref } @INC;
    my @libraries     = ( keys %initial, keys %paths );
    my $current_reads = _opened( \%ENV );
    return unless $initial_reads && $current_reads;
    for my $operand ( keys %$initial_reads ) {
        return if $initial_reads->{$operand} ne $current_reads->{$operand};
        $paths{ $current_reads->{$operand} } = 1;
    }
    my $observer = join( '/', split /::/, __PACKAGE__ ) . '.pm';
    my %modules;
    for my $name ( keys %INC ) {
        my $loaded = $INC{$name};
        next unless defined $loaded;
        return if ref $loaded;
        my $file = _absolute($loaded);
        $modules{$file} = 1
          if $name ne $observer && !grep { index( $file, "$_/" ) == 0 } @core;
        next if grep { index( $file, "$_/" ) == 0 } @libraries;
        return unless -f $file;
        $paths{$file} = 1;
    }
    my @lines = map { 'm' . unpack( 'H*', $_ ) } sort keys %modules;
    push @lines, map { unpack( 'H*', $_ ) } sort keys %paths;
    _write_record( join "\n", @lines, q{.}, q{} );
    return;
}

sub _write_record {
    my ($bytes) = @_;
    sysopen my $out, $record, O_WRONLY | O_CREAT | O_EXCL, 0600 or return;
    my ( $device, $inode ) = stat $out;
    my $written = syswrite $out, $bytes;
    my $closed  = close $out;
    return if $closed && defined $written && $written == length $bytes;
    my ( $named_device, $named_inode ) = lstat $record;
    unlink $record if defined $inode && defined $named_inode && $device == $named_device && $inode == $named_inode;
    return;
}

CHECK { _record() }

1;

__END__

=head1 NAME

Test::Mutation::CompilerInputs - record external inputs to a standalone Perl compilation

=head1 DESCRIPTION

The driver loads this module in the target Perl before a standalone compilation.
The module records additional library directories and modules loaded outside the initial search path.
For known read-only C<open> calls, the target interpreter resolves literal paths and named environment variables.
The driver checks the load-time code of non-core modules before it trusts a file operand read during compilation.
Requiring any selected file also runs its file-scope code, which a standalone syntax check skips.
With equivalence checks enabled, cached and reported verdicts share an original compilation when the source may load a module or read a file.
An operand discovered in a loaded module takes a second pass to identify its file.
Reports and shards use the target Perl's C<-c> check to record inputs when equivalence checking is disabled.
Merging shards requires a complete compiler input record.
A compile-time assignment can change a package variable without changing the deparsed program.

=cut
