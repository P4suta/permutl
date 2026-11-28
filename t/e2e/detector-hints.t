use v5.36;
use Test2::V0;
use File::Temp ();
use lib 't/e2e/lib', 't/lib';
use Capability;
use Fixture qw(write_file);
use Test::Mutation::Runner;
use Test::Mutation::Settings;
use Test::Mutation::Source;

my $use_number = "use Test::More tests => 1;\nuse Number;\nmy \$number = Number::next_number(2);\n";
my $weak       = $use_number . "pass 'the call completed';\n";
my $strong     = $use_number . "is \$number, 3, 'the next number';\n";

sub project (%tests) {
    my $root = File::Temp::tempdir( CLEANUP => 1 );
    write_file( "$root/lib/Number.pm", "package Number;\nsub next_number { return \$_[0] + 1 }\n1;\n" );
    write_file( "$root/$_",            $tests{$_} ) for sort keys %tests;
    return $root;
}

sub config ( $root, %settings ) {
    return Test::Mutation::Settings::of_call( { root => $root, jobs => 1, cache => 0, equivalence => 0, %settings } );
}

sub arithmetic_id ($config) {
    my ($addition) = grep { $_->original eq '+' } Test::Mutation::Runner::analyze($config)->{mutants}->@*;
    return $addition->id;
}

sub entry ( $result, $id ) {
    my ($match) = grep { $_->{mutant}->id eq $id } $result->entries->@*;
    return $match;
}

sub measure ( $config, $options = {} ) {
    my $next_test = \&Test::Mutation::Runner::_next_test;    ## no critic (Variables::ProtectPrivateVars)
    my %attempts;
    no warnings 'redefine';
    local *Test::Mutation::Runner::_next_test = sub ( $run, $job, $baseline ) {    ## no critic (Variables::ProtectPrivateVars)
        my $task = $next_test->( $run, $job, $baseline ) or return;
        my $test = $task->{payload}{test};
        my $id   = $job->{mutant}->id;
        die "$test ran more than twice for $id" if ++$attempts{$id}{$test} > 2;
        return $task;
    };
    return Test::Mutation::Runner::run( $config, sub { }, $options );
}

subtest 'a suggested detector must kill the current mutant in a fresh measurement' => sub {
    my $root = project( 't/a.t' => $weak, 't/z.t' => $strong );
    write_file( "$root/mutation.toml", qq{source = ["lib/**/*.pm"]\n} );
    my $config = config($root);
    my $id     = arithmetic_id($config);
    my $result = measure( $config, { detector_hints => { $id => 't/z.t' } } );
    my $found  = entry( $result, $id );
    is $result->stats->{baseline_tests},       2, 'the original tests ran in the current checkout';
    is $result->reused,                        0, 'the measurement reused no verdict';
    is [ $found->@{qw(status by tests_run)} ], [ 'Killed', 't/z.t', 1 ], 'only the proposed detector ran on the mutant';
    is $found->{covered_by},                   [qw(t/a.t t/z.t)], 'the report retains all current covering tests';
    like $found->{observations}, [ [ hash { field test => 't/z.t'; field result => 'fail'; field served => 1; etc } ] ],
      'the changed target was served to the test that failed';

    write_file( "$root/t/z.t", $use_number . "is \$number, 4, 'the original is broken';\n" );
    my $broken = measure( $config, { detector_hints => { $id => 't/z.t' } } );
    is [ map { $_->{test} } $broken->baseline_failures->@* ], ['t/z.t'], 'the original assertion now fails';
    is $broken->entries, [], 'the former detector supplies no verdict after the original fails';
};

subtest 'only a later covering test needs a separate detector trial' => sub {
    my $root   = project( 't/a.t' => $weak, 't/m.t' => "use Test::More tests => 1;\npass;\n", 't/z.t' => $strong );
    my $config = config($root);
    my $id     = arithmetic_id($config);
    for my $hint (qw(t/deleted.t t/m.t t/a.t)) {
        my $result = measure( $config, { detector_hints => { $id => $hint } } );
        my $found  = entry( $result, $id );
        is [ map { $_->{test} } $found->{observations}[0]->@* ], [qw(t/a.t t/z.t)],
          "$hint leaves the current covering order intact";
        is $result->stats->{verifications}, 0, "$hint started no extra trial";
    }
};

subtest 'a stale detector that passes leaves the usual test order and workspace intact' => sub {
    my $root = project(
        't/a.t' => $use_number . "ok !-e 'from-hint', 'the test starts from the baseline';\n",
        't/b.t' => $strong,
        't/z.t' => $use_number . <<'PERL',
if (!defined($number) || $number != 3) {
    open my $marker, '>', 'from-hint' or die $!;
    close $marker or die $!;
}
pass 'the obsolete detector accepts the change';
PERL
    );
    my $config = config($root);
    my $id     = arithmetic_id($config);
    my $result = measure( $config, { detector_hints => { $id => 't/z.t' } } );
    my $found  = entry( $result, $id );
    is [ $found->@{qw(status by)} ], [ 'Killed', 't/b.t' ], 'the current assertion determines the verdict';
    is [ map { $_->{test} } $found->{observations}[0]->@* ], [qw(t/a.t t/b.t)],
      'the ordinary measurement starts again at the first covering test';

    my $restore   = \&Test::Mutation::Tree::restore;
    my $discarded = 0;
    no warnings 'redefine';
    local *Test::Mutation::Tree::restore = sub (%args) {
        if ( grep { $_ eq 'created from-hint' } $args{changes}->@* ) {
            $discarded++;
            die "the candidate test copy cannot be restored\n";
        }
        return $restore->(%args);
    };
    my $retry = measure( $config, { detector_hints => { $id => 't/z.t' } } );
    is $discarded,                 1,       'the changed copy was retired';
    is entry( $retry, $id )->{by}, 't/b.t', 'the ordinary tests obtained a clean replacement copy';
};

subtest 'a suggested detector may precede parallel tests and must wait for serial tests' => sub {
    for my $rule ( [ par => 't/z.t' ], [ seq => 't/a.t' ], ) {
        my ( $mode, $first ) = @$rule;
        my $root = project(
            'testrules.yml' => "---\n$mode:\n  - 't/a.t'\n  - 't/z.t'\n",
            't/a.t'         => $strong,
            't/z.t'         => $strong,
        );
        my $config = config($root);
        my $id     = arithmetic_id($config);
        my $result = measure( $config, { detector_hints => { $id => 't/z.t' } } );
        is entry( $result, $id )->{by}, $first, "$mode selects an eligible detector";
    }
};

subtest 'overlapping detectors that leave unrestorable copies fall back to the covering tests' => sub {
    my $root = project(
        't/a.t' => $use_number . "ok !-e 'from-hint', 'the covering test starts in a clean copy';\n",
        't/b.t' => $strong,
        't/z.t' => $use_number . <<'PERL',
if (!defined($number) || $number != 3) {
    open my $marker, '>', 'from-hint' or die $!;
    close $marker or die $!;
}
is $number, 3, 'the suggested test detects the change';
PERL
    );
    my $config    = config( $root, jobs => 4 );
    my %hints     = map { $_->id => 't/z.t' } Test::Mutation::Runner::analyze($config)->{mutants}->@*;
    my $restore   = \&Test::Mutation::Tree::restore;
    my $discarded = 0;
    no warnings 'redefine';
    local *Test::Mutation::Tree::restore = sub (%args) {
        if ( grep { $_ eq 'created from-hint' } $args{changes}->@* ) {
            $discarded++;
            die "the detector copy cannot be restored\n";
        }
        return $restore->(%args);
    };
    my $result = measure( $config, { detector_hints => \%hints } );
    my $found  = entry( $result, arithmetic_id($config) );
    ok $discarded >= 2, 'the failing detectors left separate copies to discard';
    is [ $found->@{qw(status by tests_run)} ], [ 'Killed', 't/b.t', 2 ],
      'the normal assertion decides from a clean copy';
    is [ map { $_->{test} } $found->{observations}[0]->@* ], [qw(t/a.t t/b.t)],
      'the discarded detector supplies no observation';
};

subtest 'a suggested test that times out preserves the ordinary two-timeout budget' => sub {
    my $log = File::Temp->new;
    local $ENV{DETECTOR_ATTEMPTS} = $log->filename;
    my $stall = $use_number . <<'PERL';
if (defined($number) && $number == 1) {
    open my $tried, '>>', $ENV{DETECTOR_ATTEMPTS} or die $!;
    print {$tried} "$0\n";
    close $tried or die $!;
    sleep 30;
}
pass 'the original finishes';
PERL
    my $root   = project( 't/a.t' => $stall, 't/b.t' => $strong, 't/z.t' => $stall );
    my $config = config( $root, timeout_floor => 0.6, timeout_factor => 4 );
    my $id     = arithmetic_id($config);
    my $result = measure( $config, { detector_hints => { $id => 't/z.t' } } );
    my $found  = entry( $result, $id );
    like Test::Mutation::Source::read_bytes( $log->filename ), qr{t/z[.]t\n[^\n]*t/a[.]t\n},
      'the suggested timeout was followed by the first ordinary test';
    is [ $found->@{qw(status by tests_run)} ], [ 'Killed', 't/b.t', 2 ], 'the ordinary assertion retains its turn';
    is [ map { [ $_->@{qw(test result)} ] } $found->{observations}[0]->@* ],
      [ [ 't/a.t', 'timeout' ], [ 't/b.t', 'fail' ] ], 'only ordinary observations determine the fallback verdict';
    is $result->stats->{verifications}, 1, 'the discarded trial is included in verification work';

    write_file( "$root/t/b.t", $stall );
    write_file( "$root/t/z.t", $strong );
    my $ordinary = measure($config);
    is entry( $ordinary, $id )->{status}, 'Timeout', 'the first two ordinary tests exhaust their time limits';
    my $confirmed = measure( $config, { detector_hints => { $id => 't/z.t' } } );
    is [ entry( $confirmed, $id )->@{qw(status by tests_run)} ], [ 'Killed', 't/z.t', 1 ],
      'the current failing assertion can decide before both slow tests';
};

subtest 'a suggested test without a target witness leaves the verdict to the ordinary tests' => sub {
    my $child = <<'PERL';
use Test::More tests => 1;
%ENV = ();
my $status = system $^X, '-T', '-Ilib', '-e', 'require Number; exit(Number::next_number(2) == 3 ? 0 : 1)';
is $status, 0, 'the child computes three';
PERL
    my $root   = project( 't/a.t' => $strong, 't/z.t' => $child );
    my $config = config( $root, in_place => 1 );
    my $id     = arithmetic_id($config);
    my $result = measure( $config, { detector_hints => { $id => 't/z.t' } } );
    my $found  = entry( $result, $id );
    is $found->{covered_by},                   [qw(t/a.t t/z.t)],        'the original child reached the target';
    is [ $found->@{qw(status by tests_run)} ], [ 'Killed', 't/a.t', 1 ], 'the test that received the change decides';
};

subtest 'cache use, shards, and named reruns keep ordinary detector order' => sub {
    my $root = project( 't/a.t' => $strong, 't/z.t' => $strong );
    my $id   = arithmetic_id( config($root) );
    for my $settings ( { cache => 1 }, { shard => '1/1' }, { mutant => [$id] } ) {
        my $result =
          measure( config( $root, %$settings ), { detector_hints => { $id => 't/z.t' } } );
        is entry( $result, $id )->{by}, 't/a.t', 'the first covering test decides with ' . ( keys %$settings )[0];
    }
    my $scope    = config($root);
    my $selected = Test::Mutation::Select::resolve( config => $scope, identifiers => [$id] );
    for my $filter ( { paths => { 'lib/Number.pm' => [] } }, { selection => $selected } ) {
        my $result = measure( $scope, { %$filter, detector_hints => { $id => 't/z.t' } } );
        is entry( $result, $id )->{by}, 't/a.t', 'an explicit source or preselected inventory keeps the ordinary order';
    }
    my $empty =
      measure( config( $root, cache => 1, undetected => 1 ), { detector_hints => { $id => 't/z.t' } } );
    is $empty->entries, [], 'an empty historical selection stays empty';
};

subtest 'a revision filter keeps ordinary covering test order' => sub {
    Capability::need( 'git', length qx{git --version 2>/dev/null}, 'the selection needs Git' );
    my $root = project( 't/a.t' => $strong, 't/z.t' => $strong );
    my @git  = (
        'git',                             '-C', $root,            '-c',
        'core.hooksPath=/dev/null',        '-c', 'user.name=Test', '-c',
        'user.email=test@example.invalid', '-c', 'commit.gpgsign=false'
    );
    system( @git, 'init', '-q' ) == 0  or die 'git init failed';
    system( @git, 'add',  'lib' ) == 0 or die 'git add failed';
    system( @git, 'commit', '-qm', 'fixture' ) == 0 or die 'git commit failed';
    my $file = "$root/lib/Number.pm";
    write_file( $file, Test::Mutation::Source::read_bytes($file) =~ s/return /return  /r );
    my $config = config( $root, since => 'HEAD' );
    my $id     = arithmetic_id($config);
    my $result = measure( $config, { detector_hints => { $id => 't/z.t' } } );
    is entry( $result, $id )->{by}, 't/a.t', 'the ordinary test detected the change on the selected line';
};

subtest 'the restored original must pass before an in-place detector decides' => sub {
    my $external = File::Temp::tempdir( CLEANUP => 1 );
    local $ENV{DETECTOR_STATE} = "$external/state";
    my $detector = $use_number . <<'PERL';
if (defined($number) && $number == 1) {
    for my $path ('from-detector', $ENV{DETECTOR_STATE}) {
        open my $marker, '>', $path or die $!;
        close $marker or die $!;
    }
}
ok !-e $ENV{DETECTOR_STATE}, 'the shared fixture was empty';
PERL
    my $root   = project( 't/a.t' => $strong, 't/z.t' => $detector );
    my $config = config( $root, in_place => 1 );
    my $id     = arithmetic_id($config);
    my $result = measure( $config, { detector_hints => { $id => 't/z.t' } } );
    ok -e $ENV{DETECTOR_STATE}, 'the suggested test also fails against the restored original';
    is [ entry( $result, $id )->@{qw(status by)} ], [ 'Killed', 't/a.t' ],
      'the independent assertion detects the change';
};

done_testing;
