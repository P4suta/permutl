use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use lib 't/e2e/lib';
use Fixture qw(run_fixture write_file);
use Test::Mutation::Merge;

subtest 'a phase hidden in an imported subroutine changes observable verdicts' => sub {
    my $area = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
    my $root = "$area/project";
    local $ENV{PERL5OPT}            = '-Mstrict';
    local $ENV{PERL5LIB}            = join q{:}, "$area/modules", grep { defined } $ENV{PERL5LIB};
    local $ENV{TEST_EMBEDDED_LIMIT} = write_file( "$area/limit", "7\n" );
    write_file( "$area/modules/EmbeddedConfig.pm", <<'PERL' );
package EmbeddedConfig;
sub description {
    return qr/(?{ BEGIN {
        open my $input, '<', $ENV{TEST_EMBEDDED_LIMIT} or die $!;
        $EmbeddedConfig::LIMIT = 0 + <$input>;
        close $input or die $!;
    } 1 })/;
}
sub limit { return $EmbeddedConfig::LIMIT }
1;
PERL
    write_file( "$root/lib/Bound.pm", <<'PERL' );
package Bound;
use EmbeddedConfig ();
sub first { return $_[0] < EmbeddedConfig::limit() }
sub second { return $_[0] < EmbeddedConfig::limit() }
1;
PERL
    write_file( "$root/t/check.t", <<'PERL' );
use Test::More tests => 2;
use Bound;
ok !Bound::first(7);
ok !Bound::second(7);
PERL
    my $measure = sub ( $part, $cache ) {
        my ($result) = run_fixture(
            $root,
            shard   => "$part/2",
            cache   => $cache,
            jobs    => 1,
            enable  => ['comparison-boundary'],
            disable => [qw(@removal arithmetic comparison-negation logical)]
        );
        return $result;
    };
    my $original = $measure->( 1, 1 );
    is [ map { $_->{status} } $original->entries->@* ], ['Killed'], 'the test detects the inclusive boundary at seven';
    write_file( $ENV{TEST_EMBEDDED_LIMIT}, "5\n" );
    my $warm = $measure->( 1, 1 );
    my $peer = $measure->( 2, 0 );
    is [ map { $_->{status} } $warm->entries->@* ], ['Survived'], 'a warm run measures the new limit';
    is [ $warm->reused, $warm->cache_mismatch ],    [ 0, 0 ],     'the cached verdict is ineligible before sampling';
    is [ map { $_->{status} } $peer->entries->@* ], ['Survived'], 'a cold peer observes the same new limit';
    like dies {
        Test::Mutation::Merge::merge(
            [ { name => 'before', result => $original }, { name => 'after', result => $peer } ] )
    }, qr/measurement inputs are missing/, 'the old and new unverified limits cannot certify a combined score';

    write_file( "$area/modules/EmbeddedConfig.pm", <<'PERL' );
package EmbeddedConfig;
sub limit { my %labels = (BEGIN => 7); return "$labels{BEGIN}" }
1;
PERL
    my $stable = $measure->( 1, 1 );
    is $measure->( 1, 1 )->reused, 1, 'interpolating a literal key permits reuse of a verified verdict';
    my $other  = $measure->( 2, 0 );
    my $merged = Test::Mutation::Merge::merge(
        [ { name => 'first', result => $stable }, { name => 'second', result => $other } ] );
    is [ map { $_->{status} } $merged->entries->@* ], [qw(Killed Killed)],
      'both shards certify their observed boundaries';
};

done_testing;
