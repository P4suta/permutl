package Fixture;
use v5.36;
use Cwd         ();
use Digest::SHA ();
use File::Find  ();
use File::Path  ();
use File::Temp  ();
use Exporter 'import';
use Test2::API     qw(context);
use Test::Mutation ();

our @EXPORT_OK = qw(copy_of leftovers ran ran_from run_fixture tree_digest statuses with_driver_shims write_file);

sub write_file ( $path, $content ) {
    my ($directory) = $path =~ m{\A(.*)/};
    File::Path::make_path($directory);
    open my $handle, '>:raw', $path or die "write $path: $!";
    print {$handle} $content or die "write $path: $!";
    close $handle            or die "close $path: $!";
    return $path;
}

my $LIBRARY = Cwd::abs_path('lib');
my $COMMAND = Cwd::abs_path('bin') . '/mutation';

sub _names ( $directory, $pattern ) {
    opendir my $handle, $directory or return;
    my @names = sort grep { $_ ne q{.} && $_ ne q{..} && $_ =~ $pattern } readdir $handle;
    closedir $handle or die "close $directory: $!";
    return @names;
}

# What stands in the temporary directory of a run and as work directories in the project, apart from the known entries.
sub leftovers ( $temporary, $root, @known ) {
    my %known = map { $_ => 1 } @known;
    return [
        grep { !$known{$_} } ( map { "$_ in the temporary directory" } _names( $temporary, qr/./ ) ),
        ( map { ".mutation/$_ in the project" } _names( "$root/.mutation", qr/\Arun-/ ) )
    ];
}

# A run leaves nothing behind unless the test names what it expects to stay.
sub _left_ok ( $what, $stayed, $expected ) {
    my $as_expected = defined $expected ? $stayed->@* && !grep { $_ !~ $expected } $stayed->@* : !$stayed->@*;
    my $name        = defined $expected ? "$what leaves what the test expects" : "$what leaves nothing behind";
    my $context     = context();
    $context->ok( $as_expected ? 1 : 0, $name, [ map { "left: $_" } $stayed->@* ] );
    $context->release;
    return;
}

# Move the active measurement switches to the driver command so its independent project inherits the caller's preloads.
sub with_driver_shims ($driver) {
    my $options = $ENV{PERL5OPT} || q{};
    my @switches;
    for my $generation ( 1 .. ( $ENV{TEST_MUTATION_GENERATION} || 0 ) ) {
        my $name = "Test/Mutation/Shim/G$generation.pm";
        my $file = $INC{$name};
        next if !defined $file || ref $file;
        my ($directory) = $file =~ m{\A(.+)/\Q$name\E\z}s;
        next unless defined $directory;
        my $include = $directory =~ /\s/ ? '-Mlib+pack(q(H*),q(' . unpack( 'H*', $directory ) . '))' : "-I$directory";
        my $load    = "-MTest::Mutation::Shim::G$generation";
        push @switches, "-I$directory", $load if $options =~ s/(?<!\S)\Q$include $load\E(?!\S)//;
    }
    return $driver->() unless @switches;
    local $ENV{PERL5OPT} = join q{ }, split q{ }, $options;
    return $driver->(@switches);
}

sub _spawn ( $library, $root, $temporary, @arguments ) {
    my $output = File::Temp->new;
    my $errors = File::Temp->new;
    my $pid    = fork;
    die "fork: $!" if !defined $pid;
    if ( !$pid ) {
        chdir $root or die "chdir $root: $!";
        local $ENV{TMPDIR} = $temporary;
        open STDIN,  '<', '/dev/null'       or die "stdin: $!";
        open STDOUT, '>', $output->filename or die "stdout: $!";
        open STDERR, '>', $errors->filename or die "stderr: $!";
        with_driver_shims(
            sub (@switches) { exec {$^X} $^X, "-I$library", @switches, $COMMAND, @arguments or die "exec: $!" } );
    }
    waitpid $pid, 0;
    my $read = sub ($file) {
        open my $handle, '<', $file->filename or die "read: $!";
        local $/ = undef;
        my $text = readline $handle;
        return defined $text ? $text : q{};
    };
    return { exit => $? >> 8, stdout => $read->($output), stderr => $read->($errors) };
}

# A test states the exit status it expects, so a command that crashed never reads as one that printed nothing.
sub ran ( $exit, $root, @arguments ) {
    return ran_from( $LIBRARY, $exit, $root, @arguments );
}

sub ran_from ( $library, $exit, $root, @arguments ) {
    my $temporary = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my @known     = leftovers( $temporary, $root )->@*;
    my $run       = _spawn( $library, $root, $temporary, @arguments );
    my $context   = context();
    $context->ok(
        $run->{exit} == $exit ? 1 : 0,
        "mutation @arguments exits with status $exit",
        [ "the exit status is $run->{exit}", $run->{stderr} ]
    );
    $context->release;
    _left_ok( "mutation @arguments", leftovers( $temporary, $root, @known ), undef );
    return { $run->%*, temporary => $temporary };
}

sub copy_of ($name) {
    my $source = Cwd::abs_path("t/fixtures/$name");
    my $target = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                my $relative = substr $File::Find::name, length $source;
                return File::Path::make_path("$target$relative") if -d $File::Find::name;
                open my $in,  '<:raw', $File::Find::name  or die "read $File::Find::name: $!";
                open my $out, '>:raw', "$target$relative" or die "write $target$relative: $!";
                local $/ = undef;
                print {$out} readline $in or die "copy $relative: $!";
                close $out                or die "close $relative: $!";
            },
        },
        $source,
    );
    return $target;
}

sub tree_digest ($root) {
    my %digest;
    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                return if !-f $File::Find::name;
                $digest{ substr $File::Find::name, length($root) + 1 } =
                  Digest::SHA->new(256)->addfile($File::Find::name)->hexdigest;
            },
        },
        $root,
    );
    return \%digest;
}

# The settings go to the configuration, apart from two that belong to the test.
# `temporary` names the temporary directory of the run, and `leaves` is a pattern for what the run may leave.
sub run_fixture ( $root, %settings ) {
    my $leaves    = delete $settings{leaves};
    my $temporary = delete $settings{temporary};
    $temporary = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) ) if !defined $temporary;
    my @known = leftovers( $temporary, $root )->@*;
    my @events;

    # The run takes its settings as a call of the library does.
    my $result = eval {
        local $ENV{TMPDIR} = $temporary;
        with_driver_shims(
            sub {
                Test::Mutation::run(
                    root => $root,
                    jobs => 2,
                    %settings, on_event => sub ( $event, $data ) { push @events, $event }
                );
            }
        );
    };
    my $error = $@;
    _left_ok( 'the run', leftovers( $temporary, $root, @known ), $leaves );
    die $error if !$result;
    return ( $result, \@events, $temporary );
}

sub _label ($mutant) {
    return sprintf '%s:%d %s', $mutant->path, $mutant->from->[0], $mutant->description;
}

sub statuses ($result) {
    return { map { _label( $_->{mutant} ) => $_->{status} } $result->entries->@* };
}

1;
