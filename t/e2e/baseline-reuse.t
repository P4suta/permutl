use v5.36;
use Test2::V0;
use Digest::SHA ();
use File::Temp  ();
use lib 't/e2e/lib';
use Fixture qw(ran run_fixture with_driver_shims write_file);
use Test::Mutation::Error;
use Test::Mutation::Report::Json;
use Test::Mutation::Store;
use Test::Mutation::Store::Key;
use Test::Mutation::Runner;
use Test::Mutation::Settings;

my $root = File::Temp::tempdir( CLEANUP => 1 );
for my $name (qw(One Two)) {
    write_file( "$root/lib/$name.pm", "package $name;\nsub amount { return \$_[0] + 1 }\n1;\n" );
    write_file( "$root/t/$name.t",    "use $name;\nuse Test::More tests => 1;\nis " . $name . "::amount(2), 3;\n" );
}
write_file( "$root/t/neutral.t", "use Test::More tests => 1;\npass 'the distribution metadata is valid';\n" );
my $config = Test::Mutation::Settings::of_call( { root => $root, jobs => 1, equivalence => 0 } );

my ( @phases, @baselines );

sub original () {
    @phases    = ();
    @baselines = ();
    my $listener = sub ( $event, $data ) {
        push @phases,    $data->{name}                if $event eq 'phase';
        push @baselines, [ $data->@{qw(tests jobs)} ] if $event eq 'baseline';
        return;
    };
    return with_driver_shims( sub { Test::Mutation::Runner::run( $config, $listener, { baseline_only => 1 } ) } );
}

my $cold = original();
is $cold->stats->{baseline_tests}, 3, 'a cold baseline measures each original test';
is [ map { $_->{name} } grep { $_->{neutral} } $cold->tests->@* ], ['t/neutral.t'],
  'the independent test contributes a neutral observation';
my $warm = original();
is [ $warm->stats->@{qw(baseline_tests copies walks spawns)} ], [ 0, 0, 0, 0 ],
  'the stored observations answer an unchanged baseline before any workspace work';
is \@phases,    [qw(resolve analyze plan conclude release)], 'a fully cached baseline concludes during planning';
is \@baselines, [ [ 3, 1 ] ], 'the listener receives the original test count and job count on a fully cached baseline';
my $json = Test::Mutation::Report::Json::render( $warm, high => 80, low => 60 );
is Test::Mutation::Report::Json::parse($json)->tests, $cold->tests, 'a report preserves the neutral test';
is $warm->tests, $cold->tests, 'the cached observations retain names, durations and coverage roles';

subtest 'an unreadable fingerprint forces every original test to run' => sub {
    no warnings 'redefine';
    local *Test::Mutation::Store::Key::tree = sub {
        Test::Mutation::Error::raise( 'file-unreadable', path => 'support', reason => 'input disappeared' );
    };
    my $checked = original();
    is $checked->stats->{baseline_tests}, 3, 'the known passing tests run again when their shared input is unavailable';
    is [ map { $_->{name} } $checked->tests->@* ], [qw(t/One.t t/Two.t t/neutral.t)],
      'all measured tests reach the report';
};

write_file( "$root/t/One.t", "use One;\nuse Test::More tests => 1;\nis One::amount(3), 4;\n" );
is original()->stats->{baseline_tests}, 1, 'changing one test invalidates only its own passing fact';
write_file( "$root/lib/Two.pm", "package Two;\nsub amount { return 1 + \$_[0] }\n1;\n" );
is original()->stats->{baseline_tests}, 1, 'changing a target invalidates only a test that compiled it';
write_file( "$root/support.txt", "new project data\n" );
is original()->stats->{baseline_tests}, 3, 'a project input shared by every test invalidates the entire baseline';

my ($measured) = run_fixture( $root, jobs => 1, equivalence => 0 );
is $measured->stats->{baseline_tests}, 0, 'a mutation run can consume facts from the baseline command';
ok !grep( { $_->{status} ne 'Killed' } $measured->entries->@* ), 'the cached coverage selects the detecting tests';
my ($again) = run_fixture( $root, jobs => 1, equivalence => 0 );
is $again->stats->{baseline_tests}, 0, 'verdict sampling uses the passing original facts';
cmp_ok $again->stats->{verifications}, '>=', 3, 'a warm run still measures its verdict sample';

subtest 'a new setup effect invalidates a cached passing neighbor' => sub {
    my $project = File::Temp::tempdir( CLEANUP => 1 );
    write_file( "$project/lib/Input.pm",  "package Input;\nsub value { 1 + 2 }\n1;\n" );
    write_file( "$project/t/01-setup.t",  "use Test::More tests => 1;\npass 'setup';\n" );
    write_file( "$project/t/02-reader.t", <<'PERL' );
use Test::More tests => 1;
use Input;
ok !-e 'changed-input', 'the setup leaves the input alone';
PERL
    my $settings = Test::Mutation::Settings::of_call( { root => $project, jobs => 1 } );
    my @finished;
    my $baseline = sub {
        @finished = ();
        my $progress = sub ( $event, $data ) {
            push @finished, $data if $event eq 'baseline_finished';
            return;
        };
        return Test::Mutation::Runner::run( $settings, $progress, { baseline_only => 1 } );
    };
    is $baseline->()->baseline_failures,       [], 'both original tests pass before the edit';
    is $baseline->()->stats->{baseline_tests}, 0,  'both passing observations are available';
    write_file( "$project/t/01-setup.t", <<'PERL' );
use Test::More tests => 1;
open my $out, '>', 'changed-input' or die $!;
close $out or die $!;
pass 'setup';
PERL
    my $result = $baseline->();
    is \@finished, [ { failures => $result->baseline_failures } ],
      'the progress event includes the observed failure before measurement stops';
    is [ map { $_->{test} } $result->baseline_failures->@* ], ['t/02-reader.t'],
      'the untouched consumer now fails when the original tests run together';
    is $result->stats->{baseline_tests}, 3, 'the trial of the changed test triggers a fresh run of the pair';
    ok !-e "$project/changed-input", 'trial and baseline artifacts stay inside their copies';
    is Test::Mutation::Store::originals("$project/.mutation/measurement.sqlite")->{tests}, {},
      'a failing original suite removes every stored passing observation';
    is $baseline->()->stats->{baseline_tests}, 2, 'a failed baseline invalidates the old passing observations';
};

subtest 'a cache mismatch measures the original again before publishing verdicts' => sub {
    for my $expected ( 3, 99 ) {
        my $parent  = File::Temp::tempdir( CLEANUP => 1 );
        my $project = "$parent/project";
        local $ENV{SAMPLE_REQUIREMENT} = "$parent/expected";
        write_file( "$project/lib/Value.pm", "package Value;\nsub plus { return \$_[0] + 1 }\n1;\n" );
        write_file( "$project/lib/Rule.pm",  "package Rule;\n1;\n" );
        write_file( "$project/t/value.t",    <<'PERL' );
use strict;
use warnings;
use Value;
use Test::More tests => 1;
my $actual = Value::plus(2);
if (-e $ENV{SAMPLE_REQUIREMENT}) {
    require Rule;
    open my $rule, '<', $ENV{SAMPLE_REQUIREMENT} or die $!;
    chomp(my $expected = <$rule>);
    close $rule or die $!;
    is $actual, $expected, 'the current requirement';
} else {
    pass 'the value was computed';
}
PERL
        my $measure           = sub { return ( run_fixture( $project, jobs => 1, equivalence => 0 ) )[0] };
        my $first_measurement = $measure->();
        my $count             = scalar $first_measurement->entries->@*;
        ok $count > 0, 'the project has measurable changes';
        is [ map { $_->{status} } $first_measurement->entries->@* ], [ ('Survived') x $count ],
          'the first run caches the survivors';

        write_file( $ENV{SAMPLE_REQUIREMENT}, "$expected\n" );
        my $rechecked = $measure->();
        ok $rechecked->cache_mismatch, 'the changed requirement invalidates the sampled verdict';
        is $rechecked->stats->{baseline_tests}, 1, 'the previously cached original runs again';
        if ( $expected == 99 ) {
            is [ map { $_->{test} } $rechecked->baseline_failures->@* ], ['t/value.t'],
              'the result publishes the new failure of the original';
            is $rechecked->entries, [], 'a failing original produces an empty list of measured verdicts';
            next;
        }
        is [ map { $_->{status} } $rechecked->entries->@* ], [ ('Killed') x $count ],
          'the passing original validates the new detections';
        my $facts = Test::Mutation::Store::originals("$project/.mutation/measurement.sqlite");
        ok exists $facts->{tests}{'t/value.t'}{files}{'lib/Rule.pm'},
          'the fresh observation records the new dependency';
        my $reused_result = $measure->();
        is $reused_result->stats->{baseline_tests}, 0,      'the new passing original can be reused';
        is $reused_result->reused,                  $count, 'the measured verdicts use the new dependency key';
    }
};

subtest 'a passing test that prepares files executes again with its consumers' => sub {
    my $project = File::Temp::tempdir( CLEANUP => 1 );
    write_file( "$project/lib/Needed.pm", "package Needed;\nsub count { 1 + 2 }\n1;\n" );
    write_file( "$project/t/01-setup.t",  <<'PERL' );
use Test::More tests => 1;
open my $file, '>', 'built-data' or die $!;
close $file or die $!;
pass 'prepared the data';
PERL
    write_file( "$project/t/02-reader.t", "use Test::More tests => 1;\nuse Needed;\nok -f 'built-data';\n" );
    my $settings = Test::Mutation::Settings::of_call( { root => $project, jobs => 1 } );
    for ( 1 .. 2 ) {
        my $result = Test::Mutation::Runner::run( $settings, sub { return }, { baseline_only => 1 } );
        is $result->baseline_failures,       [], 'the consumer finds the prepared artifact';
        is $result->stats->{baseline_tests}, 2,  'the new workspace needs both tests in order';
    }
};

subtest 'a test that verifies its module bytes needs a fresh uninstrumented observation' => sub {
    my $project = File::Temp::tempdir( CLEANUP => 1 );
    my $module  = "package Integrity;\nsub total { return \$_[0] + 1 }\n1;\n";
    write_file( "$project/lib/Integrity.pm", $module );
    write_file( "$project/t/integrity.t", sprintf <<'PERL', Digest::SHA::sha256_hex($module) );
use Test::More tests => 2;
use Digest::SHA;
use Integrity;
open my $source, '<:raw', 'lib/Integrity.pm' or die $!;
my $digest = Digest::SHA->new(256)->addfile($source)->hexdigest;
is $digest, '%s', 'the original source has its published bytes';
close $source or die $!;
is Integrity::total(2), 3;
PERL
    my $settings = Test::Mutation::Settings::of_call( { root => $project, jobs => 1 } );
    for ( 1 .. 2 ) {
        my $result = Test::Mutation::Runner::run( $settings, sub { return }, { baseline_only => 1 } );
        is [ map { $_->{output} . $_->{errors} } $result->baseline_failures->@* ], [],
          'the source integrity test passes on the original bytes';
        is $result->stats->{baseline_tests}, 1, 'each run observes the original test again';
        ok $result->stats->{verifications} > 0, 'each run confirms which source the test can measure';
    }
};

subtest 'an in-place cached baseline still verifies the age of a build product' => sub {
    my $project = File::Temp::tempdir( CLEANUP => 1 );
    my $source  = "package Built;\nsub answer { return 42 }\n1;\n";
    write_file( "$project/.proverc",          "-b\n" );
    write_file( "$project/lib/Built.pm",      $source );
    write_file( "$project/blib/lib/Built.pm", $source );
    write_file( "$project/t/built.t",         "use Test::More tests => 1;\nuse Built;\nis Built::answer(), 42;\n" );
    utime 2000, 2000, "$project/lib/Built.pm"      or die "utime: $!";
    utime 3000, 3000, "$project/blib/lib/Built.pm" or die "utime: $!";
    my $settings = Test::Mutation::Settings::of_call( { root => $project, jobs => 1, in_place => 1 } );
    my $measure  = sub {
        return Test::Mutation::Runner::run( $settings, sub { return }, { baseline_only => 1 } );
    };
    is $measure->()->stats->{baseline_tests}, 1, 'the first run measures the original test';
    is $measure->()->stats->{baseline_tests}, 0, 'the unchanged product can reuse its passing test';
    utime 1000, 1000, "$project/blib/lib/Built.pm" or die "utime: $!";
    like dies { $measure->() }, qr{blib/lib/Built[.]pm.*make},
      'the stale product is rejected before a cached result can pass';
};

done_testing;
