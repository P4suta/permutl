use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use lib 't/e2e/lib';
use Fixture qw(ran run_fixture write_file);
use Test::Mutation::Merge;
use Test::Mutation::Report::Json;
use Test::Mutation::Source;

my $area = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );

subtest 'an opaque phase can change a package variable without changing the compiled program' => sub {
    my $root = "$area/global";
    local $ENV{TEST_PROJECT_TABLE} = "$area/global-limit";
    write_file( "$root/lib/Bound.pm", <<'PERL' );
package Bound;
our $LIMIT;
BEGIN {
    my $path = $ENV{TEST_PROJECT_TABLE};
    open my $input, '<', $path or die $!;
    $LIMIT = 0 + <$input>;
    close $input or die $!;
}
sub first { return $_[0] < $LIMIT }
sub second { return $_[0] < $LIMIT }
1;
PERL
    write_file( "$root/t/limit.t",
        "use Test::More tests => 2; use Bound; ok !Bound::first(7); ok !Bound::second(7);\n" );
    my @reports;
    for my $part ( 1, 2 ) {
        write_file( $ENV{TEST_PROJECT_TABLE}, $part == 1 ? "7\n" : "5\n" );
        my $dir = "$area/global-part$part";
        ran(
            0,          $root, 'run', '--shard', "$part/2", '--no-cache', '--jobs', 1,
            '--enable', 'comparison-boundary',
            ( map { ( '--disable', $_ ) } qw(@removal comparison-negation arithmetic logical) ),
            '--format', 'json', '--report-dir', $dir
        );
        my $file        = "$dir/mutation.json";
        my $part_result = Test::Mutation::Report::Json::parse( Test::Mutation::Source::read_bytes($file) );
        is [ map { $_->{status} } $part_result->entries->@* ], [ $part == 1 ? 'Killed' : 'Survived' ],
          'the test observes the value assigned during compilation';
        push @reports, $file;
    }
    my $merge = ran( 2, $root, 'merge', @reports, '--format', 'json', '--report-dir', "$area/global-joined" );
    like $merge->{stderr}, qr/measurement inputs are missing/, 'the compiled program cannot identify the phase input';
};

subtest 'loading Perl source can read external data at file scope' => sub {
    local $ENV{PERL5LIB}           = join q{:}, "$area/threshold", grep { defined } $ENV{PERL5LIB};
    local $ENV{TEST_PROJECT_TABLE} = "$area/table";
    my $initializer = <<'PERL';
my $path = $ENV{TEST_PROJECT_TABLE};
open my $input, '<', $path or die $!;
my $limit = 0 + <$input>;
close $input or die $!;
sub limit { return $limit }
PERL
    write_file( "$area/threshold/Threshold.pm", "package Threshold;\n${initializer}1;\n" );
    my $part = sub ( $root, $number ) {
        my ($result) = run_fixture(
            $root,
            jobs        => 1,
            cache       => 1,
            shard       => "$number/2",
            equivalence => 0,
            enable      => ['comparison-boundary'],
            disable     => [qw(@removal comparison-negation arithmetic logical)]
        );
        return { name => "$number", result => $result };
    };
    for my $reader (
        [ 'imported dependency', 'use Threshold ();', 'Threshold::limit()', 'lib/Bound.pm', 'use Bound;' ],
        [ 'selected module',     $initializer,        'limit()',            'lib/Bound.pm', 'use Bound;' ],
        [ 'required script',     $initializer, 'limit()', 'script/bounds', q{BEGIN { require './script/bounds' }} ]
      )
    {
        my ( $name, $load, $limit, $path, $require ) = @$reader;
        my $root = "$area/$name";
        write_file( "$root/t/check.t",
            "use Test::More tests => 2; $require ok !Bound::first(7); ok !Bound::second(7);\n" );
        write_file( "$root/$path",
                "#!$^X\npackage Bound;\n$load\n"
              . "sub first { return \$_[0] < $limit }\nsub second { return \$_[0] < $limit }\n1;\n" );
        write_file( $ENV{TEST_PROJECT_TABLE}, "7\n" );
        my $first = $part->( $root, 1 );
        is $part->( $root, 2 )->{result}->entries->[0]{status}, 'Killed',
          "the initial $name value distinguishes the boundary";
        write_file( $ENV{TEST_PROJECT_TABLE}, "5\n" );
        my $different = $part->( $root, 2 );
        is [ $different->{result}->entries->[0]{status}, $different->{result}->cache_mismatch ], [ 'Survived', 0 ],
          "the $name input is checked before sampling a cached observation";
        like dies { Test::Mutation::Merge::merge( [ $first, $different ] ) },
          qr/measurement inputs (?:are missing|differ)/,
          "a changed $name value makes the measurements incompatible";
    }
};

subtest 'a failed mutant compilation is checked again even with a verified original' => sub {
    my $root = "$area/mutant-check";
    write_file( "$root/lib/Bound.pm", <<'MODULE' );
package Bound;
BEGIN { die "broken\n" if 3 - 1 != 2 }
sub value { return 7 }
1;
MODULE
    write_file( "$root/t/use.t", "use Test::More tests => 1; use Bound; is Bound::value(), 7;\n" );
    for my $attempt ( 1, 2 ) {
        my ($result) = run_fixture(
            $root,
            jobs    => 1,
            cache   => 1,
            disable => [qw(@removal condition-negation comparison-negation)]
        );
        is [ map { [ $_->{mutant}->description, $_->{status} ] } $result->entries->@* ],
          [ [ 'replaced - with +', 'CompileError' ] ], "measurement $attempt observes the failing compile-time guard";
        is $result->reused, 0, 'a successful original does not certify the failed mutant';
    }
};

done_testing;
