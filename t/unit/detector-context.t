use v5.36;
use Test2::V0;
use Cwd        ();
use File::Temp ();
use lib 't/e2e/lib', 'xt/lib';
use Fixture qw(run_fixture write_file);
use SelfMeasurement;
use Test::Mutation::Report::Json;
use Test::Mutation::Select;
use Test::Mutation::Settings;

my $scratch = Cwd::abs_path( File::Temp::tempdir( CLEANUP => 1 ) );
my $body    = <<'BODY';
    my $left = $_[0];
    my $right = $_[1];
    my $sum = $left + $right;
    return $sum;
}
BODY
my $source = "package Example;\nsub sum {\n$body";
my $shift  = "\n\n\n";
my $weak   = "use Test::More tests => 1;\nuse Example;\nis Example::sum(4, 0), 4;\n";
my $strong = "use Test::More tests => 1;\nuse Example;\nis Example::sum(4, 1), 5;\n";

sub project ( $text, $tests, $path = 'lib/Example.pm' ) {
    my $root = File::Temp::tempdir( DIR => $scratch );
    write_file( "$root/$path", "$text\n1;\n" );
    write_file( "$root/$_",    $tests->{$_} ) for sort keys %$tests;
    return $root;
}

sub selection ($root) {
    my $config = Test::Mutation::Settings::of_call( { root => $root, cache => 0 } );
    return Test::Mutation::Select::resolve( config => $config, read_only => 1 );
}

sub additions ($selected) {
    return grep { $_->mutator eq 'arithmetic' } $selected->mutants->@*;
}

sub measure ( $root, @mutants ) {
    my ($result) = run_fixture( $root, cache => 0, jobs => 1, mutant => [ map { $_->id } @mutants ] );
    my $dir = File::Temp::tempdir( DIR => $scratch );
    my $report =
      write_file( "$dir/mutation.json", Test::Mutation::Report::Json::render( $result, high => 80, low => 60 ) );
    return ( $result, $report );
}

sub measured_report ($root) {
    my ($addition) = additions( selection($root) );
    my ( $result, $report ) = measure( $root, $addition );
    is $result->entries->[0]{status}, 'Killed', 'the earlier test actually detects the selected addition';
    return $report;
}

my %tests        = ( 't/a.t' => $weak, 't/z.t' => $strong );
my $previous     = measured_report( project( $source, \%tests ) );
my $current_root = project( "$shift$source", { %tests, 't/a.t' => $strong } );
my $current      = selection($current_root);
my ($addition)   = additions($current);
my $id           = $addition->id;
is SelfMeasurement::detector_hints( $current, $previous ), { $id => 't/z.t' },
  'a moved operator with one matching context can try a previous detector';

my $same_id = measured_report($current_root);
is SelfMeasurement::detector_hints( $current, $same_id, $previous ), { $id => 't/a.t' },
  'an exact ID takes priority over a later report for a different offset';
is SelfMeasurement::detector_hints( $current, $previous, $same_id ), { $id => 't/a.t' },
  'the same exact ID takes priority in either file order';

my $changed   = $source =~ s/\$left \+ \$right/\$left + abs(\$right)/r;
my $following = $source =~ s/return \$sum;/return int \$sum;/r;
my $duplicate = "$source\nsub also {\n$body";
for my $case (
    [ project( "$shift$source", \%tests, 'lib/Renamed.pm' ), 'the expression belongs to another file' ],
    [ project( "$shift$changed",   \%tests ),              'the moved expression changed' ],
    [ project( "$shift$following", \%tests ),              'a line following the moved expression changed' ],
    [ project( "$shift$duplicate", \%tests ),              'the current source has two identical contexts' ],
    [ project( "$shift$source",    { 't/a.t' => $weak } ), 'the earlier detecting test is absent' ],
  )
{
    my $hints;
    my $selected = selection( $case->[0] );
    is warnings { $hints = SelfMeasurement::detector_hints( $selected, $previous ) }, [],
      "ignoring the earlier test is silent when $case->[1]";
    is $hints, {}, $case->[1];
}
my $ambiguous = measured_report( project( "\n$duplicate", \%tests ) );
is SelfMeasurement::detector_hints( $current, $ambiguous ), {},
  'a report of one mutant includes the entire earlier source with both identical contexts';

subtest 'all useful observations from the same report remain available' => sub {
    my $root = File::Temp::tempdir( DIR => $scratch );
    my $text = sub ($name) { return "package $name;\nsub sum {\n$body\n1;\n" };
    write_file( "$root/lib/$_.pm", $text->($_) ) for qw(Alpha Beta Gamma);
    write_file( "$root/t/all.t",   <<'PERL' );
use Test::More tests => 3;
use Alpha;
use Beta;
use Gamma;
is Alpha::sum(4, 0), 4;
is Beta::sum(4, 1), 5;
is Gamma::sum(4, 1), 5;
PERL
    my ( $before, $report ) = measure( $root, additions( selection($root) ) );
    is [ map { $_->{status} } $before->entries->@* ], [qw(Survived Killed Killed)],
      'the test misses the first addition and detects both later additions';
    write_file( "$root/lib/Gamma.pm", $shift . $text->('Gamma') );
    my $selected = selection($root);
    my ( $alpha, $beta, $gamma ) = additions($selected);
    is SelfMeasurement::detector_hints( $selected, $report ), { $beta->id => 't/all.t', $gamma->id => 't/all.t' },
      'a missed mutant and an exact ID can precede the one that moved';
    unlink "$root/lib/Beta.pm" or die "remove Beta: $!";
    write_file( "$root/t/all.t", "use Test::More tests => 1;\nuse Gamma;\nis Gamma::sum(4, 1), 5;\n" );
    is SelfMeasurement::detector_hints( selection($root), $report ), { $gamma->id => 't/all.t' },
      'a deleted file can precede a surviving file in a report';
};

subtest 'two replacements at the same position retain their own detecting tests' => sub {
    my $text = 'package Example; sub matches { return $_[0] =~ /(?im:^abc$)/ }';
    my $root = project(
        $text,
        {
            't/case.t'  => "use Test::More tests => 1; use Example; ok Example::matches('ABC');\n",
            't/lines.t' => q{use Test::More tests => 1; use Example; ok Example::matches("before\nabc\nafter");} . "\n",
        }
    );
    write_file( "$root/mutation.toml", qq{enable = ["regex-flag"]\n} );
    my $variants = sub ($selected) {
        return grep { $_->mutator eq 'regex-flag' && $_->original eq '?im:' } $selected->mutants->@*;
    };
    my %expected = ( '?m:' => 't/case.t', '?i:' => 't/lines.t' );
    my ( $before, $report ) = measure( $root, $variants->( selection($root) ) );
    is {
        map { $_->{mutant}->replacement => [ $_->{status}, $_->{by} ] } $before->entries->@*
    },
      { map { $_ => [ 'Killed', $expected{$_} ] } keys %expected },
      'removing each scoped flag breaks only its own test';
    write_file( "$root/lib/Example.pm", "$shift$text\n1;\n" );
    my $selected = selection($root);
    is SelfMeasurement::detector_hints( $selected, $report ),
      { map { $_->id => $expected{ $_->replacement } } $variants->($selected) },
      'the moved flags select the test that actually detected each replacement';
};

subtest 'a half-open span ends on its last changed line' => sub {
    my $text        = $source . "our \$neighbor = 1;\nour \$revision = 1;\n";
    my $root        = project( $text, { 't/sum.t' => $strong } );
    my $body_mutant = sub ($selected) {
        return ( grep { $_->mutator eq 'sub-body' } $selected->mutants->@* )[0];
    };
    my $earlier = $body_mutant->( selection($root) );
    is $earlier->to->[1], 1, 'the removed body ends before the closing brace at the start of the next line';
    my ( $before, $report ) = measure( $root, $earlier );
    is $before->entries->[0]{status}, 'Killed', 'removing the body actually breaks the sum test';
    $text =~ s/\$revision = 1/\$revision = 2/;
    write_file( "$root/lib/Example.pm", "$shift$text\n1;\n" );
    my $selected = selection($root);
    is SelfMeasurement::detector_hints( $selected, $report ), { $body_mutant->($selected)->id => 't/sum.t' },
      'an edit three lines after the last changed line leaves two neighboring lines unchanged';
};

done_testing;
