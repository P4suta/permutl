use strict;
use warnings;
use Config ();
use Test::More;
use lib 't/shim/lib';
use ShimHarness qw(lib_dir project run_command run_perl write_file);

sub compile_record {
    my ( $root, $name, $operands, %environment ) = @_;
    my $record = "$root/records/$name";
    my $ran    = run_perl(
        root => $root,
        env  => { %environment, TEST_MUTATION_COMPILER_INPUTS => $record, TEST_MUTATION_COMPILER_READS => $operands },
        args => [ '-I' . lib_dir(), '-MTest::Mutation::CompilerInputs', '-c', 'probe.pl' ],
    );
    is $ran->{status}, 0, "$name compiles" or diag $ran->{stderr};
    return unless -f $record;
    open my $in, '<:raw', $record or die "open $record: $!";
    chomp( my @lines = <$in> );
    close $in or die "close $record: $!";
    return \@lines;
}

my $root    = project();
my $literal = write_file( "$root/literal input", "literal\n" );
my $config  = write_file( "$root/config",        "environment\n" );
write_file( "$root/probe.pl", <<'PERL' );
BEGIN {
    open my $literal, '<', 'literal input' or die "open literal: $!";
    open my $config, '<', $ENV{COMPILER_CONFIG} or die "open config: $!";
    die "wrong inputs" unless <$literal> eq "literal\n" && <$config> eq "environment\n";
}
PERL
my $named    = 'e' . unpack( 'H*', 'COMPILER_CONFIG' );
my $operands = join q{,}, 'f' . unpack( 'H*', 'literal input' ), $named;
my @lines    = @{ compile_record( $root, 'stable', $operands, COMPILER_CONFIG => $config ) || [] };
is pop(@lines), q{.}, 'the compiler terminates the complete input record';
my %lines = map { $_ => 1 } @lines;
ok $lines{ unpack 'H*', $literal }, 'the compiler records the absolute path of a literal read';
ok $lines{ unpack 'H*', $config },  'the compiler records the file named by the environment';

my $later_config = write_file( "$root/second config", "environment\n" );
my %later_inputs =
  map { $_ => 1 } @{ compile_record( $root, 'stable', $operands, COMPILER_CONFIG => $later_config ) || [] };
ok $later_inputs{ unpack 'H*', $later_config } && !$later_inputs{ unpack 'H*', $config },
  'a later successful compilation replaces the inputs at the same record path';

my $other = write_file( "$root/other config", "replacement\n" );
write_file( "$root/probe.pl", <<'PERL' );
BEGIN {
    $ENV{COMPILER_CONFIG} = $ENV{REPLACEMENT_CONFIG};
    open my $input, '<', $ENV{COMPILER_CONFIG} or die "open replacement: $!";
    die "wrong replacement" unless <$input> eq "replacement\n";
}
PERL
ok !defined compile_record( $root, 'rebound', $named, COMPILER_CONFIG => $config, REPLACEMENT_CONFIG => $other ),
  'rebinding an environment operand to another readable file leaves no record';
ok !defined compile_record(
    $root, 'unavailable', $named,
    COMPILER_CONFIG    => "$root/missing",
    REPLACEMENT_CONFIG => $other
  ),
  'an initially unavailable operand cannot acquire evidence later in compilation';

my $initial_setting = write_file( "$root/directory-setting", 'initial' );
write_file( "$root/changed/directory-setting", 'changed' );
write_file( "$root/probe.pl",                  <<'PERL' );
BEGIN {
    chdir 'changed' or die "enter changed directory: $!";
    open my $in, '<', $ENV{COMPILER_CONFIG} or die "open setting: $!";
    die "wrong setting" unless <$in> eq $ENV{EXPECTED_SETTING};
}
PERL
my %unchanged = map { $_ => 1 } @{
    compile_record(
        $root, 'absolute-setting', $named,
        COMPILER_CONFIG  => $initial_setting,
        EXPECTED_SETTING => 'initial'
      )
      || []
};
ok $unchanged{ unpack 'H*', $initial_setting }, 'an absolute setting survives a compiler directory change';
ok !defined compile_record(
    $root, 'relative-setting', $named,
    COMPILER_CONFIG  => 'directory-setting',
    EXPECTED_SETTING => 'changed'
  ),
  'an unchanged environment value can name a different file after the compiler changes its directory';

write_file( "$root/probe.pl", <<'PERL' );
BEGIN {
    if (open my $optional, '<', $ENV{COMPILER_CONFIG}) {
        close $optional or die "close optional config: $!";
    }
}
PERL
ok !defined compile_record( $root, 'absent', $named, COMPILER_CONFIG => "$root/missing" ),
  'a named file that does not exist cannot be recorded as a stable compiler input';

write_file( "$root/probe.pl", <<'PERL' );
BEGIN {
    open my $in, '<', $ENV{CONFIG_DIR} . '/config' or die "open indirect config: $!";
    die "wrong config" unless <$in> eq "environment\n";
}
PERL
ok !defined compile_record( $root, 'indirect', q{?}, CONFIG_DIR => $root ),
  'an opaque operand leaves no record even when its compiled read succeeds';
ok !defined compile_record( $root, 'stable', q{?}, CONFIG_DIR => $root ),
  'an opaque compilation invalidates an earlier complete record at the same path';

my $library = "$root/vendor";
my $loaded  = write_file( "$library/LibraryInput.pm",    "package LibraryInput; sub value { 5 } 1;\n" );
my $direct  = write_file( project() . '/DirectInput.pm', "package DirectInput; sub value { 7 } 1;\n" );
write_file( "$root/probe.pl", <<'PERL' );
BEGIN {
    unshift @INC, 'vendor';
    require LibraryInput;
    require $ENV{DIRECT_MODULE};
    die "wrong modules" unless LibraryInput::value() + DirectInput::value() == 12;
}
PERL
my %modules = map { $_ => 1 } @{ compile_record( $root, 'modules', q{}, DIRECT_MODULE => $direct ) || [] };
ok $modules{ unpack 'H*', $library },         'a directory added to the compiler search path is an input';
ok $modules{ 'm' . unpack( 'H*', $loaded ) }, 'a module in the added directory has a source record';
ok !$modules{ unpack 'H*', $loaded },         'the containing directory covers its module path';
ok $modules{ 'm' . unpack( 'H*', $direct ) } && $modules{ unpack 'H*', $direct },
  'a module outside the search path is both a source record and a file input';
ok !$modules{ unpack 'H*', lib_dir() }, 'the initial search directory is already known';
ok !$modules{ 'm' . unpack( 'H*', $INC{'Config.pm'} ) }, 'a Perl core module needs no source record';
ok !$modules{ 'm' . unpack( 'H*', lib_dir() . '/Test/Mutation/CompilerInputs.pm' ) },
  'the recorder excludes its own source';

my @optional = qw(FirstInput SecondInput);
for my $module (@optional) {
    write_file( "$library/$module.pm",
        qq{die "optional module disabled\n" if \$ENV{DISABLED_MODULE} eq '$module';\n1;\n} );
}
write_file( "$root/probe.pl", <<'PERL' );
BEGIN {
    unshift @INC, 'vendor';
    for my $module (qw(FirstInput SecondInput)) {
        my $file = "$module.pm";
        my $ok = eval { require $file; 1 };
        if ($module eq $ENV{DISABLED_MODULE}) {
            die "expected a failed require" unless !$ok && exists $INC{$file} && !defined $INC{$file};
        } else {
            die "load $module: $@" unless $ok;
        }
    }
}
PERL

# Swap the failed module while keeping the same hash traversal in both compilers.
for my $failed (@optional) {
    my ($available) = grep { $_ ne $failed } @optional;
    my %seen = map { $_ => 1 } @{
        compile_record(
            $root, "ignore-$failed", q{},
            DISABLED_MODULE   => $failed,
            PERL_HASH_SEED    => 0,
            PERL_PERTURB_KEYS => 0
          )
          || []
    };
    ok $seen{ 'm' . unpack( 'H*',  "$library/$available.pm" ) }, "$available is recorded when $failed fails to load";
    ok !$seen{ 'm' . unpack( 'H*', "$library/$failed.pm" ) },    "the failed $failed is excluded";
}

my $vanishing = write_file( project() . '/Transient.pm', "package Transient; sub value { 9 } 1;\n" );
write_file( "$root/probe.pl", <<'PERL' );
BEGIN {
    require $ENV{TRANSIENT_MODULE};
    unlink $ENV{TRANSIENT_MODULE} or die "unlink loaded module: $!";
    die "wrong module" unless Transient::value() == 9;
}
PERL
ok !defined compile_record( $root, 'removed', q{}, TRANSIENT_MODULE => $vanishing ),
  'a loaded file outside the search path must still exist when compilation finishes';

my $stream = write_file( "$root/module-stream", "package StreamedInput; sub value { 11 } 1;\n" );
write_file( "$root/probe.pl", <<'PERL' );
BEGIN {
    unshift @INC, sub {
        return unless $_[1] eq 'StreamedInput.pm';
        open my $in, '<', $ENV{MODULE_STREAM} or die "open module stream: $!";
        return $in;
    };
    require StreamedInput;
    die "expected the loader in %INC" unless ref $INC{'StreamedInput.pm'} && StreamedInput::value() == 11;
}
PERL
ok !defined compile_record( $root, 'streamed', q{}, MODULE_STREAM => $stream ),
  'a module provided by a loader without a file identity leaves no record';

write_file( "$root/output.pl", qq{BEGIN { warn "target diagnostic\\n" }\n} );
my $unwritable = run_perl(
    root => $root,
    env  => { TEST_MUTATION_COMPILER_INPUTS => "$root/missing/output", TEST_MUTATION_COMPILER_READS => q{} },
    args => [ '-I' . lib_dir(), '-MTest::Mutation::CompilerInputs', '-c', 'output.pl' ],
);
is_deeply [ @{$unwritable}{qw(status stderr)} ], [ 0, "target diagnostic\noutput.pl syntax OK\n" ],
  'an unavailable record destination preserves the target compiler diagnostics';

my $many = "$root/include";
mkdir $many or die "mkdir $many: $!";
for my $number ( 1 .. 128 ) {
    my $path = "$many/" . ( 'd' x 176 ) . $number;
    mkdir $path or die "mkdir $path: $!";
}
write_file( "$root/limited.pl", <<'PERL' );
use Test::Mutation::CompilerInputs ();
BEGIN {
    opendir my $dir, 'include' or die "open include: $!";
    push @INC, map { "include/$_" } grep { /^d/ } readdir $dir;
    closedir $dir or die "close include: $!";
}
PERL
my $limited = "$root/records/limited";
my $result  = run_command(
    root => $root,
    env  => {
        TEST_MUTATION_COMPILER_INPUTS => $limited,
        TEST_MUTATION_COMPILER_READS  => q{},
        PERL5OPT                      => $ENV{PERL5OPT},
        PERL5LIB                      => $ENV{PERL5LIB},
    },
    command => [
        '/bin/sh',  '-c', q{ulimit -f 32 && trap '' XFSZ && exec "$@"},
        'compiler', $^X,  '-I' . lib_dir(),
        '-c',       'limited.pl'
    ],
);
is_deeply [ @{$result}{qw(status signal)} ], [ 0, 0 ], 'the target compiles when its record exceeds the file size limit'
  or diag $result->{stderr};
ok !-e $limited, 'a partially written record is discarded';

write_file( "$root/closing.pl", <<'PERL' );
use IO::Handle ();
use POSIX ();
BEGIN {
    *CORE::GLOBAL::close = sub (;*) {
        my ($out) = @_;
        my @file = stat $out;
        my @record = stat $ENV{TEST_MUTATION_COMPILER_INPUTS};
        if (@record && @file && $file[0] == $record[0] && $file[1] == $record[1]) {
            $out->flush or die "flush record: $!";
            if ($ENV{REPLACE_RECORD_WITH}) {
                rename $ENV{REPLACE_RECORD_WITH}, $ENV{TEST_MUTATION_COMPILER_INPUTS} or die "replace record: $!";
            }
            POSIX::close(fileno($out)) == 0 or die "close descriptor: $!";
            warn "record descriptor closed\n";
        }
        return CORE::close($out);
    };
}
use Test::Mutation::CompilerInputs ();
PERL
my $closed    = "$root/records/closed";
my $close_run = run_perl(
    root => $root,
    env  => { TEST_MUTATION_COMPILER_INPUTS => $closed, TEST_MUTATION_COMPILER_READS => q{} },
    args => [ '-I' . lib_dir(), '-c', 'closing.pl' ],
);
is $close_run->{status}, 0, 'a record close error preserves the success of the target compilation';
like $close_run->{stderr}, qr/record descriptor closed/, 'the compiler flushed its record before the descriptor closed';
ok !-e $closed, 'a record with a failed close is discarded even if all bytes reached the file';

my $replacement = "$root/replacement";
symlink $literal, $replacement or die "symlink replacement: $!";
my $swapped  = "$root/records/swapped";
my $swap_run = run_perl(
    root => $root,
    env  => {
        TEST_MUTATION_COMPILER_INPUTS => $swapped,
        TEST_MUTATION_COMPILER_READS  => q{},
        REPLACE_RECORD_WITH           => $replacement,
    },
    args => [ '-I' . lib_dir(), '-c', 'closing.pl' ],
);
is $swap_run->{status}, 0,        'a concurrent replacement preserves the target compilation';
is readlink($swapped),  $literal, 'discarding a failed output preserves a replacement symlink';

done_testing;
