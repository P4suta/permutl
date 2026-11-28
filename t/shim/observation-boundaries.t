use strict;
use warnings;
use Test::More;
use Scalar::Util qw(dualvar);
use lib 't/shim/lib';
use ShimHarness          qw(all_records lib_dir project run_perl write_file);
use Test::Mutation::Shim ();

subtest 'a spec preserves extraction, ordered aliases and empty fields' => sub {
    my $root = project();
    my $spec =
      write_file( "$root/spec", "\ncommand\tcmd\tone\nextract\tother\ncommand\tcmd\ttwo\ntarget\tcmd\tcopy\t\n" );
    is_deeply Test::Mutation::Shim::read_spec($spec),
      {
        trace    => 0,
        targets  => [ { original => 'cmd', serve => 'copy', outside => q{} } ],
        commands => { cmd   => [qw(one two)] },
        extract  => { other => 1 }
      },
      'blank lines add no settings and extraction belongs to its original';
    my $missing = "$root/missing";
    my $parsed  = eval { Test::Mutation::Shim::read_spec($missing) };
    my $error   = $@;
    ok !defined $parsed, 'a missing spec supplies no settings';
    like $error, qr/\Amutation: cannot read spec \Q$missing\E: \S/, 'a missing spec names the file';
};

subtest 'the first eligible source owns a main program reached through an alias' => sub {
    my $root = project();
    my @source =
      map { write_file( "$root/$_/tool", "print qq{unrelated\\n};\n" ) } qw(extracted unrelated library later);
    my $main = write_file( "$root/installed/tool", <<'PERL' );
use strict;
my $value = 1;
$value += 2;
print "value=$value ", scalar <DATA>;
__DATA__
program data
PERL
    my $text = join q{}, map { "target\t$_\t$_\n" } @source;
    $text .= "extract\t$source[0]\n";
    $text .= "command\t$source[0]\t$main\ncommand\t$source[2]\t$root/missing\n";
    $text .= "command\t$source[2]\t$main\ncommand\t$source[3]\t$main\n";
    for my $placed ( 0, 1 ) {
        my $directory = "$root/records/$placed";
        mkdir $directory or die "create record set: $!";
        write_file( "$root/spec", "trace\t1\nobserve\t1\nplaced\t$placed\n$text" );
        my $run = run_perl(
            root => $root,
            args => [ '-I' . lib_dir(), '-MTest::Mutation::Shim', $main ],
            env  => { TEST_MUTATION_SPEC => "$root/spec", TEST_MUTATION_RECORD => $directory }
        );
        is $run->{status}, 0,                        'the selected script completes' or diag $run->{stderr};
        is $run->{stdout}, "value=3 program data\n", 'the filter preserves the program and DATA';
        is $run->{stderr}, q{},                      'an unavailable alternate path does not warn';
        my ($file) = glob "$directory/*.rec";
        open my $records, '<', $file or die "read records: $!";
        my @hits = grep { /^hit\t/ } <$records>;
        close $records or die "close records: $!";
        my %owners = map { ( split /\t/ )[1] => 1 } @hits;
        is_deeply [ sort keys %owners ], $placed ? [ $source[2] ] : [],
          'only a placed command can supply main-program coverage and the first matching alias owns it';
        ok scalar( grep { /\t3\n\z/ } @hits ), 'the statement in the installed alias has a hit' if $placed;
    }
};

subtest 'binary source reads keep byte identity and a failed close supplies no text' => sub {
    my $root = project();
    write_file( "$root/empty",   q{} );
    write_file( "$root/raw",     "\xC3\xA9\xFF\n" );
    write_file( "$root/read.pl", <<'PERL' );
use strict;
use warnings;
our $failed;
BEGIN {
    *CORE::GLOBAL::close = sub (;*) {
        my $ok = CORE::close($_[0]);
        return $failed ? 0 : $ok;
    };
}
use Test::Mutation::Shim ();
my $read = \&Test::Mutation::Shim::_slurp;
print 'raw=', unpack('H*', $read->('raw')), "\n";
print 'empty=', defined($read->('empty')) ? 'read' : 'failed', "\n";
print 'directory=', defined($read->('.')) ? 'read' : 'failed', "\n";
$failed = 1;
print 'failed=', defined($read->('raw')) ? 'read' : 'failed', "\n";
print 'missing=', defined($read->('absent')) ? 'read' : 'failed', "\n";
PERL
    my $run = run_perl( root => $root, args => [ '-I' . lib_dir(), '-Cio', 'read.pl' ] );
    is $run->{status}, 0, 'binary comparison handles the missing and unclosed file' or diag $run->{stderr};
    is $run->{stdout}, "raw=c3a9ff0a\nempty=read\ndirectory=failed\nfailed=failed\nmissing=failed\n",
      'only readable files supply bytes';
    is $run->{stderr}, q{}, 'failed reads do not leak warnings to the measured test';
};

subtest 'an empty installed copy needs a readable original before the hook can replace it' => sub {
    for my $removed ( 0, 1 ) {
        my $root        = project();
        my $original    = write_file( "$root/original/Blank.pm", q{} );
        my $replacement = write_file( "$root/mutant.pm",         "package Blank; sub value { 53 } 1;\n" );
        write_file( "$root/lib/Blank.pm", q{} );
        write_file( "$root/spec",         "trace\t0\ntarget\t$original\t$replacement\n" );
        write_file( "$root/use.pl",       <<'PERL' );
unlink 'original/Blank.pm' or die "remove original: $!" if shift;
require Blank;
print Blank::value();
PERL
        my $run = run_perl(
            root => $root,
            args => [ '-I' . lib_dir(), '-Ilib', '-MTest::Mutation::Shim', 'use.pl', $removed ],
            env  => { TEST_MUTATION_SPEC => "$root/spec", TEST_MUTATION_RECORD => "$root/records" }
        );
        if ($removed) {
            isnt $run->{status}, 0, 'the empty installed module keeps its ordinary require failure';
            like $run->{stderr}, qr/Blank[.]pm did not return a true value/, 'Perl reports the original failure';
            is_deeply [ grep { $_->[0] eq 'seen' } @{ all_records($root) } ], [], 'the hook supplied no source';
        }
        else {
            is_deeply [ $run->{status}, $run->{stdout} ], [ 0, '53' ], 'a copy of a readable empty file is replaced';
        }
    }
};

subtest 'an unquotable load path keeps its on-disk behavior in a placed run' => sub {
    for my $placed ( 0, 1 ) {
        my $root   = project();
        my $name   = 'quoted"dir';
        my $source = write_file( "$root/$name/Quoted.pm", "package Quoted; sub answer { 11 } 1;\n" );
        my $copy   = write_file( "$root/mutant",          "package Quoted; sub answer { 22 } 1;\n" );
        write_file( "$root/spec",    "trace\t0\nplaced\t$placed\ntarget\t$source\t$copy\n" );
        write_file( "$root/test.pl", "require Quoted; print Quoted::answer(), qq{\\n};\n" );
        my $run = run_perl(
            root => $root,
            args => [ '-I' . lib_dir(), "-I$name", '-MTest::Mutation::Shim', 'test.pl' ],
            env  => { TEST_MUTATION_SPEC => "$root/spec", TEST_MUTATION_RECORD => "$root/records" }
        );
        is $run->{status}, 0, 'an unquotable include path remains loadable' or diag $run->{stderr};
        is $run->{stdout}, $placed ? "11\n" : "22\n", 'only in-place interception serves alternate bytes';
    }
};

subtest 'debugger line entries compare their integer flags with the source text' => sub {
    my $path  = 'example::with::colons';
    my $lines = Test::Mutation::Shim::_source_lines($path);              ## no critic (Subroutines::ProtectPrivateSubs)
    @$lines = ( undef, dualvar( 1.8, '1.3' ), dualvar( 2, '1.0' ), undef );
    is_deeply [ Test::Mutation::Shim::_breakable_lines($path) ], [2],    ## no critic (Subroutines::ProtectPrivateSubs)
      'only the numeric flag of a breakable statement differs';
};

subtest 'the source filters switch debugger compilation at code, data, and end of input' => sub {
    my $root = project();
    write_file( "$root/lib/Target.pm", "package Target;\n1;\n" );
    write_file( "$root/bin/fake-main", "1;\n" );
    write_file( "$root/filters.pl",    <<'PERL' );
use strict;
use warnings;
use Filter::Util::Call ();
use Test::Mutation::Shim ();
my ($filter, $bytes, $count);
no warnings 'redefine';
local *Filter::Util::Call::filter_add = sub { ($filter) = @_ };
local *Filter::Util::Call::filter_read = sub { $_ = $bytes; return $count };
my $main = 'bin/fake-main';
local $0 = $main;
my $module = 'lib/Target.pm';
Test::Mutation::Shim::activate({trace => 1, placed => 1, observe => 1,
    targets => [{original => $main, serve => $main}, {original => $module, serve => $module}]}, 'records');
my $table = do { no strict 'refs'; *{"main::_<$main"}{ARRAY} };
print 'lines-ready=', defined $table ? 1 : 0, "\n";
print 'start=', $^P & 6, "\n";
die "missing main filter\n" unless $filter;
for my $case ([1, "print 1;\n"], [1, "__DATA__\n"], [1, "print 2;\n"], [1, "__END__\n"], [0, q{}]) {
    ($count, $bytes) = @$case;
    my $result = $filter->();
    print "main=$result:", $^P & 6, "\n";
}
unshift @INC, 'lib';
my (undef, $file, $hook) = Test::Mutation::Shim::_serve(undef, 'Target.pm');
die 'missing module filter' unless $hook;
for my $text ("print 1;\n", "__DATA__\n", "print 2;\n", "__END__\n", q{}) {
    local $_ = $text;
    my $result = $hook->();
    print 'module=', defined $result ? $result : 'none', ':', $^P & 6, "\n";
}
close $file or die $!;
PERL
    my $run = ShimHarness::run_bare( root => $root, args => [ '-I' . lib_dir(), 'filters.pl' ] );
    is $run->{status}, 0, 'the command and module both install working filters' or diag $run->{stderr};
    is $run->{stdout},
      join( "\n",
        'lines-ready=1', 'start=6',
        qw(main=1:6 main=1:0 main=1:6 main=1:0 main=0:0),
        qw(module=1:6 module=1:0 module=1:6 module=1:0 module=0:0), q{} ),
      'the compiler traces only source and receives the true read count for both filters';
};

subtest 'each pending source keeps tracing until its own witness runs' => sub {
    my $root = project();
    write_file( "$root/pending.pl", <<'PERL' );
use strict;
use warnings;
use Test::Mutation::Shim ();
Test::Mutation::Shim::trace_source(0, 'A.pm', 'physical-A', 'records', 0);
my (@start) = glob 'records/*.rec';
print 'started=', scalar @start, "\n";
Test::Mutation::Shim::trace_source(1, 'B.pm', 'physical-B', 'records', 0);
Test::Mutation::Shim::_trace_compile(0);
print 'both=', $^P & 6, "\n";
Test::Mutation::Shim::seen(1);
print 'one=', $^P & 6, "\n";
Test::Mutation::Shim::seen(0);
print 'done=', $^P & 6, "\n";
PERL
    my $run = ShimHarness::run_bare( root => $root, args => [ '-I' . lib_dir(), 'pending.pl' ] );
    is $run->{status}, 0, 'interleaved sources can finish in reverse order' or diag $run->{stderr};
    is $run->{stdout}, "started=1\nboth=6\none=6\ndone=0\n",
      'pending compilations own the debugger flags and the start record';
    my @targets = map { $_->[1] } grep { $_->[0] eq 'lines' } @{ all_records($root) };
    is_deeply \@targets, [qw(B.pm A.pm A.pm B.pm)], 'finishing the first witnessed source still visits every target';
};

subtest 'the debugger is initialized before a measured test loads its first target' => sub {
    my $root = project();
    write_file( "$root/debugger.pl", <<'PERL' );
use strict;
use warnings;
use Test::Mutation::Shim ();
Test::Mutation::Shim::activate({trace => 1, observe => 1, targets => []}, 'records');
print 'ready=', defined $DB::single ? $DB::single : 'uninitialized', "\n";
print 'idle=', $^P & 6, "\n";
Test::Mutation::Shim::trace_source(0, 'A.pm', 'physical-A', 'records', 0);
print 'tracing=', $DB::trace, "\n";
PERL
    my $run = ShimHarness::run_bare( root => $root, args => [ '-I' . lib_dir(), 'debugger.pl' ] );
    is $run->{status}, 0, 'a fresh interpreter can install the tracer before loading any source' or diag $run->{stderr};
    is $run->{stdout}, "ready=0\nidle=0\ntracing=1\n",
      'debugger controls are ready while idle and tracing stays enabled for the first source';
};

subtest 'eval tracing sets both filename flags in the test interpreter' => sub {
    for my $eval ( 0, 1 ) {
        my $root = project();
        write_file( "$root/eval.pl", <<'PERL' );
use strict;
use warnings;
use Test::Mutation::Shim ();
Test::Mutation::Shim::activate({trace => 1, trace_eval => shift, observe => 1, targets => []}, 'records');
print $^P & 0xc00, "\n";
PERL
        my $run = ShimHarness::run_bare( root => $root, args => [ '-I' . lib_dir(), 'eval.pl', $eval ] );
        is $run->{stdout}, ( $eval ? 0xc00 : 0 ) . "\n", 'the eval flags follow the spec';
    }
};

subtest 'a disappearing target or installed module supplies no file identity' => sub {
    my $root    = project();
    my $source  = write_file( "$root/empty.pm", q{} );
    my $missing = "$root/lost/empty.pm";
    my ( $device, $inode ) = ( stat $source )[ 0, 1 ];
    my $target = { original => $source, device => $device, inode => $inode };
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    is Test::Mutation::Shim::_target_at( $missing, 'empty.pm', [$target] ), undef,    ## no critic (Subroutines::ProtectPrivateSubs)
      'an absent path cannot match a source containing zero bytes';
    local $INC{'previously-loaded.pm'} = $missing;
    ok !Test::Mutation::Shim::_loaded_from_disk( $target, $device, $inode ),          ## no critic (Subroutines::ProtectPrivateSubs)
      'a stale module table entry proves no load';
    is_deeply \@warnings, [], 'a missing identity does not leak comparison warnings to the measured program';
};

subtest 'the exit record identifies a module loaded before the observer started' => sub {
    for my $placed ( 0, 1 ) {
        my $root   = project();
        my $loaded = write_file( "$root/installed/Resident.pm", "package Resident;\nsub value { 37 }\n1;\n" );
        my $other  = write_file( "$root/copy/Resident.pm",      "die 'the other file was loaded';\n" );
        my $pid    = fork;
        die "fork: $!" unless defined $pid;
        if ( !$pid ) {
            require $loaded;
            Test::Mutation::Shim::activate(
                {
                    observe => 1,
                    placed  => $placed,
                    targets => [ map { { original => $_, serve => $_ } } $other, $loaded ]
                },
                "$root/records"
            );
            exit( Resident::value() == 37 ? 0 : 1 );
        }
        waitpid $pid, 0;
        is $?, 0, 'the interpreter used the implementation in the installed module';
        my $load = $placed ? [ 'blind', $loaded, 'loaded-at-exit' ] : [ 'around', $loaded ];
        is_deeply all_records($root), [ [ 'begin', 0 ], $load, [ 'end', $pid ] ],
          'only the loaded inode supplies an exit observation';
    }
};

subtest 'a relative module registry entry does not identify another file after chdir' => sub {
    for my $case (
        [ 'load then move',   0, 1, 17, 0 ],
        [ 'move then load',   1, 0, 29, 0 ],
        [ 'return from load', 1, 1, 29, 0 ],
        [ 'absolute load',    0, 1, 17, 1 ],
        [ 'untracked source', 0, 1, 17, 0, 1 ],
      )
    {
        my ( $name, $move_first, $move_last, $value, $absolute, $untracked ) = @$case;
        my $root    = project();
        my $first   = write_file( "$root/lib/Resident.pm",       "package Resident; sub value { 17 } 1;\n" );
        my $other   = write_file( "$root/other/lib/Resident.pm", "package Resident; sub value { 29 } 1;\n" );
        my @targets = $untracked ? ($other) : ( $first, $other );
        my $spec    = join q{}, map { "target\t$_\t$_\n" } @targets;
        write_file( "$root/spec",    "trace\t0\nobserve\t1\nplaced\t1\n$spec" );
        write_file( "$root/move.pl", <<'PERL' );
my ($before, $after, $absolute) = @ARGV;
chdir 'other' or die "enter other directory: $!" if $before;
if (length $absolute) { require $absolute } else { require Resident }
print Resident::value(), "\n", $INC{$absolute || 'Resident.pm'}, "\n";
chdir($before ? '..' : 'other') or die "change directory after require: $!" if $after;
PERL
        my $run = run_perl(
            root => $root,
            args => [
                '-I' . lib_dir(), '-Ilib',    '-MTest::Mutation::Shim', 'move.pl',
                $move_first,      $move_last, $absolute ? $first : q{}
            ],
            env => { TEST_MUTATION_SPEC => "$root/spec", TEST_MUTATION_RECORD => "$root/records" }
        );
        is $run->{status}, 0, "$name: the ordinary require completes" or diag $run->{stderr};
        is $run->{stdout}, "$value\n" . ( $absolute ? $first : 'lib/Resident.pm' ) . "\n",
          "$name: the program identifies the value loaded and the path that Perl registered";
        my @observed = grep { $_->[0] eq 'blind' || $_->[0] eq 'around' } @{ all_records($root) };
        is_deeply \@observed, $absolute ? [ [ 'blind', $first, 'loaded-at-exit' ] ] : [],
          "$name: only an unambiguous file identity supplies coverage";
    }
};

subtest 'the command selector stops before looking up aliases for a missing main program' => sub {
    my $root = project();
    write_file( "$root/bin/tool",  "print 1;\n" );
    write_file( "$root/lookup.pl", <<'PERL' );
use strict;
use warnings;
our ($count, $armed);
BEGIN {
    *CORE::GLOBAL::stat = sub ($) {
        my $path = shift;
        $count++ if $armed;
        return CORE::stat($path);
    };
}
use Test::Mutation::Shim ();
Test::Mutation::Shim::activate({observe => 1, targets => [{original => 'bin/tool', serve => 'bin/tool'}]}, 'records');
for my $program ('irrelevant', 'gone/tool') {
    local $0 = $program;
    local $armed = 1;
    local $count = 0;
    Test::Mutation::Shim::_trace_main({commands => {'bin/tool' => ['another/tool']}});
    print "$program=$count\n";
}
PERL
    my $run = ShimHarness::run_bare( root => $root, args => [ '-I' . lib_dir(), 'lookup.pl' ] );
    is $run->{status}, 0,                             'absent commands remain uninstrumented' or diag $run->{stderr};
    is $run->{stdout}, "irrelevant=0\ngone/tool=1\n", 'an unrelated name needs no lookup and a missing main needs one';
    is $run->{stderr}, q{},                           'unavailable identities cause no warnings';
};

subtest 'observe mode leaves the test in control of loading Cwd' => sub {
    my $root = project();
    write_file( "$root/lib/Cwd.pm", "package Cwd; sub value { 41 } 1;\n" );
    write_file( "$root/spec",       "trace\t0\nobserve\t1\n" );
    my $run = ShimHarness::run_bare(
        root => $root,
        args => [
            '-I' . lib_dir(),
            '-Ilib', '-MTest::Mutation::Shim', '-e',
            'print exists $INC{"Cwd.pm"} ? "preloaded " : "unloaded "; require Cwd; print Cwd::value()'
        ],
        env => { TEST_MUTATION_SPEC => "$root/spec", TEST_MUTATION_RECORD => "$root/records" }
    );
    is_deeply [ $run->{status}, $run->{stdout} ], [ 0, 'unloaded 41' ],
      'the test loads its own Cwd after observation starts'
      or diag $run->{stderr};
};

subtest 'the main program retains its identity after changing working directory' => sub {
    my $root   = project();
    my $script = write_file( "$root/bin/app.pl",       "chdir 'other' or die \$!;\nprint 17;\n" );
    my $other  = write_file( "$root/other/bin/app.pl", "print 29;\n" );
    write_file( "$root/spec", "trace\t0\nobserve\t1\nplaced\t1\ntarget\t$script\t$script\ntarget\t$other\t$other\n" );
    my $run = run_perl(
        root => $root,
        args => [ '-I' . lib_dir(), '-MTest::Mutation::Shim', 'bin/app.pl' ],
        env  => { TEST_MUTATION_SPEC => "$root/spec", TEST_MUTATION_RECORD => "$root/records" }
    );
    is_deeply [ $run->{status}, $run->{stdout} ], [ 0, '17' ], 'Perl executes the script opened in the first directory';
    is_deeply [ grep { $_->[0] eq 'blind' } @{ all_records($root) } ], [ [ 'blind', $script, 'loaded-at-exit' ] ],
      'file coverage belongs to the main program that started';
};

subtest 'witnesses distinguish served targets from unseen targets with and without a tracer' => sub {
    for my $blind ( 0, 1 ) {
        my $root   = project();
        my $module = write_file( "$root/lib/Module.pm", "package Module;\n1;\n" );
        write_file( "$root/spec",             "trace\t$blind\ntarget\t$module\t$module\n" );
        write_file( "$root/OtherDebugger.pm", "package DB; sub DB {} 1;\n" );
        write_file( "$root/witness.pl",       <<'PERL' );
use strict;
use warnings;
Test::Mutation::Shim::seen(0);
require Module;
Test::Mutation::Shim::seen(0);
PERL
        my @args = ( '-I' . lib_dir(), '-I.', '-Ilib' );
        push @args, '-MOtherDebugger' if $blind;
        my $run = ShimHarness::run_bare(
            root => $root,
            args => [ @args, '-MTest::Mutation::Shim', 'witness.pl' ],
            env  => { TEST_MUTATION_SPEC => "$root/spec", TEST_MUTATION_RECORD => "$root/records" }
        );
        is $run->{status}, 0, 'the registered module loads with either debugger setting' or diag $run->{stderr};
        my @states = map { [ $_->[0], defined $_->[2] ? $_->[2] : q{} ] }
          grep { defined $_->[1] && $_->[1] eq $module } @{ all_records($root) };
        my $observed = $blind ? 'blind' : 'seen';
        is_deeply \@states, [ [ 'blind', q{} ], [ 'seen', 'opened' ], [ $observed, q{} ], [ $observed, q{} ] ],
          'both compilation and the explicit witness report their own observations';
    }
};

subtest 'finishing a main program still examines the modules loaded after it' => sub {
    my $root = project();
    my $main = write_file( "$root/bin/app", <<'PERL' );
use strict;
use warnings;
require Later;
Test::Mutation::Shim::seen(0);
my $dispatch = $Test::Mutation::Shim::TRACERS[-1];
$dispatch->('untracked/file.pl', 99);
PERL
    my $later = write_file( "$root/lib/Later.pm", "package Later;\n1;\n" );
    write_file( "$root/spec", "trace\t1\nplaced\t1\nobserve\t1\ntarget\t$main\t$main\ntarget\t$later\t$later\n" );
    my $run = ShimHarness::run_bare(
        root => $root,
        args => [ '-I' . lib_dir(), '-Ilib', '-MTest::Mutation::Shim', $main ],
        env  => { TEST_MUTATION_SPEC => "$root/spec", TEST_MUTATION_RECORD => "$root/records" }
    );
    is $run->{status}, 0, 'main program and ordinary module finish' or diag $run->{stderr};
    unlike $run->{stderr}, qr/uninitialized/, 'a debugger callback for an untracked file does not warn';
    my $records = all_records($root);
    is scalar( grep { $_->[0] eq 'seen' && $_->[1] eq $main } @$records ), 1,
      'a witnessed main program reports its compilation';
    is_deeply [ grep { defined $_->[1] && $_->[1] eq $later } @$records ], [ [ 'blind', $later, 'loaded-at-exit' ] ],
      'the module registry identifies the ordinary require at process exit';
    is scalar( grep { $_->[0] eq 'hit' && $_->[1] ne $main } @$records ), 0, 'only the selected main has hit records';
};

subtest 'finishing a record preserves the measured program exit status' => sub {
    my $root = project();
    write_file( "$root/exit.pl", <<'PERL' );
use strict;
use warnings;
use Test::Mutation::Shim ();
no warnings 'redefine';
*Test::Mutation::Shim::finish = sub { system {$^X} $^X, '-e', 'exit 23' };
exit 7;
PERL
    my $run = run_perl( root => $root, args => [ '-I' . lib_dir(), 'exit.pl' ] );
    is $run->{status}, 7, 'a child waited for during cleanup cannot replace the measured exit';
};

done_testing;
