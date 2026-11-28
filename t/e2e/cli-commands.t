use v5.36;
use Test2::V0;
use lib 't/e2e/lib';
use Cwd        ();
use File::Temp ();
use Fixture    qw(copy_of ran ran_from tree_digest with_driver_shims write_file);
use Test::Mutation::Mutator::Catalog;
use Test::Mutation::Runner;
use Test::Mutation::Settings;

my $root = copy_of('calc');

subtest 'command help and reference settings are available outside a project' => sub {
    my $empty = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my $help  = ran( 0, $empty, 'help' );
    like $help->{stdout}, qr/^  baseline\s+/m, 'the reference names the unmodified test run';
    my $show = ran( 0, $empty, 'help', 'show' );
    like $show->{stdout},   qr/\AUsage: mutation show ID/, 'help gives the usage of the selected command';
    unlike $show->{stdout}, qr/^  merge\s+/m,              'command help describes one command';
    my $mutators = ran( 0, $empty, 'help', 'mutators' )->{stdout};
    like $mutators,   qr/^  --root\b/m, 'the selected command accepts a project directory';
    unlike $mutators, qr/^  --jobs\b/m, 'the command lists only its own settings';
    like ran( 2, $empty, 'help', 'hepl' )->{stderr}, qr/hepl.*help/,
      'an unknown help topic suggests its nearest command';
    like ran( 0, $empty, 'settings' )->{stdout}, qr/--jobs.*(?:process|parallel)/i, 'settings explains the options';
    like ran( 2, $empty, 'hepl' )->{stderr},     qr/hepl.*help/, 'a misspelling includes the nearest command';
    is tree_digest($empty), {}, 'reference commands and refusals leave the directory empty';
};

subtest 'path operands narrow both the listing and the measurement to matching lines' => sub {
    my $project = copy_of('calc');
    my $all     = ran( 0, $project, 'list' )->{stdout};
    is ran( 0, $project, 'list', 'lib' )->{stdout}, $all, 'a directory includes its sources';
    my $selected = ran( 0, $project, 'list', 'lib/Calc.pm:7,17-18' )->{stdout};
    like $selected,   qr/lib\/Calc[.]pm:7:\d+\s+arithmetic/,  'the first range selects the addition';
    like $selected,   qr/lib\/Calc[.]pm:17:\d+\s+arithmetic/, 'the second range selects the multiplication';
    unlike $selected, qr/lib\/Calc[.]pm:12:\d+\s+comparison/, 'a line outside the ranges is absent';
    my $run = ran( 0, $project, 'run', '--format', 'terminal', 'lib/Calc.pm:7' );
    like $run->{stderr}, qr/\b3 mutants in 1 file/, 'run measures the addition, return and containing subroutine';
    like ran( 2, $project, 'list', 'lib/Calc.pm:8-7' )->{stderr}, qr/8-7/,          'a reversed range names the input';
    like ran( 2, $project, 'list', 'missing.pm' )->{stderr},      qr/missing[.]pm/, 'an absent path names the input';
};

subtest 'baseline runs the unmodified tests without mutating or replacing a report' => sub {
    my $project = copy_of('calc');
    write_file( "$project/lib/Other.pm", "package Other;\nsub total { 2 + 3 }\n1;\n" );
    my $config = Test::Mutation::Settings::of_call( { root => $project } );
    like dies { Test::Mutation::Runner::analyze( $config, { 'lib/Other.pm' => 'invalid' } ) }, qr/PathSelection/,
      'an invalid line selection is rejected before analysis';
    my $later = ran( 0, $project, 'list', 'lib/Other.pm' )->{stdout};
    like $later,   qr/lib\/Other[.]pm:2:\d+\s+arithmetic/, 'a source following an unselected file is listed';
    unlike $later, qr/lib\/Calc[.]pm/,                     'the unselected source stays out of the listing';
    my $baseline = with_driver_shims(
        sub {
            Test::Mutation::Runner::run( $config, sub { }, { baseline_only => 1 } );
        }
    );
    is [ sort keys $baseline->sources->%* ], [qw(lib/Calc.pm lib/Other.pm)],
      'the unmodified run records every source even when the project has several files';
    is $baseline->entries, [], 'a baseline produces no mutant entries';
    write_file( "$project/mutation-report/mutation.json", "previous report\n" );
    my $before = tree_digest($project);
    my $run    = ran( 0, $project, 'baseline' );
    like $run->{stdout}, qr/\b2 tests?\b/, 'the result counts unmodified tests';
    is tree_digest($project), $before, 'the project and its last report are intact';
    write_file( "$project/t/fails.t", "use Test::More tests => 1;\nfail 'broken test';\n" );
    like ran( 3, $project, 'baseline' )->{stderr}, qr/t\/fails[.]t/, 'a failure names the test and exits with status 3';
};

subtest 'list prints every mutant without running a test' => sub {
    my $before = tree_digest($root);
    my $run    = ran( 0, $root, 'list' );
    my @lines  = split /\n/, $run->{stdout};
    is scalar(@lines), 22, 'one line for each mutant and a count';
    like $lines[0], qr/\A[0-9a-f]{12}  lib\/Calc\.pm:5:10  sub-body  removed the body of add\z/,
      'identifier, place, mutator, description';
    is $lines[-1],         '21 mutants', 'the count';
    is tree_digest($root), $before,      'nothing is written';
};

subtest '--root runs the command as if it had started in the named directory' => sub {
    my $elsewhere = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my $listed    = ran( 0, $elsewhere, '--root', $root, 'list' );
    is $listed->{stdout}, ran( 0, $root, 'list' )->{stdout},                   'list names the mutants of the project';
    is ran( 0, $elsewhere, 'list', '-C', $root )->{stdout}, $listed->{stdout}, 'the option may follow the command';

    my $inside = ran( 0, $elsewhere, '--root', $root, 'exec', identifier('replaced + with -'),
        '--', $^X, '-MCwd', '-e', 'print Cwd::getcwd()' );
    my ($project_name) = $root =~ m{([^/]+)\z};
    like $inside->{stdout}, qr{/mutation-[A-Za-z0-9]+/tree/\Q$project_name\E\z},
      'exec starts in the private project copy';
    isnt $inside->{stdout}, $root, 'the original working directory remains outside the command';

    my $missing = ran( 2, $elsewhere, '--root', "$elsewhere/none", 'list' );
    is [ $missing->@{qw(exit stdout)} ], [ 2, q{} ], 'a directory that does not exist is a usage error';
    like $missing->{stderr}, qr/\Amutation: cannot enter \Q$elsewhere\E\/none: [^\n]+\n\z/, 'with one line';
    is [ glob "$elsewhere/*" ], [], 'the directory of the caller gets no file';

    my $library = Cwd::abs_path('lib');
    local $ENV{PERL5LIB} = join q{:}, grep { $_ ne $library } split /:/, defined $ENV{PERL5LIB} ? $ENV{PERL5LIB} : q{};
    my $reported = copy_of('calc');
    my $relative = ran_from( 'lib', 0, Cwd::getcwd(), '--root', $reported, '--jobs', 2 );
    ok -s "$reported/mutation-report/mutation.html", 'the bundled viewer resolves when the library path is relative';
    like $relative->{stdout}, qr/^Score: 71\.4%/m, 'and the run measures the project';
};

subtest 'list marks suppressed mutants and honors the mutator options' => sub {
    my $copy = copy_of('calc');
    write_file( "$copy/lib/Quiet.pm", "package Quiet;\nsub sum { return \$_[0] + \$_[1] }    ## no mutate\n1;\n" );
    my $run = ran( 0, $copy, 'list', '--disable', 'sub-body', '--source', 'lib/Quiet.pm' );
    like $run->{stdout}, qr/^[0-9a-f]{12}  lib\/Quiet\.pm:2:\d+  arithmetic  replaced \+ with -  \(suppressed\)$/m,
      'a suppressed mutant';
    unlike $run->{stdout}, qr/sub-body/, 'a disabled mutator is absent';

    write_file( "$copy/lib/Quiet.pm",
        "package Quiet;\nsub sum { return \$_[0] + \$_[1] }    ## no mutate (arithmetic): the sum is a constant\n1;\n"
    );
    like ran( 0, $copy, 'list', '--source', 'lib/Quiet.pm' )->{stdout},
      qr/^[0-9a-f]{12}  lib\/Quiet\.pm:2:\d+  arithmetic  replaced \+ with -  \(suppressed: the sum is a constant\)$/m,
      'a suppressed mutant with the reason of its comment';
    like ran( 0, $copy, 'list', '--source', 'lib/Quiet.pm', '--disable', 'arithmetic' )->{stdout}, qr/\A[^\n]*sub-body/,
      'and a comment that names a mutator that the run leaves out';
};

subtest 'list and run refuse every broken suppression comment of every file before a test starts' => sub {
    my $copy    = copy_of('calc');
    my $outside = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    write_file( "$copy/lib/Broken.pm",
        "package Broken;\n## use mutate\nsub one { return \$_[0] + 1 }    ## no mutate (nonesuch)\n1;\n" );
    write_file( "$copy/lib/Idle.pm",
        "package Idle;\nsub two { return \$_[0] - 1 }    ## no mutate (regex-anchor)\n1;\n" );
    write_file( "$copy/t/marker.t",
        "open my \$out, '>', '$outside/ran' or die;\nclose \$out;\nuse Test::More tests => 1;\nok 1;\n" );
    my $refusal =
        'mutation: invalid suppression comments: lib/Broken.pm:2: ## use mutate ends no open block; '
      . 'lib/Broken.pm:3: unknown mutator nonesuch; lib/Idle.pm:2: "## no mutate (regex-anchor)" suppresses no mutant';
    my $before = tree_digest($copy);
    my $listed = ran( 2, $copy, 'list' );
    is [ $listed->@{qw(stdout stderr)} ], [ q{}, "$refusal\n" ], 'list prints one line with every refusal';
    my $run = ran( 2, $copy, 'run', '--jobs', 1 );
    is [ $run->{stdout}, ( split /\n/, $run->{stderr} )[-1] ], [ q{}, $refusal ], 'run ends with the same line';
    ok !-e "$outside/ran", 'and no test started';
    is tree_digest($copy), $before, 'the project stays as it was';
};

subtest 'suppression requirements apply independently on the command line and in the configuration file' => sub {
    my $copy = copy_of('calc');
    write_file( "$copy/lib/Quiet.pm", <<'MODULE' );
package Quiet;
sub sum { return $_[0] + 1 }    ## no mutate: the value is fixed
sub difference { return $_[0] - 1 }    ## no mutate (arithmetic)
1;
MODULE
    my @list = ( 'list', '--source', 'lib/Quiet.pm' );
    my $names =
      'lib/Quiet.pm:2: "## no mutate: the value is fixed" names no mutator, and suppress-require-names asks for one';
    my $reason =
      'lib/Quiet.pm:3: "## no mutate (arithmetic)" gives no reason, and suppress-require-reason asks for one';
    my $prefix = 'mutation: invalid suppression comments: ';
    like ran( 0, $copy, @list )->{stdout}, qr/suppressed: the value is fixed/, 'both requirements default to off';
    is ran( 2, $copy, @list, '--suppress-require-names' )->{stderr}, "$prefix$names\n", 'the flag requires names alone';
    write_file( "$copy/mutation.toml", "suppress-require-reason = true\n" );
    is ran( 2, $copy, @list )->{stderr}, "$prefix$reason\n", 'the file requires a reason alone';
    is ran( 2, $copy, @list, '--suppress-require-names' )->{stderr}, "$prefix$names; $reason\n",
      'both requirements report the affected lines in order';
    is ran( 2, $copy, @list, '--suppress-require-names', '--no-suppress-require-reason' )->{stderr}, "$prefix$names\n",
      'the command line overrides the requirement from the file';
    write_file( "$copy/lib/Quiet.pm",
        "package Quiet;\nsub sum { return \$_[0] + 1 }    ## no mutate (arithmetic): the value is fixed\n1;\n" );
    like ran( 0, $copy, @list, '--suppress-require-names' )->{stdout}, qr/arithmetic .*suppressed: the value is fixed/,
      'a used directive with a name and a reason passes both requirements';
};

sub identifier ($description) {
    my ($id) = ran( 0, $root, 'list' )->{stdout} =~ /^([0-9a-f]{12})  \S+  \S+  \Q$description\E$/m;
    return $id;
}

subtest 'show prints a mutant as a patch' => sub {
    my $id  = identifier('replaced > with >=');
    my $run = ran( 0, $root, 'show', $id );
    is [ split /\n/, $run->{stdout} ],
      [
        "$id  lib/Calc.pm:12:15  comparison-boundary  replaced > with >=",
        'Last result: unmeasured',
        '--- lib/Calc.pm',
        '+++ lib/Calc.pm',
        '@@ -10,5 +10,5 @@',
        ' sub is_positive {',
        '     my ($n) = @_;',
        '-    return $n > 0 ? 1 : 0;',
        '+    return $n >= 0 ? 1 : 0;',
        ' }',
        q{ },
      ],
      'the heading and a unified diff with two lines of context';
};

subtest 'show prints a mutant that removes lines' => sub {
    my $run = ran( 0, $root, 'show', identifier('removed the body of add') );
    is [ grep { /\A[-+@]/ } split /\n/, $run->{stdout} ],
      [
        '--- lib/Calc.pm',
        '+++ lib/Calc.pm',
        '@@ -4,6 +4,6 @@',
        '-    my ( $x, $y ) = @_;',
        '-    return $x + $y;',
        '+',
        '+'
      ],
      'the removed lines and the blank lines that keep the line numbers';
};

subtest 'show accepts a unique prefix and refuses an unknown or ambiguous identifier' => sub {
    my $id = identifier('replaced + with -');
    ran( 0, $root, 'show', substr $id, 0, 6 );
    my $unknown = ran( 2, $root, 'show', 'zzzzzz' );
    is $unknown->{stderr}, "mutation: no mutant has the identifier zzzzzz\n", 'the message';
    my $missing = ran( 2, $root, 'show' );
    is $missing->{stderr}, "mutation: show needs a mutant identifier\n", 'the message';
};

subtest 'exec runs a command with one mutant active' => sub {
    my $before   = Fixture::tree_digest($root);
    my $detected = ran( 1, $root, 'exec', identifier('replaced + with -'), '--', $^X, '-Ilib', 't/add.t' );
    like $detected->{stdout}, qr/^not ok 1 - adds$/m, 'the output of the command passes through';

    my $id      = identifier('replaced + with -');
    my $tainted = ran( 0, $root, 'exec', $id, '--', $^X, '-T', '-Ilib', '-MCalc', '-e', 'print Calc::add(4,2)' );
    is $tainted->{stdout}, '2', 'a tainted interpreter loads the file installed in the copy';
    my $reader = q{open my $in, '<', 'lib/Calc.pm' or die $!; local $/; my $source = <$in>; }
      . q{open my $out, '>', 'exec.marker' or die $!; print $source =~ /return \$x - \$y/ ? 'changed' : 'original'};
    is ran( 0, $root, 'exec', $id, '--', $^X, '-e', $reader )->{stdout}, 'changed', 'a direct reader sees the mutant';
    ok !-e "$root/exec.marker", 'files created by the command stay in its private tree';

    my ($survivor) =
      ran( 0, $root, 'list' )->{stdout} =~
      /^([0-9a-f]{12})  lib\/Calc\.pm:12:\d+  comparison-boundary  replaced > with >=$/m;
    ran( 0, $root, 'exec', $survivor, '--', $^X, '-Ilib', 't/sign.t' );

    ran( 7,   $root, 'exec', identifier('replaced + with -'), '--', $^X, '-e', 'exit 7' );
    ran( 143, $root, 'exec', identifier('replaced + with -'), '--', $^X, '-e', 'kill TERM => $$; sleep 5' );
    is Fixture::tree_digest($root), $before, 'exec leaves the project and its previous cached results intact';
};

subtest 'exec reports its own failures with the statuses of env' => sub {
    my $absent = ran( 127, $root, 'exec', identifier('replaced + with -'), '--', "$root/no-such-command" );
    like $absent->{stderr}, qr{\Amutation: cannot find \Q$root\E/no-such-command: [^\n]+\n\z},
      'a command that exists nowhere has status 127 and one line';
    my $sealed = ran( 126, $root, 'exec', identifier('replaced + with -'), '--', "$root/lib" );
    like $sealed->{stderr}, qr{\Amutation: cannot run \Q$root\E/lib: [^\n]+\n\z},
      'a command that exists and fails to run has status 126 and one line';

    my $id = identifier('replaced + with -');
    symlink "$root/absent", "$root/lib/Missing.pm" or die "symlink: $!";
    my $unplaced = ran( 125, $root, 'exec', $id, '--', $^X, '-e', 'exit 0' );
    like $unplaced->{stderr}, qr{\Amutation: cannot read \Q$root\E/lib/Missing[.]pm: [^\n]+\n\z},
      'a failure of exec itself has status 125 and one line';
    unlink "$root/lib/Missing.pm" or die "unlink: $!";
};

subtest 'exec refuses a missing identifier or command' => sub {
    my $no_command = ran( 2, $root, 'exec', identifier('replaced + with -') );
    is $no_command->{stderr}, "mutation: exec needs a mutant identifier and a command\n", 'the message';
    ran( 2, $root, 'exec', 'zzzzzz', '--', $^X, '-e', '1' );
};

subtest '--shard splits the mutants into disjoint parts' => sub {
    my $ids = sub (@arguments) {
        return [ map { /\A([0-9a-f]{12})  / ? $1 : () } split /\n/, ran( 0, $root, 'list', @arguments )->{stdout} ];
    };
    my @all    = $ids->()->@*;
    my @shards = map { $ids->( '--shard', "$_/3" ) } 1 .. 3;
    is [ sort map { $_->@* } @shards ],   [ sort @all ], 'the parts together hold every mutant once';
    is [ map { scalar $_->@* } @shards ], [ 7, 7, 7 ],   'the parts have even sizes';
    is $ids->( '--shard', '1/1' ),        \@all,         'one part is the whole';

    for my $invalid (qw(0/3 4/3 2 a/b)) {
        ran( 2, $root, 'list', '--shard', $invalid );
    }
};

subtest 'mutators names every mutator with its profile and its description' => sub {
    my $run   = ran( 0, $root, 'mutators' );
    my @lines = split /\n/, $run->{stdout};
    is scalar(@lines), scalar( Test::Mutation::Mutator::Catalog::mutators()->@* ), 'one line for each mutator';
    like $run->{stdout}, qr/^arithmetic +default +Replaces an arithmetic operator with its counterpart$/m,
      'a mutator of the default profile';
    like $run->{stdout}, qr/^regex-anchor +extended +Removes an anchor from a pattern$/m,
      'a mutator of the extended profile';
    my %columns = map { /\A(\S+ +)(\S+ +)/ ? ( length($1) . q{ } . length $2 => 1 ) : ( none => 1 ) } @lines;
    is [ keys %columns ], ['21 10'], 'the columns line up two spaces after the longest name and profile';
};

subtest 'version, help, and stray arguments' => sub {
    my $version = ran( 0, $root, '--version' );
    like $version->{stdout}, qr/\Amutation \d+[.]\d+\n\z/, 'the version line';

    my $help = ran( 0, $root, '--help' );
    like $help->{stdout}, qr/^Usage: mutation \[run\] \[PATH\[:LINES\]\.\.\.\] \[options\]$/m, 'the usage line';
    like $help->{stdout}, qr/^\s+mutation exec ID \[options\] -- COMMAND/m,                    'the commands';
    like $help->{stdout}, qr/^\s+mutation merge FILE/m,                                        'the merge command';
    like $help->{stdout}, qr/^\s+mutation mutators \[options\]$/m,                             'the mutators command';
    my @undocumented = grep { $help->{stdout} !~ /^\s+(?:--[\w-]+, )*--\Q$_\E(?![\w-])/m }
      qw(root config jobs min-score format report-dir threshold-high threshold-low perl lib switch source source-exclude test
      test-exclude profile enable disable equivalence no-equivalence coverage timeout-factor timeout-floor baseline-timeout
      in-place no-in-place link keep-work no-keep-work mutant since shard cache no-cache cache-dir help version);
    is \@undocumented, [], 'every option is described';

    my $stray = ran( 2, $root, 'run', 'surplus' );
    is $stray->{stderr}, "mutation: invalid path selection surplus: the path does not exist\n",
      'the missing source path is named';

    my $listed = ran( 2, $root, 'mutators', 'surplus' );
    is [ $listed->@{qw(exit stdout stderr)} ], [ 2, q{}, "mutation: unexpected argument surplus\n" ],
      'mutators refuses a stray argument and prints no list';
};

done_testing;
