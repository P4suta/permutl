use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use lib 't/e2e/lib';
use Fixture qw(run_fixture with_driver_shims write_file);
use Test::Mutation::Merge;
use Test::Mutation::Report::Json;
use Test::Mutation::Runner;
use Test::Mutation::Settings;

my $area    = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
my $library = "$area/external";
local $ENV{TEST_PROJECT_LIBRARY} = $library;
local $ENV{TEST_PROJECT_LIMIT}   = 5;
my $module   = "package Boundary; sub positive { return \$_[0] > 0 } 1;\n";
my $external = "package Defaults; sub count () { 3 } 1;\n";
my $test     = <<'PERL';
use Test::More tests => 1;
use lib $ENV{TEST_PROJECT_LIBRARY};
use Defaults;
use Boundary;
open my $file, '<', 'limit.dat' or die $!;
my $limit = <$file>;
close $file or die $!;
ok Boundary::positive(Defaults::count()) && Defaults::count() <= $limit && $ENV{TEST_PROJECT_LIMIT} > 0;
PERL
for my $checkout (qw(first second)) {
    my $root = "$area/$checkout";
    write_file( "$root/lib/Boundary.pm", $module );
    write_file( "$root/lib/Other.pm",    "package Other; sub value { 9 } 1;\n" );
    write_file( "$root/t/boundary.t",    $test );
    write_file( "$root/limit.dat",       "4\n" );
    my $program = write_file( "$root/tools/perl", "#!$^X\nexec {q{$^X}} q{$^X}, \@ARGV or die \$!;\n" );
    chmod 0755, $program or die $!;
}
write_file( "$library/Defaults.pm", $external );

sub checkout_library ( $checkout, $part ) {
    local $ENV{PERL5LIB} = join q{:}, "$area/$checkout/lib", grep { defined } $ENV{PERL5LIB};
    return shard( $checkout, $part );
}

sub shard ( $root, $part, %settings ) {
    my ($result) = run_fixture( "$area/$root", shard => "$part/2", cache => 0, %settings );
    return { name => $root, result => $result };
}

my $first = shard( 'first', 1 );

sub compare (%settings) {
    my $other = shard( 'second', 2, %settings );
    return Test::Mutation::Merge::merge( [ $first, $other ] );
}

ok lives { compare( cache => 1, jobs => 1 ) }, 'cached and uncached observations use compatible inputs';
subtest 'shards can use independently formatted configuration files' => sub {
    my @parts;
    for my $part ( 1 .. 2 ) {
        my $checkout = "configured-$part";
        my $root     = "$area/$checkout";
        write_file( "$root/lib/Boundary.pm", $module );
        write_file( "$root/t/boundary.t",    "use Test::More tests => 1; use Boundary; ok Boundary::positive(1);\n" );
        write_file( "$root/settings.toml",   "# Settings for worker $part\njobs = $part\n" );
        push @parts, shard( $checkout, $part, config => 'settings.toml' );
    }
    ok lives { Test::Mutation::Merge::merge( \@parts ) },
      'the selected measurement settings determine whether the shards can be combined';
};

ok lives { Test::Mutation::Merge::merge( [ checkout_library( 'first', 1 ), checkout_library( 'second', 2 ) ] ) },
  'checkout-relative Perl search paths identify identical project libraries';
{
    my @parts;
    for my $number ( 1 .. 2 ) {
        my $root   = "$area/" . ( $number == 1 ? 'first' : 'second' );
        my $config = Test::Mutation::Settings::of_call( { root => $root, shard => "$number/2", cache => $number - 1 } );
        my $result = with_driver_shims(
            sub {
                Test::Mutation::Runner::run( $config, sub { }, { paths => { 'lib/Boundary.pm' => [] } } );
            }
        );
        push @parts, { name => "$number", result => $result };
    }
    ok lives { Test::Mutation::Merge::merge( \@parts ) }, 'both cache modes identify the same file selection';
}
{
    local $ENV{TEST_PROJECT_LIMIT} = 7;
    like dies { compare() }, qr/measurement inputs differ/, 'the test environment binds each measurement';
}
write_file( "$area/second/limit.dat", "5\n" );
like dies { compare() }, qr/measurement inputs differ/, 'data read by the tests belongs to the measurement';
write_file( "$area/second/limit.dat", "4\n" );
write_file( "$library/Defaults.pm",   $external =~ s/\b3\b/2/r );
like dies { compare() }, qr/measurement inputs differ/, 'an external dependency loaded by an uncached run counts';
write_file( "$library/Defaults.pm", $external );

subtest 'standalone compilation uses the same external libraries across shards' => sub {
    my $idle = <<'PERL';
package Idle;
use lib $ENV{TEST_PROJECT_LIBRARY};
use Defaults;
sub small { return $_[0] < Defaults::count() }
sub large { return $_[0] > Defaults::count() }
1;
PERL
    for my $checkout (qw(idle-first idle-second)) {
        write_file( "$area/$checkout/lib/Idle.pm", $idle );
        write_file( "$area/$checkout/t/pass.t",    "use Test::More tests => 1; pass 'ready';\n" );
    }
    my $start = shard( 'idle-first',  1, cache => 1 );
    my $end   = shard( 'idle-second', 2, cache => 1 );
    ok + ( grep { defined $_->{compiled_digest} } $start->{result}->entries->@* ),
      'the first shard compares compiled code';
    ok + ( grep { defined $_->{compiled_digest} } $end->{result}->entries->@* ),
      'the second shard compares compiled code';
    ok lives { Test::Mutation::Merge::merge( [ $start, $end ] ) }, 'equal compiler inputs produce compatible shards';
    write_file( "$library/Defaults.pm", $external =~ s/\b3\b/7/r );
    like dies { Test::Mutation::Merge::merge( [ $start, shard( 'idle-second', 2, cache => 1 ) ] ) },
      qr/measurement inputs differ/, 'a cached shard checks the library loaded only by the compiler';
    like dies { Test::Mutation::Merge::merge( [ $start, shard( 'idle-second', 2 ) ] ) },
      qr/measurement inputs differ/, 'a fresh shard binds the library loaded only by the compiler';
    write_file( "$library/Defaults.pm", $external );
    my $link = "$area/compiler-library";
    local $ENV{TEST_PROJECT_LIBRARY} = $link;
    symlink $library, $link or die $!;
    my $linked = shard( 'idle-second', 2, cache => 1 );
    my $json   = Test::Mutation::Report::Json::render( $linked->{result}, high => 80, low => 60 );
    $linked->{result} = Test::Mutation::Report::Json::parse($json);
    ok lives { Test::Mutation::Merge::merge( [ $linked, shard( 'idle-first', 1, cache => 1 ) ] ) },
      'a report keeps its compiler inputs across a JSON round trip';
    write_file( "$area/replacement/Defaults.pm", $external =~ s/\b3\b/8/r );
    unlink $link or die $!;
    symlink "$area/replacement", $link or die $!;
    like dies { Test::Mutation::Merge::merge( [ $linked, shard( 'idle-first', 1, cache => 1 ) ] ) },
      qr/measurement inputs differ/, 'a cached compiler checks the current target of a library link';
    like dies { Test::Mutation::Merge::merge( [ $linked, shard( 'idle-first', 1 ) ] ) },
      qr/measurement inputs differ/, 'a fresh compiler identifies the library by its search path';
};

subtest 'data opened during compilation identifies cached and merged verdicts' => sub {
    delete local $ENV{PERL5OPT};
    my $idle = <<'PERL';
package Idle;
BEGIN {
    open my $input, '<', $ENV{TEST_PROJECT_TABLE} or die $!;
    my $number = 0 + <$input>;
    close $input or die $!;
    require constant;
    constant->import('LIMIT', $number);
}
sub small { return $_[0] < LIMIT }
sub large { return $_[0] > LIMIT }
1;
PERL
    for my $checkout (qw(data-first data-second)) {
        write_file( "$area/$checkout/lib/Idle.pm", $idle );
        write_file( "$area/$checkout/t/pass.t",    "use Test::More tests => 1; pass 'ready';\n" );
    }
    local $ENV{TEST_PROJECT_TABLE} = "$area/limit";
    write_file( "$area/limit", "3\n" );
    my $prior = shard( 'data-first',  1, cache => 1 );
    my $other = shard( 'data-second', 2, cache => 1 );
    ok + ( grep { defined $_->{compiled_digest} } $other->{result}->entries->@* ),
      'a known input permits code comparison';
    ok lives { Test::Mutation::Merge::merge( [ $prior, $other ] ) }, 'equal external data can be combined';
    subtest 'a preloaded module can make compiler inputs opaque' => sub {
        my $root = "$area/preloaded";
        write_file( "$area/preloads/CompilerSetup.pm",
            q{package CompilerSetup; sub import { $ENV{TEST_PROJECT_PRELOADED} = 'ready' } 1;} );
        delete local $ENV{TEST_PROJECT_PRELOADED};
        local $ENV{PERL5LIB} = join q{:}, "$area/preloads", grep { defined } $ENV{PERL5LIB};
        local $ENV{PERL5OPT} = '-MCompilerSetup';
        write_file( "$root/lib/Idle.pm", $idle );
        write_file( "$root/t/limit.t",   <<'PERL' );
use Test::More tests => 2;
use Idle;
is $ENV{TEST_PROJECT_PRELOADED}, 'ready', 'the project loaded its compiler setup';
ok Idle::small(2) && !Idle::small(3), 'the limit is exclusive';
PERL
        my ($cold) = run_fixture( $root, cache => 1, jobs => 1 );
        is $cold->baseline_failures, [], 'the test observed the preloaded module';
        my @boundary = grep { $_->{mutant}->original eq '<' && $_->{mutant}->replacement eq '>=' } $cold->entries->@*;
        is [ map { [ $_->{status}, $_->{by} ] } @boundary ], [ [ 'Killed', 't/limit.t' ] ],
          'the boundary test detects the reversed comparison';
        ok !( grep { defined $_->{compiled_digest} } $cold->entries->@* ), 'opaque inputs prevent code comparison';
        my ($warm) = run_fixture( $root, cache => 1, jobs => 1 );
        is $warm->reused, 0, 'opaque inputs require another measurement';
    };
    write_file( "$area/limit", "7\n" );
    my $warm = shard( 'data-second', 2, cache => 1 );
    is $warm->{result}->reused, 0, 'changed compiler data invalidates cached verdicts';
    like dies { Test::Mutation::Merge::merge( [ $prior, $warm ] ) }, qr/measurement inputs differ/,
      'a cached shard must agree with the previous external data';
    like dies { Test::Mutation::Merge::merge( [ $prior, shard( 'data-second', 2 ) ] ) }, qr/measurement inputs differ/,
      'a fresh shard must agree with the previous external data';

    $idle =~
      s{(BEGIN \{)\n(    open[^\n]+)\$ENV\{TEST_PROJECT_TABLE\}}{$1\n    my \$path = \$ENV{TEST_PROJECT_TABLE};\n$2\$path};
    for my $checkout (qw(data-first data-second)) {
        write_file( "$area/$checkout/lib/Idle.pm", $idle );
    }
    my $opaque = shard( 'data-first',  1, cache => 1, jobs => 1 );
    my $peer   = shard( 'data-second', 2, cache => 1 );
    is $opaque->{result}->stats->{compiles}, 1, 'an unbound original needs no mutant compilations';
    unlike join( "\n", $opaque->{result}->warnings->@* ), qr/no stable text/,
      'a repeatable compilation with an unknown input has no unstable-output warning';
    is $opaque->{result}->measurement_digest, undef, 'an unidentified input leaves the measurement uncertified';
    ok !( grep { defined $_->{compiled_digest} } $peer->{result}->entries->@* ),
      'an indirect compiler input leaves the observed test verdict in place';
    ok + ( grep { $_->{status} eq 'NoCoverage' } $peer->{result}->entries->@* ),
      'the untouched target keeps its actual lack of test coverage';
    like dies { Test::Mutation::Merge::merge( [ $opaque, $peer ] ) }, qr/measurement inputs are missing/,
      'identical deparses cannot identify an opaque input';
    my @unchecked = map { shard( "data-$_->[0]", $_->[1], equivalence => 0 ) } [ first => 1 ], [ second => 2 ];
    like dies { Test::Mutation::Merge::merge( \@unchecked ) }, qr/measurement inputs are missing/,
      'unidentified compiler inputs prevent a merge without observed deparsed code';
    write_file( "$area/limit", "11\n" );
    my $changed = shard( 'data-second', 2, cache => 1 );
    is $changed->{result}->reused, 0, 'a source with opaque compiler reads is measured again';
    like dies { Test::Mutation::Merge::merge( [ $opaque, $changed ] ) }, qr/measurement inputs are missing/,
      'the changed opaque source still lacks input evidence';
};

subtest 'loaded modules cannot replace the input that a phase block read' => sub {
    delete local $ENV{PERL5OPT};
    local $ENV{TEST_PROJECT_LIBRARY} = "$area/rebind-library";
    local $ENV{TEST_PROJECT_TABLE}   = "$area/before.dat";
    local $ENV{TEST_PROJECT_LATER}   = "$area/after.dat";
    write_file( "$area/before.dat", "3\n" );
    write_file( "$area/after.dat",  "5\n" );
    my $reader = <<'PERL';
package Idle;
use lib $ENV{TEST_PROJECT_LIBRARY};
BEGIN {
    open my $input, '<', $ENV{TEST_PROJECT_TABLE} or die $!;
    my $number = 0 + <$input>;
    close $input or die $!;
    require constant;
    constant->import('LIMIT', $number);
}
use Rebind;
sub small { return $_[0] < LIMIT }
sub large { return $_[0] > LIMIT }
1;
PERL
    for my $checkout (qw(bound-first bound-second)) {
        write_file( "$area/$checkout/lib/Idle.pm", $reader );
        write_file( "$area/$checkout/t/pass.t",    "use Test::More tests => 1; pass 'ready';\n" );
    }
    my $rebind = "$area/rebind-library/Rebind.pm";
    write_file( $rebind, "package Rebind; 1;\n" );
    my $bound = shard( 'bound-second', 2, cache => 1 );
    ok + ( grep { defined $_->{compiled_digest} } $bound->{result}->entries->@* ),
      'a module that leaves the path alone permits comparison';
    ok shard( 'bound-second', 2, cache => 1 )->{result}->reused > 0, 'the stable input permits reuse';

    write_file( $rebind, 'package Rebind; $ENV{TEST_PROJECT_TABLE} = $ENV{TEST_PROJECT_LATER}; 1;' );
    my $prior = shard( 'bound-first',  1, cache => 1 );
    my $peer  = shard( 'bound-second', 2, cache => 1 );
    ok !( grep { defined $_->{compiled_digest} } $peer->{result}->entries->@* ),
      'the final path does not prove which file was read';
    like dies { Test::Mutation::Merge::merge( [ $prior, $peer ] ) }, qr/measurement inputs are missing/,
      'the unverified final binding cannot certify the shards';
    write_file( "$area/before.dat", "13\n" );
    my $warm = shard( 'bound-second', 2, cache => 1 );
    is $warm->{result}->reused, 0, 'the path assigned after the read cannot validate a prior verdict';
    like dies { Test::Mutation::Merge::merge( [ $prior, $warm ] ) }, qr/measurement inputs are missing/,
      'shards with a reassigned binding cannot supply the missing input';

    local $ENV{TEST_PROJECT_ORIGINAL} = $ENV{TEST_PROJECT_TABLE};
    write_file( "$area/rebind-library/SwitchInput.pm",
        'package SwitchInput; sub choose { $ENV{TEST_PROJECT_TABLE} = $ENV{TEST_PROJECT_LATER} } choose; 1;' );
    write_file( $rebind,
        'package Rebind; sub restore { $ENV{TEST_PROJECT_TABLE} = $ENV{TEST_PROJECT_ORIGINAL} } restore; 1;' );
    my $switched = $reader =~ s/^BEGIN/use SwitchInput;\nBEGIN/mr;
    write_file( "$area/$_/lib/Idle.pm", $switched ) for qw(bound-first bound-second);
    my $before_restore = shard( 'bound-first',  1, cache => 1 );
    my $restored       = shard( 'bound-second', 2, cache => 1 );
    ok !( grep { defined $_->{compiled_digest} } $restored->{result}->entries->@* ),
      'restoring the original path cannot prove which file an intervening read used';
    like dies { Test::Mutation::Merge::merge( [ $before_restore, $restored ] ) }, qr/measurement inputs are missing/,
      'an unobserved intermediate binding prevents merging';
    write_file( "$area/after.dat", "17\n" );
    my $changed = shard( 'bound-second', 2, cache => 1 );
    is $changed->{result}->reused, 0, 'the restored path cannot validate results for the intermediate file';
    like dies { Test::Mutation::Merge::merge( [ $before_restore, $changed ] ) }, qr/measurement inputs are missing/,
      'changing the intermediate file cannot validate the missing input';
};

subtest 'a library loaded by the compiler reads an external data file' => sub {
    delete local $ENV{PERL5OPT};
    local $ENV{TEST_PROJECT_LIBRARY} = "$area/data-library";
    local $ENV{TEST_PROJECT_TABLE}   = "$area/imported-limit";
    my $defaults = <<'PERL';
package Defaults;
BEGIN {
    open my $input, '<', $ENV{TEST_PROJECT_TABLE} or die $!;
    my $number = 0 + <$input>;
    close $input or die $!;
    require constant;
    constant->import('count', $number);
}
1;
PERL
    my $idle = <<'PERL';
package Idle;
BEGIN { unshift @INC, $ENV{TEST_PROJECT_LIBRARY} }
use Defaults;
sub small { return $_[0] < Defaults::count() }
sub large { return $_[0] > Defaults::count() }
1;
PERL
    write_file( "$area/$_/lib/Idle.pm",           $idle ) for qw(idle-first idle-second);
    write_file( "$area/imported-limit",           "3\n" );
    write_file( "$area/data-library/Defaults.pm", "package Defaults; sub count () { 3 } 1;\n" );
    my $check_only = "#!$^X\n" . <<'PERL';
die "unexpected deparse\n" if grep { $_ eq '-MO=Deparse' } @ARGV;
exec {$^X} $^X, @ARGV or die $!;
PERL

    for my $checkout (qw(idle-first idle-second)) {
        chmod 0755, write_file( "$area/$checkout/tools/check-perl", $check_only ) or die $!;
    }
    my $simple = shard( 'idle-second', 2 );
    write_file( "$area/data-library/Defaults.pm", $defaults );
    my $prior = shard( 'idle-first',  1, cache => 1 );
    my $other = shard( 'idle-second', 2, cache => 1 );
    ok + ( grep { defined $_->{compiled_digest} } $other->{result}->entries->@* ),
      'a known file in an imported module permits code comparison';
    is $other->{result}->stats->{compiles}, $simple->{result}->stats->{compiles} + 1,
      'only the original needs a second compilation to bind the imported read';
    ok lives { Test::Mutation::Merge::merge( [ $prior, $other ] ) }, 'identical imported constants can merge';
    ok shard( 'idle-second', 2, cache => 1 )->{result}->reused > 0,  'an unchanged imported data file permits reuse';
    my %syntax = ( equivalence => 0, cache => 1, perl => 'tools/check-perl' );
    my $seen   = shard( 'idle-first',  1, %syntax );
    my $next   = shard( 'idle-second', 2, %syntax );
    ok lives { Test::Mutation::Merge::merge( [ $seen, $next ] ) },
      'known equal compiler inputs merge without deparsing';
    ok shard( 'idle-second', 2, %syntax )->{result}->reused > 0, 'a syntax-only observation validates cached verdicts';
    write_file( "$area/imported-limit", "9\n" );
    my $checked = shard( 'idle-second', 2, %syntax );
    is $checked->{result}->reused, 0, 'a syntax-only cache checks the changed input before reuse';
    like dies { Test::Mutation::Merge::merge( [ $seen, $checked ] ) }, qr/measurement inputs differ/,
      'changed compiler inputs cannot merge when equivalence is disabled';
    my $warm = shard( 'idle-second', 2, cache => 1 );
    is $warm->{result}->reused, 0, 'a warm run verifies data read from a compiler dependency';
    like dies { Test::Mutation::Merge::merge( [ $prior, $warm ] ) }, qr/measurement inputs differ/,
      'changed data behind an imported constant rejects a cached shard';
    like dies { Test::Mutation::Merge::merge( [ $prior, shard( 'idle-second', 2 ) ] ) }, qr/measurement inputs differ/,
      'changed data behind an imported constant rejects a fresh shard';

    my $indirect = $defaults =~ s/\$ENV\{TEST_PROJECT_TABLE\}/table()/r;
    $indirect =~ s/^BEGIN/sub table { return \$ENV{TEST_PROJECT_TABLE} }\nBEGIN/m;
    write_file( "$area/data-library/Defaults.pm", $indirect );
    my $before = shard( 'idle-first', 1 );
    ok !( grep { defined $_->{compiled_digest} } $before->{result}->entries->@* ),
      'the unresolved imported read keeps the mutant fingerprints out of comparisons';
    like dies { Test::Mutation::Merge::merge( [ $before, shard( 'idle-second', 2 ) ] ) },
      qr/measurement inputs are missing/, 'an indirect imported read needs a verified input even for equal constants';
    write_file( "$area/imported-limit", "13\n" );
    like dies { Test::Mutation::Merge::merge( [ $before, shard( 'idle-second', 2 ) ] ) },
      qr/measurement inputs are missing/, 'a changed constant cannot certify an unidentified imported input';
    write_file( "$area/data-library/Defaults.pm", $defaults );
    write_file( "$area/idle-first/lib/Idle.pm", $idle =~ s/use Defaults;/use ApplicationContext ();\nuse Defaults;/r );
    write_file( "$area/idle-first/t/pass.t",    <<'PERL' );
use Test::More tests => 1;
BEGIN { $INC{'ApplicationContext.pm'} = __FILE__ }
use Idle;
ok Idle::small(1);
PERL
    my $incomplete = shard( 'idle-first', 1, %syntax )->{result};
    is $incomplete->baseline_failures,  [],    'the test supplies the application context required to load the source';
    is $incomplete->measurement_digest, undef, 'a failed syntax check cannot certify a partial compiler input record';
};

my $wrapped = shard( 'first', 1, perl => 'tools/perl' );
ok lives { Test::Mutation::Merge::merge( [ $wrapped, shard( 'second', 2, perl => 'tools/perl' ) ] ) },
  'identical project-relative interpreters work in separate checkouts';
write_file( "$area/second/tools/perl", "#!$^X\n# another launcher\nexec {q{$^X}} q{$^X}, \@ARGV or die \$!;\n" );
like dies { Test::Mutation::Merge::merge( [ $wrapped, shard( 'second', 2, perl => 'tools/perl' ) ] ) },
  qr/measurement inputs differ/, 'changing a launcher changes the measured environment';

done_testing;
