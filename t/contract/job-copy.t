use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use lib 't/e2e/lib', 't/shim/lib', 't/lib';
use ShimHarness ();
use Fixture     qw(write_file);
use Raised;
use Test::Mutation::Record;
use Test::Mutation::Runner;
use Test::Mutation::Select;
use Test::Mutation::Settings;
use Test::Mutation::Source;
use Test::Mutation::Workspace;
use Test::Mutation::Workspace::Slot;

my $root     = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
my $original = "package Example;\r\nsub answer { 42 }\r\n1;\r\n";
my $mutant   = $original =~ s/42/43/r;
my $path     = 'lib/Example.pm';
write_file( "$root/$path",      $original );
write_file( "$root/blib/$path", $original );
chmod oct '444', "$root/blib/$path" or die "chmod: $!";
my $placed = Test::Mutation::Workspace::Slot::place( $root, $path, $original, $mutant );
is $placed, [ $path, "blib/$path" ], 'the job receives the mutant in its source and the identical built module';
is Test::Mutation::Source::read_bytes("$root/$_"), $mutant, "exact new bytes in $_" for $placed->@*;
is( ( ( stat "$root/blib/$path" )[2] & oct '777' ), oct '444', 'a read-only copy keeps its mode' );
my $outside = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
write_file( "$outside/Shared.pm", $original );
symlink $outside, "$root/shared" or die "link: $!";
my $bad =
  Raised::error( sub { Test::Mutation::Workspace::Slot::place( $root, 'shared/Shared.pm', $original, $mutant ) } );
is $bad->[1], 'file-unwritable',                                        'a linked parent cannot write outside the job';
is Test::Mutation::Source::read_bytes("$outside/Shared.pm"), $original, 'the external source keeps its bytes';
symlink "$outside/Shared.pm", "$root/lib/Shared.pm" or die "link: $!";
Test::Mutation::Workspace::Slot::place( $root, 'lib/Shared.pm', $original, $mutant );
ok !-l "$root/lib/Shared.pm", 'an atomic replacement detaches a linked file';
is Test::Mutation::Source::read_bytes("$outside/Shared.pm"),  $original, 'external bytes remain original';
is Test::Mutation::Source::read_bytes("$root/lib/Shared.pm"), $mutant,   'the private file has the changed bytes';
subtest 'invalid replacement bytes are rejected before a file is replaced' => sub {
    my $tree = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    write_file( "$tree/Target.pm", $original );
    like dies { Test::Mutation::Workspace::Slot::place( $tree, 'Target.pm', $original, [] ) },
      qr/type constraint "Str"/, 'the placement boundary requires source bytes';
    is Test::Mutation::Source::read_bytes("$tree/Target.pm"), $original, 'the private file retains the original bytes';
};

subtest 'built commands keep their installation-specific interpreter and source body' => sub {
    my $tree      = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my $source    = "#!/usr/bin/env perl\nprint 7;\n";
    my $changed   = $source =~ s/7/11/r;
    my $installed = $source =~ s{\A[^\n]+}{#!/opt/perl}r;
    for my $case (
        [ 'bin/tool',         $source,    $changed ],
        [ 'blib/bin/tool',    $source,    $changed ],
        [ 'blib/script/tool', $installed, $installed =~ s/7/11/r ],
      )
    {
        write_file( "$tree/$case->[0]", $case->[1] );
        chmod oct '751', "$tree/$case->[0]" or die $!;
    }
    is Test::Mutation::Workspace::Slot::place( $tree, 'bin/tool', $source, $changed ),
      [qw(bin/tool blib/bin/tool blib/script/tool)], 'all matching executable copies are returned in order';
    is Test::Mutation::Source::read_bytes("$tree/blib/script/tool"),
      "#!/opt/perl\nprint 11;\n", 'only the body changes below an installed shebang';
    is Test::Mutation::Source::read_bytes("$tree/blib/bin/tool"), $changed,
      'an exact executable copy receives all replacement bytes';
    is( [ ( stat "$tree/bin/tool" )[2] & oct '7777' ], [ oct '751' ], 'the source remains executable' );

    for my $other ( "#!/opt/perl\nprint 71;\n", "print 7;\n", q{} ) {
        write_file( "$tree/bin/tool",         $source );
        write_file( "$tree/blib/script/tool", $other );
        write_file( "$tree/blib/bin/tool",    $other );
        is Test::Mutation::Workspace::Slot::place( $tree, 'bin/tool', $source, $changed ), ['bin/tool'],
          'a generated command with different content is outside the placement';
        is Test::Mutation::Source::read_bytes("$tree/blib/script/tool"), $other,
          'the unmatched script retains its bytes';
    }
    write_file( "$tree/lib/Installer.pm",      $source );
    write_file( "$tree/blib/lib/Installer.pm", $installed );
    is Test::Mutation::Workspace::Slot::place( $tree, 'lib/Installer.pm', $source, $changed ),
      ['lib/Installer.pm'], 'interpreter rewriting applies only to executable directories';
};

subtest 'a fresh child reports line coverage from a witness in its on-disk module' => sub {
    my $child = ShimHarness::project();
    write_file( "$child/Clockwork.pm", <<'MODULE' );
package Clockwork;
BEGIN { require Test::Mutation::Shim; Test::Mutation::Shim::trace_source(0, 'Clockwork.pm', __FILE__, 'records', 0) }
UNITCHECK { Test::Mutation::Shim::seen(0) }
sub read_value { return 11 }
sub unused     { return 12 }
1;
MODULE
    my $run = ShimHarness::run_bare(
        root  => $child,
        clear => 1,
        args  => [ '-I' . ShimHarness::lib_dir(), '-e', q{require './Clockwork.pm'; print Clockwork::read_value()} ]
    );
    is [ $run->@{qw(status stdout stderr)} ], [ 0, '11', q{} ], 'the child loads the on-disk module without a hook';
    my $record = Test::Mutation::Record::read_directory("$child/records");
    my $served = $record->{served}{'Clockwork.pm'};
    is $served->{traced}, 1, 'the standalone witness supplies line coverage for the parent';
    ok $served->{hits}{4} && !$served->{hits}{5}, 'only the method invoked by the child has a hit';
};

subtest 'exec can load the same module without tracing its second interpreter' => sub {
    my $project = ShimHarness::project();
    my $source  = "$project/lib/Example.pm";
    write_file( $source, "package Example;\nsub before { 23 }\nsub after { 47 }\n1;\n" );
    my $settings = "trace\t1\nplaced\t1\ntarget\t$source\t$source\n";
    write_file( "$project/traced.spec", $settings );
    write_file( "$project/disk.spec",   $settings . "observe\t1\n" );
    write_file( "$project/first.pl",    <<'PERL' );
require Example;
die 'the first interpreter did not execute the module' unless Example::before() == 23;
$ENV{TEST_MUTATION_SPEC} = 'disk.spec';
exec {$^X} $^X, @ARGV, '-MTest::Mutation::Shim', 'second.pl', $$ or die "exec: $!";
PERL
    write_file( "$project/second.pl", <<'PERL' );
die 'exec changed the PID' unless $$ == shift;
require Example;
print Example::after();
PERL
    my @libraries = ( '-I' . ShimHarness::lib_dir(), "-I$project/lib" );
    my $run       = ShimHarness::run_bare(
        root => $project,
        args => [ @libraries, '-MTest::Mutation::Shim', 'first.pl', @libraries ],
        env  => { TEST_MUTATION_SPEC => 'traced.spec', TEST_MUTATION_RECORD => "$project/records" }
    );
    is [ $run->@{qw(status stdout stderr)} ], [ 0, '47', q{} ], 'both interpreters execute the module at the same PID';
    my ($file) = glob "$project/records/*.rec";
    like Test::Mutation::Source::read_bytes($file),
      qr/^seen\t\Q$source\E\n.*^begin\t1\n.*^blind\t\Q$source\E\tloaded-at-exit$/ms,
      'the replacement reports its own disk load';
    my $record = Test::Mutation::Record::read_directory("$project/records");
    is [ $record->@{qw(begun ended)} ], [ 2, 1 ], 'only the replacement interpreter runs its END block';
    my $served = $record->{served}{$source};
    ok $served->{hits}{2} && !$served->{hits}{3}, 'only the call before exec has a line hit';
    is $served->{traced}, 0, 'the untraced load in the replacement interpreter requires file coverage';
};

subtest 'two observers in one interpreter can identify the same traced load' => sub {
    my $project = ShimHarness::project();
    my $source  = "$project/lib/Example.pm";
    write_file( $source, "package Example;\nsub value { 23 }\n1;\n" );
    my $settings = "trace\t1\nplaced\t1\ntarget\t$source\t$source\n";
    write_file( "$project/traced.spec",                  $settings );
    write_file( "$project/disk.spec",                    $settings . "observe\t1\n" );
    write_file( "$project/lib/Test/Mutation/Shim/G1.pm", Test::Mutation::Runner::shim_text(1) );
    write_file( "$project/observers.pl",                 <<'PERL' );
require Example;
die 'the module did not run' unless Example::value() == 23;
require Test::Mutation::Shim::G1;
Test::Mutation::Shim::G1->import();
PERL
    my $run = ShimHarness::run_bare(
        root => $project,
        args => [ '-I' . ShimHarness::lib_dir(), "-I$project/lib", '-MTest::Mutation::Shim', 'observers.pl' ],
        env  => {
            TEST_MUTATION_SPEC      => 'traced.spec',
            TEST_MUTATION_RECORD    => "$project/records",
            TEST_MUTATION_SPEC_G1   => 'disk.spec',
            TEST_MUTATION_RECORD_G1 => "$project/records"
        }
    );
    is [ $run->@{qw(status stderr)} ], [ 0, q{} ], 'both observers share the interpreter that executed the module';
    my ($file) = glob "$project/records/*.rec";
    like Test::Mutation::Source::read_bytes($file),
      qr/^seen\t\Q$source\E\n.*^begin\t1\n.*^blind\t\Q$source\E\tloaded-at-exit$/ms,
      'the second observer finds the loaded file';
    my $record = Test::Mutation::Record::read_directory("$project/records");
    is [ $record->@{qw(begun ended)} ],    [ 2, 2 ], 'both observers reach their END blocks';
    is $record->{served}{$source}{traced}, 1,        'the second observer finds the compilation traced by the first';
};

subtest 'an installed command without a blib/bin entry receives the changed bytes' => sub {
    my $tree = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    write_file( "$tree/bin/tool",         $original );
    write_file( "$tree/blib/script/tool", $original );
    is Test::Mutation::Workspace::Slot::place( $tree, 'bin/tool', $original, $mutant ),
      [qw(bin/tool blib/script/tool)], 'an absent candidate does not hide a later installed command';
    is Test::Mutation::Source::read_bytes("$tree/blib/script/tool"), $mutant, 'the installed command uses the mutant';
    like dies { Test::Mutation::Workspace::Slot::place( $tree, 'bin/tool', $original, {} ) },
      qr/Str|parameter/i, 'a reference cannot be installed as source bytes';
};

subtest 'a placement writes bytes through a staging handle with a preexisting encoding' => sub {
    my $tree = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    write_file( "$tree/Source.pm", $original );
    my $new = File::Temp->can('new');
    no warnings 'redefine';
    local *File::Temp::new = sub {
        my $temporary = $new->(@_);
        binmode $temporary, ':encoding(UTF-8)' or die "encoding: $!";
        return $temporary;
    };
    my $bytes = "mutant:\x{ff}\r\n";
    Test::Mutation::Workspace::Slot::place( $tree, 'Source.pm', $original, $bytes );
    is Test::Mutation::Source::read_bytes("$tree/Source.pm"), $bytes, 'a staging layer cannot transcode the source';
};

subtest 'a failed placement leaves a typed error and the original bytes' => sub {
    my $tree = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    write_file( "$tree/lib/Present.pm", $original );
    my $absent =
      Raised::error( sub { Test::Mutation::Workspace::Slot::place( $tree, 'lib/Missing.pm', $original, $mutant ) } );
    is $absent->[1], 'file-unreadable', 'an absent target is refused before replacement';
    my $target = 'lib/build/generated/Module.pm';
    write_file( "$tree/$target", $original );
    rename "$tree/lib/build", "$tree/lib/moved" or die "move the build directory: $!";
    my $moved = Raised::error( sub { Test::Mutation::Workspace::Slot::place( $tree, $target, $original, $mutant ) } );
    is $moved->[1], 'file-unwritable', 'placement fails when the target directory can no longer be resolved';
    is Test::Mutation::Source::read_bytes("$tree/lib/moved/generated/Module.pm"), $original,
      'the relocated source keeps its original bytes';
    {
        no warnings 'redefine';
        local *File::Temp::new = sub { die "storage unavailable\n" };
        my $failed = Raised::error(
            sub { Test::Mutation::Workspace::Slot::place( $tree, 'lib/Present.pm', $original, $mutant ) } );
        is $failed->[1], 'file-unwritable', 'a staging-file failure names the operation';
        like $failed->[2], qr/storage unavailable/, 'the storage diagnostic is retained';
    }
    is Test::Mutation::Source::read_bytes("$tree/lib/Present.pm"), $original,
      'an unsuccessful write leaves the original bytes';
};
subtest 'a failing write, mode change or rename preserves the existing entry' => sub {
    my $tree = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    write_file( "$tree/Module.pm", $original );
    my $new = File::Temp->can('new');
    {
        no warnings 'redefine';
        local *File::Temp::new = sub {
            my $handle = $new->(@_);
            close $handle or die "close staging file: $!";
            return $handle;
        };
        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        my $error =
          Raised::error( sub { Test::Mutation::Workspace::Slot::place( $tree, 'Module.pm', $original, $mutant ) } );
        is $error->[1], 'file-unwritable', 'an unwritable staging handle cannot replace the target';
    }
    {
        no warnings 'redefine';
        local *File::Temp::filename = sub { return "$tree/no-such-staging-file" };
        my $error =
          Raised::error( sub { Test::Mutation::Workspace::Slot::place( $tree, 'Module.pm', $original, $mutant ) } );
        is $error->[1], 'file-mode-unsettable', 'the install verifies the permission change before rename';
    }
    is Test::Mutation::Source::read_bytes("$tree/Module.pm"), $original,
      'failed writes and mode changes preserve the original source';
    mkdir "$tree/Changed.pm" or die "mkdir: $!";
    my $error =
      Raised::error( sub { Test::Mutation::Workspace::Slot::place( $tree, 'Changed.pm', $original, $mutant ) } );
    is $error->[1], 'file-unrenamable', 'a directory appearing at the target blocks the rename';
    ok -d "$tree/Changed.pm", 'a different filesystem entry remains intact';
};

subtest 'the shim distinguishes a placed source on disk from a load outside the hook' => sub {
    my $check = <<'PERL';
my @loaded = stat $INC{'Example.pm'};
my @placed = stat 'lib/Example.pm';
exit 2 unless @loaded && @placed && $loaded[0] == $placed[0] && $loaded[1] == $placed[1];
print Example::value();
PERL
    for my $case ( [ 1, 'blind' ], [ 0, 'around' ] ) {
        my ( $placed_on_disk, $record ) = @$case;
        my $project = ShimHarness::project();
        my $target  = "$project/lib/Example.pm";
        write_file( $target,              "package Example;\nsub value { 24 }\nsub unused { die 'unused' }\n1;\n" );
        write_file( "$project/unused.pm", "die 'the hook must not replace this file';\n" );
        write_file( "$project/spec",
            "trace\t0\nplaced\t$placed_on_disk\nobserve\t1\ntarget\t$target\t$project/unused.pm\n" );
        my $result = ShimHarness::run_perl(
            root => $project,
            env  => { TEST_MUTATION_SPEC => "$project/spec", TEST_MUTATION_RECORD => "$project/records" },
            args => [ '-I' . ShimHarness::lib_dir(), '-MTest::Mutation::Shim', '-Ilib', '-MExample', '-e', $check ],
        );
        is [ $result->{status}, $result->{stdout} ], [ 0, '24' ], 'the interpreter reads the source bytes from disk';
        is [ map { [ $_->[0], $_->[1] ] } grep { $_->[0] ne 'end' } ShimHarness::records($project)->@* ],
          [ [ $record, $target ] ], 'the observation identifies whether the file was placed in the copy';
        my $raw = ShimHarness::all_records($project);
        is [ map { $_->[1] } grep { $_->[0] eq 'begin' } @$raw ], [0], 'the interpreter ran without line tracing';
        my $read = Test::Mutation::Record::read_directory("$project/records");
        is [ $read->{served}{$target}, $read->{compiled}{$target}, $read->{bypassed}{$target} ],
          $placed_on_disk ? [ { traced => 0, hits => {} }, 1, undef ] : [ undef, undef, 1 ],
          'the placed file has file coverage and the unplaced file records a bypass';
    }
};

subtest 'original runs record the Perl include directories in both cache modes' => sub {
    for my $case ( [ 0, 'baseline', 1 ], [ 0, 'mutants/aa', 0 ], [ 1, 'baseline', 1 ], [ 1, 'mutants/aa', 0 ] ) {
        my ( $cache, $name, $expected ) = @$case;
        my $project = ShimHarness::project();
        mkdir "$project/mutants" or die "mkdir: $!";
        write_file( "$project/support/LocalDependency.pm", "package LocalDependency; 1;\n" );
        my $config = Test::Mutation::Settings::of_call( { root => $project, cache => $cache } );
        my $run    = { config => $config, project => $project, work => $project };
        my $spec   = Test::Mutation::Runner::_spec( $run, $project, $name, 0, [] );                ## no critic (Subroutines::ProtectPrivateSubs)
        my $child  = ShimHarness::run_perl(
            root => $project,
            env  => { TEST_MUTATION_SPEC => $spec, TEST_MUTATION_RECORD => "$project/records" },
            args =>
              [ '-I' . ShimHarness::lib_dir(), '-Isupport', '-MTest::Mutation::Shim', '-MLocalDependency', '-e', '1' ]
        );
        my $record  = Test::Mutation::Record::read_directory("$project/records");
        my @support = grep { $_ eq "$project/support" } ( $record->{includes} || [] )->@*;
        is [ $child->{status}, scalar @support ], [ 0, $expected ], "include path observed for $name with cache $cache";
    }
};

# A failed job can move to a verified original tree once for the same test.
## no critic (Subroutines::ProtectPrivateSubs Variables::ProtectPrivateVars)
subtest 'a failed test runs again only when the original passes in a different tree' => sub {
    my $config         = Test::Mutation::Settings::of_call( { root => Fixture::copy_of('calc') } );
    my $fixture_mutant = Test::Mutation::Select::resolve( config => $config )->mutants->[0];
    for my $case (
        [ 'baseline unchanged', 0, 0, {}, undef, 'observe' ],
        [ 'test passed',        1, 1, {}, undef, 'observe' ],
        [ 'missing record',     1, 0, {}, undef, 'observe' ],
        [ 'read confirmation',  1, 0, {}, undef, 'confirmed' ],
        [ 'original failed',    1, 0, { unstable => 1 },         undef,   'unstable' ],
        [ 'same state',         1, 0, { same     => 1 },         undef,   'observe' ],
        [ 'same reference',     1, 0, { root     => 'clean' },   'clean', 'observe' ],
        [ 'first reference',    1, 0, { root     => 'clean' },   undef,   'repeat' ],
        [ 'changed reference',  1, 0, { root     => 'ordered' }, 'clean', 'repeat' ],
        [ 'unrestored slot',    1, 0, { root     => 'clean' },   undef,   'stop' ],
      )
    {
        my ( $label, $changed, $passed, $proof, $starting, $decision ) = @$case;
        my $run = { root => 'working', baseline_changed => $changed, controls => {}, stats => { verifications => 0 } };
        my $job = { mutant => $fixture_mutant, duration => 2, starting_tree => $starting, spec => 'old.spec' };
        my $payload = { test => 'test.t', job => $job, confirm_read => $decision eq 'confirmed' };
        my $result  = { passed => $passed, duration => 3 };
        my @steps;
        no warnings 'redefine';
        local *Test::Mutation::Runner::_collect = sub {
            return Test::Mutation::Record::parse( $label eq 'missing record' ? [] : ["begin\t1\n"] );
        };
        local *Test::Mutation::Runner::_verified_reference = sub {
            push @steps, 'original';
            return $proof;
        };
        local *Test::Mutation::Runner::_release = sub {
            push @steps, 'release';
            $job->{restore_error} = 'unreadable' if $decision eq 'stop';
            return;
        };
        local *Test::Mutation::Runner::_next_test = sub {
            push @steps, 'repeat';
            return { root => $job->{starting_tree}, previous_spec => exists $job->{spec} ? 1 : 0 };
        };
        local *Test::Mutation::Runner::_check_load = sub { push @steps, 'observe'; return };
        my $next = Test::Mutation::Runner::_after_test( $run, {}, { payload => $payload }, $result );
        my @expected;
        push @expected, 'original' if keys %$proof;
        push @expected, 'release'  if $decision eq 'stop' || $decision eq 'repeat';
        push @expected, 'repeat'   if $decision eq 'repeat';
        push @expected, 'observe'  if $decision eq 'observe' || $decision eq 'unstable';
        is \@steps,                      \@expected, "$label chooses the required control and next action";
        is $run->{stats}{verifications}, $decision eq 'repeat' ? 1 : 0, "$label counts only a scheduled repeat";
        is $job->{duration},             5,                             "$label includes the elapsed test time";
        is $next, $decision eq 'repeat' ? { root => $proof->{root}, previous_spec => 0 } : undef,
          "$label returns the task for the verified state";
        is $job->{outcome}{anomaly}, { reason => 'unstable-test', detail => 'test.t failed without the mutant' },
          'a failure of the original identifies the responsible test'
          if $decision eq 'unstable';
        is $job->{outcome}{read_check}, 'fail', 'the second reading retains its result' if $decision eq 'confirmed';
    }
};

subtest 'the test command uses the disk specification for a trial or an agreed disk-only test' => sub {
    my $tree = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    write_file( "$tree/t/read.t",  "1;\n" );
    write_file( "$tree/t/other.t", "1;\n" );
    my $workspace = Test::Mutation::Workspace::acquire($tree);
    my $work      = $workspace->directory . '/work';
    my $spec      = "$work/source.spec";
    write_file( $spec, "trace\t1\n" );
    my $run = {
        root       => $tree,
        work       => $work,
        workspace  => $workspace,
        perl       => $^X,
        generation => 2,
        config     => Test::Mutation::Settings::of_call( { root => $tree } ),
        targets    => [],
        disk_test  => { 't/read.t' => 1 }
    };

    for my $case ( [ 0, 't/other.t', 0 ], [ 1, 't/other.t', 1 ], [ 0, 't/read.t', 1 ], [ 1, 't/read.t', 1 ] ) {
        my ( $trial, $test, $on_disk ) = @$case;
        $run->{try_disk} = $trial;
        my $task = Test::Mutation::Runner::_test_task(
            $run,
            root            => $tree,
            test            => $test,
            spec            => $spec,
            timeout         => 10,
            stop_on_failure => 0,
            payload         => {}
        );
        my $selected = $task->{env}{TEST_MUTATION_SPEC_G2};
        is $selected, $on_disk ? "$spec.disk" : $spec, "$test receives its selected source in trial $trial";
        is Test::Mutation::Source::read_bytes($selected),
          "trace\t1\n" . ( $on_disk ? "observe\t1\n" : q{} ), 'only the disk observation is appended';
    }
    ok $workspace->release(0), 'the test commands release their private files';
};

subtest 'a failed record cleanup leaves the observation usable and removes the temporary files' => sub {
    my $project = ShimHarness::project();
    my $records = "$project/records";
    my $tmp     = "$project/tmp";
    write_file( "$records/first.rec", "begin\t1\nend\t1\n" );
    write_file( "$tmp/output",        "temporary\n" );
    my $expected = Test::Mutation::Record::read_directory($records);
    my $remove   = Test::Mutation::Tree->can('remove');
    no warnings 'redefine';
    local *Test::Mutation::Tree::remove = sub ($path) {
        die "record directory busy\n" if $path eq $records;
        return $remove->($path);
    };
    my $record = Test::Mutation::Runner::_collect( { payload => { record => $records, tmp => $tmp, targets => [] } } );
    is $record, $expected, 'the caller receives the observation despite the cleanup error';
    ok -d $records && !-e $tmp, 'cleanup continues with the other directory';
};

subtest 'finishing a mutant removes its source and both specifications before reporting the verdict' => sub {
    my $directory = File::Temp::tempdir( CLEANUP => 1 );
    my ( $file, $spec ) = ( "$directory/mutant.pm", "$directory/test.spec" );
    my @owned = ( $file, $spec, "$spec.disk" );
    write_file( $_,                           "private\n" ) for @owned;
    write_file( "$directory/other.spec.disk", "another job\n" );
    my $config = Test::Mutation::Settings::of_call( { root => Fixture::copy_of('calc'), equivalence => 0 } );
    my $job    = {
        file     => $file,
        spec     => $spec,
        duration => 0,
        tests    => [],
        mutant   => Test::Mutation::Select::resolve( config => $config )->mutants->[0],
        verdict  => Test::Mutation::Verdict::start(),
    };
    my @events;
    my $run = {
        jobs     => 1,
        stats    => {},
        config   => $config,
        listener => sub ( $event, $entry ) {
            push @events, [ $event, $entry->{status}, grep { -e } @owned ];
        }
    };
    my @jobs = ($job);
    Test::Mutation::Runner::_execute_jobs( $run, {}, sub { return shift @jobs }, {}, undef );
    is \@events, [ [ 'mutant', 'NoCoverage' ] ], 'the verdict arrives after all three private files have gone';
    is Test::Mutation::Source::read_bytes("$directory/other.spec.disk"), "another job\n",
      'a concurrent job keeps its own disk specification';
};

subtest 'the original run records whether its tests changed the job copy' => sub {
    for my $changes ( 0, 1 ) {
        my $tree = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
        my $run  = {
            root    => $tree,
            project => $tree,
            copies  => 'slots',
            targets => [],
            config  => Test::Mutation::Settings::of_call( { root => $tree } )
        };
        my $baseline = { tests => {} };
        no warnings 'redefine';
        local *Test::Mutation::Runner::_baseline = sub {
            write_file( "$tree/created-by-test", 'ready' ) if $changes;
            return $baseline;
        };
        is Test::Mutation::Runner::_observed_baseline( $run, [] ), $baseline, 'the original observations are retained';
        is $run->{baseline_changed}, $changes, 'only a filesystem change requires checking the original again';
    }
};
## use critic

subtest 'reproducing a mutant preserves inherited Perl options and library paths' => sub {
    my $project       = Fixture::copy_of('calc');
    my $library_dir   = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my $config        = Test::Mutation::Settings::of_call( { root => $project, in_place => 1 } );
    my $selection     = Test::Mutation::Select::resolve( config => $config );
    my ($subtraction) = grep { $_->description eq 'replaced + with -' } $selection->mutants->@*;
    my $program       = write_file( "$library_dir/observe.pl", <<'PERL' );
use Calc;
open my $out, '>', $ARGV[0] or die "write: $!";
print {$out} join "\n", Calc::add(6, 4), $ENV{PERL5OPT} // q{}, $ENV{PERL5LIB} // q{};
close $out or die "close: $!";
PERL
    for my $case ( [ 'unset', undef, undef ], [ 'empty', q{}, q{} ], [ 'configured', '-Mstrict', $library_dir ] ) {
        my ( $label, $options, $libraries ) = @$case;
        local @ENV{qw(PERL5OPT PERL5LIB)} = ( $options, $libraries );
        delete @ENV{qw(PERL5OPT PERL5LIB)} unless defined $options;
        my $output = "$library_dir/$label.txt";
        my $status = Test::Mutation::Runner::run_command( $config, $selection->sources->{ $subtraction->path },
            $subtraction, [ $^X, '-Ilib', $program, $output ] );
        is $status, 0, "$label options allow the command to run";
        my ( $value, $flags, $paths ) = split /\n/, Test::Mutation::Source::read_bytes($output), -1;
        is $value, 2, 'the child loads the specified subtraction mutant';
        unlike $flags, qr/\A\s|\s\z/,     'absent options introduce no empty switch';
        unlike $paths, qr/(?:\A|:):|:\z/, 'absent library paths introduce no implicit working directory';

        if ( length( $options // q{} ) ) {
            ok scalar( grep { $_ eq $options } split /\s+/, $flags ), 'the child inherits the requested switch';
            ok scalar( grep { $_ eq $libraries } split /:/, $paths ), 'the child inherits the requested library';
        }
    }
};

done_testing;
