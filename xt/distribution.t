use v5.36;
use Test2::V0;
use Archive::Tar           ();
use IO::Uncompress::Gunzip ();
use Cwd                    ();
use File::Path             ();
use File::Temp             ();
use JSON::PP               ();
use Module::CPANfile;
use lib 't/lib', 't/e2e/lib';
use Fixture qw(write_file);
use Gate;
use Test::Mutation;

# The gate builds the distribution in a scratch copy and checks what an installation would receive.

my $BUILD_OUTPUT = qr{\A/(?:local|blib|[.]git|[.]mutation|mutation-report)(?:/|\z)|[.]log\z};

sub build_output ( $prefix, @members ) {
    return [ grep { substr( $_, length $prefix ) =~ $BUILD_OUTPUT } sort @members ];
}

subtest 'the gate rejects an archive that holds build output' => sub {
    is build_output( 'P-1', 'P-1/lib/A.pm', 'P-1/t/unit/a.t', 'P-1/localize.pm' ), [], 'sources and tests stay';
    is build_output( 'P-1', 'P-1/lib/A.pm', 'P-1/local/lib/perl5/B.pm', 'P-1/build.log', 'P-1/.git/HEAD', 'P-1/blib' ),
      [ 'P-1/.git/HEAD', 'P-1/blib', 'P-1/build.log', 'P-1/local/lib/perl5/B.pm' ],
      'installed dependencies, build output, repository data, and logs are named';
};

my $root    = Cwd::getcwd();
my $scratch = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );

open my $list, q{-|}, 'git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z' or die "git: $!";
my @files = split /\0/, do { local $/ = undef; readline $list };
close $list or die 'git ls-files failed';

for my $file (@files) {
    next if !-f "$root/$file";
    my ($directory) = "$scratch/$file" =~ m{\A(.*)/};
    File::Path::make_path($directory);
    open my $in,  '<:raw', "$root/$file"    or die "read $file: $!";
    open my $out, '>:raw', "$scratch/$file" or die "write $file: $!";
    print {$out} do { local $/ = undef; readline $in }
      or die "copy $file: $!";
    close $out or die "close $file: $!";
}

sub in_scratch (@command) {
    my $pid = fork;
    die "fork: $!" if !defined $pid;
    if ( !$pid ) {
        chdir $scratch or die "chdir: $!";
        open STDOUT, '>',  "$scratch/build.log" or die "stdout: $!";
        open STDERR, '>&', \*STDOUT             or die "stderr: $!";
        exec @command or die "exec: $!";
    }
    waitpid $pid, 0;
    return $? == 0;
}

sub build_log {
    open my $log, '<', "$scratch/build.log" or return 'no build log';
    local $/ = undef;
    return scalar readline $log;
}

ok in_scratch( 'git', 'init', '--quiet' ), 'the source copy has a Git index' or diag build_log();
my @tracked = grep { -f "$scratch/$_" } @files;
ok in_scratch( 'git', 'add', '--force', '--', @tracked ), 'the index contains the distribution inputs'
  or diag build_log();

ok in_scratch( $^X, 'Makefile.PL' ), 'Makefile.PL runs'             or diag build_log();
ok in_scratch('make'),               'make builds the distribution' or diag build_log();

ok -x "$scratch/blib/script/mutation",                                                   'the command is built';
ok -f "$scratch/blib/lib/Test/Mutation.pm",                                              'the main module is built';
ok -f "$scratch/blib/lib/Test/Mutation/Report/resources/mutation-test-elements.js",      'the bundled viewer is built';
ok -f "$scratch/blib/lib/Test/Mutation/Report/resources/mutation-test-elements.LICENSE", 'with its license text';

open my $handle, '<:raw', "$scratch/MYMETA.json" or die "read MYMETA.json: $!";
my $meta = JSON::PP->new->utf8->decode( do { local $/ = undef; readline $handle } );
close $handle or die "close MYMETA.json: $!";

my $declared = Module::CPANfile->load("$root/cpanfile")->prereq_specs;
is $meta->{name},                       'Test-Mutation',                           'the distribution name';
is $meta->{version},                    Test::Mutation->VERSION,                   'the version of the main module';
is $meta->{license},                    [ 'mit', 'apache_2_0' ],                   'the licenses of the repository';
is $meta->{author},                     ['Yasunobu Sakashita'],                    'the author';
is $meta->{resources}{repository}{web}, 'https://github.com/P4suta/Test-Mutation', 'the repository';
is $meta->{resources}{bugtracker}{web}, 'https://github.com/P4suta/Test-Mutation/issues', 'the issue tracker';
is $meta->{no_index}, { directory => [ 't', 'xt' ], package => ['DB'] },
  'the index leaves out the tests and the debugger package that the shim extends';
is $meta->{prereqs}{runtime}{requires}, $declared->{runtime}{requires}, 'runtime requirements match cpanfile';
is $meta->{prereqs}{test}{requires},    $declared->{test}{requires},    'test requirements match cpanfile';

my $version = qx{$^X -I$scratch/blib/lib $scratch/blib/script/mutation --version};
is $version, 'mutation ' . Test::Mutation->VERSION . "\n", 'the built command runs';

sub test_files {
    open my $makefile, '<', "$scratch/Makefile" or die "read Makefile: $!";
    my ($line) = grep { /\ATEST_FILES = / } readline $makefile;
    return $line;
}
is test_files(), "TEST_FILES = t/unit/*.t t/shim/*.t t/assumptions/*.t\n", 'an installation runs the quick tests';
{
    local $ENV{EXTENDED_TESTING} = 1;
    ok in_scratch( $^X, 'Makefile.PL' ), 'Makefile.PL runs for extended testing' or diag build_log();
    is test_files(), "TEST_FILES = t/unit/*.t t/shim/*.t t/assumptions/*.t t/e2e/*.t\n",
      'extended testing adds the end-to-end tests';
}
ok in_scratch( $^X, 'Makefile.PL' ), 'Makefile.PL runs again' or diag build_log();

ok in_scratch( 'make', 'test' ), 'make test passes' or diag build_log();
my ($test_files) = build_log() =~ /^Files=(\d+), Tests=\d+/m;
ok( defined $test_files && $test_files >= 25, 'and runs the unit, assumption, and shim tests' ) || diag build_log();

my @private =
  qw(.claude/worktrees/topic/lib/Unpublished.pm .env.local lib/Unpublished.pm lib/.DS_Store lib/._Module.pm);
write_file( "$scratch/$_", "local build data\n" ) for @private;
my @release_tools = qw(
  release-please-config.json xt/release-please/package.json xt/release-please/node_modules/dependency/index.js
  xt/release-publish/draft.rs xt/release-workflow.t xt/publication-workflow.t xt/release-archive.t xt/bin/verify-release-archive
  xt/local-release-check.t xt/bin/record-release-check xt/bin/verify-local-release-check
  xt/ci-interpreters.t xt/bin/check-ci-interpreters
);
write_file( "$scratch/$_", "release automation\n" ) for grep { !-e "$scratch/$_" } @release_tools;
ok in_scratch( 'git', 'add', '--force', '--', @release_tools ), 'the release tools are tracked'
  or diag build_log();

symlink "$scratch/lib", "$scratch/.claude/worktrees/topic/lib-link" or die "link the shared library: $!";
write_file( "$scratch/MANIFEST", "MANIFEST\nlib/Unpublished.pm\n" );
ok in_scratch( $^X, 'xt/bin/distribution-manifest' ), 'the release regenerates the manifest from tracked sources'
  or diag build_log();
ok in_scratch( 'make', 'dist' ), 'make packs the distribution' or diag build_log();

my $prefix = 'Test-Mutation-' . Test::Mutation->VERSION;
my %packed = map { $_ => 1 } Archive::Tar->list_archive("$scratch/$prefix.tar.gz");
my @wanted = qw(
  Makefile.PL cpanfile META.json .perlcriticrc .perltidyrc README.md Changes LICENSE-MIT LICENSE-APACHE THIRD_PARTY_NOTICES.md bin/mutation
  lib/Test/Mutation.pm lib/Test/Mutation/Shim.pm lib/Test/Mutation/Report/resources/mutation-test-elements.js
  t/unit/tap.t t/shim/serve.t t/fixtures/calc/lib/Calc.pm
  t/e2e/confirm-detectors.t xt/bin/confirm-self-measurement xt/lib/SelfMeasurement.pm
);
is [ grep { !$packed{"$prefix/$_"} } @wanted ], [], 'the archive holds the sources, the tests, and the notices';
is build_output( $prefix, keys %packed ),       [], 'and leaves out installed dependencies, build output, and reports';
is [ grep { $packed{"$prefix/$_"} } @private ], [],
  'worktrees, local settings and filesystem metadata stay out of the archive';
is [ grep { $packed{"$prefix/$_"} } @release_tools ], [],
  'the CPAN archive leaves out publication tools and their dependencies';
Gate::checked( 'members of the archive', scalar( keys %packed ), at_least => 150 );

IO::Uncompress::Gunzip::gunzip( "$scratch/$prefix.tar.gz" => \my $bytes ) or die 'cannot read the archive';
ok $bytes !~ /(?:LIBARCHIVE|SCHILY)[.]xattr/, 'the archive carries no extended attribute of the build machine';
is [ grep { m{/[.]_} } sort keys %packed ], [], 'and no resource fork file';

done_testing;
