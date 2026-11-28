use v5.36;
use Test2::V0;
use File::Temp ();
use lib 't/e2e/lib', 't/lib';
use Capability;
use Fixture qw(copy_of run_fixture statuses write_file);

Capability::need( 'class', $] >= 5.038, 'the fixture needs the class syntax of Perl 5.38' );

my ($result) = run_fixture( copy_of('counter') );

is statuses($result),
  {
    'lib/Counter.pm:6 replaced + with -'                        => 'Survived',
    'lib/Counter.pm:8 removed the body of ADJUST'               => 'Survived',
    'lib/Counter.pm:9 removed the statement'                    => 'Survived',
    'lib/Counter.pm:9 replaced + with -'                        => 'Survived',
    'lib/Counter.pm:12 removed the body of bump'                => 'Killed',
    'lib/Counter.pm:13 removed the statement'                   => 'Killed',
    'lib/Counter.pm:13 replaced += with -='                     => 'Killed',
    'lib/Counter.pm:14 removed the return value'                => 'Killed',
    'lib/Counter.pm:17 removed the body of count'               => 'Killed',
    'lib/Counter.pm:17 removed the return value'                => 'Killed',
    'lib/Counter.pm:19 removed the body of limit'               => 'NoCoverage',
    'lib/Counter.pm:19 removed the return value'                => 'NoCoverage',
    'lib/Counter.pm:21 removed the body of size'                => 'Killed',
    'lib/Counter.pm:21 removed the return value'                => 'Killed',
    'lib/Counter.pm:21 replaced > with <='                      => 'Killed',
    'lib/Counter.pm:21 replaced > with >='                      => 'Ignored',
    'lib/Counter.pm:21 swapped the branches of the conditional' => 'Killed',
  },
  'a change in a field or an ADJUST block survives, and a change in a method compares its compiled code';
is $result->warnings, [], 'no warning';

subtest 'a class can read an external limit when the test loads its module' => sub {
    my $root  = copy_of('counter');
    my $table = File::Temp->new;
    local $ENV{COUNTER_SETTING} = $table->filename;
    write_file( "$root/lib/Counter.pm", <<'PERL' );
use v5.38;
use experimental 'class';
class Counter {
    method below ($n) { return $n < $Counter::LIMIT }
    open my $data, '<', $ENV{COUNTER_SETTING} or die $!;
    $Counter::LIMIT = <$data>;
}
1;
PERL
    write_file( "$root/t/counter.t", "use Test::More tests => 1; use Counter; ok !Counter->new->below(7);\n" );
    for my $case ( [ 7, 'Killed' ], [ 5, 'Survived' ] ) {
        write_file( $table->filename, "$case->[0]\n" );
        my ($run) = run_fixture(
            $root,
            jobs        => 1,
            cache       => 1,
            shard       => '1/1',
            equivalence => 0,
            disable     => [qw(@removal comparison-negation logical)]
        );
        is [ map { $_->{status} } grep { $_->{mutant}->description eq 'replaced < with <=' } $run->entries->@* ],
          [ $case->[1] ],
          'the comparison uses the present file contents even after a cached run';
        is $run->reused,             0,     'a file read outside the compiler cannot certify a cached class verdict';
        is $run->measurement_digest, undef, 'a shard cannot bind unknown class initialization inputs';
    }
};

done_testing;
