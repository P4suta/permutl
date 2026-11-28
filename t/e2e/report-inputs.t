use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use lib 't/lib';
use Capability;
use lib 't/e2e/lib';
use Fixture qw(copy_of run_fixture write_file);
use Test::Mutation::Merge;
use Test::Mutation::Report::Json;
use Test::Mutation::Report::Publication;
use Digest::SHA ();

my $root = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
write_file( "$root/lib/Calc.pm", <<'PERL' );
package Calc;
sub add { my ( $left, $right ) = @_; return $left + $right }
1;
PERL
write_file( "$root/t/add.t", <<'PERL' );
use Test::More tests => 1;
use JSON::PP;
use Calc;
open my $input, '<:raw', 'spec/mutation.json' or die $!;
my $operand = decode_json( readline $input )->{operand};
is Calc::add( 4, $operand ), 4 + $operand, 'adds the operand from the specification';
PERL

sub specification ($value) {
    write_file( "$root/spec/mutation.json", qq[{"framework":{"name":"Test::Mutation"},"operand":$value}] );
    return;
}

sub subtraction ($result) {
    my ($entry) = grep { $_->{mutant}->original eq q{+} && $_->{mutant}->replacement eq q{-} } $result->entries->@*;
    return $entry->{status};
}

specification(0);
my ($before) = run_fixture( $root, cache => 1 );
is subtraction($before), 'Survived', 'adding zero and subtracting zero agree';
my ($first) = run_fixture( $root, cache => 0, shard => '1/2' );
specification(1);
my ($after) = run_fixture( $root, cache => 1 );
is subtraction($after), 'Killed', 'an edited specification changes the cached verdict';
my ($changed_part) = run_fixture( $root, cache => 0, shard => '2/2' );
my @parts = ( { name => 'one', result => $first }, { name => 'two', result => $changed_part } );
like dies { Test::Mutation::Merge::merge( \@parts ) }, qr/measurement inputs differ/,
  'parts measured with different operand data cannot form a single result';

subtest 'an in-place test can read project inputs inside the chosen report directory' => sub {
    my %settings = ( in_place => 1, report_dir => 'spec', jobs => 1 );
    specification(0);
    my ($cached) = run_fixture( $root, cache => 1, %settings );
    my ($part)   = run_fixture( $root, cache => 0, shard => '1/2', %settings );
    is subtraction($cached), 'Survived', 'the in-place test reads its operand from the report directory';
    specification(1);
    my ($rechecked) = run_fixture( $root, cache => 1, %settings );
    is subtraction($rechecked), 'Killed', 'changing a visible operand invalidates the in-place verdict';
    my ($new_part) = run_fixture( $root, cache => 0, shard => '2/2', %settings );
    my @pieces = ( { name => 'before', result => $part }, { name => 'after', result => $new_part } );
    like dies { Test::Mutation::Merge::merge( \@pieces ) }, qr/measurement inputs differ/,
      'in-place shards cannot merge observations from different operands in the report directory';
};

subtest 'isolated tests see the same inputs before and after a report is published' => sub {
    my $previous = "$root/history/part";
    my $program  = <<'PERL';
use Test::More tests => 1;
use Calc;
my $operand = -d 'history/part' ? 1 : 0;
is Calc::add( 4, $operand ), 4 + $operand, 'the project directory determines the operand';
PERL
    write_file( "$root/t/history.t", $program );
    my %settings = ( test => ['t/history.t'], cache => 0 );
    my ($before_report) = run_fixture( $root, %settings );
    run_fixture( $root, %settings, cache => 1 );
    my $report = Test::Mutation::Report::Json::render( $before_report, high => 80, low => 60 );
    write_file( "$previous/mutation.json", $report );
    Test::Mutation::Report::Publication::record( $root, $previous,
        { 'mutation.json' => Digest::SHA::sha256_hex($report) } );
    my ($published) = run_fixture( $root, %settings );
    is $published->measurement_digest, $before_report->measurement_digest, 'the only new files are generated reports';
    is subtraction($published), subtraction($before_report), 'a reported directory cannot change an isolated verdict';
    my ($cached) = run_fixture( $root, %settings, cache => 1 );
    ok $cached->reused, 'a published directory hidden from the tests preserves the earlier cached verdicts';
    my ($visible) = run_fixture( $root, %settings, in_place => 1, jobs => 1 );
    is subtraction($visible), 'Killed', 'an in-place test can observe the actual report directory';
    my ($linked) = run_fixture( $root, %settings, link => ['history'] );
    is subtraction($linked), 'Killed', 'a directory explicitly linked to the project keeps its published reports';
    subtest 'an unreadable project link leaves the published report outside an isolated copy' => sub {
        Capability::has( 'unprivileged', $> != 0, 'the project link must be unreadable' ) or return;
        my $private = write_file( "$root/private-input", "unused\n" );
        chmod 0, $private or die "protect $private: $!";
        my ($uncertified) = run_fixture( $root, %settings, link => ['private-input'] );
        unlink $private or die "remove $private: $!";
        is $uncertified->baseline_failures,  [],         'the original test can run without reading the linked input';
        is $uncertified->measurement_digest, undef,      'the unreadable input prevents shard certification';
        is subtraction($uncertified),        'Survived', 'writing a report cannot change the operand in the test copy';
    };
    symlink 'history/part/mutation.json', "$root/operand.json" or die "link input: $!";
    write_file( "$root/t/linked.t", <<'PERL' );
use Test::More tests => 1;
use JSON::PP;
use Calc;
open my $input, '<:raw', 'operand.json' or die $!;
local $/;
my $operand = decode_json( readline $input )->{framework}{name} eq 'Test::Mutation' ? 1 : 0;
is Calc::add( 4, $operand ), 4 + $operand, 'a linked report supplies the operand';
PERL
    my ($alias) = run_fixture( $root, %settings, test => ['t/linked.t'] );
    is subtraction($alias), 'Killed', 'a relative symlink to the published bytes keeps its target in the copy';
    unlink "$root/operand.json" or die "unlink input: $!";
    write_file( "$previous/operand", 'data' );
    my ($ordinary) = run_fixture( $root, %settings );
    isnt $ordinary->measurement_digest, $published->measurement_digest, 'a regular sibling remains a project input';
    is subtraction($ordinary),          'Killed', 'the copy keeps a report directory containing other inputs';
};

subtest 'a shard verifies the prepared inputs before running a test' => sub {
    for my $case (
        [ 'copy_started',  't/add.t' ],
        [ 'copy_started',  'spec/operand' ],
        [ 'copy_finished', 't/add.t' ],
        [ 'copy_finished', 'spec/added' ],
      )
    {
        my ( $event, $path ) = @$case;
        my $project = copy_of('calc');
        write_file( "$project/spec/operand", 'zero' );
        my @events;
        my $error = dies {
            Test::Mutation::run(
                root     => $project,
                shard    => '1/2',
                cache    => 0,
                jobs     => 1,
                on_event => sub ( $name, $data ) {
                    push @events, $name;
                    return unless $name eq $event;
                    my $directory = $event eq 'copy_started' ? $project : $data->{root};
                    write_file( "$directory/$path",
                        $path eq 't/add.t' ? "use Test::More tests => 1;\npass;\n" : 'edit' );
                    return;
                }
            );
        };
        like $error, qr/measurement inputs changed/, "$event rejects the changed $path";
        ok !grep( { $_ eq 'baseline_test' || $_ eq 'mutant_test' } @events ), 'the unverified copy runs no test';
    }
};

subtest 'cache entries describe the input bytes actually run in the copy' => sub {
    specification(0);
    my %settings     = ( root => $root, cache => 1, test => ['t/add.t'], jobs => 1 );
    my $first_result = Test::Mutation::run(
        %settings,
        on_event => sub ( $name, $data ) {
            specification(1) if $name eq 'copy_finished';
            return;
        }
    );
    is subtraction($first_result), 'Survived', 'the first measurement used the copied zero';
    my $baseline = Test::Mutation::Runner::run(
        Test::Mutation::Settings::of_call( \%settings ),
        sub (@) { return },
        { baseline_only => 1 }
    );
    is $baseline->stats->{baseline_tests}, 1, 'the passing original for zero cannot be reused for one';
    my $later = Test::Mutation::run(%settings);
    is subtraction($later), 'Killed', 'the later measurement of one cannot reuse the old subtraction verdict';
    for my $relative (qw(t/add.t lib/Calc.pm)) {
        my %fresh = ( %settings, cache_dir => Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) ) );
        my $path  = "$root/$relative";
        my $bytes = Test::Mutation::Source::read_bytes($path);
        Test::Mutation::run(
            %fresh,
            on_event => sub ( $name, $data ) {
                write_file( $path, "$bytes\n# changed checkout\n" ) if $name eq 'copy_finished';
                return;
            }
        );
        my $current = Test::Mutation::Runner::run(
            Test::Mutation::Settings::of_call( \%fresh ),
            sub (@) { return },
            { baseline_only => 1 }
        );
        is $current->stats->{baseline_tests}, 1,
          "changing the original $relative after copying invalidates its cached test";
    }
};

subtest 'a copied project link keeps its declared target even when two targets contain identical bytes' => sub {
    my $project = copy_of('calc');
    my $other   = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    write_file( "$project/linked/operand", "1\n" );
    write_file( "$other/linked/operand",   "1\n" );
    my $error = dies {
        Test::Mutation::run(
            root     => $project,
            cache    => 0,
            jobs     => 1,
            link     => ['linked'],
            on_event => sub ( $name, $data ) {
                return unless $name eq 'copy_finished';
                my $link = "$data->{root}/linked";
                unlink $link or die "unlink $link: $!";
                symlink "$other/linked", $link or die "link $link: $!";
                return;
            }
        );
    };
    like $error, qr/measurement inputs changed.*linked/, 'the prepared link must lead to its configured project path';
};

done_testing;
