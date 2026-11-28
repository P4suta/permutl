use v5.36;
use Test2::V0;
use File::Temp ();
use lib 't/e2e/lib', 't/lib', 't/shim/lib';
use Encode ();
use POSIX  ();
use Raised;
use ShimHarness ();
use Fixture     qw(write_file);
use Test::Mutation::Mutant;
use Test::Mutation::Source;
use Test::Mutation::Record;
use Test::Mutation::Runner;
use Test::Mutation::Settings;
use Test::Mutation::Workspace;
use Test::Mutation::Witness;
use Test::Mutation::Syntax::PPI;

my $text   = "package Loaded;\r\nsub value { return 2 + 1 }\r\n__PACKAGE__ eq 'Loaded';\r\n__DATA__\r\npayload\r\n";
my $source = Test::Mutation::Source->from_bytes( path => 'lib/Loaded.pm', bytes => "\xEF\xBB\xBF$text" );
my ( $first, $offset ) = Test::Mutation::Syntax::PPI::witness_offsets($source)->@*;
is substr( $source->text, $first,  7 ),  'package',     'the first statement follows the byte-order mark';
is substr( $source->text, $offset, 11 ), '__PACKAGE__', 'the witness precedes the final code before the data section';
my $marked = Test::Mutation::Witness::insert( $source->text, $offset, 3, 0, '/tmp/[odd] \x27', 12 );
is scalar( $marked =~ tr/\n// ), scalar( $source->text =~ tr/\n// ), 'the statement adds no line';
like $marked, qr/\}__PACKAGE__ eq 'Loaded';\r\n__DATA__\r\npayload/, 'the return expression and data remain intact';
my $empty = Test::Mutation::Source->from_bytes( path => 'empty.pl', bytes => "# one comment\n" );
is Test::Mutation::Syntax::PPI::witness_offsets($empty), undef,
  'a file with no executable statement has no insertion point';

subtest 'witness coordinates follow executable statements and the embedded Perl entry point' => sub {
    my $input = "# header\r\n1;\r\n#!/usr/bin/perl\r\n# comment\r\n\r\npackage Embedded;\r\n1;\r\n__DATA__\r\n9;\r\n";
    my $unit  = Test::Mutation::Source->from_bytes( path => 'bin/embedded', bytes => $input );
    is Test::Mutation::Syntax::PPI::witness_offsets($unit),
      [ index( $input, '1;' ), rindex( $input, '1;' ), index( $input, 'package Embedded;' ) ],
      'the first executable token after the interpreter line is a separate insertion point';
    my $script = "#!/usr/bin/perl\r\n# comment\r\npackage Main;\r\n1;\r\n";
    my $main   = Test::Mutation::Source->from_bytes( path => 'bin/main', bytes => $script );
    is Test::Mutation::Syntax::PPI::witness_offsets($main),
      [ index( $script, 'package Main;' ), rindex( $script, '1;' ) ], 'a normal shebang leaves two positions';
    my $end = "1;\n#!/usr/bin/perl\n# no further code\n";
    is Test::Mutation::Syntax::PPI::witness_offsets(
        Test::Mutation::Source->from_bytes( path => 'bin/end', bytes => $end ) ),
      [ 0, 0 ], 'a shebang after the last executable statement adds no entry';

    for my $case ( [ "# header\n#!perl\n1;\n", '1;', '1;' ], [ "1;\nsub x {\n#!perl\n2;\n}\n", '1;', 'sub x' ], ) {
        my ( $code, $start, $last ) = @$case;
        my $program = Test::Mutation::Source->from_bytes( path => 'bin/wrapped', bytes => $code );
        is Test::Mutation::Syntax::PPI::witness_offsets($program), [ index( $code, $start ), index( $code, $last ) ],
          'extract mode adds no location already covered or outside the top-level statement boundaries';
    }
    like dies { Test::Mutation::Syntax::PPI::witness_offsets( {} ) }, qr/did not pass type constraint/,
      'the parser accepts a source object';
    {
        no warnings 'redefine';
        local *PPI::Document::new = sub { return };
        is Test::Mutation::Syntax::PPI::witness_offsets($main), undef, 'an unreadable syntax tree supplies no witness';
    }
};

subtest 'witnesses encode Unicode paths and preserve byte paths without transcoding them' => sub {
    for my $path ( "work/\x{3042}", "work/\xff" ) {
        my $bytes         = utf8::is_utf8($path) ? Encode::encode_utf8($path) : $path;
        my $hex           = unpack 'H*', $bytes;
        my $marked_source = Test::Mutation::Witness::insert( '1;', 0, 2, 7, $path, 9 );
        like $marked_source, qr/\Q$hex\E/, 'the stand-alone witness embeds the exact pathname bytes';
        my $traced = Test::Mutation::Witness::trace(
            text       => '1;',
            offset     => 0,
            generation => 2,
            index      => 7,
            target     => $path,
            work       => $path,
            descriptor => 9,
            line       => 3
        );
        like $traced, qr/\Q$hex\E/, 'the tracer can refer to the same pathname';
    }
    like dies { Test::Mutation::Witness::insert( '1;', 0, 0, 0, '/tmp', 3 ) }, qr/PositiveInt|parameter/,
      'the witness needs a positive generation';
    like dies { Test::Mutation::Witness::trace( text => '1;' ) }, qr/parameter|argument/i,
      'the tracer requires the recording directory and coordinates';
};

subtest 'a recording descriptor stays above standard streams and identifies the selected directory' => sub {
    my $work = File::Temp::tempdir( CLEANUP => 1 );
    my $slot = Test::Mutation::Witness::reserve($work);
    my $fd   = fileno $slot;
    cmp_ok $fd, '>', 2, 'the reserved number leaves the standard streams available';
    mkdir "$work/records" or die "mkdir: $!";
    is Test::Mutation::Witness::inherit( "$work/records", $fd ), $fd,
      'the inherited binding returns the reserved number';
    is [ ( stat $slot )[ 0, 1 ] ], [ ( stat "$work/records" )[ 0, 1 ] ],
      'the descriptor identifies the directory by device and inode';
    my $absent = Raised::error( sub { Test::Mutation::Witness::reserve("$work/absent") } );
    is $absent->[1], 'file-unreadable', 'reservation reports an absent identity file';
    my $missing = Raised::error( sub { Test::Mutation::Witness::inherit( "$work/absent", $fd ) } );
    is $missing->[1], 'directory-unopenable', 'a missing record directory has a typed failure';
    {
        no warnings 'redefine';
        local *POSIX::dup2 = sub { return };
        my $error = Raised::error( sub { Test::Mutation::Witness::inherit( "$work/records", $fd ) } );
        is $error->[1], 'test-streams-unset', 'failure to bind the selected stream cannot start the child';
    }
    like dies { Test::Mutation::Witness::reserve( [] ) }, qr/type constraint "Str" [(]in \$_\[0\][)]/,
      'a descriptor reservation checks its pathname';
    like dies { Test::Mutation::Witness::inherit( "$work/records", 0 ) }, qr/parameter|PositiveInt/,
      'inheritance requires a positive descriptor';
    for my $stream ( 0 .. 2 ) {
        my $child = fork;
        die "fork: $!" unless defined $child;
        if ( !$child ) {
            POSIX::close($stream);
            my $reserved = Test::Mutation::Witness::reserve($work);
            POSIX::_exit( fileno($reserved) > 2 ? 0 : 1 );
        }
        waitpid $child, 0;
        is $?, 0, "reservation moves away from unused standard descriptor $stream";
    }
};

subtest 'a full descriptor table preserves the reason the witness cannot reserve a private handle' => sub {
    my $dir   = File::Temp::tempdir( CLEANUP => 1 );
    my $probe = write_file( "$dir/reserve.pl", <<'PERL' );
use strict;
use warnings;
use Errno qw(EMFILE);
use POSIX ();
use Test::Mutation::Witness ();
eval { Test::Mutation::Witness::reserve('absent-identity') };
my @open;
while ( open my $handle, '<', $0 ) { push @open, $handle }
die "file table still available\n" unless $! == EMFILE;
my $reason = "$!";
POSIX::close(0) == 0 or die "close stdin: $!";
my @warnings;
local $SIG{__WARN__} = sub { push @warnings, @_ };
my $caught = eval { Test::Mutation::Witness::reserve($0); 1 };
my $error = $@;
pop @open;
die "reservation unexpectedly succeeded\n" if $caught;
die "unexpected diagnostic: $error" unless ref($error) && $error->isa('Test::Mutation::Error')
    && $error->id eq 'file-unreadable' && index($error->message, $reason) >= 0;
die @warnings if @warnings;
PERL
    my $status = system {'bash'} 'bash', '-c', 'ulimit -n 48 && exec "$@"', 'reserve', $^X, '-Ilib', $probe;
    is $status, 0, 'exhaustion reports the duplication error without reopening a standard stream';
};

sub observation_project () {
    my $work    = File::Temp::tempdir( CLEANUP => 1 );
    my $project = "$work/project";
    my $root    = "$work/baseline/project";
    my @targets = qw(lib/A.pm lib/B.pm lib/C.pm);
    my %sources;
    for my $path (@targets) {
        my ($name) = $path =~ m{/([A-Z])[.]pm};
        my $bytes = "package $name;\nsub value { 21 }\n1;\n";
        write_file( "$project/$path", $bytes );
        write_file( "$root/$path",    $bytes );
        $sources{$path} = Test::Mutation::Source->from_bytes( path => $path, bytes => $bytes );
    }
    return {
        work       => "$work/work",
        project    => $project,
        root       => $root,
        name       => 'project',
        generation => 1,
        jobs       => 2,
        config     => Test::Mutation::Settings::of_call( { root => $project } ),
        workspace  => Test::Mutation::Workspace::acquire($project),
        sources    => \%sources,
        targets    => \@targets,
    };
}

sub replacement ( $source, $start, $end, $change ) {
    return Test::Mutation::Mutant->new(
        id          => '123456789abc',
        path        => $source->path,
        mutator     => 'statement-removal',
        start       => $start,
        end         => $end,
        original    => substr( $source->text, $start, $end - $start ),
        replacement => $change,
        description => 'change the selected source span',
        from        => $source->position_of($start),
        to          => $source->position_of($end),
        scope       => [ 1, 3 ],
    );
}

## no critic (Subroutines::ProtectPrivateSubs Variables::ProtectPrivateVars)
subtest 'a standalone line trace preserves modules loaded before and after its witnesses' => sub {
    my $run = observation_project();
    Test::Mutation::Runner::_prepare_work($run);
    my $generation = $run->{generation};
    my $package    = "Test::Mutation::Shim::G$generation";
    my $module     = "Test/Mutation/Shim/G$generation.pm";
    my $perl       = $ENV{TEST_MUTATION_SECOND_PERL} || $^X;
    for my $order (qw(before after)) {
        my $root     = ShimHarness::project();
        my $handlers = <<'PERL';
use strict;
use warnings;
sub trace_source { die "project tracer called\n" }
sub seen { die "project witness called\n" }
sub value { return 42 }
1;
PERL
        write_file( "$root/lib/$module", "package $package;\n$handlers" );
        my $other = "Test::Mutation::Shim::TraceG$generation";
        write_file( "$root/lib/Test/Mutation/Shim/TraceG$generation.pm", "package $other;\n$handlers" );
        my $load = "BEGIN { require $package }\n";
        my $body = "sub measured {\n    return 2;\n}\n";
        my $path = "$root/target.pl";
        my $instrumented =
          Test::Mutation::Witness::insert( $body, length($body), $generation, 0, "$run->{work}/records", 9 );

        for ( 1 .. 2 ) {
            $instrumented = Test::Mutation::Witness::trace(
                text       => $instrumented,
                offset     => 0,
                line       => 1,
                generation => $generation,
                index      => 0,
                target     => $path,
                work       => $run->{work},
                descriptor => 9
            );
        }
        $instrumented = $order eq 'before' ? $load . $instrumented : $instrumented . $load;
        $instrumented = "BEGIN { require $other }\n" . $instrumented;
        write_file( $path, $instrumented . 'print measured() + ' . $package . "::value(), qq{\\n};\n" . <<'PERL' );
die "tracer in module list\n" if grep { defined && index($_, $ARGV[0]) == 0 } values %INC;
die "missing project module\n" unless $INC{$ARGV[1]} eq $ARGV[2];
PERL
        my $result = ShimHarness::run_command(
            root    => $root,
            command => [ $perl, "-I$root/lib", $path, "$run->{work}/", $module, "$root/lib/$module" ],
            env     => { "TEST_MUTATION_RECORD_G$generation" => "$root/records" },
        );
        is $result, { status => 0, signal => 0, stdout => "44\n", stderr => q{} },
          "the target loads its own module $order the two witnesses";
        my $records = ShimHarness::all_records($root);
        is [ grep { $_->[0] eq 'begin' } @$records ], [ [ 'begin', 1 ] ], 'the second witness retains the first tracer';
        ok scalar( grep { $_->[0] eq 'hit' && $_->[1] eq $path && $_->[2] == 2 } @$records ),
          'executing the function records its original line';
    }
    ok $run->{workspace}->release(0), 'the tracing workspace is released';
};

subtest 'a standalone compilation witness records a blind load alongside a project shim' => sub {
    my $root = ShimHarness::project();
    write_file( "$root/lib/Test/Mutation/Shim/G3.pm", <<'PERL' );
package Test::Mutation::Shim::G3;
sub seen { die "project witness called\n" }
1;
PERL
    my $path    = "$root/run.pl";
    my $program = "use Test::Mutation::Shim::G3 ();\n1;\n";
    write_file( $path, Test::Mutation::Witness::insert( $program, length($program), 3, 4, "$root/records", 9 ) );
    my $result = ShimHarness::run_command(
        root    => $root,
        command => [ $ENV{TEST_MUTATION_SECOND_PERL} || $^X, "-I$root/lib", $path ],
        env     => { TEST_MUTATION_RECORD_G3 => "$root/records" },
    );
    is $result, { status => 0, signal => 0, stdout => q{}, stderr => q{} }, 'the project witness is not invoked';
    is ShimHarness::all_records($root), [ [ 'blind', 4 ] ], 'the file-level record identifies the compiled target';
};

subtest 'placing a replacement preserves the witness position around a changed span' => sub {
    my $run = observation_project();
    Test::Mutation::Runner::_prepare_work($run);
    Test::Mutation::Runner::_prepare_witnesses($run);
    my $root     = $run->{copies} = $run->{root};
    my $path     = 'lib/A.pm';
    my $module   = $run->{sources}{$path};
    my $original = $module->text;
    my $body     = "sub value { 21 }\n";
    my $head     = "package A;\n";
    my $end      = length( $head . $body );

    for my $case (
        [ '21',         '135',           $head . "sub value { 135 }\n", "1;\n" ],
        [ $body,        "sub x { 8 }\n", $head . "sub x { 8 }\n",       "1;\n" ],
        [ $body . '1;', '7;',            $head,                         "7;\n" ],
        [ '1;',         '13;',           $head . $body,                 "13;\n" ],
        [ ";\n",        "; # last\n",    $head . $body,                 "1; # last\n" ],
      )
    {
        my ( $old, $new, $prefix, $suffix ) = @$case;
        my $start  = $old eq ";\n" ? rindex( $original, $old ) : index( $original, $old );
        my $mutant = replacement( $module, $start, $start + length($old), $new );
        for my $raw ( 0, 1 ) {
            write_file( "$root/$path", $original );
            local $run->{trace_eval} = $raw;
            my ( $file, $spec ) = Test::Mutation::Runner::_write_mutant( $run, $module, $mutant, $root, $raw );
            is Test::Mutation::Source::read_bytes($file), $prefix . $suffix,
              'the compilation input contains the plain replacement';
            my $bytes = Test::Mutation::Source::read_bytes("$root/$path");
            if ($raw) {
                is $bytes, $prefix . $suffix, 'a source-reading test receives the exact replacement';
            }
            else {
                like $bytes, qr/\A\Q$prefix\EUNITCHECK\{.*\}\Q$suffix\E\z/s,
                  'the copied module retains the original statement boundary or the start of the covering replacement';
            }
            like Test::Mutation::Source::read_bytes($spec), qr/^placed\t1$/m,
              'the process knows the replacement is on disk';
            is( ( Test::Mutation::Source::read_bytes($spec) =~ /^trace_eval\t1$/m ? 1 : 0 ),
                $raw, 'only an eval diagnostic requests eval filenames in the test process' );
        }
    }
    is $run->{witness}{$path}{offset}, $end, 'placing the replacements preserves the original witness coordinates';
    ok $run->{workspace}->release(0), 'the source and the task descriptor are released';
};

subtest 'successive tests select the prepared project and plain or witnessed source independently' => sub {
    my $run = observation_project();
    Test::Mutation::Runner::_prepare_work($run);
    Test::Mutation::Runner::_prepare_witnesses($run);
    $run->{perl}   = $^X;
    $run->{copies} = "$run->{work}/slots";
    my @tests = qw(first.t same.t reads.t reads-again.t ordered.t);
    write_file( "$run->{root}/$_", "#!perl\n1;\n" ) for @tests;
    my $ordered = Test::Mutation::Runner::_control_copy( $run, $run->{root} );
    write_file( "$ordered/prepared", "setup completed\n" );
    $run->{controls}{'ordered.t'}     = { root => $ordered };
    $run->{sensitive}{'same.t'}       = {};
    $run->{sensitive}{$_}{'lib/A.pm'} = 1 for qw(reads.t reads-again.t);
    my $module     = $run->{sources}{'lib/A.pm'};
    my $start      = index( $module->text, '21' );
    my $mutant     = replacement( $module, $start, $start + 2, '42' );
    my $raw_source = $module->text =~ s/21/42/r;
    my $baseline   = { tests  => { map { $_ => { duration => 1 } } @tests } };
    my $job        = { mutant => $mutant, tests => \@tests, index => 0 };
    my $task       = sub ($index) {
        $job->{index} = $index;
        return Test::Mutation::Runner::_next_test( $run, $job, $baseline );
    };
    my $initial_copy = $task->(0)->{cwd};
    like Test::Mutation::Source::read_bytes("$initial_copy/lib/A.pm"), qr/UNITCHECK/, 'an ordinary test gets a witness';
    write_file( "$initial_copy/from-first", "earlier test\n" );
    is $task->(1)->{cwd}, $initial_copy, 'the next ordinary test keeps its prepared copy';
    ok -f "$initial_copy/from-first", 'a compatible task keeps the current mutant placement';
    my $plain = $task->(2)->{cwd};
    is Test::Mutation::Source::read_bytes("$plain/lib/A.pm"), $raw_source, 'a byte comparison gets the unmarked mutant';
    ok !-e "$plain/from-first", 'a change of source representation starts from the reference state';
    write_file( "$plain/from-reader", "plain run\n" );
    is $task->(3)->{cwd}, $plain, 'two byte comparisons share the same placement';
    ok -f "$plain/from-reader", 'the second reader keeps the current source';
    my $prepared = $task->(4)->{cwd};
    like Test::Mutation::Source::read_bytes("$prepared/lib/A.pm"), qr/UNITCHECK/,
      'a prepared ordinary test gets a witness';
    is Test::Mutation::Source::read_bytes("$prepared/prepared"), "setup completed\n", 'the ordered setup is present';
    ok !-e "$prepared/from-reader", 'changes from another reference stay out of the prepared copy';
    Test::Mutation::Runner::_release( $run, $job );
    ok $run->{workspace}->release(0), 'the job and its private files are released';
};

subtest 'the baseline reinstates source bytes after observing the unmodified project' => sub {
    my $run = observation_project();
    Test::Mutation::Runner::_prepare_witnesses($run);
    $run->{copies} = $run->{root};
    my $path  = "$run->{root}/lib/B.pm";
    my $bytes = Test::Mutation::Source::read_bytes($path);
    no warnings 'redefine';
    local *Test::Mutation::Runner::_baseline = sub {
        like Test::Mutation::Source::read_bytes($path), qr/UNITCHECK/, 'the unmodified test observes a loaded target';
        write_file( "$run->{root}/created-by-test", "baseline output\n" );
        return { failures => [] };
    };
    is Test::Mutation::Runner::_observed_baseline( $run, [] ), { failures => [] },
      'the original test result survives restoration';
    is Test::Mutation::Source::read_bytes($path), $bytes, 'the target returns to its original content';
    is $run->{baseline_changed}, 1, 'a file created by the test is recorded separately from the witness';
    ok $run->{workspace}->release(0), 'the observed workspace is released';
};

subtest 'only an applicable original test observation starts an extra diagnostic phase' => sub {
    my $run = observation_project();
    Test::Mutation::Runner::_prepare_witnesses($run);
    $run->{jobs} = 1;
    my $handle = $run->{task_descriptor};
    for my $case (
        [ 0, 'line', 1, [] ],
        [ 0, 'line', 0, [] ],
        [ 1, 'line', 0, ['raw'] ],
        [ 1, 'file', 1, [] ],
        [ 1, 'line', 1, ['trace'] ],
      )
    {
        my ( $witnessed, $coverage, $passed, $phases ) = @$case;
        my @observed;
        local $run->{config} = Test::Mutation::Settings::of_call( { root => $run->{project}, coverage => $coverage } );
        local $run->{task_descriptor} = $witnessed ? $handle : undef;
        no warnings 'redefine';
        local *Test::Mutation::Runner::_raw_baseline = sub { push @observed, 'raw';   return };
        local *Test::Mutation::Runner::_trace_blind  = sub { push @observed, 'trace'; return };
        local *Test::Mutation::Runner::_unmodified   = sub {
            return {
                'observed.t' => {
                    result => { passed => $passed, early => 0, duration => 1, output => q{}, errors => q{} },
                    record => Test::Mutation::Record::parse( ["begin\t0\nend\t1\n"] ),
                }
            };
        };
        my $result = Test::Mutation::Runner::_baseline( $run, ['observed.t'], [] );
        is \@observed, $phases, 'the measured coverage mode, completed baseline, and witness determine the extra work';
        is scalar $result->{failures}->@*, $passed ? 0 : 1, 'the original verdict is preserved';
    }
    ok $run->{workspace}->release(0), 'the diagnostic workspace is released';
};

subtest 'a bypass warning for one copied target preserves coverage of the following target' => sub {
    my $run  = observation_project();
    my $root = $run->{root};
    $run->{sensitive}{'two.t'}{'lib/C.pm'} = 1;
    my $record = Test::Mutation::Record::parse(
        [
                "begin\t1\naround\t$root/lib/A.pm\nseen\t$root/lib/B.pm\nhit\t$root/lib/B.pm\t2\n"
              . "seen\t$root/lib/C.pm\nhit\t$root/lib/C.pm\t3\n"
        ]
    );
    my $outcome = { 'two.t' => { result => { passed => 1, early => 0, duration => 1 }, record => $record } };
    my ($tests) =
      Test::Mutation::Runner::_baseline_records( $run, ['two.t'], [qw(lib/A.pm lib/B.pm lib/C.pm)], $outcome );
    is $tests->{'two.t'}{files},
      { 'lib/B.pm' => { traced => 1, hits => { 2 => 1 } }, 'lib/C.pm' => { traced => 0, hits => {} } },
      'the bypass preserves the traced lines of B and the file-level coverage of the byte-sensitive C';
    is $tests->{'two.t'}{anomalies}, {}, 'the copy reports the bypass as a warning';
    ok $run->{workspace}->release(0), 'the private workspace is released';
};

subtest 'a witness changes only matching bytes and leaves the other sources available' => sub {
    my $run  = observation_project();
    my $root = $run->{root};
    Test::Mutation::Runner::_prepare_witnesses($run);
    unlink "$root/lib/A.pm" or die "unlink: $!";
    write_file( "$root/lib/B.pm", 'created during setup' );
    Test::Mutation::Runner::_mark_originals( $run, $root, 1 );
    ok !-e "$root/lib/A.pm", 'a missing target is not recreated';
    is Test::Mutation::Source::read_bytes("$root/lib/B.pm"), 'created during setup',
      'a changed target retains its new content';
    like Test::Mutation::Source::read_bytes("$root/lib/C.pm"), qr/UNITCHECK/,
      'the remaining matching source receives its witness';
    Test::Mutation::Runner::_mark_originals( $run, $root, 0 );
    is Test::Mutation::Source::read_bytes("$root/lib/C.pm"), $run->{sources}{'lib/C.pm'}->text,
      'removing the witness restores the original file bytes';
    ok $run->{workspace}->release(0), 'the observation directory is released';
};

subtest 'a test that reads the source runs without witnesses only for the sources it checks' => sub {
    my $run = observation_project();
    Test::Mutation::Runner::_prepare_witnesses($run);
    Test::Mutation::Runner::_mark_originals( $run, $run->{root}, 1 );
    my @tests   = qw(always.t reads.t unrelated.t limit.t);
    my %outcome = map { $_ => { result => { passed => 0 }, origin => 'first' } } @tests;
    $outcome{'limit.t'}{result}{timed_out} = 1;
    my ( @trials, @names, @tested );
    no warnings 'redefine';
    local *Test::Mutation::Runner::_unmodified = sub ( $context, $name, $trace, $jobs, $tests, $purpose ) {
        my $root = $context->{root};
        my ($test) = @$tests;
        push @names,  $name;
        push @trials, $root;
        push @tested, $test;
        is [ $trace, $jobs, $purpose, $context->{try_disk}, $context->{first} ], [ 0, 1, 'verifications', 1, {} ],
          'the raw control runs alone on disk with fresh interpreter arguments';
        my $has_witness = Test::Mutation::Source::read_bytes("$root/lib/B.pm") =~ /UNITCHECK/;
        my $limited     = $test eq 'unrelated.t' && $has_witness;
        my $pass        = $test ne 'always.t'    && !( $test eq 'reads.t' && $has_witness ) && !$limited;
        return { $test => { result => { passed => $pass ? 1 : 0, timed_out => $limited ? 1 : 0 }, origin => 'raw' } };
    };
    Test::Mutation::Runner::_raw_baseline( $run, \@tests, \%outcome );
    is $run->{disk_test}, { 'reads.t' => 1 },
      'only a reproducible observation of changed source bytes selects disk mode';
    is $run->{sensitive}{'reads.t'}, { 'lib/B.pm' => 1 }, 'the observation names the one inspected file';
    is [ map { $outcome{$_}{origin} } @tests ], [qw(first raw first first)], 'other original results remain available';
    is \@tested, [ 'always.t', ('reads.t') x 4, ('unrelated.t') x 4 ],
      'an initially incomplete test starts no raw control';
    is \@names, [ map { "source-check-$_" } 1 .. @trials ],
      'successive controls write separate positive record numbers';
    is [ grep { -d $_ } @trials ], [], 'every executed control copy is discarded';
    ok !-d "$run->{work}/controls/1/project", 'the shared clean reference is discarded after the last control';
    ok $run->{workspace}->release(0),         'the observation directory is released';
};

subtest 'an in-place probe attributes only previously unobserved loads from passing control tests' => sub {
    my $run     = observation_project();
    my $project = $run->{project};
    $run->{guard} = { backup => $run->{root} };
    $run->{root}  = $project;
    my @tests   = qw(a.t b.t c.t d.t);
    my %outcome = map { $_ => { record => Test::Mutation::Record::parse( ["begin\t1\n"] ) } } @tests;
    $outcome{'a.t'}{record}{served}{"$project/lib/A.pm"}  = { traced => 0, hits => {} };
    $outcome{'a.t'}{record}{outside}{"$project/lib/C.pm"} = 1;
    $outcome{'c.t'}{record}{bypassed}{"$project/$_"}      = 1 for $run->{targets}->@*;
    my ( @tested, $trial );
    no warnings 'redefine';
    local *Test::Mutation::Runner::_unmodified = sub ( $context, $name, $trace, $jobs, $tests, $purpose ) {
        @tested = @$tests;
        $trial  = $context->{root};
        is [ $name, $trace, $jobs, $purpose ], [ 'in-place-loads', 0, 1, 'verifications' ],
          'the copy checks loads in isolation';
        for my $path ( $run->{targets}->@* ) {
            like Test::Mutation::Source::read_bytes("$trial/$path"), qr/UNITCHECK/,
              "the diagnostic copy records compilation of $path";
        }
        my %observed;
        for my $test (@$tests) {
            my @paths    = $test eq 'd.t' ? ('lib/A.pm') : $run->{targets}->@*;
            my %compiled = map { ( "$trial/$_", 1 ) } @paths;
            $observed{$test} = { result => { passed => $test ne 'b.t' }, record => { compiled => \%compiled } };
        }
        return \%observed;
    };
    Test::Mutation::Runner::_observe_in_place_loads( $run, \@tests, $run->{targets}, \%outcome );
    is \@tested, [qw(a.t b.t d.t)], 'a fully accounted-for test needs no diagnostic execution';
    is $outcome{'a.t'}{record}{bypassed}, { "$project/lib/B.pm" => 1 },
      'a served or external target keeps its existing evidence';
    is $outcome{'b.t'}{record}{bypassed}, {}, 'a failing control establishes no load';
    is $outcome{'d.t'}{record}{bypassed}, { "$project/lib/A.pm" => 1 },
      'only the source compiled by the test is attributed';
    ok !-d $trial, 'the diagnostic copy is removed after its records are read';
    is $run->{root}, $project, 'the in-place run resumes in the project';
    ok $run->{workspace}->release(0), 'the private workspace is released';
};
subtest 'a diagnostic trace refines a blind load only after the same original test passes' => sub {
    my $run  = observation_project();
    my $root = $run->{root};
    Test::Mutation::Runner::_prepare_witnesses($run);
    $run->{sensitive}{'sensitive.t'}{'lib/A.pm'} = 1;
    my %records = (
        'a-fails.t'     => "blind\t$root/lib/A.pm",
        'b-passes.t'    => "blind\t$root/lib/A.pm\nblind\t$root/lib/B.pm\nseen\t$root/lib/C.pm",
        'b-reverse.t'   => "blind\t$root/lib/A.pm\nblind\t$root/lib/B.pm",
        'c-blind.t'     => "blind\t$root/lib/B.pm",
        'd-absent.t'    => "blind\t$root/lib/A.pm",
        'e-sensitive.t' => "seen\t$root/lib/C.pm",
        'sensitive.t'   => "blind\t$root/lib/A.pm",
    );
    my %outcome =
      map { ( $_, { record => Test::Mutation::Record::parse( ["begin\t1\n$records{$_}\n"] ) } ) } keys %records;
    my ( @tested, $probe );
    no warnings 'redefine';
    local *Test::Mutation::Runner::_unmodified = sub ( $context, $name, $trace, $jobs, $tests, $purpose ) {
        @tested = @$tests;
        $probe  = $context->{root};
        is [ $name, $trace, $jobs, $purpose, $context->{trace_eval} ], [ 'trace-lines', 1, 2, 'verifications', 1 ],
          'the diagnostic copy traces code evaluated as text';
        like Test::Mutation::Source::read_bytes("$probe/lib/A.pm"), qr/trace_source/,
          'the first blind target receives a tracer';
        like Test::Mutation::Source::read_bytes("$probe/lib/B.pm"), qr/trace_source/,
          'the second blind target receives its tracer';
        unlike Test::Mutation::Source::read_bytes("$probe/lib/C.pm"), qr/trace_source/,
          'an already traced source keeps its bytes';
        my $line = "seen\t$probe/lib/A.pm\nhit\t$probe/lib/A.pm\t2\nlines\t$probe/lib/A.pm\t2,3\n";
        return {
            'a-fails.t' =>
              { result => { passed => 0 }, record => Test::Mutation::Record::parse( ["begin\t1\n$line"] ) },
            'b-passes.t' => {
                result => { passed => 1 },
                record => Test::Mutation::Record::parse(
                    [
                            "begin\t1\n$line"
                          . "seen\t$probe/lib/B.pm\nhit\t$probe/lib/B.pm\t6\noutside\t$probe/lib/B.pm\n"
                    ]
                )
            },
            'b-reverse.t' => {
                result => { passed => 1 },
                record => Test::Mutation::Record::parse(
                    ["begin\t1\noutside\t$probe/lib/A.pm\nseen\t$probe/lib/B.pm\nhit\t$probe/lib/B.pm\t7\n"]
                )
            },
            'c-blind.t' => {
                result => { passed => 1 },
                record =>
                  Test::Mutation::Record::parse( ["begin\t1\nblind\t$probe/lib/B.pm\nhit\t$probe/lib/B.pm\t9\n"] )
            },
            'd-absent.t' => { result => { passed => 1 }, record => Test::Mutation::Record::parse( ["begin\t1\n"] ) },
        };
    };
    Test::Mutation::Runner::_trace_blind( $run, \%outcome );
    is \@tested, [qw(a-fails.t b-passes.t b-reverse.t c-blind.t d-absent.t)],
      'only tests with an untraced and byte-insensitive target run';
    is $outcome{'b-passes.t'}{record}{served}{"$root/lib/A.pm"}, { traced => 1, hits => { 2 => 1 } },
      'the passing traced load supplies the original project line';
    is $outcome{'b-passes.t'}{record}{breakable}{"$root/lib/A.pm"}, { 2 => 1, 3 => 1 },
      'the breakable-line map accompanies the trace';
    is $outcome{'b-reverse.t'}{record}{served}{"$root/lib/B.pm"}, { traced => 1, hits => { 7 => 1 } },
      'an anomalous load of A preserves the traced lines of B in the same test';
    for my $case (
        [ 'a-fails.t',   'A' ],
        [ 'b-passes.t',  'B' ],
        [ 'c-blind.t',   'B' ],
        [ 'd-absent.t',  'A' ],
        [ 'sensitive.t', 'A' ]
      )
    {
        my ( $test, $module ) = @$case;
        is $outcome{$test}{record}{served}{"$root/lib/$module.pm"}, { traced => 0, hits => {} },
          "$test preserves file-level evidence when refined coverage is unavailable";
    }
    ok !-d $probe,                    'the diagnostic files are removed after the trace';
    ok $run->{workspace}->release(0), 'the private workspace is released';
};
## use critic

done_testing;
