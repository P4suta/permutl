use v5.36;
use Test2::V0;
use File::Temp ();
use lib 't/e2e/lib';
use Fixture qw(run_fixture write_file);
use Test::Mutation::Merge;

my $project = File::Temp::tempdir( CLEANUP => 1 );
write_file( "$project/lib/Offset.pm", <<'PERL' );
package Offset;
sub one { return $_[0] + 1 }
sub two { return $_[0] + 2 }
sub label { return "BEGIN $_[0]" }
1;
PERL
write_file( "$project/t/offset.t", <<'PERL' );
use Test::More tests => 3;
use Offset;
is Offset::one(4), 5;
is Offset::two(4), 6;
is Offset::label('work'), 'BEGIN work';
PERL

sub part ($number) {
    my ($report) = run_fixture( $project, jobs => 1, cache => 1, shard => "$number/2" );
    return { name => "part $number", result => $report };
}

my $one = part(1);
my $two = part(2);
ok lives { Test::Mutation::Merge::merge( [ $one, $two ] ) }, 'shards measured with the same quote parser merge';
my $warm = part(1)->{result};
is $warm->stats->{baseline_tests}, 0, 'the same parser reuses the original test';
ok $warm->reused, 'the same parser reuses the verdicts';

{
    local $PPIx::QuoteLike::VERSION = PPIx::QuoteLike->VERSION . '_001';
    my $changed = part(2);
    is $changed->{result}->catalog_digest, $one->{result}->catalog_digest,
      'a driver quote parser upgrade preserves the indexed catalog';
    is $changed->{result}->stats->{baseline_tests}, 1, 'the upgraded parser measures the original test again';
    is $changed->{result}->reused,                  0, 'the upgraded parser measures every selected mutant again';
    like dies { Test::Mutation::Merge::merge( [ $one, $changed ] ) }, qr/measurement inputs differ/,
      'shards from different driver quote parser versions cannot merge';
}

sub rechecks_compiler_parser ( $name, $upgraded ) {
    part(2);
    my $report = $upgraded->()->{result};
    is [ $report->stats->{baseline_tests}, $report->reused ], [ 1, 0 ],
      "a changed $name version rechecks the original test and its verdicts";
    return;
}

rechecks_compiler_parser(
    'PPI',
    sub {
        local $PPI::VERSION = PPI->VERSION . '_001';
        return part(2);
    }
);
rechecks_compiler_parser(
    'PPIx::Regexp',
    sub {
        local $PPIx::Regexp::VERSION = PPIx::Regexp->VERSION . '_001';
        return part(2);
    }
);

done_testing;
