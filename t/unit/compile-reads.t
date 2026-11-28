use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use lib 't/e2e/lib';
use Fixture        qw(run_fixture write_file);
use Test::Mutation ();
use Test::Mutation::Store::Key;
use Test::Mutation::Syntax::PPI;

sub reads ($source) {
    return scalar Test::Mutation::Syntax::PPI::compile_reads($source);
}

subtest 'reading a source file constructs one syntax tree for a simple phase block' => sub {
    my $constructor = PPI::Document->can('new');
    my $parses      = 0;
    no warnings 'redefine';
    local *PPI::Document::new = sub {
        ++$parses if caller eq 'Test::Mutation::Syntax::PPI';
        return $constructor->(@_);
    };
    is reads(q{BEGIN { open my $in, '<', 'limits' }}), [ [ file => 'limits' ] ], 'the operand is a literal file';
    is $parses,                                        1, 'the default source mode parses the block once';
};

subtest 'scheduled blocks identify the file operands of read-only open' => sub {
    is reads(q{BEGIN { open my $in, '<', $ENV{TABLE} or die $!; close $in }}), [ [ env => 'TABLE' ] ],
      'the target environment supplies one named input';
    is reads(q{UNITCHECK { CORE::open(my $in, '<:raw', '/data/file') }}), [ [ file => '/data/file' ] ],
      'a literal path and a PerlIO layer identify one input';
    is reads(q{BEGIN;}), undef, 'a phase declaration without a body supplies no read evidence';
    is reads(q{END { 1 } sub CHECK { open my $in, '<', 'limits' }}), [ [ file => 'limits' ] ],
      'a later explicit CHECK subroutine still runs during compilation';
    is reads(q{BEGIN { unshift @INC, $ENV{LIBRARY}; push @INC, '/opt/lib' }}), [],
      'the compiler already records literal and environment-derived include directories';
    is reads(q{sub load { open my $in, '<', make_path() } # BEGIN }), [],
      'runtime statements do not run in the compiler';
};

subtest 'the compiler cannot identify an indirect read from its operands' => sub {
    is reads(q{BEGIN { open my $in, '<', $ENV{TABLE} . '.other' }}), undef,
      'a path expression is not a single variable';
    is reads(q{BEGIN { read_table() }}), undef, 'a helper may run arbitrary code';
    is reads(q{BEGIN { $ENV{TABLE} = '/other'; open my $in, '<', $ENV{TABLE} }}), undef,
      'the launch environment does not determine a reassigned variable';
    is reads(q{use lib (do { $ENV{TABLE} = 'alternate'; 'lib' }); BEGIN { open my $in, '<', $ENV{TABLE} }}), undef,
      'a parenthesized import argument can change the path before a phase block opens it';
};

subtest 'literal numeric guards have no external compiler inputs' => sub {
    is reads(q{BEGIN { die "broken\n" if 3 - 1 != 2 }}),            [], 'a fixed arithmetic comparison reads no file';
    is reads(q{BEGIN { CORE::die 'broken' unless 2 <= 3 }}),        [], 'a fixed lower bound reads no file';
    is reads(q{BEGIN { die "broken\n" if 3 - read_limit() != 2 }}), undef, 'a call can read an external limit';
    is reads(q{BEGIN { die "broken\n" if -e '/outside' }}),         undef, 'a file test depends on the filesystem';
    is reads(q{BEGIN { die "@{[read_limit()]}" if 1 }}),            undef, 'the error message can execute code';
};

subtest 'an imported module must preserve an environment-derived file operand' => sub {
    my $at_load = sub ($source) { return scalar Test::Mutation::Syntax::PPI::compile_reads( $source, 1 ) };
    is $at_load->(q{package Data; use strict; sub count { return 3 } 1;}), [],
      'declarations and the module return value do not change a binding';
    is $at_load->(q{package Data; use constant LIMIT => 7; 1;}), [], 'a literal numeric constant has no outside input';
    is $at_load->(q{package Data; use constant LIMIT => read_limit(); 1;}), undef,
      'computing a constant can read an outside file';
    is $at_load->(q{package Data; use lib $ENV{CUSTOM}, $ENV{FALLBACK}; 1;}), [],
      'the target records both include directories supplied by named environment variables';
    is $at_load->(q{package Data; use lib $ENV{CUSTOM}, fallback(); 1;}), undef,
      'a computed fallback directory can read an outside file';
    is $at_load->(q{package Data; $ENV{TABLE} = 'other'; 1;}), undef, 'a file-scope assignment runs on import';
    is $at_load->(q{package Data; apply_settings(); 1;}),      undef, 'a file-scope helper can alter the environment';
    is $at_load->(q{package Data; use strict; sub choose { $ENV{TABLE} = 'other' } choose; 1;}), undef,
      'a bare call after a fixed import runs when the compiler loads the module';
    is $at_load->(q{package Data; sub import { $ENV{TABLE} = 'other' } 1;}), undef, 'an import hook executes on use';
    is $at_load->(q{package Data; use Settings apply_settings(); 1;}), undef, 'an import argument can execute a helper';
};

subtest 'lexical changes to other features preserve native class declarations' => sub {
    my $reads = sub ($change) {
        my $source = "use experimental 'class'; $change class Model { method value { 7 } } 1;";
        return scalar Test::Mutation::Syntax::PPI::compile_reads( $source, 1 );
    };
    for my $change (
        q{use feature 'say';},
        q{no feature 'say';},
        q{use experimental 'signatures';},
        q{no experimental 'signatures';},
        q{no feature ();},
        q{no experimental;},
        q{require feature;},
        q{use feature ':5.36';},
        q{no v100.0;}
      )
    {
        is $reads->($change), [], "the class remains enabled after $change";
    }
    for my $change (
        q{no feature 'class';},
        q{no experimental 'class';},
        q{no feature;}, q{no feature ':all';},
        q{use v5.38;}
      )
    {
        is $reads->($change), undef, "the class syntax is no longer enabled after $change";
    }
    is $reads->(q{no experimental 'class'; use feature qw(say class);}), [], 'an explicit import enables class again';
};

subtest 'a compiler search path inside the project can resolve to an external library' => sub {
    local $ENV{PERL5OPT} = '-Mstrict';
    my $area     = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my $project  = "$area/project";
    my $external = "$area/external";
    write_file( "$project/a-local/Local.pm", "package Local; sub floor () { 1 } 1;\n" );
    write_file( "$external/Defaults.pm",     "package Defaults; sub limit () { 3 } 1;\n" );
    symlink $external, "$project/z-defaults" or die "link compiler library: $!";
    local $ENV{TEST_LOCAL_LIBRARY}  = "$project/a-local";
    local $ENV{TEST_LINKED_LIBRARY} = "$project/z-defaults";
    write_file( "$project/lib/Bounds.pm", <<'PERL' );
package Bounds;
use lib $ENV{TEST_LOCAL_LIBRARY}, $ENV{TEST_LINKED_LIBRARY};
use Local ();
use Defaults ();
sub inside { return Local::floor() < Defaults::limit() }
1;
PERL
    write_file( "$project/t/pass.t", "use Test::More tests => 1; pass 'ready';\n" );
    my %compiled;
    my $compile = \&Test::Mutation::Runner::_compile_task;    ## no critic (Variables::ProtectPrivateVars)
    no warnings 'redefine';
    local *Test::Mutation::Runner::_compile_task = sub ( $run, $job, $kind, $file, $switch ) {    ## no critic (Variables::ProtectPrivateVars)
        die "repeated $kind for $file\n" if $compiled{$kind}{$file}++;
        return $compile->( $run, $job, $kind, $file, $switch );
    };
    my ($result) = run_fixture( $project, cache => 0, jobs => 1 );
    ok !exists $result->compiler_inputs->{ Test::Mutation::Store::Key::digest("$project/a-local") },
      'the ordinary library is already part of the project';
    is $result->compiler_inputs->{ Test::Mutation::Store::Key::digest($external) },
      Test::Mutation::Store::Key::tree( $external, [] ),
      'the compiler binds the external directory reached by the link';
};

subtest 'a mutant that empties the file operand supplies its own compile-time inputs' => sub {
    my $root = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    write_file( "$root/limit.dat",    "7\n" );
    write_file( "$root/lib/Bound.pm", <<'MODULE' );
package Bound;
BEGIN {
    open my $input, '<', 'limit.dat';
    my $limit = 0 + <$input>;
    close $input;
    require constant;
    constant->import('LIMIT', $limit);
}
sub limit { return LIMIT() }
1;
MODULE
    write_file( "$root/t/check.t", "use Test::More tests => 1; use Bound; ok defined Bound::limit();\n" );
    my $changes = Test::Mutation::mutants( root => $root, enable => ['string-literal'] );
    my ($emptied) = grep { $_->original eq q{'limit.dat'} && $_->replacement eq q{''} } @$changes;
    my ($result) =
      run_fixture( $root, cache => 0, jobs => 1, enable => ['string-literal'], mutant => [ $emptied->id ] );
    my $entry = $result->entries->[0];
    is $entry->{status}, 'Survived', 'the test accepts the default value after the open fails';
    ok defined $result->measurement_digest, 'the original program has a known file operand';
    is $entry->{compiled_digest}, undef, 'the mutant cannot certify its empty operand with the original file';
};

subtest 'standalone compilation records the external file used by an explicit BEGIN subroutine' => sub {
    my $area = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my $root = "$area/project";
    local $ENV{PERL5OPT}            = '-Mstrict';
    local $ENV{TEST_COMPILER_LIMIT} = write_file( "$area/limit", "4\n" );
    write_file( "$root/lib/Bound.pm", <<'PERL' );
package Bound;
use warnings 'numeric', 'uninitialized';
sub BEGIN {
    open my $input, '<', $ENV{TEST_COMPILER_LIMIT} or die $!;
    my $limit = 0 + <$input>;
    close $input or die $!;
    require constant;
    constant->import('LIMIT', $limit);
}
sub below { return $_[0] < LIMIT }
1;
PERL
    write_file( "$root/t/check.t", "use Test::More tests => 1; use Bound; ok Bound::below(3);\n" );
    my ($result) = run_fixture( $root, cache => 0, jobs => 1 );
    is $result->baseline_failures, [], 'the target Perl compiles and uses the constant';
    is $result->compiler_inputs->{ Test::Mutation::Store::Key::digest("$area/limit") },
      Test::Mutation::Store::Key::file("$area/limit"), 'the report binds the external bytes used for the constant';
};

subtest 'an import can redirect a relative input before the compiler opens it' => sub {
    my $area = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my $root = "$area/project";
    local $ENV{TEST_LIMIT_DIRECTORY} = "$area/data";
    write_file( "$root/limit", "3\n" );
    my $enter = q{$ENV{TEST_PREVIOUS_DIRECTORY} = Cwd::getcwd(); chdir $ENV{TEST_LIMIT_DIRECTORY} or die $!};
    my $leave = q{chdir $ENV{TEST_PREVIOUS_DIRECTORY} or die $!};
    my $read  = <<'PERL';
BEGIN {
    open my $input, '<', 'limit' or die $!;
    my $limit = 0 + <$input>;
    close $input or die $!;
    require constant;
    constant->import('LIMIT', $limit);
}
PERL
    my $source = sub ( $before, $after ) {
        write_file( "$root/lib/Bound.pm", join "\n", 'package Bound;',
            'use Cwd ();', $before, $read, $after, 'sub below { return $_[0] < LIMIT }', "1;\n" );
    };
    $source->( "use warnings do { $enter; 'numeric' };", "use warnings do { $leave; 'numeric' };" );
    write_file( "$root/t/check.t", "use Test::More tests => 1; use Bound; ok !Bound::below(7);\n" );
    my $boundary = sub ($cache) {
        my ($result) = run_fixture(
            $root,
            cache   => $cache,
            jobs    => 1,
            shard   => '1/1',
            enable  => ['comparison-boundary'],
            disable => [qw(@removal arithmetic comparison-negation logical)]
        );
        my ($entry) = grep { $_->{mutant}->mutator eq 'comparison-boundary' } $result->entries->@*;
        return [ $entry->{status}, $result->cache_mismatch, $entry->{compiled_digest} ];
    };
    write_file( "$area/data/limit", "7\n" );
    is $boundary->(1), [ 'Killed', 0, undef ], 'the test distinguishes strict comparison at seven';
    write_file( "$area/data/limit", "5\n" );
    is $boundary->(1), [ 'Survived', 0, undef ], 'the changed limit invalidates the old verdict before cache sampling';
    is $boundary->(0), [ 'Survived', 0, undef ], 'fresh tests agree with the cached run';

    local $ENV{PERL5LIB} = join q{:}, "$area/imports", grep { defined } $ENV{PERL5LIB};
    write_file( "$area/imports/Enter.pm", "package Enter; use Cwd (); $enter; 1;\n" );
    write_file( "$area/imports/Leave.pm", "package Leave; $leave; 1;\n" );
    $source->( 'use Enter ();', 'use Leave ();' );
    is $boundary->(1), [ 'Survived', 0, undef ], 'an imported module can redirect the same literal input';
    write_file( "$area/data/limit", "7\n" );
    is $boundary->(1), [ 'Killed', 0, undef ], 'the previous survival cannot be reused after the data changes';
};

subtest 'a detecting test depends on the file read by an imported constant' => sub {
    my $area = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my $root = "$area/project";
    local $ENV{PERL5OPT}          = '-Mstrict';
    local $ENV{PERL5LIB}          = join q{:}, "$area/modules", grep { defined } $ENV{PERL5LIB};
    local $ENV{TEST_IMPORTED_MAX} = write_file( "$area/data/limit", "7\n" );
    write_file( "$area/modules/Threshold.pm", <<'PERL' );
package Threshold;
BEGIN {
    open my $input, '<', $ENV{TEST_IMPORTED_MAX} or die $!;
    my $limit = 0 + <$input>;
    close $input or die $!;
    require constant;
    constant->import('LIMIT', $limit);
}
1;
PERL
    write_file( "$root/lib/Bound.pm", <<'PERL' );
package Bound;
use Threshold ();
sub first { return $_[0] < Threshold::LIMIT() }
sub second { return $_[0] < Threshold::LIMIT() }
1;
PERL
    write_file( "$root/lib/Plain.pm", q{package Plain; sub below { return $_[0] < 1 } 1;} );
    write_file( "$root/t/check.t",    <<'PERL' );
use Test::More tests => 3;
use Bound;
use Plain;
ok !Bound::first(7);
ok !Bound::second(7);
ok !Plain::below(1);
PERL
    my $measure = sub ($cache) {
        my ($result) = run_fixture(
            $root,
            cache   => $cache,
            jobs    => 2,
            shard   => '1/1',
            enable  => ['comparison-boundary'],
            disable => [qw(@removal arithmetic comparison-negation logical)]
        );
        return $result;
    };
    my $statuses = sub ($result) {
        return [ map { $_->{status} } $result->entries->@* ];
    };
    my $cold = $measure->(1);
    is $statuses->($cold), [ ('Killed') x 3 ], 'the test detects each changed boundary';
    is $cold->compiler_inputs->{ Test::Mutation::Store::Key::digest( $ENV{TEST_IMPORTED_MAX} ) },
      Test::Mutation::Store::Key::file( $ENV{TEST_IMPORTED_MAX} ), 'the report identifies the external operand';
    is $cold->stats->{compiles}, 2, 'the reader shares its discovery and binding and the plain source needs neither';
    my $same = $measure->(1);
    is [ $same->reused, $same->stats->{compiles} ], [ 3, 0 ], 'verified inputs need no repeat compiler process';
    write_file( $ENV{TEST_IMPORTED_MAX}, "5\n" );
    my $warm  = $measure->(1);
    my $fresh = $measure->(0);
    is $statuses->($fresh), [ 'Survived', 'Survived', 'Killed' ], 'the new limit changes the two dependent verdicts';
    is $statuses->($warm),  $statuses->($fresh),           'cached and fresh runs agree after the external change';
    is [ $warm->reused, $warm->cache_mismatch ], [ 1, 0 ], 'only the independent verdict is eligible for sampling';
};

done_testing;
