use v5.36;
use Test2::V0;
use Cwd        ();
use File::Path qw(make_path);
use File::Temp ();
use Fcntl      qw(:flock);
use POSIX      ();

our ( $write_fault, $read_fault, $after_read, $close_fault );    ## no critic (Variables::ProhibitPackageVars)
our $io_package = 'Test::Mutation::Workspace';                   ## no critic (Variables::ProhibitPackageVars)

BEGIN {
    no warnings 'once';
    *CORE::GLOBAL::syswrite = sub : prototype(*$;$$) {
        if ( defined $write_fault && caller eq $io_package ) {
            $! = 5;    ## no critic (Variables::RequireLocalizedPunctuationVars)
            return $write_fault eq 'short' ? 1 : undef;
        }
        return CORE::syswrite( $_[0], $_[1], $_[2], $_[3] ) if @_ == 4;
        return CORE::syswrite( $_[0], $_[1], $_[2] ) if @_ == 3;
        return CORE::syswrite( $_[0], $_[1] );
    };
    *CORE::GLOBAL::sysread = sub : prototype(*\$$;$) {
        if ( $read_fault && caller eq $io_package ) {
            $! = 5;    ## no critic (Variables::RequireLocalizedPunctuationVars)
            return;
        }
        my $count =
          @_ == 4 ? CORE::sysread( $_[0], ${ $_[1] }, $_[2], $_[3] ) : CORE::sysread( $_[0], ${ $_[1] }, $_[2] );
        $after_read->() if $after_read && caller eq 'Test::Mutation::Workspace';
        return $count;
    };
    *CORE::GLOBAL::close = sub : prototype(;*) (@handle) {
        my $closed = @handle ? CORE::close( $handle[0] ) : CORE::close();
        return $closed unless ( $close_fault || q{} ) eq 'file' && caller eq 'Test::Mutation::Workspace';
        $! = 5;    ## no critic (Variables::RequireLocalizedPunctuationVars)
        return !1;
    };
    *CORE::GLOBAL::closedir = sub : prototype(*) ($dir) {
        my $closed = CORE::closedir($dir);
        return $closed unless ( $close_fault || q{} ) eq 'directory' && caller eq 'Test::Mutation::Workspace';
        $! = 5;    ## no critic (Variables::RequireLocalizedPunctuationVars)
        return !1;
    };
}

use Test::Mutation::Workspace;
use Test::Mutation::Report::Publication;

my $parent  = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
my $project = File::Temp::tempdir( CLEANUP => 1 );
local $ENV{TMPDIR} = $parent;

sub put ( $path, $text ) {
    open my $out, '>:raw', $path or die $!;
    print {$out} $text or die $!;
    close $out         or die $!;
    return;
}

sub workspaces () {
    opendir my $entries, $parent or die $!;
    return [ sort grep { /\Amutation-/ } readdir $entries ];
}

subtest 'failed reads and partial writes cannot certify report files' => sub {
    my $root    = File::Temp::tempdir( CLEANUP => 1 );
    my $digests = { 'mutation.json' => 'b' x 64 };
    local $io_package = 'Test::Mutation::Report::Publication';
    Test::Mutation::Report::Publication::record( $root, $root, $digests );
    {
        local $read_fault = 1;
        my $found;
        is warnings { $found = Test::Mutation::Report::Publication::outputs( $root, q{.} ) }, [],
          'a read error leaves the recorded files in the measurement without warnings';
        is $found, {}, 'the failed read identifies no generated files';
    }
    for my $fault (qw(short failed)) {
        local $write_fault = $fault;
        like dies { Test::Mutation::Report::Publication::record( $root, $root, $digests ) },
          qr/\Acannot write .*\.test-mutation-outputs: /, "a $fault write prevents successful publication";
    }
};

subtest 'acquisition either returns a complete workspace or removes the partial result' => sub {
    like dies { Test::Mutation::Workspace::acquire( [] ) }, qr/type constraint "Str" [(]in \$_\[0\][)]/,
      'the project path is validated at the acquisition boundary';
    {
        no warnings qw(once redefine);    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
        my $attempts = 0;
        local *File::Spec::tmpdir = sub { return ++$attempts == 1 ? "$parent/absent/place" : $parent };
        local $SIG{__WARN__} = sub { die @_ };
        my $found = Test::Mutation::Workspace::acquire($project);
        like $found->directory, qr{\A\Q$parent\E/}, 'a vanished temporary parent falls back to the system parent';
        $found->release(0);
    }
    for my $fault (qw(short failed)) {
        local $write_fault = $fault;
        like dies { Test::Mutation::Workspace::acquire($project) }, qr/cannot write .*owner/,
          'an incomplete marker rejects the acquisition';
        is workspaces(), [], 'the failed acquisition releases its directory';
    }
    {
        no warnings 'redefine';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
        local *Test::Mutation::Tree::make = sub { die "cannot prepare a slot\n" };
        like dies { Test::Mutation::Workspace::acquire($project) }, qr/cannot prepare a slot/,
          'acquisition preserves the original error';
        is workspaces(), [], 'the partial tree is removed after a preparation error';
    }
    {
        local $close_fault = 'directory';
        like dies { Test::Mutation::Workspace::acquire($project) }, qr/cannot close \Q$parent\E/,
          'an incomplete listing of previous runs stops reclamation';
    }
    {
        local $close_fault = 'file';
        like dies { Test::Mutation::Workspace::acquire($project) }, qr/cannot close .*processes/,
          'an unclosed lease file prevents publication of a workspace';
        is workspaces(), [], 'the failed lease close leaves no partial directory';
    }
    like dies { Test::Mutation::Workspace::acquire('/') }, qr/no temporary directory outside the project/,
      'the root of the filesystem leaves no eligible temporary parent';
    is $ENV{TMPDIR}, $parent, 'looking for another temporary directory preserves the caller environment';
};

subtest 'a candidate is reclaimed only while the opened marker still names the same file' => sub {
    my $reclaim = \&Test::Mutation::Workspace::_reclaim_directory;    ## no critic (Variables::ProtectPrivateVars)
    my $dir     = "$parent/mutation-aaaaaa";
    make_path($dir);
    my $path   = "$dir/owner";
    my $marker = "Test::Mutation workspace\n";
    put( "$parent/marker", $marker );
    symlink "$parent/marker", $path or die $!;
    {
        local $after_read = sub { die "a symlink target was read\n" };
        $reclaim->($dir);
        ok -l $path, 'cleanup never reads an owner marker through a symlink';
    }
    unlink $path or die $!;
    for my $replace ( 0, 1 ) {
        put( $path, $marker );
        local $after_read = sub {
            rename $path, "$dir/previous" or die $!;
            put( $path, 'a different entry' ) if $replace;
        };
        $reclaim->($dir);
        ok -d $dir, 'a removed or replaced owner marker prevents deletion';
    }
    unlink $path                 or die $!;
    POSIX::mkfifo( $path, 0600 ) or die $!;
    {
        local $SIG{ALRM} = sub { die "cleanup blocked opening a FIFO\n" };
        alarm 1;
        my $error = dies { $reclaim->($dir) };
        alarm 0;
        is $error, undef, 'an owner FIFO cannot block the next run';
    }
    ok -p $path, 'a special file cannot identify an abandoned workspace';
    unlink $path or die $!;
    put( $path, $marker );
    symlink $dir, "$parent/mutation-bbbbbb" or die $!;
    {
        local $after_read = sub { die "a linked directory was entered\n" };
        $reclaim->("$parent/mutation-bbbbbb");
    }
    put( "$dir/processes", q{} );
    {
        no warnings 'redefine';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
        local *Test::Mutation::Workspace::Processes::finish = sub { return 0 };
        $reclaim->($dir);
        ok -d $dir, 'unreleased processes keep the directory';
    }
    $reclaim->($dir);
    ok !-e $dir, 'an abandoned workspace with a matching marker is reclaimed';
};

subtest 'an explicit release reports whether the lock and cleanup completed' => sub {
    my $saved = Test::Mutation::Workspace::acquire($project);
    like dies {
        Test::Mutation::Workspace->new( directory => $saved->directory, _lock => $saved->_lock, typo => 1 )
    }, qr/typo/, 'unknown workspace attributes are rejected';
    {
        no warnings 'redefine';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
        local *Test::Mutation::Workspace::Processes::finish = sub { return 0 };
        ok !$saved->release(0), 'the caller receives a refusal while a process holds the lease';
    }
    like dies { Test::Mutation::Workspace::release( bless( {}, 'ForeignWorkspace' ), 0 ) },
      qr/not isa Test::Mutation::Workspace/, 'only a workspace can release its lease';
    my $kept = $saved->directory;
    ok $saved->release(1),                   'a completed run can be kept';
    ok -f "$kept/kept" && !-e "$kept/owner", 'retention replaces the reclaimable marker';
    ok !defined fileno $saved->_lock,        'the retained workspace releases the file lock';
    my $fails = Test::Mutation::Workspace::acquire($project);
    my $dest  = $fails->directory . '/kept';
    mkdir $dest or die $!;
    ok !$fails->release(1), 'a failed retention is reported';
    my $last = Test::Mutation::Workspace::acquire($project);
    {
        local $close_fault = 'file';
        like dies { $last->release(0) }, qr/cannot close .*owner/, 'the driver reports a failed close of its lock';
    }
};

done_testing;
