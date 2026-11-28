package Test::Mutation::Witness;
use v5.36;
use Digest::SHA            ();
use Encode                 ();
use Fcntl                  ();
use File::Basename         ();
use POSIX                  ();
use Types::Standard        qw(FileHandle Int Maybe Str StrMatch);
use Types::Common::Numeric qw(PositiveOrZeroInt PositiveInt);
use Type::Params           qw(signature_for);
use Test::Mutation::Error;

our $VERSION = '0.001';

signature_for insert =>
  ( positional => [ Str, PositiveOrZeroInt, PositiveInt, PositiveOrZeroInt, Str, PositiveInt ], returns => Str );

sub insert ( $text, $offset, $generation, $index, $records, $descriptor ) {
    my $package   = "Test::Mutation::Shim::G$generation";
    my $work      = File::Basename::dirname($records);
    my $trace     = trace_package($work);
    my $preloaded = _preloaded( $generation, $work );
    my $directory = _directory( $generation, $records, $descriptor );
    my $statement =
        "UNITCHECK{package DB;unless(defined&${trace}::seen?${trace}::seen($index):"
      . "$preloaded&&defined&${package}::seen&&${package}::seen($index)){"
      . $directory
      . 'if(CORE::open(my$h,q{>>:raw},"$d/blind-$$.rec")){CORE::syswrite($h,"blind\t'
      . $index
      . '\n");CORE::close($h)}}}';
    substr $text, $offset, 0, $statement;
    return $text;
}

sub _path_bytes ($path) {
    return utf8::is_utf8($path) ? Encode::encode_utf8($path) : $path;
}

sub _literal ($path) {
    my $hex = unpack 'H*', _path_bytes($path);
    return 'CORE::pack(q{H*},q{' . $hex . '})';
}

sub _preloaded ( $generation, $work ) {
    my $module = "Test/Mutation/Shim/G$generation.pm";
    return '($INC{q{' . $module . '}}||q{}) eq ' . _literal("$work/shim/$module");
}

sub _directory ( $generation, $records, $descriptor ) {
    my $variable = "TEST_MUTATION_RECORD_G$generation";
    return 'my($d)=keys%{+{($ENV{' . $variable . '}||q{}),1}};' unless defined $descriptor;
    return
        'my($d)=keys%{+{(defined$ENV{'
      . $variable
      . '}?$ENV{'
      . $variable
      . '}:do{my@k;'
      . 'if(CORE::open(my$i,q{<&},'
      . $descriptor
      . ')){@k=(CORE::stat($i))[0,1];CORE::close($i)}'
      . _literal($records)
      . '.q{/}.join(q{-},@k)}),1}};';
}

signature_for binding => (
    positional => [ StrMatch [qr/\A(?:[^\W\d]\w*::)*[^\W\d]\w*\z/], PositiveInt, Str, Str, Maybe [PositiveInt] ],
    returns    => Str,
);

sub binding ( $name, $generation, $target, $records, $descriptor ) {
    my $autoload = $name =~ s/[^:]+\z/AUTOLOAD/r;
    my $missing  = 'unless(defined&' . $name . '||defined&' . $autoload . '){';
    my $write =
        'local$!;local$?;local$@;'
      . _directory( $generation, $records, $descriptor )
      . 'if(length($d)&&CORE::open(my$h,q{>>:raw},"$d/call-$$.rec")){CORE::syswrite($h,"seen\t".'
      . _literal($target);
    return join q{},
      map { $_->[0] . '{' . $missing . $write . '."\t' . $_->[1] . '\n");CORE::close($h)}}}' }
      [ 'UNITCHECK', 'unresolved' ], [ 'END', 'unresolved-at-exit' ];
}

signature_for trace => (
    named => [
        text       => Str,
        offset     => PositiveOrZeroInt,
        generation => PositiveInt,
        index      => PositiveOrZeroInt,
        target     => Str,
        work       => Str,
        descriptor => PositiveInt,
        line       => PositiveInt
    ],
    returns => Str,
);

sub trace ($arg) {
    my $generation = $arg->generation;
    my $package    = "Test::Mutation::Shim::G$generation";
    my $trace      = trace_package( $arg->work );
    my $preloaded  = _preloaded( $generation, $arg->work );
    my $statement =
        'BEGIN{package DB;my$t;if('
      . $preloaded
      . '){$t=\&'
      . $package
      . '::trace_source}'
      . 'else{unless(defined&'
      . $trace
      . '::trace_source){my$f='
      . _literal( $arg->work . '/trace.pl' ) . ';'
      . 'local$INC{$f};delete$INC{$f};CORE::require($f)}$t=\&'
      . $trace
      . '::trace_source}'
      . _directory( $generation, $arg->work . '/records', $arg->descriptor ) . '$t->('
      . join( ',', $arg->index, _literal( $arg->target ), '__FILE__', '$d', $arg->line . '-__LINE__' ) . ')}';
    my $text = $arg->text;
    substr $text, $arg->offset, 0, $statement;
    return $text;
}

signature_for trace_package => ( positional => [Str], returns => Str );

sub trace_package ($work) {
    return 'Test::Mutation::Shim::Trace_' . Digest::SHA::sha256_hex( _path_bytes($work) );
}

signature_for reserve => ( positional => [Str], returns => FileHandle );

sub reserve ($path) {
    sysopen my $file, $path, Fcntl::O_RDONLY()
      or Test::Mutation::Error::raise( 'file-unreadable', path => $path, reason => "$!" );
    return $file if fileno($file) > 2;
    my $number = fcntl $file, Fcntl::F_DUPFD(), 3;
    defined $number or Test::Mutation::Error::raise( 'file-unreadable', path => $path, reason => "$!" );
    open my $slot, '<&=', $number
      or Test::Mutation::Error::raise( 'file-unreadable', path => $path, reason => "$!" );
    return $slot;
}

signature_for inherit => ( positional => [ Str, PositiveInt ], returns => Int );

sub inherit ( $directory, $descriptor ) {
    sysopen my $identity, $directory, Fcntl::O_RDONLY()
      or Test::Mutation::Error::raise( 'directory-unopenable', path => $directory, reason => "$!" );
    my $bound = POSIX::dup2( fileno($identity), $descriptor );
    Test::Mutation::Error::raise( 'test-streams-unset', reason => "$!" ) unless defined $bound;
    return $bound;
}

1;

__END__

=head1 NAME

Test::Mutation::Witness - record the compilation of a copied Perl source file

=head1 FUNCTIONS

=head2 insert

Inserts a C<UNITCHECK> block at a character offset without adding a line.
The block records the target index through the shim or in the record directory of the current test.

=head2 binding

Checks the function name introduced by a replacement in its lexical scope when Perl finishes compiling the file and when the process exits.
A package with an autoloader can resolve the call at run time.

=head2 trace

Places a line tracer before the first statement of a diagnostic copy.

=head2 trace_package

Returns the package name for the tracer in a single workspace.

=head2 reserve

Reserves a descriptor above the standard streams for the duration of the run.

=head2 inherit

Binds the reserved descriptor to the private directory of one test before C<exec>.
A descendant that clears its environment can still identify its test by the device and inode of the directory.

=cut
